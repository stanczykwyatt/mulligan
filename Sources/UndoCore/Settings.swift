import Foundation

/// Where snapshots live and how much is kept. Each value comes from an environment variable, then
/// the `config` file in the data folder, then the default.
public struct Settings: Equatable, Sendable {
    /// The folder holding every project's snapshots.
    public var dataHome: String
    /// Files bigger than this are left out of snapshots, and never touched by a restore.
    public var maxFileBytes: Int64
    /// The most snapshots kept per project. Older ones are dropped first.
    public var keep: Int
    /// Snapshots older than this many days are dropped.
    public var maxAgeDays: Int
    /// When a project's snapshots take more than this on disk, the oldest are dropped.
    public var maxStoreBytes: Int64
    /// Whether a prompt's first words are kept as the snapshot's label.
    public var keepPrompts: Bool
    /// How long to wait for another mulligan working on the same project.
    public var lockTimeout: Double

    public static let defaultMaxFileMB: Int64 = 10
    public static let defaultKeep = 500
    public static let defaultMaxAgeDays = 30
    public static let defaultMaxStoreMB: Int64 = 2000

    public init(
        dataHome: String, maxFileBytes: Int64 = defaultMaxFileMB << 20, keep: Int = defaultKeep,
        maxAgeDays: Int = defaultMaxAgeDays, maxStoreBytes: Int64 = defaultMaxStoreMB << 20, keepPrompts: Bool = true,
        lockTimeout: Double = 30
    ) {
        self.dataHome = dataHome
        self.maxFileBytes = maxFileBytes
        self.keep = keep
        self.maxAgeDays = maxAgeDays
        self.maxStoreBytes = maxStoreBytes
        self.keepPrompts = keepPrompts
        self.lockTimeout = lockTimeout
    }

    /// The data folder: `MULLIGAN_HOME`, else `$XDG_DATA_HOME/mulligan`, else
    /// `~/.local/share/mulligan`.
    public static func dataHome(environment: [String: String]) throws -> String {
        if let chosen = environment["MULLIGAN_HOME"], !chosen.isEmpty {
            guard chosen.hasPrefix("/") else { throw UndoError.badSetting("MULLIGAN_HOME must be an absolute path.") }
            return Paths.clean(chosen)
        }
        if let xdg = environment["XDG_DATA_HOME"], xdg.hasPrefix("/") {
            return Paths.clean(xdg) + "/mulligan"
        }
        guard let home = environment["HOME"], home.hasPrefix("/"), home != "/" else {
            throw UndoError.badSetting("HOME isn't set, so there's nowhere to keep snapshots. Set MULLIGAN_HOME.")
        }
        return Paths.clean(home) + "/.local/share/mulligan"
    }

    /// Reads the settings from the environment and the data folder's `config` file.
    public static func load(environment: [String: String]) throws -> Settings {
        let home = try dataHome(environment: environment)
        var settings = Settings(dataHome: home)
        var values = readConfig(at: home + "/config")
        let names = [
            "max-file-mb": "MULLIGAN_MAX_FILE_MB", "keep": "MULLIGAN_KEEP", "max-age-days": "MULLIGAN_MAX_AGE_DAYS",
            "max-store-mb": "MULLIGAN_MAX_STORE_MB", "prompts": "MULLIGAN_PROMPTS", "lock-timeout": "MULLIGAN_LOCK_TIMEOUT",
        ]
        for (key, variable) in names {
            if let value = environment[variable], !value.isEmpty { values[key] = value }
        }
        func number(_ key: String, _ range: ClosedRange<Int64>) throws -> Int64? {
            guard let text = values[key] else { return nil }
            guard let value = Int64(text.trimmingCharacters(in: .whitespaces)), range.contains(value) else {
                throw UndoError.badSetting("\(key) must be a whole number from \(range.lowerBound) to \(range.upperBound), not “\(Text.safe(text))”.")
            }
            return value
        }
        if let value = try number("max-file-mb", 1...4096) { settings.maxFileBytes = value << 20 }
        if let value = try number("keep", 1...100_000) { settings.keep = Int(value) }
        if let value = try number("max-age-days", 1...3650) { settings.maxAgeDays = Int(value) }
        if let value = try number("max-store-mb", 10...1_048_576) { settings.maxStoreBytes = value << 20 }
        if let value = try number("lock-timeout", 1...600) { settings.lockTimeout = Double(value) }
        if let text = values["prompts"]?.lowercased() {
            switch text {
            case "1", "on", "yes", "true": settings.keepPrompts = true
            case "0", "off", "no", "false": settings.keepPrompts = false
            default: throw UndoError.badSetting("prompts must be on or off, not “\(Text.safe(text))”.")
            }
        }
        return settings
    }

    /// Parses `key = value` lines. `#` starts a comment. Unknown keys are kept and ignored.
    static func readConfig(at path: String) -> [String: String] {
        guard let data = FileManager.default.contents(atPath: path), data.count < 64 << 10 else { return [:] }
        var values: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let content = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            let parts = content.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            values[key] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }
}

/// Everything that can go wrong, worded for the person reading it.
public enum UndoError: Error, CustomStringConvertible, Equatable {
    case notAProject(String)
    case refusedRoot(String, String)
    case gitMissing
    case gitTooOld(String)
    case badSetting(String)
    case busy(String)
    case noSuchSnapshot(String)
    case noSnapshots(String)
    case nothingToUndo
    case nothingToRedo(String)
    case notInSnapshot(String, Int)
    case outsideProject(String)
    case storeMismatch(String)
    case snapshotFailed(String)
    case restoreFailed(String)
    case restoreStopped(String, Int)
    case usage(String)

    public var description: String {
        switch self {
        case .notAProject(let path):
            return "\(Text.safe(path)) isn't in a project. mulligan works in a folder with a git repository, or one you've set up with `mulligan init`."
        case .refusedRoot(let path, let why):
            return "Won't snapshot \(Text.safe(path)): \(why)"
        case .gitMissing:
            return "git wasn't found. mulligan keeps its snapshots with git, so please install it first."
        case .gitTooOld(let version):
            return "git \(version) is too old. mulligan needs git 2.25 or later."
        case .badSetting(let message):
            return message
        case .busy(let path):
            return "Another mulligan is still working on \(Text.safe(path)). Try again in a moment."
        case .noSuchSnapshot(let id):
            return "There's no snapshot \(Text.safe(id)). `mulligan list` shows them."
        case .noSnapshots(let path):
            return "No snapshots yet for \(Text.safe(path)). Take one with `mulligan snap`, or set up your agent with `mulligan setup`."
        case .nothingToUndo:
            return "Nothing to undo: there's no earlier snapshot that differs from your files."
        case .nothingToRedo(let why):
            return "Nothing to redo: \(why)"
        case .notInSnapshot(let path, let id):
            return "\(Text.safe(path)) isn't in snapshot #\(id), and isn't in your files now."
        case .outsideProject(let path):
            return "\(Text.safe(path)) is outside the project."
        case .storeMismatch(let message):
            return message
        case .snapshotFailed(let message):
            return "Couldn't take a snapshot, so nothing was changed. \(message)"
        case .restoreFailed(let message):
            return "Couldn't restore, and your files were left as they were. \(message)"
        case .restoreStopped(let message, let id):
            return "The restore stopped: \(message) Your files from just before are in snapshot #\(id); `mulligan undo \(id)` puts them back."
        case .usage(let message):
            return message
        }
    }
}
