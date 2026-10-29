import Foundation
import Testing
@testable import UndoCore

@Suite("Finding the project")
struct ProjectTests {
    @Test func findsTheRepositoryAboveTheCurrentFolder() throws {
        let sandbox = try Sandbox()
        try sandbox.write("src/deep/file.txt", "x")
        let root = try Project.root(from: sandbox.path("src/deep"), settings: sandbox.settings, home: sandbox.home)
        #expect(root == sandbox.project)
    }

    @Test func refusesAFolderWithoutGitUntilItsSetUp() throws {
        let sandbox = try Sandbox(git: false)
        #expect(throws: UndoError.notAProject(sandbox.project)) {
            try Project.root(from: sandbox.project, settings: sandbox.settings, home: sandbox.home)
        }
        try sandbox.write("a.txt", "a")
        _ = try sandbox.snap()
        try sandbox.write("sub/b.txt", "b")
        #expect(try Project.root(from: sandbox.path("sub"), settings: sandbox.settings, home: sandbox.home) == sandbox.project)
    }

    @Test func refusesHomeRootAndSystemFolders() throws {
        let sandbox = try Sandbox()
        for folder in ["/", "/usr", "/tmp", "/Users", "/home"] {
            #expect(throws: UndoError.self) { try Project.check(folder, settings: sandbox.settings, home: sandbox.home) }
        }
        #expect(throws: UndoError.self) { try Project.check(sandbox.home, settings: sandbox.settings, home: sandbox.home) }
        // A folder holding the home folder is refused too.
        #expect(throws: UndoError.self) { try Project.check(sandbox.base, settings: sandbox.settings, home: sandbox.home) }
    }

    @Test func aDotfilesRepositoryInHomeIsRefused() throws {
        let sandbox = try Sandbox(git: false)
        try sandbox.sh("git", "init", "-q", ".", in: sandbox.home)
        let work = sandbox.home + "/code/app"
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        #expect(throws: UndoError.self) { try Project.root(from: work, settings: sandbox.settings, home: sandbox.home) }
    }

    @Test func refusesWhenSnapshotsWouldLandInsideTheProject() throws {
        let sandbox = try Sandbox()
        var settings = sandbox.settings
        settings.dataHome = sandbox.project + "/.undo-data"
        #expect(throws: UndoError.self) { try Project.check(sandbox.project, settings: settings, home: sandbox.home) }
        settings.dataHome = sandbox.base
        #expect(throws: UndoError.self) { try Project.check(sandbox.project, settings: settings, home: sandbox.home) }
    }

    @Test func aNestedRepositoryIsItsOwnProject() throws {
        let sandbox = try Sandbox()
        try sandbox.write("vendor/lib/a.txt", "a")
        try sandbox.sh("git", "init", "-q", ".", in: sandbox.path("vendor/lib"))
        #expect(try Project.root(from: sandbox.path("vendor/lib"), settings: sandbox.settings, home: sandbox.home) == sandbox.path("vendor/lib"))
    }

    @Test func storesAreKeptApartPerProject() throws {
        let one = try Sandbox()
        var settings = one.settings
        settings.dataHome = one.data
        let a = Store.folder(for: "/x/app", settings: settings)
        let b = Store.folder(for: "/y/app", settings: settings)
        #expect(a != b)
        #expect(a.hasPrefix(one.data + "/projects/app-"))
    }
}

@Suite("Taking snapshots")
struct SnapshotTests {
    @Test func firstSnapshotHoldsEveryFile() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "alpha")
        try sandbox.write("src/b.swift", "print(1)")
        let result = try sandbox.snap("first")
        #expect(result.created)
        #expect(result.snapshot.id == 1)
        #expect(result.snapshot.label == "first")
        #expect(result.snapshot.agent == "test")
        let entries = try sandbox.store().entries(of: result.snapshot.tree)
        #expect(Set(entries.keys) == ["a.txt", "src/b.swift"])
    }

    @Test func unchangedFilesMakeNoNewSnapshot() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "alpha")
        let first = try sandbox.snap()
        let second = try sandbox.snap()
        #expect(!second.created)
        #expect(second.snapshot.id == first.snapshot.id)
        #expect(try sandbox.store().snapshots().count == 1)
    }

    @Test func editsDeletesAndRenamesAreCaught() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "alpha")
        try sandbox.write("b.txt", "beta")
        try sandbox.write("c.txt", "gamma")
        let first = try sandbox.snap()
        try sandbox.write("a.txt", "ALPHA")
        try sandbox.remove("b.txt")
        try FileManager.default.moveItem(atPath: sandbox.path("c.txt"), toPath: sandbox.path("renamed.txt"))
        let second = try sandbox.snap()
        let changes = try sandbox.store().changes(from: first.snapshot.tree, to: second.snapshot.tree)
        #expect(changes.contains(Change(kind: .modified, path: "a.txt")))
        #expect(changes.contains(Change(kind: .deleted, path: "b.txt")))
        #expect(changes.contains(Change(kind: .deleted, path: "c.txt")))
        #expect(changes.contains(Change(kind: .added, path: "renamed.txt")))
    }

    @Test func changesMadeByShellCommandsAreCaught() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "alpha")
        let first = try sandbox.snap()
        try sandbox.sh("sh", "-c", "echo generated > made-by-shell.txt && rm a.txt && mkdir -p out && date > out/stamp")
        let second = try sandbox.snap()
        let changes = try sandbox.store().changes(from: first.snapshot.tree, to: second.snapshot.tree)
        #expect(changes.map(\.path).sorted() == ["a.txt", "made-by-shell.txt", "out/stamp"])
    }

    @Test func idsKeepCountingUp() throws {
        let sandbox = try Sandbox()
        for index in 1...4 {
            try sandbox.write("a.txt", "\(index)")
            #expect(try sandbox.snap().snapshot.id == index)
        }
        let snapshots = try sandbox.store().snapshots()
        #expect(snapshots.map(\.id) == [1, 2, 3, 4])
        #expect(snapshots.allSatisfy { $0.event == .manual })
    }

    @Test func respectsGitignoreGlobalAndInfoExclude() throws {
        let sandbox = try Sandbox()
        try sandbox.write(".gitignore", "node_modules/\n*.log\n.env\n")
        try sandbox.write("node_modules/pkg/index.js", "x")
        try sandbox.write("debug.log", "x")
        try sandbox.write(".env", "SECRET=1")
        try sandbox.write("kept.txt", "x")
        try sandbox.write("local-only.txt", "x")
        try sandbox.write("global-ignored.tmp", "x")
        try "local-only.txt\n".write(toFile: sandbox.path(".git/info/exclude"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: sandbox.home + "/.config/git", withIntermediateDirectories: true)
        try "*.tmp\n".write(toFile: sandbox.home + "/.config/git/ignore", atomically: true, encoding: .utf8)
        let result = try sandbox.snap()
        let files = Set(try sandbox.store().entries(of: result.snapshot.tree).keys)
        #expect(files == [".gitignore", "kept.txt"])
    }

    @Test func bigFilesAreLeftOutAndSaidSo() throws {
        let sandbox = try Sandbox { $0.maxFileBytes = 1024 }
        try sandbox.write("small.txt", "x")
        try sandbox.write("model.bin", Data(repeating: 7, count: 4096))
        let result = try sandbox.snap()
        #expect(result.skipped == [Skipped(path: "model.bin", reason: .tooBig(4096))])
        #expect(result.snapshot.skipped == 1)
        #expect(Set(try sandbox.store().entries(of: result.snapshot.tree).keys) == ["small.txt"])
    }

    @Test func aFileThatGrowsTooBigLeavesTheSnapshot() throws {
        let sandbox = try Sandbox { $0.maxFileBytes = 1024 }
        try sandbox.write("data.csv", "a,b\n")
        let first = try sandbox.snap()
        #expect(try sandbox.store().entries(of: first.snapshot.tree)["data.csv"] != nil)
        try sandbox.write("data.csv", Data(repeating: 65, count: 5000))
        let second = try sandbox.snap()
        // Not an old copy passed off as current: it's simply not in the snapshot.
        #expect(try sandbox.store().entries(of: second.snapshot.tree)["data.csv"] == nil)
        #expect(second.skipped.map(\.path) == ["data.csv"])
    }

    @Test func binaryFilesAreKeptExactly() throws {
        let sandbox = try Sandbox()
        let bytes = Data((0..<4096).map { UInt8(($0 * 7 + 3) % 256) })
        try sandbox.write("image.png", bytes)
        let result = try sandbox.snap()
        let entry = try #require(try sandbox.store().entries(of: result.snapshot.tree)["image.png"])
        let stored = try sandbox.store().git.run(["cat-file", "blob", entry.object])
        #expect(stored == bytes)
    }

    @Test func lineEndingsAndFiltersAreNeverApplied() throws {
        let sandbox = try Sandbox()
        // The project asks for line ending changes and a filter; snapshots must ignore both.
        try sandbox.write(".gitattributes", "*.txt text eol=lf\n*.dat filter=evil\n* ident\n")
        try sandbox.write("crlf.txt", "one\r\ntwo\r\n")
        try sandbox.write("keyword.txt", "$Id$\n")
        try sandbox.write("payload.dat", "raw")
        let result = try sandbox.snap()
        let store = try sandbox.store()
        let entries = try store.entries(of: result.snapshot.tree)
        #expect(try store.git.run(["cat-file", "blob", entries["crlf.txt"]!.object]) == Data("one\r\ntwo\r\n".utf8))
        #expect(try store.git.run(["cat-file", "blob", entries["keyword.txt"]!.object]) == Data("$Id$\n".utf8))
        #expect(try store.git.run(["cat-file", "blob", entries["payload.dat"]!.object]) == Data("raw".utf8))
    }

    @Test func symlinksAreStoredAsLinksAndNeverFollowed() throws {
        let sandbox = try Sandbox()
        let outside = sandbox.base + "/outside-secret.txt"
        try "secret".write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: sandbox.base + "/outside-folder", withIntermediateDirectories: true)
        try "also secret".write(toFile: sandbox.base + "/outside-folder/x.txt", atomically: true, encoding: .utf8)
        try sandbox.link("to-file", to: outside)
        try sandbox.link("to-folder", to: sandbox.base + "/outside-folder")
        try sandbox.link("dangling", to: "nowhere/at/all")
        let result = try sandbox.snap()
        let store = try sandbox.store()
        let entries = try store.entries(of: result.snapshot.tree)
        #expect(entries["to-file"]?.mode == "120000")
        #expect(entries["to-folder"]?.mode == "120000")
        #expect(entries["dangling"]?.mode == "120000")
        #expect(entries["to-folder/x.txt"] == nil)
        #expect(try store.git.text(["cat-file", "blob", entries["to-file"]!.object]) == outside)
    }

    @Test func nestedRepositoriesAndSubmodulesAreLeftAlone() throws {
        let sandbox = try Sandbox()
        try sandbox.write("main.txt", "x")
        try sandbox.write("nested/inner.txt", "inner")
        try sandbox.sh("git", "init", "-q", ".", in: sandbox.path("nested"))
        try sandbox.write("empty-repo/file.txt", "never committed")
        try sandbox.sh("git", "init", "-q", ".", in: sandbox.path("empty-repo"))
        // A real submodule, added from another local repository.
        let library = sandbox.base + "/library"
        try FileManager.default.createDirectory(atPath: library, withIntermediateDirectories: true)
        try sandbox.sh("git", "init", "-q", ".", in: library)
        try "lib".write(toFile: library + "/lib.txt", atomically: true, encoding: .utf8)
        try sandbox.sh("git", "add", ".", in: library)
        try sandbox.sh("git", "-c", "user.name=T", "-c", "user.email=t@t", "commit", "-qm", "lib", in: library)
        try sandbox.sh("git", "-c", "protocol.file.allow=always", "submodule", "add", "-q", library, "modules/library")

        let result = try sandbox.snap()
        let files = Set(try sandbox.store().entries(of: result.snapshot.tree).keys)
        #expect(files.contains("main.txt"))
        #expect(files.contains(".gitmodules"))
        #expect(!files.contains { $0.hasPrefix("nested/") || $0.hasPrefix("empty-repo/") || $0.hasPrefix("modules/library") })
        #expect(Set(result.skipped.map(\.path)).isSuperset(of: ["nested", "empty-repo"]))
    }

    @Test func specialFilesAreSkippedAndNeverReplaced() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        try sandbox.write("pipe", "was a file once")
        _ = try sandbox.snap()
        try sandbox.remove("pipe")
        try sandbox.sh("mkfifo", "pipe")
        let result = try sandbox.snap()
        #expect(Set(try sandbox.store().entries(of: result.snapshot.tree).keys) == ["a.txt"])
        // Going back would replace the pipe, which no snapshot holds, so it's left alone.
        let restore = try sandbox.store().undo(to: 1)
        #expect(restore.kept.map(\.path) == ["pipe"])
        #expect(sandbox.kind("pipe") == .other)
    }

    @Test func oddFileNames() throws {
        let sandbox = try Sandbox()
        let names = [
            "with space.txt", " leading space", "trailing space ", "-dash-first", "*glob?[x]", "#hash", "!bang",
            "quote\"s and 'single'", "back\\slash", "tab\there", "new\nline", "emoji 🙂.md", "café.txt", "日本語/ファイル.txt",
            ":(literal)magic", "dir with space/inner file",
        ]
        for (index, name) in names.enumerated() { try sandbox.write(name, "content \(index)") }
        let first = try sandbox.snap()
        let stored = Set(try sandbox.store().entries(of: first.snapshot.tree).keys)
        for name in names {
            #expect(stored.contains(name) || stored.contains(name.precomposedStringWithCanonicalMapping), "\(name)")
        }
        for name in names { try sandbox.write(name, "changed") }
        let before = sandbox.projectFiles()
        _ = try sandbox.store().undo(to: first.snapshot.id)
        for (index, name) in names.enumerated() { #expect(sandbox.read(name) == "content \(index)", "\(name)") }
        _ = try sandbox.store().redo()
        #expect(sandbox.projectFiles() == before)
    }

    @Test func emptyProjectIsFine() throws {
        let sandbox = try Sandbox()
        let result = try sandbox.snap()
        #expect(result.created)
        #expect(try sandbox.store().entries(of: result.snapshot.tree).isEmpty)
        #expect(throws: UndoError.nothingToUndo) { try sandbox.store().undo() }
    }

    @Test func storeIsPrivate() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        let store = try sandbox.store()
        _ = try sandbox.snap()
        for folder in [sandbox.data, store.folder] {
            let attributes = try FileManager.default.attributesOfItem(atPath: folder)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "\(folder)")
        }
        #expect(Store.recordedProject(in: store.folder) == sandbox.project)
        #expect(!FileManager.default.fileExists(atPath: store.folder + "/git/hooks"))
    }
}
