import Foundation

/// Text that came from somewhere else (file names, prompts, tool commands) made safe to print.
public enum Text {
    /// Removes control characters, escape sequences and invisible direction marks, so a file
    /// name or prompt can't move the cursor, recolor the terminal or disguise itself.
    public static func safe(_ string: String) -> String {
        var result = ""
        result.unicodeScalars.reserveCapacity(string.unicodeScalars.count)
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x09, 0x0A, 0x0D: result.unicodeScalars.append(" ")
            case 0x00...0x1F, 0x7F...0x9F: result.unicodeScalars.append("?")
            case 0x200B...0x200F, 0x202A...0x202E, 0x2066...0x2069, 0xFEFF: continue
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// One line of at most `limit` characters, with spaces collapsed and an ellipsis if cut.
    public static func line(_ string: String, limit: Int) -> String {
        let words = safe(string).split(whereSeparator: { $0 == " " })
        let joined = words.joined(separator: " ")
        guard joined.count > limit else { return joined }
        return String(joined.prefix(max(limit - 1, 0))).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "just now", "4 min ago", "3 h ago", "2 days ago", or the date.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<45: return "just now"
        case ..<3600: return "\(max(1, (seconds + 30) / 60)) min ago"
        case ..<86_400: return "\(seconds / 3600) h ago"
        case ..<(86_400 * 2): return "yesterday"
        case ..<(86_400 * 14): return "\(seconds / 86_400) days ago"
        default:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone.current
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        }
    }

    /// A byte count the way people say it: "812 KB", "3.4 MB".
    public static func bytes(_ count: Int64) -> String {
        let units = ["bytes", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        if unit == 0 { return "\(count) bytes" }
        return value < 10 ? String(format: "%.1f", value) + " " + units[unit] : "\(Int(value.rounded())) \(units[unit])"
    }

    /// "1 file", "3 files".
    public static func count(_ number: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(number) \(number == 1 ? singular : (plural ?? singular + "s"))"
    }
}

/// Plain path handling, without touching the disk unless the name says so.
public enum Paths {
    /// An absolute path with `.`, `..`, repeated and trailing slashes worked out.
    public static func clean(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The path with every symbolic link resolved, or nil if it doesn't exist.
    public static func real(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The path with links resolved as far as it exists, and the rest added on, so a folder that
    /// hasn't been made yet still compares correctly with real paths.
    public static func realAsFarAsExists(_ path: String) -> String {
        var existing = clean(path)
        var rest: [String] = []
        while existing != "/" {
            if let resolved = real(existing) {
                return rest.isEmpty ? resolved : clean(resolved + "/" + rest.reversed().joined(separator: "/"))
            }
            rest.append((existing as NSString).lastPathComponent)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return clean(path)
    }

    /// Whether `path` is `folder` or inside it.
    public static func isInside(_ path: String, _ folder: String) -> Bool {
        folder == "/" || path == folder || path.hasPrefix(folder + "/")
    }

    /// `path` relative to `folder`, which it must be inside. "" for the folder itself.
    public static func relative(_ path: String, to folder: String) -> String? {
        guard isInside(path, folder) else { return nil }
        if path == folder { return "" }
        return String(path.dropFirst(folder == "/" ? 1 : folder.count + 1))
    }

    /// Every folder a relative path sits in, outermost first: "a/b/c" → ["a", "a/b"].
    static func parents(_ relative: String) -> [String] {
        var result: [String] = []
        var index = relative.startIndex
        while let slash = relative[index...].firstIndex(of: "/") {
            result.append(String(relative[..<slash]))
            index = relative.index(after: slash)
        }
        return result
    }

    /// A short, stable fingerprint of a path (64-bit FNV-1a), for naming its store.
    static func fingerprint(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16).leftPadded(to: 16)
    }
}

extension String {
    func leftPadded(to length: Int, with character: Character = "0") -> String {
        count >= length ? self : String(repeating: character, count: length - count) + self
    }
}

/// What kind of thing is at a path, from `lstat`, so links are never followed.
enum FileKind: Equatable {
    case file, folder, link, other, missing

    init(mode: mode_t) {
        switch Int(mode) & 0o170000 {
        case 0o100000: self = .file
        case 0o040000: self = .folder
        case 0o120000: self = .link
        default: self = .other
        }
    }

    init(path: String) {
        var info = stat()
        self = lstat(path, &info) == 0 ? FileKind(mode: info.st_mode) : .missing
    }
}
