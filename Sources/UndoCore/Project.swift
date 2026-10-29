import Foundation

/// Works out which folder is the project, and refuses folders that are too big or too risky to
/// snapshot as a whole.
public enum Project {
    /// Folders that are never a project, even with a `.git` in them.
    static let systemFolders: Set<String> = [
        "/", "/bin", "/sbin", "/usr", "/usr/local", "/etc", "/var", "/opt", "/tmp", "/private", "/private/tmp",
        "/private/var", "/private/etc", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/home",
        "/root", "/dev", "/proc", "/sys", "/boot", "/srv", "/mnt", "/media", "/nix", "/snap",
    ]

    /// The project folder for `start`: the nearest folder at or above it that has a `.git` or was
    /// set up with `mulligan init`. Throws if there's none, or if it's a folder mulligan won't
    /// take on, like your home folder.
    public static func root(from start: String, settings: Settings, home: String?) throws -> String {
        guard let real = Paths.real(start) else { throw UndoError.notAProject(start) }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isFolder), isFolder.boolValue else {
            throw UndoError.notAProject(start)
        }
        var folder = real
        while true {
            if Store.isRegistered(folder, settings: settings) || FileManager.default.fileExists(atPath: folder + "/.git") {
                try check(folder, settings: settings, home: home)
                return folder
            }
            if folder == "/" { break }
            folder = (folder as NSString).deletingLastPathComponent
            if folder.isEmpty { folder = "/" }
        }
        throw UndoError.notAProject(real)
    }

    /// Throws if `folder` must never be snapshotted or restored as a whole.
    public static func check(_ folder: String, settings: Settings, home: String?) throws {
        if folder.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            throw UndoError.refusedRoot(folder, "its path has a line break or another control character in it.")
        }
        if systemFolders.contains(folder) {
            throw UndoError.refusedRoot(folder, "it's a system folder, not a project.")
        }
        if let home, home.hasPrefix("/") {
            let realHome = Paths.real(home) ?? Paths.clean(home)
            if folder == realHome {
                throw UndoError.refusedRoot(folder, "it's your home folder. Run mulligan inside a project, or set one up with `mulligan init` in its folder.")
            }
            if Paths.isInside(realHome, folder) {
                throw UndoError.refusedRoot(folder, "your home folder is inside it.")
            }
        }
        let data = Paths.realAsFarAsExists(settings.dataHome)
        if Paths.isInside(data, folder) {
            throw UndoError.refusedRoot(folder, "mulligan's own snapshots (\(Text.safe(data))) are inside it, so it would snapshot itself.")
        }
        if Paths.isInside(folder, data) {
            throw UndoError.refusedRoot(folder, "it's inside mulligan's own data folder.")
        }
    }
}
