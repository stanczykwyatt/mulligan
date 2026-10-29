import Foundation

/// What an agent's hook told mulligan, boiled down to where and what.
public struct HookEvent: Equatable, Sendable {
    public var cwd: String?
    public var event: Event
    public var label: String
}

/// Reads the JSON an agent hands its hooks. Every agent words it differently, so this looks for
/// the fields any of them use, and never fails: a payload it can't read still gets a snapshot.
public enum Hooks {
    public static let agents = ["codex", "claude", "gemini", "opencode", "cursor", "aider", "other"]

    /// The most of a payload that's read. Tool inputs can hold whole files; only a few fields
    /// are needed.
    public static let payloadLimit = 16 << 20

    public static func parse(_ data: Data?, agent: String, eventName: String? = nil, keepPrompts: Bool) -> HookEvent {
        var object: [String: Any] = [:]
        if let data, !data.isEmpty, data.count <= payloadLimit,
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            object = parsed
        }
        let roots = object["workspace_roots"] as? [Any]
        let cwd = first(object, ["cwd", "directory", "project_dir"]) ?? roots?.first as? String
        let name = eventName ?? first(object, ["hook_event_name", "hookEventName", "event", "type"]) ?? ""
        var input: [String: Any] = [:]
        for key in ["tool_input", "toolInput", "toolArgs", "args", "input"] {
            if let found = object[key] as? [String: Any] {
                input = found
                break
            }
        }
        var tool = first(object, ["tool_name", "toolName", "tool"])
        if tool == nil, string(object, "command") != nil, name.lowercased().contains("shell") { tool = "shell" }
        var prompt = first(object, ["prompt", "user_prompt"])
        if prompt == nil {
            let messages = (object["input-messages"] as? [Any]) ?? (object["input_messages"] as? [Any])
            prompt = messages?.last as? String
        }
        var detail = first(input, ["command", "cmd"]) ?? string(object, "command")
        if detail == nil, let parts = input["command"] as? [Any] {
            detail = parts.compactMap { $0 as? String }.joined(separator: " ")
        }
        if detail == nil {
            detail = first(input, ["file_path", "filePath", "path", "absolute_path"]) ?? string(object, "file_path")
        }

        // Codex's apply_patch carries a whole patch; name the files it touches instead.
        if let patch = patchText(in: input) ?? detail.flatMap({ $0.contains("*** Begin Patch") ? $0 : nil }) {
            detail = patchedFiles(patch)
        }
        let event = classify(name, hasTool: tool != nil, hasPrompt: prompt != nil)
        var label: String
        switch event {
        case .prompt:
            if keepPrompts, let prompt, !Text.line(prompt, limit: 60).isEmpty {
                label = "prompt: “\(Text.line(prompt, limit: 60))”"
            } else {
                label = "prompt"
            }
        case .tool:
            let shown = detail.map { shorten($0, cwd: cwd) }
            label = [tool ?? "tool", shown].compactMap { $0 }.joined(separator: ": ")
        case .turn:
            label = name.lowercased().contains("start") ? "session started" : "turn ended"
        default:
            label = name.isEmpty ? "hook" : name
        }
        return HookEvent(cwd: cwd, event: event, label: Text.line(label, limit: 90))
    }

    static func classify(_ name: String, hasTool: Bool, hasPrompt: Bool) -> Event {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "")
        if key.contains("prompt") || key == "beforeagent" || key == "chat.message" || key == "usermessage" { return .prompt }
        if key.contains("pretool") || key.contains("beforetool") || key.contains("execute.before")
            || key.hasPrefix("beforeshell") || key.hasPrefix("beforemcp") || key == "beforefileedit" { return .tool }
        if key == "stop" || key == "agentstop" || key.contains("afteragent") || key.contains("turncomplete") || key.contains("turnend")
            || key == "session.idle" || key == "subagentstop" || key.contains("sessionstart") || key == "sessionend" { return .turn }
        if hasTool { return .tool }
        if hasPrompt { return .prompt }
        return .turn
    }

    static func patchText(in input: [String: Any]) -> String? {
        for value in input.values {
            if let text = value as? String, text.contains("*** Begin Patch") { return text }
            if let parts = value as? [Any], let text = parts.compactMap({ $0 as? String }).first(where: { $0.contains("*** Begin Patch") }) {
                return text
            }
        }
        return nil
    }

    /// "src/a.ts", or "src/a.ts and 2 more", from a patch's "*** Update File:" lines.
    static func patchedFiles(_ patch: String) -> String? {
        var files: [String] = []
        for line in patch.split(separator: "\n") {
            for marker in ["*** Update File: ", "*** Add File: ", "*** Delete File: "] where line.hasPrefix(marker) {
                files.append(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let first = files.first else { return nil }
        return files.count == 1 ? first : "\(first) and \(files.count - 1) more"
    }

    /// A file path relative to where the agent is working, or a command's first line.
    static func shorten(_ text: String, cwd: String?) -> String {
        if let cwd, text.hasPrefix(cwd + "/") { return String(text.dropFirst(cwd.count + 1)) }
        return Text.line(text, limit: 60)
    }

    static func first(_ object: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let value = string(object, key) { return value }
        }
        return nil
    }

    static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }
}
