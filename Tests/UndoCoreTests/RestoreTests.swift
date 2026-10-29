import Foundation
import Testing
@testable import UndoCore

@Suite("Undo, redo and restore")
struct RestoreTests {
    @Test func undoPutsEditsDeletesAndNewFilesBack() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "original")
        try sandbox.write("b.txt", "keep me")
        let before = sandbox.projectFiles()
        _ = try sandbox.snap("before the agent", event: .prompt)
        try sandbox.write("a.txt", "agent rewrote this")
        try sandbox.remove("b.txt")
        try sandbox.write("new/c.txt", "agent made this")
        let result = try sandbox.store().undo()
        #expect(sandbox.projectFiles() == before)
        #expect(!sandbox.exists("new"))
        #expect(result.target.id == 1)
        #expect(result.before.id == 2)
        #expect(Set(result.changes.map(\.path)) == ["a.txt", "b.txt", "new/c.txt"])
    }

    @Test func undoIsUndoableWithRedoAndWithUndoID() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "one")
        _ = try sandbox.snap()
        try sandbox.write("a.txt", "two")
        let after = sandbox.projectFiles()
        let result = try sandbox.store().undo()
        #expect(sandbox.read("a.txt") == "one")
        _ = try sandbox.store().redo()
        #expect(sandbox.projectFiles() == after)
        _ = try sandbox.store().undo(to: 1)
        #expect(sandbox.read("a.txt") == "one")
        _ = try sandbox.store().undo(to: result.before.id)
        #expect(sandbox.projectFiles() == after)
    }

    @Test func repeatedUndoStepsBackAndRedoStepsForward() throws {
        let sandbox = try Sandbox()
        for text in ["A", "B", "C"] {
            try sandbox.write("a.txt", text)
            _ = try sandbox.snap(text)
        }
        try sandbox.write("a.txt", "D")
        let store = try sandbox.store()
        _ = try store.undo()
        #expect(sandbox.read("a.txt") == "C")
        _ = try store.undo()
        #expect(sandbox.read("a.txt") == "B")
        _ = try store.undo()
        #expect(sandbox.read("a.txt") == "A")
        #expect(throws: UndoError.nothingToUndo) { try store.undo() }
        _ = try store.redo()
        #expect(sandbox.read("a.txt") == "B")
        _ = try store.redo()
        #expect(sandbox.read("a.txt") == "C")
        _ = try store.redo()
        #expect(sandbox.read("a.txt") == "D")
        #expect(throws: UndoError.self) { try store.redo() }
        // Stepping back and forth doesn't fill the timeline: only D needed a snapshot.
        #expect(try store.snapshots().count == 4)
    }

    @Test func undoAfterNewChangesTakesThoseBackFirst() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "A")
        _ = try sandbox.snap()
        try sandbox.write("a.txt", "B")
        let store = try sandbox.store()
        _ = try store.undo()
        #expect(sandbox.read("a.txt") == "A")
        try sandbox.write("a.txt", "edited after the undo")
        #expect(throws: UndoError.self) { try store.redo() }
        _ = try store.undo()
        #expect(sandbox.read("a.txt") == "A")
        _ = try store.redo()
        #expect(sandbox.read("a.txt") == "edited after the undo")
    }

    @Test func undoAfterNewWorkThatEndedWhereTheUndoLeftOffStepsBackOneStep() throws {
        let sandbox = try Sandbox()
        for text in ["A", "B", "C"] {
            try sandbox.write("a.txt", text)
            _ = try sandbox.snap(text)
        }
        let store = try sandbox.store()
        _ = try store.undo()
        #expect(sandbox.read("a.txt") == "B")
        // The agent does something, then changes it back.
        try sandbox.write("a.txt", "D")
        _ = try sandbox.snap("D")
        try sandbox.write("a.txt", "B")
        _ = try sandbox.snap("back to B")
        _ = try store.undo()
        #expect(sandbox.read("a.txt") == "D")
        _ = try store.redo()
        #expect(sandbox.read("a.txt") == "B")
        #expect(throws: UndoError.self) { try store.redo() }
    }

    @Test func restoreTakesOnlyThePathsAsked() throws {
        let sandbox = try Sandbox()
        try sandbox.write("src/a.txt", "a1")
        try sandbox.write("src/b.txt", "b1")
        try sandbox.write("docs/readme.md", "r1")
        _ = try sandbox.snap()
        try sandbox.write("src/a.txt", "a2")
        try sandbox.write("src/b.txt", "b2")
        try sandbox.write("src/new.txt", "made later")
        try sandbox.write("docs/readme.md", "r2")
        let store = try sandbox.store()
        _ = try store.restore(["src/a.txt"], from: 1)
        #expect(sandbox.read("src/a.txt") == "a1")
        #expect(sandbox.read("src/b.txt") == "b2")
        _ = try store.restore(["src"], from: 1)
        #expect(sandbox.read("src/b.txt") == "b1")
        #expect(!sandbox.exists("src/new.txt"))
        #expect(sandbox.read("docs/readme.md") == "r2")
        // The restores can be taken back.
        _ = try store.undo()
        #expect(sandbox.read("src/b.txt") == "b2")
        #expect(sandbox.read("src/new.txt") == "made later")
    }

    @Test func restoringAPathThatWasNeverThereFails() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        _ = try sandbox.snap()
        #expect(throws: UndoError.notInSnapshot("missing.txt", 1)) { try sandbox.store().restore(["missing.txt"], from: 1) }
        #expect(throws: UndoError.noSuchSnapshot("#99")) { try sandbox.store().restore(["a.txt"], from: 99) }
        #expect(throws: UndoError.noSuchSnapshot("#99")) { try sandbox.store().undo(to: 99) }
    }

    @Test func restoringAFileTheSnapshotDidntHaveRemovesIt() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a.txt", "a")
        _ = try sandbox.snap()
        try sandbox.write("created.txt", "new")
        _ = try sandbox.store().restore(["created.txt"], from: 1)
        #expect(!sandbox.exists("created.txt"))
        // It's in the snapshot taken first, so it can come back.
        let last = try #require(try sandbox.store().snapshots().last)
        _ = try sandbox.store().restore(["created.txt"], from: last.id)
        #expect(sandbox.read("created.txt") == "new")
    }

    @Test func symlinksComeBackAsLinks() throws {
        let sandbox = try Sandbox()
        try sandbox.write("real.txt", "r")
        try sandbox.link("link", to: "real.txt")
        _ = try sandbox.snap()
        try sandbox.remove("link")
        try sandbox.write("link", "now a file")
        _ = try sandbox.store().undo()
        #expect(sandbox.kind("link") == .link)
        #expect(sandbox.linkTarget("link") == "real.txt")
    }

    @Test func executableBitComesBack() throws {
        let sandbox = try Sandbox()
        try sandbox.write("run.sh", "#!/bin/sh\necho hi\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sandbox.path("run.sh"))
        _ = try sandbox.snap()
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: sandbox.path("run.sh"))
        try sandbox.write("run.sh", "#!/bin/sh\necho changed\n")
        _ = try sandbox.store().undo()
        let mode = try FileManager.default.attributesOfItem(atPath: sandbox.path("run.sh"))[.posixPermissions] as? NSNumber
        #expect((mode?.intValue ?? 0) & 0o100 != 0)
        #expect(sandbox.read("run.sh") == "#!/bin/sh\necho hi\n")
    }

    @Test func binaryFilesComeBackByteForByte() throws {
        let sandbox = try Sandbox()
        let bytes = Data((0..<100_000).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 7) })
        try sandbox.write("blob.bin", bytes)
        try sandbox.write("crlf.txt", "a\r\nb\r\n")
        try sandbox.write(".gitattributes", "*.txt text eol=lf\n")
        _ = try sandbox.snap()
        try sandbox.write("blob.bin", Data("corrupted".utf8))
        try sandbox.write("crlf.txt", "a\nb\n")
        _ = try sandbox.store().undo()
        #expect(sandbox.bytes("blob.bin") == bytes)
        #expect(sandbox.bytes("crlf.txt") == Data("a\r\nb\r\n".utf8))
    }

    @Test func caseOnlyRenamesAreSafe() throws {
        let sandbox = try Sandbox()
        try sandbox.write("Readme.md", "x")
        _ = try sandbox.snap()
        try FileManager.default.moveItem(atPath: sandbox.path("Readme.md"), toPath: sandbox.path("tmp-name"))
        try FileManager.default.moveItem(atPath: sandbox.path("tmp-name"), toPath: sandbox.path("README.md"))
        try sandbox.write("README.md", "changed")
        let store = try sandbox.store()
        if Store.isCaseInsensitive(sandbox.project) {
            // Like git on such a disk, a change of case alone isn't a change; the contents are.
            let result = try store.undo()
            #expect(result.kept.isEmpty)
            #expect(sandbox.read("README.md") == "x")
        } else {
            _ = try store.undo()
            let names = try FileManager.default.contentsOfDirectory(atPath: sandbox.project).filter { $0 != ".git" }
            #expect(names == ["Readme.md"])
        }
    }

    @Test func aFileReplacedByAFolderAndBack() throws {
        let sandbox = try Sandbox()
        try sandbox.write("thing", "a file")
        _ = try sandbox.snap()
        try sandbox.remove("thing")
        try sandbox.write("thing/inside.txt", "now a folder")
        let after = sandbox.projectFiles()
        _ = try sandbox.store().undo()
        #expect(sandbox.kind("thing") == .file)
        #expect(sandbox.read("thing") == "a file")
        _ = try sandbox.store().redo()
        #expect(sandbox.projectFiles() == after)
    }

    @Test func emptyFoldersLeftByDeletedFilesAreCleanedUp() throws {
        let sandbox = try Sandbox()
        try sandbox.write("keep.txt", "k")
        _ = try sandbox.snap()
        try sandbox.write("deep/er/new.txt", "n")
        _ = try sandbox.store().undo()
        #expect(!sandbox.exists("deep"))
    }
}
