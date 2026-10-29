import Foundation
import Testing
@testable import UndoCore

@Suite("Paths and text")
struct PathsAndTextTests {
    @Test func cleansPaths() {
        #expect(Paths.clean("/a/./b//c/../d/") == "/a/b/d")
        #expect(Paths.clean("/../..") == "/")
        #expect(Paths.clean("/") == "/")
    }

    @Test func tellsWhatsInside() {
        #expect(Paths.isInside("/a/b", "/a"))
        #expect(Paths.isInside("/a", "/a"))
        #expect(!Paths.isInside("/ab", "/a"))
        #expect(Paths.isInside("/anything", "/"))
        #expect(Paths.relative("/a/b/c", to: "/a") == "b/c")
        #expect(Paths.relative("/a", to: "/a") == "")
        #expect(Paths.relative("/b", to: "/a") == nil)
    }

    @Test func listsParents() {
        #expect(Paths.parents("a/b/c.txt") == ["a", "a/b"])
        #expect(Paths.parents("c.txt").isEmpty)
    }

    @Test func fingerprintsAreStableAndDistinct() {
        #expect(Paths.fingerprint("/x/project") == Paths.fingerprint("/x/project"))
        #expect(Paths.fingerprint("/x/project") != Paths.fingerprint("/x/project2"))
        #expect(Paths.fingerprint("/x").count == 16)
    }

    @Test func storeFoldersHaveReadableSafeNames() {
        let name = Store.folderName(for: "/Users/x/My Project ✨")
        #expect(name.hasPrefix("My_Project__-"))
        #expect(!name.contains("/"))
        #expect(Store.folderName(for: "/..").hasPrefix("project-"))
    }

    @Test func safeTextCantDriveTheTerminal() {
        let hostile = "evil\u{1b}[2J\u{1b}]0;title\u{07}name\u{202e}txt.exe\nnext"
        let safe = Text.safe(hostile)
        #expect(!safe.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f })
        #expect(!safe.contains("\u{202e}"))
        #expect(safe.contains("name"))
    }

    @Test func linesAreCutWithAnEllipsis() {
        #expect(Text.line("a   b\n c", limit: 20) == "a b c")
        let cut = Text.line(String(repeating: "word ", count: 40), limit: 20)
        #expect(cut.count <= 20)
        #expect(cut.hasSuffix("…"))
    }

    @Test func saysHowLongAgo() {
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(Text.ago(now.addingTimeInterval(-10), now: now) == "just now")
        #expect(Text.ago(now.addingTimeInterval(-300), now: now) == "5 min ago")
        #expect(Text.ago(now.addingTimeInterval(-7200), now: now) == "2 h ago")
        #expect(Text.ago(now.addingTimeInterval(-90_000), now: now) == "yesterday")
        #expect(Text.ago(now.addingTimeInterval(-86_400 * 5), now: now) == "5 days ago")
        #expect(Text.ago(now.addingTimeInterval(-86_400 * 40), now: now).count == 10)
    }

    @Test func saysSizes() {
        #expect(Text.bytes(512) == "512 bytes")
        #expect(Text.bytes(3_400_000) == "3.4 MB")
        #expect(Text.bytes(250_000) == "250 KB")
        #expect(Text.count(1, "file") == "1 file")
        #expect(Text.count(3, "file") == "3 files")
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func defaultsLiveUnderLocalShare() throws {
        let settings = try Settings.load(environment: ["HOME": "/home/someone"])
        #expect(settings.dataHome == "/home/someone/.local/share/mulligan")
        #expect(settings.maxFileBytes == 10 << 20)
        #expect(settings.keep == 500)
        #expect(settings.keepPrompts)
    }

    @Test func followsXDGAndTheOverride() throws {
        #expect(try Settings.dataHome(environment: ["HOME": "/h", "XDG_DATA_HOME": "/xdg"]) == "/xdg/mulligan")
        #expect(try Settings.dataHome(environment: ["HOME": "/h", "MULLIGAN_HOME": "/custom/"]) == "/custom")
        #expect(throws: UndoError.self) { try Settings.dataHome(environment: ["MULLIGAN_HOME": "relative"]) }
        #expect(throws: UndoError.self) { try Settings.dataHome(environment: [:]) }
        #expect(throws: UndoError.self) { try Settings.dataHome(environment: ["HOME": "/"]) }
    }

    @Test func readsTheConfigFileAndEnvironmentWins() throws {
        let sandbox = try Sandbox(git: false)
        try FileManager.default.createDirectory(atPath: sandbox.data, withIntermediateDirectories: true)
        let config = "# limits\nmax-file-mb = 3\nkeep = 50   # fifty\nprompts = off\nunknown = 1\n"
        FileManager.default.createFile(atPath: sandbox.data + "/config", contents: Data(config.utf8))
        var settings = try Settings.load(environment: ["MULLIGAN_HOME": sandbox.data])
        #expect(settings.maxFileBytes == 3 << 20)
        #expect(settings.keep == 50)
        #expect(!settings.keepPrompts)
        settings = try Settings.load(environment: ["MULLIGAN_HOME": sandbox.data, "MULLIGAN_KEEP": "7", "MULLIGAN_PROMPTS": "on"])
        #expect(settings.keep == 7)
        #expect(settings.keepPrompts)
    }

    @Test func refusesNonsense() {
        #expect(throws: UndoError.self) { try Settings.load(environment: ["MULLIGAN_HOME": "/nowhere", "MULLIGAN_KEEP": "lots"]) }
        #expect(throws: UndoError.self) { try Settings.load(environment: ["MULLIGAN_HOME": "/nowhere", "MULLIGAN_KEEP": "0"]) }
        #expect(throws: UndoError.self) { try Settings.load(environment: ["MULLIGAN_HOME": "/nowhere", "MULLIGAN_PROMPTS": "maybe"]) }
        #expect(throws: UndoError.self) { try Settings.load(environment: ["MULLIGAN_HOME": "/nowhere", "MULLIGAN_MAX_FILE_MB": "-1"]) }
    }
}

@Suite("Reading agents' hook payloads")
struct HookPayloadTests {
    func parse(_ json: String, agent: String = "x", prompts: Bool = true) -> HookEvent {
        Hooks.parse(Data(json.utf8), agent: agent, keepPrompts: prompts)
    }

    @Test func claudePrompt() {
        let event = parse(#"{"session_id":"s","cwd":"/p","hook_event_name":"UserPromptSubmit","prompt":"add a 7-day forecast\nplease"}"#)
        #expect(event.cwd == "/p")
        #expect(event.event == .prompt)
        #expect(event.label == "prompt: “add a 7-day forecast please”")
    }

    @Test func promptsCanBeLeftOut() {
        let event = parse(#"{"hook_event_name":"UserPromptSubmit","prompt":"secret plans"}"#, prompts: false)
        #expect(event.label == "prompt")
    }

    @Test func claudeShellAndEdit() {
        let bash = parse(#"{"cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"npm run format"}}"#)
        #expect(bash.event == .tool)
        #expect(bash.label == "Bash: npm run format")
        let edit = parse(#"{"cwd":"/p","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/p/src/app.ts","old_string":"a","new_string":"b"}}"#)
        #expect(edit.label == "Edit: src/app.ts")
    }

    @Test func turnEnds() {
        #expect(parse(#"{"hook_event_name":"Stop"}"#).event == .turn)
        #expect(parse(#"{"hook_event_name":"AfterAgent","prompt":"x"}"#).event == .turn)
        #expect(parse(#"{"hook_event_name":"agentStop"}"#).event == .turn)
        #expect(parse(#"{"hook_event_name":"userPromptSubmitted","prompt":"x"}"#).event == .prompt)
        #expect(parse(#"{"hook_event_name":"SessionStart"}"#).label == "session started")
    }

    @Test func codexNotify() {
        let json = #"{"type":"agent-turn-complete","thread-id":"t","turn-id":"1","cwd":"/p","input-messages":["first","rename the API client"],"last-assistant-message":"done"}"#
        let event = parse(json, agent: "codex")
        #expect(event.cwd == "/p")
        #expect(event.event == .turn)
    }

    @Test func codexHooks() {
        let tool = parse(#"{"cwd":"/p","hook_event_name":"PreToolUse","tool_name":"apply_patch","tool_input":{"command":["apply_patch","*** Begin Patch\n*** End Patch"]}}"#)
        #expect(tool.event == .tool)
        #expect(tool.label == "apply_patch")
        let patch = "*** Begin Patch\n*** Update File: src/forecast.ts\n@@\n-a\n+b\n*** Add File: src/week.ts\n+x\n*** End Patch"
        let payload = try! JSONSerialization.data(withJSONObject: [
            "cwd": "/p", "hook_event_name": "PreToolUse", "tool_name": "apply_patch", "tool_input": ["command": patch],
        ])
        #expect(Hooks.parse(payload, agent: "codex", keepPrompts: true).label == "apply_patch: src/forecast.ts and 1 more")
    }

    @Test func geminiEvents() {
        #expect(parse(#"{"cwd":"/p","hook_event_name":"BeforeAgent","prompt":"hi"}"#).event == .prompt)
        let tool = parse(#"{"cwd":"/p","hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"command":"ls"}}"#)
        #expect(tool.event == .tool)
        #expect(tool.label == "run_shell_command: ls")
    }

    @Test func cursorAndCopilot() {
        let cursor = parse(#"{"hook_event_name":"afterFileEdit","workspace_roots":["/w"],"file_path":"/w/a.ts"}"#)
        #expect(cursor.cwd == "/w")
        let copilot = parse(#"{"cwd":"/c","toolName":"bash","toolArgs":{"command":"make"}}"#)
        #expect(copilot.event == .tool)
        #expect(copilot.label == "bash: make")
    }

    @Test func survivesGarbage() {
        let nothing = Hooks.parse(nil, agent: "opencode", keepPrompts: true)
        #expect(nothing.cwd == nil)
        #expect(nothing.event == .turn)
        let junk = Hooks.parse(Data("not json {".utf8), agent: "x", keepPrompts: true)
        #expect(junk.cwd == nil)
        let array = Hooks.parse(Data("[1,2]".utf8), agent: "x", keepPrompts: true)
        #expect(array.cwd == nil)
    }

    @Test func labelsAreSafeAndShort() {
        let event = parse(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"echo \u001b[31mred\u001b[0m && "# + String(repeating: "x", count: 300) + #""}}"#)
        #expect(!event.label.contains("\u{1b}"))
        #expect(event.label.count <= 90)
    }

    @Test func eventNameFromTheCommandLineWins() {
        let event = Hooks.parse(Data(#"{"prompt":"x"}"#.utf8), agent: "aider", eventName: "Stop", keepPrompts: true)
        #expect(event.event == .turn)
    }
}

@Suite("Setup instructions")
struct SetupTests {
    @Test func everyAgentHasInstructionsThatCallTheHook() throws {
        for name in Setup.names {
            let text = try #require(Setup.instructions(for: name))
            if name != "other" { #expect(text.contains("mulligan")) }
        }
        #expect(Setup.instructions(for: "nonsense") == nil)
        for name in ["codex", "claude", "gemini", "cursor", "copilot", "qwen"] {
            #expect(Setup.instructions(for: name)?.contains("mulligan hook \(name)") == true)
        }
    }

    @Test func jsonSnippetsAreValidJSON() throws {
        for name in ["codex", "claude", "gemini", "cursor", "copilot", "qwen"] {
            let text = try #require(Setup.instructions(for: name))
            let start = try #require(text.firstIndex(of: "{"))
            // The snippet ends at the line holding only "}".
            let end = try #require(text.range(of: "\n}\n", range: start..<text.endIndex))
            let json = String(text[start..<end.lowerBound]) + "\n}"
            let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
            #expect(parsed?["hooks"] != nil, "\(name)")
        }
    }
}
