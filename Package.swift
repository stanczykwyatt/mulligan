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
        // One C function, for the one thing Swift 6 can't do on Linux: change stdout's buffering.
        .target(name: "LineBuffer"),
        .executableTarget(name: "mulligan", dependencies: ["UndoCore", "LineBuffer"]),
        // The tests run the command line tool too, so it's listed here to be built first.
        .testTarget(name: "UndoCoreTests", dependencies: ["UndoCore", "mulligan"]),
    ]
)
