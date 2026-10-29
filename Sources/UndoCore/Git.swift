import Foundation

/// A git command that failed, with what git said.
public struct GitError: Error, CustomStringConvertible, Sendable {
    public let arguments: [String]
    public let status: Int32
    public let message: String

    public var description: String {
        let said = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = arguments.first ?? ""
        return said.isEmpty ? "git \(command) failed (exit \(status))" : "git \(command) failed: \(said)"
    }
}

/// Runs git against the snapshot store, never against the project's own repository.
///
/// Every call gets `GIT_DIR` pointing at the store and the project as its work tree, so git never
/// looks for, reads or writes the project's `.git`. The user's global and system git config are
/// left out, so nothing in them (hooks, filters, fsmonitor, credential helpers) can run, and the
/// settings that matter are passed on every call as well as kept in the store's own config.
public struct Git: Sendable {
    public let executable: String
    public let gitDir: String
    public let workTree: String
    /// An empty folder git sees as HOME, so it can't find the user's own config there.
    let emptyHome: String
    /// The user's global ignore file, read once so the store respects it like git would.
    let globalExcludes: String?

    public init(executable: String, gitDir: String, workTree: String, emptyHome: String, globalExcludes: String?) {
        self.executable = executable
        self.gitDir = gitDir
        self.workTree = workTree
        self.emptyHome = emptyHome
        self.globalExcludes = globalExcludes
    }

    /// Settings passed with every command, so a damaged or edited store config can't change them.
    var fixedSettings: [String] {
        [
            "core.bare=false",
            "core.hooksPath=\(gitDir)/no-hooks",
            "core.fsmonitor=false",
            "core.autocrlf=false",
            "core.safecrlf=false",
            "core.symlinks=true",
            "core.quotePath=false",
            "core.excludesFile=\(globalExcludes ?? "\(gitDir)/no-global-excludes")",
            "protocol.allow=never",
            "gc.auto=0",
            "commit.gpgSign=false",
            "advice.addEmbeddedRepo=false",
            "advice.addIgnoredFile=false",
        ].flatMap { ["-c", $0] }
    }

    func environment(indexFile: String?, forDisplay: Bool) -> [String: String] {
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_DIR"] = gitDir
        env["GIT_WORK_TREE"] = workTree
        if let indexFile { env["GIT_INDEX_FILE"] = indexFile }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["HOME"] = emptyHome
        env["XDG_CONFIG_HOME"] = emptyHome
        env["GIT_AUTHOR_NAME"] = "mulligan"
        env["GIT_AUTHOR_EMAIL"] = "mulligan@localhost"
        env["GIT_COMMITTER_NAME"] = "mulligan"
        env["GIT_COMMITTER_EMAIL"] = "mulligan@localhost"
        if !forDisplay {
            env["LC_ALL"] = "C"
            env["GIT_PAGER"] = "cat"
        }
        return env
    }

    /// Runs git and returns what it printed. Throws `GitError` on a nonzero exit.
    @discardableResult
    public func run(_ arguments: [String], input: Data? = nil, indexFile: String? = nil) throws -> Data {
        let result = try Self.spawn(
            executable: executable, arguments: fixedSettings + arguments,
            environment: environment(indexFile: indexFile, forDisplay: false), input: input, directory: workTree
        )
        guard result.status == 0 else {
            throw GitError(arguments: arguments, status: result.status, message: String(decoding: result.error, as: UTF8.self))
        }
        return result.output
    }

    /// Runs git and returns its output as text, without the final newline.
    public func text(_ arguments: [String], input: Data? = nil, indexFile: String? = nil) throws -> String {
        let data = try run(arguments, input: input, indexFile: indexFile)
        var string = String(decoding: data, as: UTF8.self)
        while string.hasSuffix("\n") { string.removeLast() }
        return string
    }

    /// Runs git with its output going straight to the terminal, so it can page and color a diff.
    public func display(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = fixedSettings + arguments
        process.environment = environment(indexFile: nil, forDisplay: true)
        process.currentDirectoryURL = URL(fileURLWithPath: workTree)
        process.standardInput = FileHandle.nullDevice
        try process.run()
        runningChild = process.processIdentifier
        waitForExit(process)
        runningChild = 0
        return process.terminationStatus
    }

    struct Result {
        var status: Int32
        var output: Data
        var error: Data
    }

    /// Starts a program with pipes for its output and error, reading both at once so neither can
    /// fill up and stall it. Git runs in the project's top folder, so paths and "." always mean the
    /// whole project, wherever mulligan itself was started.
    static func spawn(executable: String, arguments: [String], environment: [String: String], input: Data?, directory: String = "/") throws -> Result {
        ignoreBrokenPipes()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let inputPipe = input == nil ? nil : Pipe()
        process.standardInput = inputPipe ?? FileHandle.nullDevice
        try process.run()
        runningChild = process.processIdentifier
        defer { runningChild = 0 }

        // Error output and input each get a thread of their own, not a dispatch queue: a caller
        // that blocks every worker (like a test runner) would otherwise leave them never running.
        let errorData = DataBox()
        let finished = DispatchSemaphore(value: 0)
        var helpers = 1
        Thread.detachNewThread {
            errorData.set(error.fileHandleForReading.readDataToEndOfFile())
            finished.signal()
        }
        if let input, let inputPipe {
            helpers += 1
            Thread.detachNewThread {
                // A program that exits without reading all of it closes the pipe; that's its business.
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
                finished.signal()
            }
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        for _ in 0..<helpers { finished.wait() }
        waitForExit(process)
        return Result(status: process.terminationStatus, output: outputData, error: errorData.get())
    }

    /// Finds git on PATH, or uses `MULLIGAN_GIT` when it's set.
    public static func find(environment: [String: String]) -> String? {
        if let chosen = environment["MULLIGAN_GIT"], !chosen.isEmpty {
            return FileManager.default.isExecutableFile(atPath: chosen) ? chosen : nil
        }
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/local/bin"
        // Only absolute folders: a relative one like "." or "node_modules/.bin" could hand a hook
        // a git that came with the project.
        for folder in path.split(separator: ":") where folder.hasPrefix("/") {
            let candidate = "\(folder)/git"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Git's version as numbers, like [2, 39, 5].
    public static func version(executable: String) throws -> [Int] {
        let result = try spawn(
            executable: executable, arguments: ["--version"],
            environment: ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
            input: nil
        )
        let text = String(decoding: result.output, as: UTF8.self)
        guard let word = text.split(separator: " ").first(where: { $0.first?.isNumber == true }) else { return [] }
        return word.split(separator: ".").prefix(3).map { Int($0.prefix(while: \.isNumber)) ?? 0 }
    }

    /// Reads the user's global ignore file setting the way git would find it, without running
    /// anything from their config.
    static func userGlobalExcludes(executable: String, environment: [String: String]) -> String? {
        var env = environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["LC_ALL"] = "C"
        let home = env["HOME"] ?? ""
        if let result = try? spawn(
            executable: executable, arguments: ["config", "--global", "--path", "--get", "core.excludesFile"],
            environment: env, input: nil
        ), result.status == 0 {
            let path = String(decoding: result.output, as: UTF8.self).trimmingCharacters(in: .newlines)
            if path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) { return path }
        }
        let configHome = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        let fallback = "\(configHome)/git/ignore"
        return !home.isEmpty && FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// The git mulligan is waiting on, if any, so a signal handler can stop it rather than leave it
/// running on its own. Only the command line tool, which runs one git at a time, relies on it.
nonisolated(unsafe) public var runningChild: pid_t = 0

/// Waits for a program that has closed its output, which is about to exit or has. Polling
/// `isRunning` is quicker than `waitUntilExit`, which waits on the run loop in long steps.
func waitForExit(_ process: Process) {
    var pause: UInt32 = 200
    while process.isRunning {
        usleep(pause)
        pause = min(pause * 2, 20_000)
    }
}

/// Writing to a program that has already exited must be an error, not the end of mulligan.
func ignoreBrokenPipes() {
    signal(SIGPIPE, SIG_IGN)
}

extension Data {
    /// Splits git's NUL-separated output into strings, dropping the empty end.
    func nulSeparated() -> [String] {
        split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    }
}
