import Foundation

/// What prompted a snapshot.
public enum Event: String, Sendable, CaseIterable {
    /// You sent the agent a prompt.
    case prompt
    /// The agent was about to use a tool: edit a file, run a command.
    case tool
    /// The agent finished a turn.
    case turn
    /// `mulligan run` or `watch` saw files change.
    case watch
    /// You ran `mulligan snap`.
    case manual
    /// Taken just before an undo, redo or restore, so it can be undone too.
    case restore
}

/// One point on the timeline: every file in the project as it was then.
public struct Snapshot: Sendable, Equatable {
    public let id: Int
    public let commit: String
    public let tree: String
    public let date: Date
    public let label: String
    public let agent: String?
    public let event: Event?
    /// How many files were left out because they were too big or not regular files.
    public let skipped: Int
}

/// A file left out of a snapshot, and why.
public struct Skipped: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case tooBig(Int64)
        case nestedRepository
        case notAFile
        /// It can't be read, or git won't take its name (like `git~1` or `.git.`).
        case unreadable
    }
    public let path: String
    public let reason: Reason
}

/// What taking a snapshot did.
public struct SnapshotResult: Sendable {
    public let snapshot: Snapshot
    /// False when nothing had changed since the latest snapshot, which is returned instead.
    public let created: Bool
    public let skipped: [Skipped]
}

/// What a snapshot is labeled with and where it came from.
public struct SnapshotRequest: Sendable {
    public var label: String
    public var agent: String?
    public var event: Event

    public init(label: String, agent: String? = nil, event: Event) {
        self.label = label
        self.agent = agent
        self.event = event
    }
}

extension Store {
    static let refPrefix = "refs/undo/"

    static func refName(_ id: Int) -> String { refPrefix + String(id).leftPadded(to: 8) }

    // MARK: - Reading the timeline

    /// Every snapshot, oldest first.
    public func snapshots() throws -> [Snapshot] {
        guard exists else { return [] }
        let format = "%(refname)%00%(objectname)%00%(tree)%00%(creatordate:unix)%00%(contents)%1e"
        let text = try git.text(["for-each-ref", "--format=\(format)", Self.refPrefix])
        var result: [Snapshot] = []
        for record in text.split(separator: "\u{1e}") {
            let fields = record.split(separator: "\0", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5 else { continue }
            let name = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.hasPrefix(Self.refPrefix), let id = Int(name.dropFirst(Self.refPrefix.count)) else { continue }
            let message = Self.parse(message: fields[4])
            result.append(Snapshot(
                id: id, commit: fields[1], tree: fields[2],
                date: Date(timeIntervalSince1970: TimeInterval(fields[3]) ?? 0),
                label: message.label, agent: message.agent, event: message.event, skipped: message.skipped
            ))
        }
        return result.sorted { $0.id < $1.id }
    }

    /// The snapshot with this number.
    public func snapshot(_ id: Int) throws -> Snapshot {
        guard let found = try snapshots().first(where: { $0.id == id }) else { throw UndoError.noSuchSnapshot("#\(id)") }
        return found
    }

    static func message(for request: SnapshotRequest, skipped: Int) -> String {
        var lines = [Text.line(request.label, limit: 200).isEmpty ? request.event.rawValue : Text.line(request.label, limit: 200), ""]
        if let agent = request.agent, !agent.isEmpty { lines.append("Agent: \(Text.line(agent, limit: 40))") }
        lines.append("Event: \(request.event.rawValue)")
        if skipped > 0 { lines.append("Skipped: \(skipped)") }
        return lines.joined(separator: "\n") + "\n"
    }

    static func parse(message: String) -> (label: String, agent: String?, event: Event?, skipped: Int) {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var agent: String?
        var event: Event?
        var skipped = 0
        for line in lines.dropFirst() {
            if line.hasPrefix("Agent: ") { agent = String(line.dropFirst(7)) }
            if line.hasPrefix("Event: ") { event = Event(rawValue: String(line.dropFirst(7))) }
            if line.hasPrefix("Skipped: ") { skipped = Int(line.dropFirst(9)) ?? 0 }
        }
        return (Text.safe(lines.first ?? ""), agent.map(Text.safe), event, skipped)
    }

    // MARK: - Taking snapshots

    /// Takes a snapshot of the project's files, unless nothing changed since the latest one.
    public func snapshot(_ request: SnapshotRequest) throws -> SnapshotResult {
        if !exists { try create() }
        return try withLock {
            let result = try snapshotLocked(request)
            if result.created { try? pruneLocked(now: Date(), after: result.snapshot.id) }
            return result
        }
    }

    func snapshotLocked(_ request: SnapshotRequest) throws -> SnapshotResult {
        let (tree, skipped) = try stage()
        let all = try snapshots()
        if let latest = all.last, latest.tree == tree {
            return SnapshotResult(snapshot: latest, created: false, skipped: skipped)
        }
        // Before a restore, files that already match a snapshot are safe as they are, so undoing
        // and redoing back and forth doesn't fill the timeline with copies.
        if request.event == .restore, let same = all.last(where: { $0.tree == tree }) {
            return SnapshotResult(snapshot: same, created: false, skipped: skipped)
        }
        let id = nextID(after: all.last?.id ?? 0)
        let message = Self.message(for: request, skipped: skipped.count)
        do {
            let commit = try git.text(["commit-tree", tree, "-F", "-"], input: Data(message.utf8))
            try git.run(["update-ref", Self.refName(id), commit, ""])
            try write("\(id + 1)\n", to: nextIDFile)
        } catch let error as GitError {
            throw UndoError.snapshotFailed(error.description)
        }
        return SnapshotResult(snapshot: try snapshot(id), created: true, skipped: skipped)
    }

    func nextID(after latest: Int) -> Int {
        let recorded = read(nextIDFile).flatMap { Int($0) } ?? 1
        return max(recorded, latest + 1, 1)
    }

    /// Brings the store's index up to date with the project's files and returns the tree they
    /// make, with the files that were left out. Throws if git can't read the files, and changes
    /// nothing in the project either way.
    func stage() throws -> (tree: String, skipped: [Skipped]) {
        do {
            return try stageOnce()
        } catch {
            // A file that vanished between listing and adding is the usual cause; one retry sorts it.
            do {
                return try stageOnce()
            } catch let error as GitError {
                throw UndoError.snapshotFailed(error.description)
            }
        }
    }

    private func stageOnce() throws -> (tree: String, skipped: [Skipped]) {
        try writeAttributes()
        try writeExcludes()
        var skipped: [Skipped] = []
        var leaveOut: [String] = []

        // Files the store doesn't have yet: new ones, nested repositories (listed as "dir/"),
        // and anything that isn't a plain file or a link.
        for path in try git.run(["ls-files", "-z", "--others", "--exclude-standard"]).nulSeparated() {
            if path.hasSuffix("/") {
                let folder = String(path.dropLast())
                skipped.append(Skipped(path: folder, reason: .nestedRepository))
                leaveOut.append(folder)
                continue
            }
            if let reason = leaveOutReason(path) {
                skipped.append(Skipped(path: path, reason: reason))
                leaveOut.append(path)
            }
        }
        // Files the store has that changed, which may have grown too big or become unreadable.
        for path in try git.run(["ls-files", "-z", "--modified"]).nulSeparated() {
            if let reason = leaveOutReason(path), !leaveOut.contains(path) {
                skipped.append(Skipped(path: path, reason: reason))
                leaveOut.append(path)
            }
        }
        // A file git refuses (a name it won't store, or one that vanished or can't be read) mustn't
        // stop every snapshot: it's left out like any other, and the rest are saved.
        for _ in 0..<20 {
            try dropFromIndex(leaveOut)
            let pathspecs = ["."] + leaveOut.map { ":(exclude,literal)" + $0 }
            do {
                try git.run(["add", "--all", "--pathspec-from-file=-", "--pathspec-file-nul"], input: Data(pathspecs.map { $0 + "\0" }.joined().utf8))
                break
            } catch let error as GitError {
                let refused = Self.refusedPaths(in: error.message).filter { !leaveOut.contains($0) }
                guard !refused.isEmpty else { throw error }
                for path in refused {
                    skipped.append(Skipped(path: path, reason: .unreadable))
                    leaveOut.append(path)
                }
            }
        }
        let tree = try git.text(["write-tree"])
        return (tree, skipped.sorted { $0.path < $1.path })
    }

    /// Takes left-out paths out of the store's index too, so an old copy isn't passed off as current.
    func dropFromIndex(_ leaveOut: [String]) throws {
        guard !leaveOut.isEmpty else { return }
        let tracked = try git.run(["ls-files", "-z", "--cached"]).nulSeparated()
        let drop = tracked.filter { path in leaveOut.contains { path == $0 || path.hasPrefix($0 + "/") } }
        guard !drop.isEmpty else { return }
        try git.run(["update-index", "-z", "--force-remove", "--stdin"], input: Data(drop.map { $0 + "\0" }.joined().utf8))
    }

    /// The paths in git's complaints about files it couldn't add.
    static func refusedPaths(in message: String) -> [String] {
        var paths: [String] = []
        for line in message.split(separator: "\n").map(String.init) {
            for (start, end) in [("invalid path '", "'"), ("open(\"", "\")"), ("unable to index file '", "'"), ("unable to stat '", "'"), ("short read while indexing ", "")] {
                guard let range = line.range(of: start) else { continue }
                var path = String(line[range.upperBound...])
                if !end.isEmpty, let close = path.range(of: end, options: .backwards) { path = String(path[..<close.lowerBound]) }
                path = path.trimmingCharacters(in: .whitespaces)
                if !path.isEmpty, !path.hasPrefix("/") { paths.append(path) }
            }
        }
        return paths
    }

    /// Why a file is left out of snapshots, or nil if it goes in.
    func leaveOutReason(_ path: String) -> Skipped.Reason? {
        var info = stat()
        guard lstat(root + "/" + path, &info) == 0 else { return nil }
        let kind = FileKind(mode: info.st_mode)
        if kind == .link { return nil }
        if kind == .folder { return .nestedRepository }
        guard kind == .file else { return .notAFile }
        let size = Int64(info.st_size)
        if size > settings.maxFileBytes { return .tooBig(size) }
        return access(root + "/" + path, R_OK) == 0 ? nil : .unreadable
    }

    /// The store's ignore list: a few files nobody wants back, plus the project's own
    /// `.git/info/exclude`, which is read and never changed.
    func writeExcludes() throws {
        var lines = ["# Written by mulligan. The project's .gitignore files apply as well.", ".DS_Store"]
        if let projectExcludes = projectInfoExclude() {
            lines.append("# From the project's .git/info/exclude")
            lines.append(projectExcludes)
        }
        let text = lines.joined(separator: "\n") + "\n"
        let path = gitDir + "/info/exclude"
        if FileManager.default.contents(atPath: path) == Data(text.utf8) { return }
        try makePrivateFolder(gitDir + "/info")
        try write(text, to: path)
    }

    /// The project repository's `info/exclude`, following a `.git` file to the real repository
    /// for worktrees and submodules.
    func projectInfoExclude() -> String? {
        let dotGit = root + "/.git"
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit, isDirectory: &isFolder) else { return nil }
        var gitDirectory = dotGit
        if !isFolder.boolValue {
            guard let pointer = read(dotGit), pointer.hasPrefix("gitdir:") else { return nil }
            let target = pointer.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            gitDirectory = target.hasPrefix("/") ? target : Paths.clean(root + "/" + target)
            if let common = read(gitDirectory + "/commondir") {
                gitDirectory = common.hasPrefix("/") ? common : Paths.clean(gitDirectory + "/" + common)
            }
        }
        // Only a plain file is read: never a link, a pipe or a device, which could point anywhere or hang.
        let excludePath = gitDirectory + "/info/exclude"
        guard FileKind(path: excludePath) == .file,
              let data = FileManager.default.contents(atPath: excludePath), data.count < 1 << 20 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The tree the project's files make right now, without recording a snapshot.
    public func currentTree() throws -> (tree: String, skipped: [Skipped]) {
        if !exists { try create() }
        return try withLock { try stage() }
    }
}
