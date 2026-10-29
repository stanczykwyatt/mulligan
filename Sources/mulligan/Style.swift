import Foundation
import UndoCore

/// Terminal colors, only when printing to a terminal and NO_COLOR isn't set.
struct Style {
    let enabled: Bool

    init(environment: [String: String], fd: Int32 = STDOUT_FILENO) {
        enabled = isatty(fd) == 1 && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
    }

    private func wrap(_ code: String, _ text: String) -> String { enabled ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text }
    func bold(_ text: String) -> String { wrap("1", text) }
    func dim(_ text: String) -> String { wrap("2", text) }
    func green(_ text: String) -> String { wrap("32", text) }
    func yellow(_ text: String) -> String { wrap("33", text) }
    func red(_ text: String) -> String { wrap("31", text) }
    func ice(_ text: String) -> String { wrap("36", text) }
}

/// Text that lines up in columns: pads by characters, which is right for the names and labels
/// shown here.
func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

/// A path with the home folder shortened to ~.
func tilde(_ path: String, home: String?) -> String {
    guard let home, home.count > 1, Paths.isInside(path, home) else { return Text.safe(path) }
    return "~" + Text.safe(String(path.dropFirst(home.count)))
}

/// "+2 ~1 -1" for a list of changes.
func tally(_ changes: [Change], style: Style) -> String {
    let added = changes.filter { $0.kind == .added }.count
    let modified = changes.filter { $0.kind == .modified }.count
    let deleted = changes.filter { $0.kind == .deleted }.count
    var parts: [String] = []
    if added > 0 { parts.append(style.green("+\(added)")) }
    if modified > 0 { parts.append(style.yellow("~\(modified)")) }
    if deleted > 0 { parts.append(style.red("-\(deleted)")) }
    return parts.joined(separator: " ")
}

/// Up to `limit` changes, one per line, like "  ~ src/app.ts".
func changeLines(_ changes: [Change], style: Style, limit: Int = 12) -> [String] {
    var lines = changes.prefix(limit).map { change -> String in
        let path = Text.safe(change.path)
        switch change.kind {
        case .added: return "  " + style.green("+ " + path)
        case .modified: return "  " + style.yellow("~ " + path)
        case .deleted: return "  " + style.red("- " + path)
        }
    }
    if changes.count > limit { lines.append(style.dim("  …and \(changes.count - limit) more")) }
    return lines
}

/// How a snapshot reads in the timeline: what was about to happen when it was taken.
func describe(_ snapshot: Snapshot) -> String {
    switch snapshot.event {
    case .tool: return "before " + snapshot.label
    case .turn: return snapshot.label == "session started" ? "session started" : "end of turn"
    case .watch: return "files changed"
    default: return snapshot.label
    }
}

func describe(_ skipped: Skipped) -> String {
    switch skipped.reason {
    case .tooBig(let bytes): return "\(Text.safe(skipped.path)) (\(Text.bytes(bytes)), over the size limit)"
    case .nestedRepository: return "\(Text.safe(skipped.path))/ (its own git repository)"
    case .notAFile: return "\(Text.safe(skipped.path)) (not a regular file)"
    case .unreadable: return "\(Text.safe(skipped.path)) (can't be read, or git won't take its name)"
    }
}
