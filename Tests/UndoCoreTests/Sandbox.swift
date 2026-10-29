import Foundation
@testable import UndoCore

/// A throwaway world for one test: a project folder, a data folder and a home folder, all in a
/// fresh temporary folder that's deleted afterwards. Nothing outside it is ever read or written,
/// and HOME points inside it, so no real agent config or git config is in play.
final class Sandbox {
    let base: String
    let project: String
    let data: String
    let home: String
    var settings: Settings
    var environment: [String: String]

    init(git: Bool = true, settings configure: (inout Settings) -> Void = { _ in }) throws {
        let temporary = Paths.real(NSTemporaryDirectory()) ?? NSTemporaryDirectory()
        base = Paths.clean(temporary + "/mulligan-test-" + UUID().uuidString)
        project = base + "/My Project"
        data = base + "/data"
        home = base + "/home"
        for folder in [project, home] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        }
        var settings = Settings(dataHome: data)
        configure(&settings)
        self.settings = settings
        environment = [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            "HOME": home,
            "MULLIGAN_HOME": data,
            "NO_COLOR": "1",
            "TMPDIR": base,
        ]
        if git {
            try sh("git", "init", "-q", ".")
            try sh("git", "config", "user.name", "Test")
            try sh("git", "config", "user.email", "test@example.com")
            try sh("git", "config", "commit.gpgSign", "false")
        }
    }

    deinit {
        // A test may leave folders read-only on purpose.
        _ = try? Self.spawn(["chmod", "-R", "u+w", base], in: "/", environment: ["PATH": "/usr/bin:/bin"])
        try? FileManager.default.removeItem(atPath: base)
    }

    func store() throws -> Store {
        try Store.open(root: project, settings: settings, environment: environment, create: true)
    }

    @discardableResult
    func snap(_ label: String = "test", event: Event = .manual) throws -> SnapshotResult {
        try store().snapshot(SnapshotRequest(label: label, agent: "test", event: event))
    }

    // MARK: Files

    func path(_ relative: String) -> String { project + "/" + relative }

    func write(_ relative: String, _ text: String) throws {
        try write(relative, Data(text.utf8))
    }

    func write(_ relative: String, _ data: Data) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: full, contents: data) else { throw SandboxError("couldn't write \(relative)") }
    }

    func read(_ relative: String) -> String? {
        FileManager.default.contents(atPath: path(relative)).map { String(decoding: $0, as: UTF8.self) }
    }

    func bytes(_ relative: String) -> Data? {
        FileManager.default.contents(atPath: path(relative))
    }

    func exists(_ relative: String) -> Bool {
        FileKind(path: path(relative)) != .missing
    }

    func kind(_ relative: String) -> FileKind { FileKind(path: path(relative)) }

    func remove(_ relative: String) throws {
        try FileManager.default.removeItem(atPath: path(relative))
    }

    func link(_ relative: String, to target: String) throws {
        try FileManager.default.createDirectory(atPath: (path(relative) as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: path(relative), withDestinationPath: target)
    }

    func linkTarget(_ relative: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path(relative))
    }

    /// Every file under a folder, by relative path, with its bytes (or link target), so two
    /// moments can be compared exactly.
    func contents(of folder: String) -> [String: Data] {
        var result: [String: Data] = [:]
        guard let walker = FileManager.default.enumerator(atPath: folder) else { return result }
        while let name = walker.nextObject() as? String {
            let full = folder + "/" + name
            switch FileKind(path: full) {
            case .file: result[name] = FileManager.default.contents(atPath: full) ?? Data()
            case .link: result[name] = Data(("link → " + ((try? FileManager.default.destinationOfSymbolicLink(atPath: full)) ?? "")).utf8)
            default: continue
            }
        }
        return result
    }

    /// The project's files, leaving out its .git.
    func projectFiles() -> [String: Data] {
        contents(of: project).filter { !$0.key.hasPrefix(".git/") && $0.key != ".git" }
    }

    // MARK: Programs

    @discardableResult
    func sh(_ arguments: String..., in folder: String? = nil, input: String? = nil) throws -> String {
        let result = try Self.spawn(arguments, in: folder ?? project, environment: environment, input: input.map { Data($0.utf8) })
        guard result.status == 0 else {
            throw SandboxError("\(arguments.joined(separator: " ")) failed: \(String(decoding: result.error, as: UTF8.self))")
        }
        return String(decoding: result.output, as: UTF8.self)
    }

    struct Output {
        var status: Int32
        var out: String
        var err: String
    }

    /// Runs the built mulligan with this sandbox's environment.
    func agentUndo(_ arguments: [String], in folder: String? = nil, input: String? = nil, extra: [String: String] = [:]) throws -> Output {
        var env = environment
        for (key, value) in extra { env[key] = value }
        let result = try Self.spawn([Self.binary] + arguments, in: folder ?? project, environment: env, input: input.map { Data($0.utf8) })
        return Output(status: result.status, out: String(decoding: result.output, as: UTF8.self), err: String(decoding: result.error, as: UTF8.self))
    }

    static func spawn(_ arguments: [String], in folder: String, environment: [String: String], input: Data? = nil) throws -> Git.Result {
        let resolved = arguments[0].hasPrefix("/") ? arguments[0] : "/usr/bin/env"
        let rest = arguments[0].hasPrefix("/") ? Array(arguments.dropFirst()) : arguments
        // Process can't take a working folder portably on every platform's Foundation, so the
        // shell is asked to change into it.
        let script = "cd \"$1\" && shift && exec \"$@\""
        return try Git.spawn(executable: "/bin/sh", arguments: ["-c", script, "sh", folder, resolved] + rest, environment: environment, input: input)
    }

    /// The built command line tool, next to the test bundle.
    static let binary: String = {
        if let chosen = ProcessInfo.processInfo.environment["MULLIGAN_BIN"] { return chosen }
        var candidates: [String] = []
        #if os(macOS)
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append((bundle.bundlePath as NSString).deletingLastPathComponent + "/mulligan")
        }
        #endif
        candidates.append((Bundle.main.bundlePath as NSString).appendingPathComponent("mulligan"))
        candidates.append(((CommandLine.arguments.first ?? "") as NSString).deletingLastPathComponent + "/mulligan")
        // From this file up to the package, then its usual build folders.
        let package = Paths.clean(#filePath + "/../../..")
        candidates += [".build/debug/mulligan", ".build/release/mulligan"].map { package + "/" + $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates.last!
    }()
}

struct SandboxError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
