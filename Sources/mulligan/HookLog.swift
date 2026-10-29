import Foundation
import UndoCore

/// Where a hook writes what went wrong, since it can't print. Kept small: once it passes 64 KB
/// it starts over.
enum HookLog {
    static func path(_ settings: Settings) -> String { settings.dataHome + "/hook-errors.log" }

    static func record(_ message: String, settings: Settings?) {
        guard let settings else { return }
        let file = path(settings)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(Text.line(message, limit: 400))\n"
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file),
           (attributes[.size] as? NSNumber)?.intValue ?? 0 > 64 << 10 {
            try? FileManager.default.removeItem(atPath: file)
        }
        if !FileManager.default.fileExists(atPath: file) {
            try? FileManager.default.createDirectory(atPath: settings.dataHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            FileManager.default.createFile(atPath: file, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: file) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(line.utf8))
    }

    /// The newest line, if the log has one from the last week.
    static func last(settings: Settings) -> String? {
        guard let data = FileManager.default.contents(atPath: path(settings)) else { return nil }
        guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last else { return nil }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let date = ISO8601DateFormatter().date(from: String(parts[0])),
              Date().timeIntervalSince(date) < 7 * 86_400 else { return nil }
        return "\(Text.ago(date)): \(parts[1])"
    }
}
