import Foundation

/// A file a restore left alone, and why.
public struct Kept: Sendable, Equatable {
    public let path: String
    public let reason: String
}

/// One file a restore or a diff between snapshots touches.
public struct Change: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case added, modified, deleted }
    public let kind: Kind
    public let path: String
}

/// What a restore did.
public struct RestoreResult: Sendable {
    /// The snapshot holding your files as they were just before, so the restore can be undone.
    public let before: Snapshot
    /// The snapshot the files came from.
    public let target: Snapshot
    /// What changed in your files.
    public let changes: [Change]
    /// Files left as they were, because the snapshot taken just before couldn't hold them.
    public let kept: [Kept]
    /// Set when the files didn't end up exactly as planned, most likely because something was
    /// writing to them at the same time.
    public let warning: String?
}

/// Where undo and redo left your files, and what redo can bring back.
struct Position: Equatable {
    /// The snapshot your files were put back to.
    var id: Int
    /// The tree they made then, to tell whether anything changed since.
    var tree: String
    /// The newest snapshot when that happened.
    var mark: Int
    /// Snapshots redo brings back, the next one last.
    var redo: [Int]

    var text: String { "position \(id) \(tree) \(mark)\nredo \(redo.map(String.init).joined(separator: " "))\n" }

    init(id: Int, tree: String, mark: Int, redo: [Int]) {
        self.id = id
        self.tree = tree
        self.mark = mark
        self.redo = redo
    }

    init?(text: String) {
        let lines = text.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        guard let first = lines.first, first.count == 4, first[0] == "position",
              let id = Int(first[1]), let mark = Int(first[3]) else { return nil }
        self.id = id
        self.tree = first[2]
        self.mark = mark
        self.redo = lines.dropFirst().first.map { $0.dropFirst().compactMap { Int($0) } } ?? []
    }
}

extension Store {
    // MARK: - Undo and redo

    /// Puts your files back one step: to the snapshot before the latest change, or, right after
    /// an undo, to the one before that. With an id, to that snapshot.
    public func undo(to id: Int? = nil) throws -> RestoreResult {
        guard exists else { throw UndoError.noSnapshots(root) }
        return try withLock {
            let all = try snapshots()
            guard !all.isEmpty else { throw UndoError.noSnapshots(root) }
            let (current, _) = try stage()
            let position = readPosition()
            // Unchanged only if the files match where the undo left them and nothing different
            // has been snapshotted since, even if it was changed back.
            let unchangedSinceUndo = position.map { position in
                position.tree == current && all.allSatisfy { $0.id <= position.mark || $0.tree == position.tree }
            } ?? false

            let target: Snapshot
            if let id {
                guard let found = all.first(where: { $0.id == id }) else { throw UndoError.noSuchSnapshot("#\(id)") }
                target = found
            } else if let position, unchangedSinceUndo {
                guard let found = all.last(where: { $0.id < position.id && $0.tree != current }) else { throw UndoError.nothingToUndo }
                target = found
            } else if let position, position.tree != current, let back = all.first(where: { $0.id == position.id }) {
                // Files changed since the last undo: step back through what happened after it,
                // then to where that undo left them.
                target = all.last(where: { $0.id > position.mark && $0.tree != current }) ?? back
            } else {
                guard let found = all.last(where: { $0.tree != current }) else { throw UndoError.nothingToUndo }
                target = found
            }
            var redo = unchangedSinceUndo ? (position?.redo ?? []) : []
            let result = try restoreLocked(to: target, paths: nil, label: "before undo to #\(target.id)") { before in
                redo.append(before.id)
            }
            let latest = (try? snapshots().last?.id) ?? result.before.id
            writePosition(Position(id: target.id, tree: (try? stage().tree) ?? target.tree, mark: latest, redo: redo))
            return result
        }
    }

    /// Takes back the last undo.
    public func redo() throws -> RestoreResult {
        guard exists else { throw UndoError.noSnapshots(root) }
        return try withLock {
            guard var position = readPosition(), !position.redo.isEmpty else {
                throw UndoError.nothingToRedo("there's no undo to take back.")
            }
            let (current, _) = try stage()
            let all = try snapshots()
            guard position.tree == current, all.allSatisfy({ $0.id <= position.mark || $0.tree == position.tree }) else {
                throw UndoError.nothingToRedo("your files changed since the last undo. `mulligan list` still has every snapshot, including the one taken just before the undo.")
            }
            let id = position.redo.removeLast()
            guard let target = all.first(where: { $0.id == id }) else {
                writePosition(position)
                throw UndoError.nothingToRedo("snapshot #\(id) has since been cleared away.")
            }
            let result = try restoreLocked(to: target, paths: nil, label: "before redo to #\(target.id)") { _ in }
            position.id = target.id
            position.tree = (try? stage().tree) ?? target.tree
            writePosition(position)
            return result
        }
    }

    /// Puts some files or folders back as they were in a snapshot, leaving everything else as
    /// it is. Paths are relative to the project.
    public func restore(_ paths: [String], from id: Int) throws -> RestoreResult {
        guard exists else { throw UndoError.noSnapshots(root) }
        return try withLock {
            let target = try snapshot(id)
            let result = try restoreLocked(to: target, paths: paths, label: "before restoring files from #\(id)") { _ in }
            // Your files now match no snapshot, so the next undo takes this restore back.
            clearPosition()
            return result
        }
    }

    // MARK: - Restoring

    /// The one place files are changed. Takes a snapshot of your files first, then moves them
    /// from that snapshot to the target with git's two-tree update, which only replaces or
    /// removes files whose contents are in one of the two. Anything on disk the first snapshot
    /// couldn't hold (ignored, too big, a nested repository) is kept out of the way.
    func restoreLocked(to target: Snapshot, paths: [String]?, label: String, recordBefore: (Snapshot) -> Void) throws -> RestoreResult {
        let before: Snapshot
        do {
            before = try snapshotLocked(SnapshotRequest(label: label, event: .restore)).snapshot
        } catch let error as UndoError {
            throw UndoError.restoreFailed("The snapshot taken first failed: \(error)")
        }
        recordBefore(before)
        let from = before.tree

        do {
            var goal = target.tree
            if let paths {
                let fromEntries = try entries(of: from)
                let targetEntries = try entries(of: target.tree)
                for path in paths where path.isEmpty == false {
                    let inEither = fromEntries.keys.contains { $0 == path || $0.hasPrefix(path + "/") }
                        || targetEntries.keys.contains { $0 == path || $0.hasPrefix(path + "/") }
                    guard inEither else { throw UndoError.notInSnapshot(path, target.id) }
                }
                goal = try combine(base: from, taking: paths.contains("") ? [""] : paths, from: target.tree)
            }
            let fromEntries = try entries(of: from)
            let kept = protectedPaths(from: fromEntries, to: try entries(of: goal))
            if !kept.isEmpty {
                goal = try combine(base: goal, taking: kept.map(\.path), from: from)
            }
            let changes = try self.changes(from: from, to: goal)
            if !changes.isEmpty {
                do {
                    try git.run(["read-tree", "-m", "-u", from, goal])
                } catch let error as GitError {
                    // Git checks everything before writing, so this usually means nothing was
                    // written. If it stopped partway, the first snapshot has every file.
                    throw UndoError.restoreStopped(error.description, before.id)
                }
            }
            // Files that only appear because a restored .gitignore stopped ignoring them aren't a
            // problem; files that differ from what was written are.
            var warning: String?
            if let after = try? stage().tree, after != goal,
               try self.changes(from: goal, to: after).contains(where: { $0.kind != .added }) {
                warning = "Some files changed while they were being restored, probably because something was writing to them. Your files as they were before are in snapshot #\(before.id)."
            }
            return RestoreResult(before: before, target: target, changes: changes, kept: kept, warning: warning)
        } catch let error as GitError {
            throw UndoError.restoreFailed(error.description)
        }
    }

    /// Paths the goal would change where the disk holds something the snapshot taken just
    /// before doesn't, so replacing it couldn't be undone. They're left as they are.
    func protectedPaths(from: [String: TreeEntry], to goal: [String: TreeEntry]) -> [Kept] {
        let ignoreCase = (try? git.text(["config", "--bool", "core.ignoreCase"])) == "true"
        let lowered = ignoreCase ? Set(from.keys.map { $0.lowercased() }) : []
        func saved(_ path: String) -> Bool {
            from[path] != nil || (ignoreCase && lowered.contains(path.lowercased()))
        }
        var kept: [String: String] = [:]
        func isKept(_ path: String) -> Bool {
            kept[path] != nil || Paths.parents(path).contains { kept[$0] != nil }
        }

        for (path, entry) in goal.sorted(by: { $0.key < $1.key }) where from[path] != entry {
            if isKept(path) { continue }
            var blocked = false
            var parentReplaced = false
            for folder in Paths.parents(path) {
                let kind = FileKind(path: root + "/" + folder)
                if kind == .missing { break }
                if kind == .folder { continue }
                if saved(folder) {
                    // A saved file or link is in the way; git replaces it with the folder, so
                    // nothing below it exists yet. (Looking below a link would look outside.)
                    parentReplaced = true
                } else {
                    kept[folder] = "it's in the way of files in the snapshot, and isn't in the snapshot taken just before (ignored, too big, or not a regular file)"
                    blocked = true
                }
                break
            }
            if blocked || parentReplaced { continue }
            switch FileKind(path: root + "/" + path) {
            case .missing:
                continue
            case .folder:
                if let reason = unsavedContents(of: path, saved: saved) { kept[path] = reason }
            default:
                if !saved(path) {
                    kept[path] = "it isn't in the snapshot taken just before (ignored, too big, or not a regular file), so replacing it couldn't be undone"
                }
            }
        }
        return kept.map { Kept(path: $0.key, reason: $0.value) }.sorted { $0.path < $1.path }
    }

    /// Why a folder that a file would replace can't be cleared, or nil if everything in it is
    /// in the snapshot taken just before.
    func unsavedContents(of folder: String, saved: (String) -> Bool) -> String? {
        guard let walker = FileManager.default.enumerator(atPath: root + "/" + folder) else { return nil }
        while let name = walker.nextObject() as? String {
            let path = folder + "/" + name
            switch FileKind(path: root + "/" + path) {
            case .folder:
                if FileKind(path: root + "/" + path + "/.git") != .missing {
                    return "it holds a nested git repository, which snapshots leave alone"
                }
            case .missing:
                continue
            default:
                if !saved(path) {
                    return "it holds files that aren't in the snapshot taken just before, like \(Text.safe(path))"
                }
            }
        }
        return nil
    }

    // MARK: - Trees

    struct TreeEntry: Equatable {
        var mode: String
        var object: String
    }

    /// Every file in a tree, with its mode and contents' id.
    func entries(of tree: String) throws -> [String: TreeEntry] {
        var result: [String: TreeEntry] = [:]
        for record in try git.run(["ls-tree", "-r", "-z", "--full-tree", tree]).nulSeparated() {
            guard let tab = record.firstIndex(of: "\t") else { continue }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3 else { continue }
            result[String(record[record.index(after: tab)...])] = TreeEntry(mode: String(fields[0]), object: String(fields[2]))
        }
        return result
    }

    /// A tree that's `base`, except at and under `paths`, where it's whatever `source` has
    /// there, including nothing. Built in a scratch index, so the store's own isn't disturbed.
    func combine(base: String, taking paths: [String], from source: String) throws -> String {
        let scratch = gitDir + "/index-combine-\(getpid())"
        defer { unlink(scratch) }
        func matches(_ path: String) -> Bool {
            paths.contains { $0.isEmpty || path == $0 || path.hasPrefix($0 + "/") }
        }
        try git.run(["read-tree", base], indexFile: scratch)
        let drop = try git.run(["ls-files", "-z", "--cached"], indexFile: scratch).nulSeparated().filter(matches)
        if !drop.isEmpty {
            try git.run(["update-index", "-z", "--force-remove", "--stdin"], input: Data(drop.map { $0 + "\0" }.joined().utf8), indexFile: scratch)
        }
        let add = try git.run(["ls-tree", "-r", "-z", "--full-tree", source]).nulSeparated().filter { record in
            guard let tab = record.firstIndex(of: "\t") else { return false }
            return matches(String(record[record.index(after: tab)...]))
        }
        if !add.isEmpty {
            try git.run(["update-index", "-z", "--index-info"], input: Data(add.map { $0 + "\0" }.joined().utf8), indexFile: scratch)
        }
        return try git.text(["write-tree"], indexFile: scratch)
    }

    /// What differs between two trees, file by file.
    public func changes(from: String, to: String) throws -> [Change] {
        if from == to { return [] }
        let fields = try git.run(["diff-tree", "-r", "-z", "--no-renames", "--name-status", from, to]).nulSeparated()
        var result: [Change] = []
        var index = 0
        while index + 1 < fields.count {
            let kind: Change.Kind
            switch fields[index].first {
            case "A": kind = .added
            case "D": kind = .deleted
            default: kind = .modified
            }
            result.append(Change(kind: kind, path: fields[index + 1]))
            index += 2
        }
        return result
    }

    // MARK: - Position

    func readPosition() -> Position? {
        read(positionFile).flatMap { Position(text: $0) }
    }

    func writePosition(_ position: Position) {
        try? write(position.text, to: positionFile)
    }

    func clearPosition() {
        unlink(positionFile)
    }

    /// The snapshot your files match right now, if an undo or redo put them there.
    public func currentPosition() -> Int? {
        readPosition()?.id
    }
}
