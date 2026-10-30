// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mulligan",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mulligan", targets: ["mulligan"]),
    ],
    targets: [
        // Finding the project, the snapshot store kept outside it, taking snapshots, the timeline,
        // and putting files back, with nothing tied to the terminal, so it can all be tested in
        // temporary folders with real git.
        .target(name: "UndoCore"),
        // One C function that sets up stdout and the signal mask before anything else runs.
        .target(name: "StartUp"),
        .executableTarget(name: "mulligan", dependencies: ["UndoCore", "StartUp"]),
        // The tests run the command line tool too, so it's listed here to be built first.
        .testTarget(name: "UndoCoreTests", dependencies: ["UndoCore", "mulligan"]),
    ]
)
