import Foundation
import Testing
@testable import UndoCore

@Suite("Safety")
struct SafetyTests {
    /// The project's .git, exactly: every file's bytes, plus every folder's name.
    func gitState(_ sandbox: Sandbox) -> [String: Data] {
        var state = sandbox.contents(of: sandbox.path(".git"))
        if let walker = FileManager.default.enumerator(atPath: sandbox.path(".git")) {
            while let name = walker.nextObject() as? String {
                if FileKind(path: sandbox.path(".git/" + name)) == .folder { state["folder:" + name] = Data() }
            }
        }
        return state
    }

    @Test func theProjectsGitIsNeverTouched() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "committed")
        try sandbox.write("b.txt", "committed")
        try sandbox.sh("git", "add", ".")
        try sandbox.sh("git", "commit", "-qm", "first")
        try sandbox.write("a.txt", "stashed change")
        try sandbox.sh("git", "stash", "-q")
        try sandbox.write("b.txt", "staged change")
        try sandbox.sh("git", "add", "b.txt")
        try sandbox.write("b.txt", "unstaged on top")
        try sandbox.write("untracked.txt", "u")
        // A hook that would leave a mark if anything ran it.
        let marker = sandbox.base + "/hook-ran"
        for hook in ["pre-commit", "post-checkout", "post-index-change", "reference-transaction", "fsmonitor-watchman"] {
            let script = sandbox.path(".git/hooks/" + hook)
            try "#!/bin/sh\ntouch \"\(marker)\"\n".write(toFile: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        }
        try sandbox.sh("git", "config", "core.hooksPath", ".git/hooks")
        try sandbox.sh("git", "config", "core.fsmonitor", ".git/hooks/fsmonitor-watchman")
        let before = gitState(sandbox)

        let store = try sandbox.store()
        _ = try sandbox.snap()
        try sandbox.write("a.txt", "agent edit")
        try sandbox.write("c.txt", "agent file")
        _ = try sandbox.snap("tool", event: .tool)
        try sandbox.remove("b.txt")
        _ = try store.undo()
        _ = try store.undo()
        _ = try store.redo()
        _ = try store.restore(["a.txt"], from: 1)
        _ = try store.prune(keep: 2)
        _ = try store.currentTree()

        #expect(gitState(sandbox) == before)
        #expect(!FileManager.default.fileExists(atPath: marker))
        #expect(try sandbox.sh("git", "stash", "list").contains("stash@{0}"))
        #expect(try sandbox.sh("git", "diff", "--cached", "--name-only") == "b.txt\n")
    }

    @Test func gitEnvironmentFromAnAgentIsIgnored() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        try sandbox.sh("git", "add", ".")
        try sandbox.sh("git", "commit", "-qm", "first")
        let before = gitState(sandbox)
        // As if called from inside a git hook, with GIT_DIR and GIT_INDEX_FILE pointing at the project.
        let output = try sandbox.agentUndo(["snap"], extra: [
            "GIT_DIR": sandbox.path(".git"), "GIT_INDEX_FILE": sandbox.path(".git/index"), "GIT_WORK_TREE": sandbox.project,
        ])
        #expect(output.status == 0, "\(output.err)")
        #expect(gitState(sandbox) == before)
    }

    @Test func neverOverwritesAnIgnoredFileItCouldntRestore() throws {
        let sandbox = try Sandbox()
        try sandbox.write("config.json", "from the snapshot")
        _ = try sandbox.snap()
        try sandbox.remove("config.json")
        _ = try sandbox.snap()
        // Later it comes back ignored, holding something precious no snapshot has.
        try sandbox.write(".gitignore", "config.json\n")
        try sandbox.write("config.json", "precious, never snapshotted")
        let result = try sandbox.store().undo(to: 1)
        #expect(sandbox.read("config.json") == "precious, never snapshotted")
        #expect(result.kept.map(\.path) == ["config.json"])
        #expect(!sandbox.exists(".gitignore"))
    }

    @Test func neverOverwritesABigFileItCouldntRestore() throws {
        let sandbox = try Sandbox { $0.maxFileBytes = 1024 }
        try sandbox.write("data.bin", "small then")
        _ = try sandbox.snap()
        let big = Data(repeating: 1, count: 4096)
        try sandbox.write("data.bin", big)
        try sandbox.write("other.txt", "new")
        let result = try sandbox.store().undo(to: 1)
        #expect(sandbox.bytes("data.bin") == big)
        #expect(result.kept.map(\.path) == ["data.bin"])
        #expect(!sandbox.exists("other.txt"))
    }

    @Test func neverClearsAFolderHoldingUnsavedFiles() throws {
        let sandbox = try Sandbox()
        try sandbox.write("build", "was a file")
        _ = try sandbox.snap()
        try sandbox.remove("build")
        try sandbox.write(".gitignore", "build/\n")
        try sandbox.write("build/output.o", "ignored, never snapshotted")
        let result = try sandbox.store().undo(to: 1)
        #expect(sandbox.read("build/output.o") == "ignored, never snapshotted")
        #expect(result.kept.map(\.path) == ["build"])
    }

    @Test func neverWritesThroughAnUnsavedThingInTheWay() throws {
        let sandbox = try Sandbox()
        try sandbox.write("cache/data.txt", "snapshotted")
        _ = try sandbox.snap()
        try sandbox.remove("cache")
        try sandbox.write(".gitignore", "cache\n")
        try sandbox.write("cache", "an ignored file where a folder was")
        let result = try sandbox.store().undo(to: 1)
        #expect(sandbox.read("cache") == "an ignored file where a folder was")
        #expect(result.kept.map(\.path) == ["cache"])
    }

    @Test func neverWritesThroughALinkToOutside() throws {
        let sandbox = try Sandbox()
        try sandbox.write("out/file.txt", "inside")
        _ = try sandbox.snap()
        try sandbox.remove("out")
        let elsewhere = sandbox.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        try sandbox.link("out", to: elsewhere)
        _ = try sandbox.store().undo(to: 1)
        #expect(!FileManager.default.fileExists(atPath: elsewhere + "/file.txt"))
        #expect(sandbox.kind("out") == .folder)
        #expect(sandbox.read("out/file.txt") == "inside")
        #expect(sandbox.linkTarget("out") == nil)
        // The link is in the snapshot taken before, so it can come back too.
        _ = try sandbox.store().redo()
        #expect(sandbox.linkTarget("out") == elsewhere)
    }

    @Test func nestedRepositoriesSurviveEveryRestore() throws {
        let sandbox = try Sandbox()
        try sandbox.write("main.txt", "1")
        _ = try sandbox.snap()
        try sandbox.write("vendor/tool/code.c", "int main;")
        try sandbox.sh("git", "init", "-q", ".", in: sandbox.path("vendor/tool"))
        let nestedBefore = sandbox.contents(of: sandbox.path("vendor/tool"))
        try sandbox.write("main.txt", "2")
        _ = try sandbox.store().undo(to: 1)
        #expect(sandbox.read("main.txt") == "1")
        #expect(sandbox.contents(of: sandbox.path("vendor/tool")) == nestedBefore)
    }

    @Test(.enabled(if: getuid() != 0, "root can write to read-only folders")) func aFailedSnapshotMeansNothingIsRestored() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "one")
        _ = try sandbox.snap()
        try sandbox.write("a.txt", "two")
        try sandbox.write("b.txt", "new")
        let store = try sandbox.store()
        // Make the store unable to save anything, like a full disk would.
        try sandbox.sh("chmod", "-R", "a-w", store.gitDir + "/objects")
        let before = sandbox.projectFiles()
        #expect(throws: UndoError.self) { try store.undo() }
        #expect(sandbox.projectFiles() == before)
        try sandbox.sh("chmod", "-R", "u+w", store.gitDir + "/objects")
    }

    @Test func aGitThatCantWriteFilesFailsClosed() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "one")
        _ = try sandbox.snap()
        try sandbox.write("a.txt", "two, and longer than a block of bytes " + String(repeating: "x", count: 5000))
        // A git that runs out of space: any file it writes past zero bytes kills it.
        let realGit = try #require(Git.find(environment: sandbox.environment))
        let fullDisk = sandbox.base + "/full-disk-git"
        try "#!/bin/sh\nulimit -f 0\nexec \"\(realGit)\" \"$@\"\n".write(toFile: fullDisk, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fullDisk)
        var environment = sandbox.environment
        environment["MULLIGAN_GIT"] = fullDisk
        let store = try Store.open(root: sandbox.project, settings: sandbox.settings, environment: environment, create: true)
        let before = sandbox.projectFiles()
        #expect(throws: UndoError.self) { try store.undo() }
        #expect(sandbox.projectFiles() == before)
        // And the store still works once there's space again, despite what the killed git left.
        let result = try sandbox.store().undo()
        #expect(sandbox.read("a.txt") == "one")
        #expect(result.before.id == 2)
        #expect(try sandbox.store().git.text(["fsck", "--no-progress"]).isEmpty)
    }

    @Test func concurrentSnapshotsWaitForEachOther() throws {
        let sandbox = try Sandbox()
        for index in 0..<20 { try sandbox.write("file\(index).txt", "start") }
        _ = try sandbox.snap()
        // Eight hooks firing at once while files keep changing.
        let processes = try (0..<8).map { index -> Process in
            try sandbox.write("file\(index).txt", "changed by \(index)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: Sandbox.binary)
            process.arguments = ["hook", "test"]
            var environment = sandbox.environment
            environment["PWD"] = sandbox.project
            process.environment = environment
            process.currentDirectoryURL = URL(fileURLWithPath: sandbox.project)
            let input = Pipe()
            process.standardInput = input
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let payload = #"{"cwd":"\#(sandbox.project)","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"step \#(index)"}}"#
            try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            try input.fileHandleForWriting.close()
            return process
        }
        for process in processes {
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
        let store = try sandbox.store()
        let snapshots = try store.snapshots()
        #expect(Set(snapshots.map(\.id)).count == snapshots.count)
        #expect(snapshots.count >= 2)
        #expect(try store.git.text(["fsck", "--no-progress"]).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: sandbox.data + "/hook-errors.log"))
        // The newest snapshot has every change.
        let newest = try #require(snapshots.last)
        let current = try store.currentTree().tree
        #expect(newest.tree == current)
    }

    @Test func aBusyLockGivesUpWithAClearError() throws {
        let sandbox = try Sandbox { $0.lockTimeout = 0.3 }
        try sandbox.write("a.txt", "a")
        let store = try sandbox.store()
        _ = try store.snapshot(SnapshotRequest(label: "x", event: .manual))
        let other = try sandbox.store()
        #expect(throws: UndoError.busy(sandbox.project)) {
            try store.withLock { try other.withLock { () } }
        }
    }

    @Test func limitsDropTheOldestButKeepTheNewest() throws {
        let sandbox = try Sandbox { $0.keep = 3 }
        for index in 1...6 {
            try sandbox.write("a.txt", "\(index)")
            _ = try sandbox.snap()
        }
        let store = try sandbox.store()
        #expect(try store.snapshots().map(\.id) == [4, 5, 6])
        // Age: everything but the newest is past the limit a year from now.
        let result = try store.prune(now: Date().addingTimeInterval(365 * 86_400))
        #expect(result.removed == [4, 5])
        #expect(try store.snapshots().map(\.id) == [6])
        // Numbers are never reused.
        try sandbox.write("a.txt", "7")
        #expect(try sandbox.snap().snapshot.id == 7)
    }

    @Test func sizeCapDropsOldSnapshots() throws {
        let sandbox = try Sandbox { $0.maxStoreBytes = 300_000 }
        let store = try sandbox.store()
        for _ in 1...9 {
            var generator = SystemRandomNumberGenerator()
            let noise = Data((0..<120_000).map { _ in UInt8.random(in: 0...255, using: &generator) })
            try sandbox.write("noise.bin", noise)
            _ = try sandbox.snap()
        }
        let result = try store.prune()
        #expect(!result.removed.isEmpty)
        // The newest five are always kept, however big.
        #expect(try store.snapshots().map(\.id).suffix(5) == [5, 6, 7, 8, 9])
    }

    @Test func unreadableAndRefusedFilesDontStopSnapshots() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        try sandbox.write("locked.txt", "secret")
        try sandbox.write("git~1/inside.txt", "a name git refuses on some systems")
        try sandbox.write(".git./x", "another")
        try sandbox.sh("chmod", "000", sandbox.path("locked.txt"))
        let result = try sandbox.snap()
        let files = Set(try sandbox.store().entries(of: result.snapshot.tree).keys)
        #expect(files.contains("a.txt"))
        if getuid() != 0 { #expect(!files.contains("locked.txt")) }
        #expect(!files.contains(".git./x"))
        // Undo still works, and leaves what it couldn't save alone.
        try sandbox.write("a.txt", "changed")
        _ = try sandbox.store().undo()
        try sandbox.sh("chmod", "644", sandbox.path("locked.txt"))
        #expect(sandbox.read("a.txt") == "a")
        #expect(sandbox.read("locked.txt") == "secret")
    }

    @Test func dataFolderInsideTheProjectIsCaughtBeforeItExists() throws {
        let sandbox = try Sandbox()
        // Reached through a link, and not made yet.
        let linked = sandbox.base + "/link-to-project"
        try FileManager.default.createSymbolicLink(atPath: linked, withDestinationPath: sandbox.project)
        var settings = sandbox.settings
        settings.dataHome = linked + "/undo-data"
        #expect(throws: UndoError.self) { try Project.check(sandbox.project, settings: settings, home: sandbox.home) }
    }

    @Test func projectPathsWithLineBreaksAreRefused() throws {
        let sandbox = try Sandbox()
        #expect(throws: UndoError.self) { try Project.check("/work/odd\nname", settings: sandbox.settings, home: sandbox.home) }
    }

    @Test func clearDeletesSnapshotsButNoFiles() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        _ = try sandbox.snap()
        let files = sandbox.projectFiles()
        let store = try sandbox.store()
        try store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.gitDir))
        #expect(Store.recordedProject(in: store.folder) == nil)
        #expect(sandbox.projectFiles() == files)
    }
}
