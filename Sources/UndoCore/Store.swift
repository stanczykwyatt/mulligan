import Foundation

/// One project's snapshots: a git repository kept in mulligan's data folder, with the project
/// as its work tree. The project's own `.git` is never read or written, apart from reading its
/// `info/exclude` so the same files are left out.
///
///     <data>/projects/<name>-<fingerprint>/
///         project      the project's path, to check the folder belongs to it
///         git/         the snapshot repository (objects, refs/undo/<id>, index)
///         home/        an empty folder git sees as HOME
///         lock         held while anything reads or changes the snapshots
///         next-id      the number the next snapshot gets
///         position     where undo and redo left your files, if they did
public struct Store: Sendable {
    public let root: String
    public let folder: String
    public let settings: Settings
    public let git: Git

    var gitDir: String { folder + "/git" }
    var projectFile: String { folder + "/project" }
    var lockFile: String { folder + "/lock" }
    var nextIDFile: String { folder + "/next-id" }
    var positionFile: String { folder + "/position" }

    /// The folder for a project's snapshots. Two projects whose paths share a fingerprint get
    /// separate folders, told apart by the path each one records.
    static func folder(for root: String, settings: Settings) -> String {
        let base = settings.dataHome + "/projects/" + folderName(for: root)
        var candidate = base
        var suffix = 2
        while let recorded = recordedProject(in: candidate), recorded != root {
            candidate = base + "-\(suffix)"
            suffix += 1
        }
        return candidate
    }

    static func folderName(for root: String) -> String {
        let name = (root as NSString).lastPathComponent
        let safe = String(name.unicodeScalars.map { scalar -> Character in
            let c = Character(scalar)
            return c.isASCII && (c.isLetter || c.isNumber || c == "-" || c == "_" || c == ".") ? c : "_"
        }.prefix(40))
        return (safe.isEmpty || safe.allSatisfy { $0 == "." } ? "project" : safe) + "-" + Paths.fingerprint(root)
    }

    static func recordedProject(in folder: String) -> String? {
        guard let data = FileManager.default.contents(atPath: folder + "/project") else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    /// Whether `folder` has snapshots already, so it counts as a project even without a `.git`.
    static func isRegistered(_ folder: String, settings: Settings) -> Bool {
        recordedProject(in: Self.folder(for: folder, settings: settings)) == folder
    }

    /// Opens the store for a project, creating it on first use when `create` is set.
    public static func open(root: String, settings: Settings, environment: [String: String], create: Bool) throws -> Store {
        guard let executable = Git.find(environment: environment) else { throw UndoError.gitMissing }
        let version = try Git.version(executable: executable)
        guard version.count >= 2, (version[0], version[1]) >= (2, 25) else {
            throw UndoError.gitTooOld(version.map(String.init).joined(separator: "."))
        }
        let folder = folder(for: root, settings: settings)
        let excludes = Git.userGlobalExcludes(executable: executable, environment: environment)
        let git = Git(executable: executable, gitDir: folder + "/git", workTree: root, emptyHome: folder + "/home", globalExcludes: excludes)
        let store = Store(root: root, folder: folder, settings: settings, git: git)
        if !FileManager.default.fileExists(atPath: store.projectFile) {
            guard create else { throw UndoError.noSnapshots(root) }
            try store.create()
        }
        return store
    }

    var exists: Bool { Self.recordedProject(in: folder) == root }

    /// Makes the store's folders, private to this user, and an empty snapshot repository.
    func create() throws {
        let manager = FileManager.default
        try makePrivateFolder(settings.dataHome)
        try makePrivateFolder(settings.dataHome + "/projects")
        try makePrivateFolder(folder)
        try withLock {
            if exists { return }
            try makePrivateFolder(folder + "/home")
            if !manager.fileExists(atPath: gitDir + "/HEAD") {
                let result = try Git.spawn(
                    executable: git.executable, arguments: ["init", "--quiet", "--bare", gitDir],
                    environment: ["PATH": "/usr/bin:/bin", "HOME": folder + "/home", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "LC_ALL": "C"],
                    input: nil
                )
                guard result.status == 0 else {
                    throw UndoError.snapshotFailed("git init failed: \(String(decoding: result.error, as: UTF8.self))")
                }
            }
            try configure()
            try write(root + "\n", to: projectFile)
        }
    }

    /// The store's own settings, written once. The important ones are passed on every call too.
    func configure() throws {
        var settings: [(String, String)] = [
            ("core.bare", "false"),
            ("core.logAllRefUpdates", "false"),
            ("core.autocrlf", "false"),
            ("core.symlinks", "true"),
            ("core.fileMode", "true"),
            ("core.ignoreCase", Self.isCaseInsensitive(root) ? "true" : "false"),
            ("gc.auto", "0"),
            ("gc.reflogExpire", "now"),
            ("gc.reflogExpireUnreachable", "now"),
            ("receive.denyCurrentBranch", "refuse"),
        ]
        #if os(macOS)
        settings.append(("core.precomposeUnicode", "true"))
        #endif
        for (key, value) in settings {
            try git.run(["config", key, value])
        }
        try writeAttributes()
        try? FileManager.default.removeItem(atPath: gitDir + "/hooks")
        try? FileManager.default.removeItem(atPath: gitDir + "/description")
    }

    /// Whether the file system holding `folder` ignores case, found by looking up the folder's
    /// own name with its case swapped.
    static func isCaseInsensitive(_ folder: String) -> Bool {
        #if os(macOS)
        // The file system says so itself; the name probe below is only a fallback.
        switch pathconf(folder, _PC_CASE_SENSITIVE) {
        case 0: return true
        case 1: return false
        default: break
        }
        #endif
        var path = folder
        while path != "/" {
            let name = (path as NSString).lastPathComponent
            let swapped = String(name.map { $0.isUppercase ? Character($0.lowercased()) : Character($0.uppercased()) })
            if swapped != name {
                let parent = (path as NSString).deletingLastPathComponent
                var original = stat()
                var other = stat()
                guard lstat(path, &original) == 0 else { return false }
                guard lstat(parent + "/" + swapped, &other) == 0 else { return false }
                return original.st_ino == other.st_ino && original.st_dev == other.st_dev
            }
            path = (path as NSString).deletingLastPathComponent
        }
        #if os(macOS)
        return true
        #else
        return false
        #endif
    }

    static let attributes = "* -text -filter -ident -working-tree-encoding\n"

    /// Store each file exactly as it is: no line-ending changes, filters or keyword expansion,
    /// whatever the project's .gitattributes ask for. This file outranks .gitattributes. It's
    /// checked before every snapshot, in case it was ever removed.
    func writeAttributes() throws {
        let path = gitDir + "/info/attributes"
        if FileManager.default.contents(atPath: path) == Data(Self.attributes.utf8) { return }
        try makePrivateFolder(gitDir + "/info")
        try write(Self.attributes, to: path)
    }

    // MARK: - Locking

    /// Runs `body` while holding the store's lock, so two hooks firing at once take their
    /// snapshots one after the other. Waits up to the lock timeout, then gives up.
    public func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = openLockFile(lockFile)
        guard fd >= 0 else {
            throw UndoError.snapshotFailed("Couldn't open \(lockFile): \(String(cString: strerror(errno))).")
        }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(settings.lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR, Date() < deadline else { throw UndoError.busy(root) }
            usleep(20_000)
        }
        defer { flock(fd, LOCK_UN) }
        clearGitLocks { Date().timeIntervalSince($0) > 600 }
        let started = Date().addingTimeInterval(-0.05)
        do {
            return try body()
        } catch {
            // Every git started in `body` has exited by now, so lock files made since it began
            // are theirs, left by one that was killed (a full disk does that).
            clearGitLocks { $0 >= started }
            throw error
        }
    }

    /// While mulligan holds its lock, no other mulligan is using the store, so a lock file git
    /// left behind is from a git that was killed (a full disk, Ctrl-C), and would block every later
    /// snapshot. Ones made by this process's own gits are cleared as soon as they've exited; any
    /// others only once they're ten minutes old, in case a git started by an mulligan that was
    /// itself killed is still finishing.
    func clearGitLocks(where shouldClear: (Date) -> Bool) {
        let manager = FileManager.default
        var candidates = ["index.lock", "packed-refs.lock", "HEAD.lock", "config.lock", "shallow.lock"].map { gitDir + "/" + $0 }
        if let names = try? manager.contentsOfDirectory(atPath: gitDir) {
            candidates += names.filter { $0.hasPrefix("index-combine-") }.map { gitDir + "/" + $0 }
        }
        if let names = try? manager.contentsOfDirectory(atPath: gitDir + "/refs/undo") {
            candidates += names.filter { $0.hasSuffix(".lock") }.map { gitDir + "/refs/undo/" + $0 }
        }
        for path in candidates {
            guard let modified = (try? manager.attributesOfItem(atPath: path))?[.modificationDate] as? Date else { continue }
            if shouldClear(modified) { unlink(path) }
        }
    }

    // MARK: - Small files

    func write(_ text: String, to path: String) throws {
        let temporary = path + ".tmp-\(getpid())"
        guard FileManager.default.createFile(atPath: temporary, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw UndoError.snapshotFailed("Couldn't write \(path): the disk may be full.")
        }
        guard rename(temporary, path) == 0 else {
            let reason = String(cString: strerror(errno))
            unlink(temporary)
            throw UndoError.snapshotFailed("Couldn't write \(path): \(reason).")
        }
    }

    func read(_ path: String) -> String? {
        FileManager.default.contents(atPath: path).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func makePrivateFolder(_ path: String) throws {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) {
            guard isFolder.boolValue else { throw UndoError.badSetting("\(path) should be a folder, but it's a file.") }
            return
        }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue { return }
            throw UndoError.snapshotFailed("Couldn't make \(path): \(error.localizedDescription)")
        }
    }

    /// How much space the store takes, adding up every file in it.
    public func size() -> Int64 {
        var total: Int64 = 0
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return 0 }
        while let name = walker.nextObject() as? String {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: folder + "/" + name),
               attributes[.type] as? FileAttributeType == .typeRegular,
               let bytes = attributes[.size] as? NSNumber {
                total += bytes.int64Value
            }
        }
        return total
    }
}

/// Opens (creating) a lock file. Outside `Store`, whose `open` is something else.
private func openLockFile(_ path: String) -> Int32 {
    open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
}
