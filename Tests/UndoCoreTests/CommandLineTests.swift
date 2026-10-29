import Foundation
import Testing
@testable import UndoCore

@Suite("The mulligan command")
struct CommandLineTests {
    @Test func helpAndVersion() throws {
        let sandbox = try Sandbox()
        let help = try sandbox.agentUndo(["--help"])
        #expect(help.status == 0)
        #expect(help.out.contains("mulligan undo [ID]"))
        #expect(try sandbox.agentUndo(["--version"]).out.hasPrefix("mulligan 0."))
        let unknown = try sandbox.agentUndo(["frobnicate"])
        #expect(unknown.status == 2)
    }

    @Test func aWholeSession() throws {
        let sandbox = try Sandbox()
        try sandbox.write("app.py", "print('v1')\n")
        let snap = try sandbox.agentUndo(["snap", "-m", "before the refactor"])
        #expect(snap.status == 0, "\(snap.err)")
        #expect(snap.out.contains("#1"))
        try sandbox.write("app.py", "print('v2')\n")
        try sandbox.write("new.py", "x = 1\n")

        let list = try sandbox.agentUndo(["list"])
        #expect(list.status == 0)
        #expect(list.out.contains("before the refactor"))
        #expect(list.out.contains("2 files changed since #1"))
        #expect(!list.out.contains("\u{1b}["))

        let diff = try sandbox.agentUndo(["diff", "1"])
        #expect(diff.out.contains("-print('v1')"))
        #expect(diff.out.contains("+print('v2')"))
        #expect(try sandbox.agentUndo(["diff", "--stat"]).out.contains("app.py"))

        let undo = try sandbox.agentUndo(["undo"])
        #expect(undo.status == 0, "\(undo.err)")
        #expect(undo.out.contains("Back to #1"))
        #expect(sandbox.read("app.py") == "print('v1')\n")
        #expect(!sandbox.exists("new.py"))

        let redo = try sandbox.agentUndo(["redo"])
        #expect(redo.status == 0, "\(redo.err)")
        #expect(sandbox.read("app.py") == "print('v2')\n")

        let restore = try sandbox.agentUndo(["restore", "1", "--", "app.py"])
        #expect(restore.status == 0, "\(restore.err)")
        #expect(sandbox.read("app.py") == "print('v1')\n")
        #expect(sandbox.read("new.py") == "x = 1\n")

        let status = try sandbox.agentUndo(["status"])
        #expect(status.out.contains("Snapshots"))
    }

    @Test func worksFromASubfolderAndWithTheProjectOption() throws {
        let sandbox = try Sandbox()
        try sandbox.write("src/lib/a.txt", "a")
        let fromSubfolder = try sandbox.agentUndo(["snap"], in: sandbox.path("src/lib"))
        #expect(fromSubfolder.status == 0)
        try sandbox.write("src/lib/a.txt", "changed")
        let restore = try sandbox.agentUndo(["restore", "1", "--", "a.txt"], in: sandbox.path("src/lib"))
        #expect(restore.status == 0, "\(restore.err)")
        #expect(sandbox.read("src/lib/a.txt") == "a")
        let elsewhere = try sandbox.agentUndo(["-C", sandbox.project, "list"], in: sandbox.home)
        #expect(elsewhere.status == 0)
    }

    @Test func refusesPathsOutsideTheProjectOrInItsGit() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        _ = try sandbox.agentUndo(["snap"])
        #expect(try sandbox.agentUndo(["restore", "1", "--", "../elsewhere.txt"]).status != 0)
        #expect(try sandbox.agentUndo(["restore", "1", "--", ".git/config"]).status != 0)
        #expect(try sandbox.agentUndo(["restore", "1", "a.txt"]).status == 2)
        #expect(try sandbox.agentUndo(["undo", "abc"]).status == 2)
    }

    @Test func refusesTheHomeFolder() throws {
        let sandbox = try Sandbox(git: false)
        try sandbox.sh("git", "init", "-q", ".", in: sandbox.home)
        let result = try sandbox.agentUndo(["snap"], in: sandbox.home)
        #expect(result.status == 1)
        #expect(result.err.contains("home folder"))
        #expect(!FileManager.default.fileExists(atPath: sandbox.data + "/projects"))
        #expect(try sandbox.agentUndo(["init"], in: sandbox.home).status == 1)
    }

    @Test func initSetsUpAFolderWithoutGit() throws {
        let sandbox = try Sandbox(git: false)
        try sandbox.write("notes.md", "n")
        #expect(try sandbox.agentUndo(["snap"]).status == 1)
        let setUp = try sandbox.agentUndo(["init"])
        #expect(setUp.status == 0, "\(setUp.err)")
        try sandbox.write("notes.md", "changed")
        #expect(try sandbox.agentUndo(["undo"]).status == 0)
        #expect(sandbox.read("notes.md") == "n")
    }

    @Test func listAndUndoWithNoSnapshotsSaySo() throws {
        let sandbox = try Sandbox()
        let list = try sandbox.agentUndo(["list"])
        #expect(list.status == 1)
        #expect(list.err.contains("No snapshots yet"))
        #expect(try sandbox.agentUndo(["undo"]).status == 1)
        #expect(try sandbox.agentUndo(["redo"]).status == 1)
    }

    @Test func hooksArePerfectlySilentAndAlwaysSucceed() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        let payload = #"{"session_id":"s","cwd":"\#(sandbox.project)","hook_event_name":"UserPromptSubmit","prompt":"make it faster"}"#
        let ok = try sandbox.agentUndo(["hook", "claude"], in: sandbox.home, input: payload)
        #expect(ok.status == 0)
        #expect(ok.out.isEmpty)
        #expect(ok.err.isEmpty)
        let snapshots = try sandbox.store().snapshots()
        #expect(snapshots.count == 1)
        #expect(snapshots[0].agent == "claude")
        #expect(snapshots[0].event == .prompt)
        #expect(snapshots[0].label == "prompt: “make it faster”")

        // Outside any project, with junk, or with no input: still silent and 0.
        for input in [#"{"cwd":"/"}"#, "garbage", ""] {
            let quiet = try sandbox.agentUndo(["hook", "gemini"], in: sandbox.home, input: input)
            #expect(quiet.status == 0)
            #expect(quiet.out.isEmpty)
            #expect(quiet.err.isEmpty)
        }
    }

    @Test(.enabled(if: getuid() != 0, "root can write to read-only folders")) func aFailingHookLeavesANoteForStatus() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        let payload = #"{"cwd":"\#(sandbox.project)","hook_event_name":"Stop"}"#
        #expect(try sandbox.agentUndo(["hook", "codex"], input: payload).status == 0)
        // The store can't take anything new, like on a full disk.
        let store = try sandbox.store()
        try sandbox.sh("chmod", "-R", "a-w", store.gitDir + "/objects")
        try sandbox.write("a.txt", "changed")
        let failing = try sandbox.agentUndo(["hook", "codex"], input: payload)
        try sandbox.sh("chmod", "-R", "u+w", store.gitDir + "/objects")
        #expect(failing.status == 0)
        #expect(failing.out.isEmpty)
        #expect(failing.err.isEmpty)
        let log = try #require(FileManager.default.contents(atPath: sandbox.data + "/hook-errors.log"))
        #expect(String(decoding: log, as: UTF8.self).contains("codex: Couldn't take a snapshot"))
        #expect(try sandbox.agentUndo(["status"]).out.contains("last problem"))
    }

    @Test func hooksSurviveAClosedOrOddStandardInput() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        for redirect in ["<&-", "< /dev/null", "< ."] {
            let command = "cd \"\(sandbox.project)\" && \"\(Sandbox.binary)\" hook claude \(redirect)"
            let result = try Sandbox.spawn(["/bin/sh", "-c", command], in: sandbox.project, environment: sandbox.environment)
            #expect(result.status == 0, "\(redirect)")
            #expect(result.output.isEmpty && result.error.isEmpty, "\(redirect): \(String(decoding: result.error, as: UTF8.self))")
        }
        #expect(try sandbox.store().snapshots().count == 1)
    }

    @Test func aHookReadsItsPayloadEvenIfThePipeStaysOpen() throws {
        let sandbox = try Sandbox()
        let other = sandbox.base + "/Other Project"
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        try sandbox.sh("git", "init", "-q", ".", in: other)
        try "o".write(toFile: other + "/o.txt", atomically: true, encoding: .utf8)
        // The payload names the other project; the pipe is held open for a while after it.
        let payload = #"{"cwd":"\#(other)","hook_event_name":"Stop"}"#
        let command = "(printf '%s\\n' '\(payload)'; sleep 8) | \"\(Sandbox.binary)\" hook claude"
        let started = Date()
        let result = try Sandbox.spawn(["/bin/sh", "-c", command], in: sandbox.project, environment: sandbox.environment)
        #expect(result.status == 0)
        let otherStore = try Store.open(root: other, settings: sandbox.settings, environment: sandbox.environment, create: false)
        #expect(try otherStore.snapshots().count == 1)
        // It didn't wait for the pipe to close (the shell does, for sleep, so allow for that).
        _ = started
    }

    @Test func worksTheSameFromASubfolder() throws {
        let sandbox = try Sandbox()
        try sandbox.write("top.txt", "top 1")
        try sandbox.write("sub/x.log", "old")
        try sandbox.write("sub/s.txt", "s1")
        #expect(try sandbox.agentUndo(["snap"], in: sandbox.path("sub")).status == 0)
        try sandbox.write("top.txt", "top 2")
        let second = try sandbox.agentUndo(["snap"], in: sandbox.path("sub"))
        #expect(second.out.contains("Snapshot #2"), "\(second.out)")
        // An ignored file that no snapshot holds is kept, from a subfolder too.
        try sandbox.remove("sub/x.log")
        _ = try sandbox.agentUndo(["snap"], in: sandbox.path("sub"))
        try sandbox.write(".gitignore", "*.log\n")
        try sandbox.write("sub/x.log", "precious")
        let undo = try sandbox.agentUndo(["undo", "1"], in: sandbox.path("sub"))
        #expect(undo.status == 0, "\(undo.err)")
        #expect(sandbox.read("sub/x.log") == "precious")
        #expect(sandbox.read("top.txt") == "top 1")
        try sandbox.write("sub/s.txt", "s2")
        let diff = try sandbox.agentUndo(["diff", "1", "--", "s.txt"], in: sandbox.path("sub"))
        #expect(diff.out.contains("+s2"), "\(diff.out)")
        // A hook whose agent was started in the subfolder still snapshots the whole project.
        try sandbox.write("top.txt", "top 3")
        let payload = #"{"cwd":"\#(sandbox.path("sub"))","hook_event_name":"Stop"}"#
        _ = try sandbox.agentUndo(["hook", "codex"], in: sandbox.path("sub"), input: payload)
        let newest = try #require(try sandbox.store().snapshots().last)
        let entries = try sandbox.store().entries(of: newest.tree)
        let content = try sandbox.store().git.run(["cat-file", "blob", try #require(entries["top.txt"]).object])
        #expect(content == Data("top 3".utf8))
    }

    @Test func codexNotifyPassesJSONAsAnArgument() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        let payload = #"{"type":"agent-turn-complete","turn-id":"1","cwd":"\#(sandbox.project)","input-messages":["fix the bug"]}"#
        let result = try sandbox.agentUndo(["hook", "codex", payload], in: sandbox.home, input: "")
        #expect(result.status == 0)
        let snapshot = try #require(try sandbox.store().snapshots().first)
        #expect(snapshot.agent == "codex")
        #expect(snapshot.event == .turn)
    }

    @Test func hookCanBeTurnedOff() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        _ = try sandbox.agentUndo(["hook", "claude"], input: "{}", extra: ["MULLIGAN_DISABLE": "1"])
        #expect(!FileManager.default.fileExists(atPath: sandbox.data))
    }

    @Test func runWrapsACommandAndKeepsItsExitStatus() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "before")
        let script = "echo during > a.txt; echo made > b.txt; sleep 1.5; echo later > c.txt; exit 3"
        let result = try sandbox.agentUndo(["run", "--every", "0.5", "--", "sh", "-c", script])
        #expect(result.status == 3)
        let store = try sandbox.store()
        let snapshots = try store.snapshots()
        #expect(snapshots.count >= 3)
        #expect(try store.entries(of: snapshots[0].tree).keys.sorted() == ["a.txt"])
        #expect(try store.entries(of: snapshots.last!.tree).keys.sorted() == ["a.txt", "b.txt", "c.txt"])
        // Undo all the way back to before the command.
        _ = try store.undo(to: snapshots[0].id)
        #expect(sandbox.read("a.txt") == "before")
        #expect(!sandbox.exists("b.txt"))
    }

    @Test func runPassesSignalsThroughAndReportsThem() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        // The command ends by a signal, so mulligan ends by the same one.
        let result = try sandbox.agentUndo(["run", "--", "sh", "-c", "kill -TERM $$"])
        #expect(result.status == SIGTERM)
        // And the command starts with broken pipes handled normally, not ignored.
        let pipeline = try sandbox.agentUndo(["run", "--", "sh", "-c", "yes | head -n 1"])
        #expect(pipeline.status == 0)
        #expect(!pipeline.err.contains("Broken pipe"))
        #expect(try sandbox.agentUndo(["run", "--", "no-such-program-here"]).status != 0)
        #expect(try sandbox.agentUndo(["run"]).status == 2)
    }

    @Test func clearNeedsConfirmation() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        _ = try sandbox.agentUndo(["snap"])
        let refused = try sandbox.agentUndo(["clear"])
        #expect(refused.status == 2)
        #expect(try sandbox.store().snapshots().count == 1)
        let store = try sandbox.store()
        #expect(try sandbox.agentUndo(["clear", "--yes"]).status == 0)
        #expect(!FileManager.default.fileExists(atPath: store.gitDir))
        #expect(Store.recordedProject(in: store.folder) == nil)
        #expect(sandbox.read("a.txt") == "a")
        #expect(try sandbox.agentUndo(["list"]).status == 1)
    }

    @Test func pruneAndSetupCommands() throws {
        let sandbox = try Sandbox()
        for index in 1...3 {
            try sandbox.write("a.txt", "\(index)")
            _ = try sandbox.agentUndo(["snap"])
        }
        let prune = try sandbox.agentUndo(["prune", "--keep", "1"])
        #expect(prune.status == 0, "\(prune.err)")
        #expect(prune.out.contains("Dropped 2 snapshots"))
        #expect(try sandbox.agentUndo(["setup"]).out.contains("mulligan setup codex"))
        #expect(try sandbox.agentUndo(["setup", "codex"]).out.contains("UserPromptSubmit"))
        #expect(try sandbox.agentUndo(["setup", "nope"]).status == 2)
    }

    @Test func hostileFileNamesArePrintedSafely() throws {
        let sandbox = try Sandbox()
        try sandbox.write("plain.txt", "a")
        _ = try sandbox.agentUndo(["snap"])
        try sandbox.write("evil\u{1b}[31mred.txt", "x")
        let list = try sandbox.agentUndo(["undo"])
        #expect(list.status == 0)
        #expect(!list.out.contains("\u{1b}"))
    }
}

@Suite("Setup snippets, run as an agent would")
struct SnippetTests {
    /// Every hook command in the printed setup JSON, run through a shell the way the agent runs
    /// it, with a made-up payload. Uses a throwaway HOME and no real agent or agent config.
    @Test(arguments: ["codex", "claude", "gemini", "cursor", "copilot", "qwen"])
    func hookCommandsWork(agent: String) throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        let text = try #require(Setup.instructions(for: agent))
        let start = try #require(text.firstIndex(of: "{"))
        let end = try #require(text.range(of: "\n}\n", range: start..<text.endIndex))
        let json = try #require(try JSONSerialization.jsonObject(with: Data((String(text[start..<end.lowerBound]) + "\n}").utf8)) as? [String: Any])
        var commands: [String] = []
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                for key in ["command", "bash"] { if let command = object[key] as? String { commands.append(command) } }
                object.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        collect(json["hooks"] ?? [:])
        #expect(!commands.isEmpty)
        var environment = sandbox.environment
        environment["PATH"] = (Sandbox.binary as NSString).deletingLastPathComponent + ":" + (environment["PATH"] ?? "")
        for (index, command) in commands.enumerated() {
            try sandbox.write("a.txt", "step \(index)")
            let payload = #"{"cwd":"\#(sandbox.project)","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"step \#(index)"}}"#
            let result = try Sandbox.spawn(["/bin/sh", "-c", command], in: sandbox.home, environment: environment, input: Data(payload.utf8))
            #expect(result.status == 0)
            #expect(result.output.isEmpty)
            #expect(result.error.isEmpty)
        }
        let snapshots = try sandbox.store().snapshots()
        #expect(snapshots.count == commands.count)
        #expect(snapshots.allSatisfy { $0.agent == agent })
    }

    @Test func codexNotifyLineWorks() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        // notify = ["mulligan", "hook", "codex"]: Codex adds the JSON as one more argument.
        let line = try #require(Setup.codex.split(separator: "\n").first { $0.hasPrefix("notify = ") })
        let words = try #require(try JSONSerialization.jsonObject(with: Data(line.dropFirst("notify = ".count).utf8)) as? [String])
        #expect(words == ["mulligan", "hook", "codex"])
        let payload = #"{"type":"agent-turn-complete","cwd":"\#(sandbox.project)","input-messages":["x"]}"#
        let result = try Sandbox.spawn([Sandbox.binary] + words.dropFirst() + [payload], in: sandbox.home, environment: sandbox.environment)
        #expect(result.status == 0)
        #expect(try sandbox.store().snapshots().count == 1)
    }
}

@Suite("Timeline bookkeeping")
struct BookkeepingTests {
    @Test func positionRoundTrips() {
        let position = Position(id: 4, tree: "abc", mark: 9, redo: [9, 6])
        #expect(Position(text: position.text) == position)
        #expect(Position(text: "nonsense") == nil)
        #expect(Position(text: "position 1 t 2\n")?.redo == [])
    }

    @Test func messagesRoundTrip() {
        let message = Store.message(for: SnapshotRequest(label: "Bash: rm -rf build\u{1b}[0m", agent: "codex", event: .tool), skipped: 2)
        let parsed = Store.parse(message: message)
        #expect(parsed.agent == "codex")
        #expect(parsed.event == .tool)
        #expect(parsed.skipped == 2)
        #expect(!parsed.label.contains("\u{1b}"))
    }

    @Test func limitsPickTheRightSnapshots() throws {
        let sandbox = try Sandbox()
        let store = try sandbox.store()
        let now = Date()
        let all = (1...6).map { id in
            Snapshot(id: id, commit: "c", tree: "t\(id)", date: now.addingTimeInterval(Double(id - 7) * 86_400), label: "", agent: nil, event: .manual, skipped: 0)
        }
        #expect(store.overLimits(all, now: now, keep: 4, maxAgeDays: 100) == [1, 2])
        #expect(store.overLimits(all, now: now, keep: 100, maxAgeDays: 3) == [1, 2, 3])
        #expect(store.overLimits(all, now: now.addingTimeInterval(1e9), keep: 100, maxAgeDays: 1) == [1, 2, 3, 4, 5])
        #expect(store.overLimits(Array(all.prefix(1)), now: now.addingTimeInterval(1e9), keep: 1, maxAgeDays: 1).isEmpty)
    }

    @Test func listMarksWhereUndoLeftYourFiles() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "1")
        _ = try sandbox.agentUndo(["snap", "-m", "one"])
        try sandbox.write("a.txt", "2")
        _ = try sandbox.agentUndo(["snap", "-m", "two"])
        _ = try sandbox.agentUndo(["undo"])
        let list = try sandbox.agentUndo(["list"])
        #expect(list.out.contains("◀ your files"))
        #expect(list.out.contains("redo"))
    }

    @Test func watchSnapshotsUntilInterrupted() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Sandbox.binary)
        process.arguments = ["watch", "--every", "0.5"]
        process.environment = sandbox.environment
        process.currentDirectoryURL = URL(fileURLWithPath: sandbox.project)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        func waitFor(_ count: Int) throws {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline, (try? sandbox.store().snapshots().count) ?? 0 < count {
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        try waitFor(1)
        try sandbox.write("b.txt", "made while watching")
        try waitFor(2)
        process.interrupt()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let snapshots = try sandbox.store().snapshots()
        #expect(snapshots.count == 2)
        #expect(snapshots.last?.event == .watch)
    }
}
