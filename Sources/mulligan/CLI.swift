import Foundation
import UndoCore

let version = "0.1.0"

let usage = """
mulligan \(version): undo for coding agents. Snapshots your project's files as an agent works, \
so you can go back to any point.

Usage:
  mulligan list [-n COUNT | --all]       the timeline of snapshots
  mulligan diff [ID [ID2]] [--stat] [-- PATH...]
                                           what changed since snapshot ID (default: the latest)
  mulligan undo [ID]                     put your files back one step, or as they were at ID
  mulligan redo                          take back the last undo
  mulligan restore ID -- PATH...         put only these files or folders back as they were at ID
  mulligan snap [-m LABEL]               take a snapshot now
  mulligan run [--every SECONDS] -- COMMAND [ARG...]
                                           run an agent, snapshotting whenever files change
  mulligan watch [--every SECONDS]       snapshot whenever files change, until Ctrl-C
  mulligan setup [AGENT]                 how to hook up codex, claude, gemini, opencode,
                                           cursor or aider
  mulligan hook AGENT [EVENT]            what an agent's hook runs; reads its JSON on stdin
  mulligan status                        this project's snapshots, their size and the limits
  mulligan prune [--keep COUNT] [--older-than DAYS]
                                           drop old snapshots now
  mulligan clear [--yes]                 delete every snapshot of this project
  mulligan init                          use a folder without git as a project

Options:
  -C, --project DIR    work on the project at DIR instead of the current folder
  -h, --help           show this
  --version            show the version

Snapshots live in ~/.local/share/mulligan, never in your project or its .git. Every undo,
redo and restore takes a snapshot first, so it can be undone too.
"""

struct CLI {
    var arguments: [String]
    var environment: [String: String]
    var out = FileHandle.standardOutput
    var style: Style
    var errorStyle: Style

    init(arguments: [String], environment: [String: String]) {
        self.arguments = arguments
        self.environment = environment
        style = Style(environment: environment)
        errorStyle = Style(environment: environment, fd: STDERR_FILENO)
    }

    /// The home folder, from HOME, or the user database when HOME isn't set, so the home check
    /// never gets skipped.
    var home: String? {
        if let home = environment["HOME"], home.hasPrefix("/") { return Paths.real(home) ?? Paths.clean(home) }
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        let path = String(cString: directory)
        return path.hasPrefix("/") ? (Paths.real(path) ?? path) : nil
    }

    func say(_ line: String = "") { print(line) }

    func warn(_ line: String) {
        FileHandle.standardError.write(Data((errorStyle.yellow("mulligan: ") + line + "\n").utf8))
    }

    func fail(_ line: String) -> Int32 {
        FileHandle.standardError.write(Data((errorStyle.red("mulligan: ") + line + "\n").utf8))
        return 1
    }

    // MARK: - Running a command

    func run() -> Int32 {
        var words = arguments
        var projectOption: String?
        var index = 0
        while index < words.count, words[index] != "--" {
            if words[index] == "-C" || words[index] == "--project" {
                guard index + 1 < words.count else { return fail("\(words[index]) needs a folder.") }
                projectOption = words[index + 1]
                words.removeSubrange(index...(index + 1))
                continue
            }
            if words[index].hasPrefix("--project=") {
                projectOption = String(words[index].dropFirst("--project=".count))
                words.remove(at: index)
                continue
            }
            index += 1
        }
        guard let command = words.first else {
            say(usage)
            return 0
        }
        let rest = Array(words.dropFirst())
        do {
            switch command {
            case "-h", "--help", "help": say(usage); return 0
            case "--version", "version": say("mulligan \(version)"); return 0
            case "setup": return try setup(rest)
            case "hook": return hook(rest, projectOption: projectOption)
            default: break
            }
            let settings = try Settings.load(environment: environment)
            let start = try startFolder(projectOption)
            if command == "init" { return try initialize(start, settings: settings) }
            let root = try Project.root(from: start, settings: settings, home: home)
            switch command {
            case "list", "ls", "log": return try list(rest, root: root, settings: settings)
            case "diff", "show": return try diff(rest, root: root, settings: settings)
            case "undo", "back": return try undo(rest, root: root, settings: settings)
            case "redo": return try redo(rest, root: root, settings: settings)
            case "restore": return try restore(rest, root: root, settings: settings)
            case "snap", "snapshot", "save": return try snap(rest, root: root, settings: settings)
            case "run": return try Runner(cli: self, root: root, settings: settings).run(rest)
            case "watch": return try Runner(cli: self, root: root, settings: settings).watch(rest)
            case "status": return try status(rest, root: root, settings: settings)
            case "prune": return try prune(rest, root: root, settings: settings)
            case "clear": return try clear(rest, root: root, settings: settings)
            default:
                FileHandle.standardError.write(Data("mulligan: there's no command “\(Text.safe(command))”.\n\n\(usage)\n".utf8))
                return 2
            }
        } catch let error as UndoError {
            if case .usage(let message) = error {
                _ = fail(message)
                return 2
            }
            return fail(error.description)
        } catch {
            return fail("\(error)")
        }
    }

    func startFolder(_ option: String?) throws -> String {
        let cwd = FileManager.default.currentDirectoryPath
        guard let option else { return cwd }
        return option.hasPrefix("/") ? option : Paths.clean(cwd + "/" + option)
    }

    func open(_ root: String, _ settings: Settings, create: Bool) throws -> Store {
        try Store.open(root: root, settings: settings, environment: environment, create: create)
    }

    func needsNoArguments(_ rest: [String], _ command: String) throws {
        if let extra = rest.first { throw UndoError.usage("\(command) doesn't take “\(Text.safe(extra))”. See `mulligan help`.") }
    }

    func snapshotID(_ text: String) throws -> Int {
        let digits = text.hasPrefix("#") ? String(text.dropFirst()) : text
        guard let id = Int(digits), id > 0 else {
            throw UndoError.usage("“\(Text.safe(text))” isn't a snapshot number. `mulligan list` shows them.")
        }
        return id
    }

    // MARK: - Commands

    func initialize(_ start: String, settings: Settings) throws -> Int32 {
        guard let folder = Paths.real(start) else { throw UndoError.notAProject(start) }
        try Project.check(folder, settings: settings, home: home)
        let store = try open(folder, settings, create: true)
        let result = try store.snapshot(SnapshotRequest(label: "set up", event: .manual))
        say("Set up \(style.bold(tilde(folder, home: home))). Snapshot #\(result.snapshot.id) holds its files as they are now.")
        reportSkipped(result.skipped)
        return 0
    }

    func snap(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        var label = "snapshot"
        var agent: String?
        var index = 0
        while index < rest.count {
            switch rest[index] {
            case "-m", "--message":
                guard index + 1 < rest.count else { throw UndoError.usage("-m needs a label.") }
                label = rest[index + 1]
                index += 2
            case "--agent":
                guard index + 1 < rest.count else { throw UndoError.usage("--agent needs a name.") }
                agent = rest[index + 1]
                index += 2
            default:
                throw UndoError.usage("snap doesn't take “\(Text.safe(rest[index]))”. Use -m to give it a label.")
            }
        }
        let store = try open(root, settings, create: true)
        let previous = try store.snapshots().last
        let result = try store.snapshot(SnapshotRequest(label: label, agent: agent, event: .manual))
        if result.created {
            if let previous {
                let changes = try store.changes(from: previous.tree, to: result.snapshot.tree)
                say("Snapshot \(style.bold("#\(result.snapshot.id)")): \(Text.count(changes.count, "file")) changed since #\(previous.id).")
            } else {
                say("Snapshot \(style.bold("#\(result.snapshot.id)")): the first one for \(tilde(root, home: home)).")
            }
        } else {
            say("Nothing changed since #\(result.snapshot.id), so no new snapshot.")
        }
        reportSkipped(result.skipped)
        return 0
    }

    func reportSkipped(_ skipped: [Skipped]) {
        guard !skipped.isEmpty else { return }
        warn("left out of snapshots, and never touched by a restore: " + skipped.prefix(5).map(describe).joined(separator: ", ")
            + (skipped.count > 5 ? ", and \(skipped.count - 5) more" : "") + ".")
    }

    func list(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        var limit = 20
        var index = 0
        while index < rest.count {
            switch rest[index] {
            case "--all", "-a": limit = Int.max; index += 1
            case "-n":
                guard index + 1 < rest.count, let value = Int(rest[index + 1]), value > 0 else { throw UndoError.usage("-n needs a number.") }
                limit = value
                index += 2
            default: throw UndoError.usage("list doesn't take “\(Text.safe(rest[index]))”.")
            }
        }
        let store = try open(root, settings, create: false)
        let all = try store.snapshots()
        guard !all.isEmpty else { throw UndoError.noSnapshots(root) }
        let (current, _) = try store.currentTree()
        let position = store.currentPosition()
        let shown = Array(all.suffix(limit))
        let now = Date()

        say("\(style.bold((root as NSString).lastPathComponent)) · \(Text.count(all.count, "snapshot")) · \(style.dim(tilde(root, home: home)))")
        if shown.count < all.count { say(style.dim("  \(all.count - shown.count) older not shown; --all shows every one")) }
        say()
        let idWidth = String(shown.last?.id ?? 1).count + 1
        let agentWidth = min(10, shown.map { ($0.agent ?? "").count }.max() ?? 0)
        for (offset, snapshot) in shown.enumerated() {
            let nextTree = offset + 1 < shown.count ? shown[offset + 1].tree : (all.last?.id == snapshot.id ? current : nil)
            var after = ""
            if let nextTree {
                let changes = try store.changes(from: snapshot.tree, to: nextTree)
                after = tally(changes, style: style)
            }
            var line = "  " + style.bold(pad("#\(snapshot.id)", idWidth)) + "  " + style.dim(pad(Text.ago(snapshot.date, now: now), 11))
            if agentWidth > 0 { line += "  " + style.ice(pad(String((snapshot.agent ?? "").prefix(agentWidth)), agentWidth)) }
            line += "  " + pad(Text.line(describe(snapshot), limit: 52), 52)
            if !after.isEmpty { line += "  " + after }
            if snapshot.id == position, snapshot.tree == current { line += style.ice("  ◀ your files") }
            say(line)
        }
        say()
        if let latest = all.last {
            if latest.tree == current {
                say(style.dim("  Your files match #\(latest.id)."))
            } else if let position, all.first(where: { $0.id == position })?.tree == current {
                say(style.dim("  Your files match #\(position). `mulligan redo` takes the undo back."))
            } else {
                let changes = try store.changes(from: latest.tree, to: current)
                say("  " + style.bold("now") + "  \(Text.count(changes.count, "file")) changed since #\(latest.id)  " + tally(changes, style: style))
            }
        }
        say(style.dim("  `mulligan diff ID` shows what changed since a snapshot; `mulligan undo ID` goes back to it."))
        return 0
    }

    func diff(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        var ids: [Int] = []
        var stat = false
        var paths: [String] = []
        var index = 0
        while index < rest.count {
            let word = rest[index]
            if word == "--" {
                paths = try projectPaths(Array(rest[(index + 1)...]), root: root)
                break
            }
            if word == "--stat" { stat = true } else if word.hasPrefix("-") {
                throw UndoError.usage("diff doesn't take “\(Text.safe(word))”.")
            } else {
                ids.append(try snapshotID(word))
            }
            index += 1
        }
        guard ids.count <= 2 else { throw UndoError.usage("diff takes at most two snapshots.") }
        let store = try open(root, settings, create: false)
        let all = try store.snapshots()
        guard let latest = all.last else { throw UndoError.noSnapshots(root) }
        let from = try ids.first.map { try store.snapshot($0) } ?? latest
        let to = ids.count == 2 ? try store.snapshot(ids[1]).tree : try store.currentTree().tree
        var arguments = ["diff"]
        if stat { arguments.append("--stat") }
        arguments += [from.tree, to, "--"]
        arguments += paths.isEmpty ? [] : paths.map { ":(literal)" + $0 }
        if from.tree == to {
            say(style.dim(ids.count == 2 ? "#\(ids[0]) and #\(ids[1]) hold the same files." : "Your files are the same as in #\(from.id)."))
            return 0
        }
        return try store.git.display(arguments)
    }

    /// Paths typed by the user, relative to the current folder, as paths in the project.
    func projectPaths(_ typed: [String], root: String) throws -> [String] {
        let cwd = Paths.real(FileManager.default.currentDirectoryPath) ?? FileManager.default.currentDirectoryPath
        return try typed.map { word in
            let absolute = word.hasPrefix("/") ? Paths.clean(word) : Paths.clean(cwd + "/" + word)
            // The folder holding the path is resolved, so a project reached through a link still matches.
            let parent = (absolute as NSString).deletingLastPathComponent
            let resolved = (Paths.real(parent).map { $0 == "/" ? "/" + (absolute as NSString).lastPathComponent : $0 + "/" + (absolute as NSString).lastPathComponent }) ?? absolute
            guard let relative = Paths.relative(resolved, to: root) ?? Paths.relative(absolute, to: root) else {
                throw UndoError.outsideProject(word)
            }
            if relative == ".git" || relative.hasPrefix(".git/") {
                throw UndoError.usage("mulligan never touches the project's .git.")
            }
            return relative
        }
    }

    func undo(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        guard rest.count <= 1 else { throw UndoError.usage("undo takes at most one snapshot number.") }
        let id = try rest.first.map(snapshotID)
        let store = try open(root, settings, create: false)
        let result = try store.undo(to: id)
        report(result, verb: "Back to")
        return 0
    }

    func redo(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        try needsNoArguments(rest, "redo")
        let store = try open(root, settings, create: false)
        let result = try store.redo()
        report(result, verb: "Redone: back to")
        return 0
    }

    func restore(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        guard let separator = rest.firstIndex(of: "--"), separator == 1, rest.count > 2 else {
            throw UndoError.usage("Use: mulligan restore ID -- PATH...  (the -- keeps a file name from being read as an option)")
        }
        let id = try snapshotID(rest[0])
        let paths = try projectPaths(Array(rest[2...]), root: root)
        let store = try open(root, settings, create: false)
        let result = try store.restore(paths, from: id)
        report(result, verb: "Restored from")
        return 0
    }

    func report(_ result: RestoreResult, verb: String) {
        let target = result.target
        say("\(verb) \(style.bold("#\(target.id)")) \(style.dim("(\(Text.line(describe(target), limit: 60)), \(Text.ago(target.date)))")).")
        if result.changes.isEmpty {
            say("Your files already matched it, so nothing changed.")
        } else {
            say("\(Text.count(result.changes.count, "file")) changed:")
            changeLines(result.changes, style: style).forEach { say($0) }
        }
        if !result.kept.isEmpty {
            warn("left \(Text.count(result.kept.count, "path")) as it is, because the snapshot taken just before couldn't hold it:")
            for kept in result.kept.prefix(10) {
                FileHandle.standardError.write(Data("  \(Text.safe(kept.path)): \(kept.reason)\n".utf8))
            }
        }
        if let warning = result.warning { warn(warning) }
        if !result.changes.isEmpty {
            say(style.dim("Your files from just before are in #\(result.before.id). `mulligan undo \(result.before.id)` goes back to them."))
        }
    }

    func status(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        try needsNoArguments(rest, "status")
        say("\(style.dim(pad("Project", 10)))\(tilde(root, home: home))")
        guard let store = try? open(root, settings, create: false) else {
            say("\(style.dim(pad("Snapshots", 10)))none yet")
            sayLimits(settings)
            return 0
        }
        let all = try store.snapshots()
        if let first = all.first, let last = all.last {
            say("\(style.dim(pad("Snapshots", 10)))\(all.count), #\(first.id) to #\(last.id), oldest \(Text.ago(first.date)), newest \(Text.ago(last.date))")
        } else {
            say("\(style.dim(pad("Snapshots", 10)))none yet")
        }
        say("\(style.dim(pad("Stored in", 10)))\(tilde(store.folder, home: home)) (\(Text.bytes(store.size())))")
        if let position = store.currentPosition() { say("\(style.dim(pad("Undo", 10)))your files were last put back to #\(position)") }
        if let problem = HookLog.last(settings: settings) {
            say("\(style.dim(pad("Hooks", 10)))\(style.yellow("last problem:")) \(Text.line(problem, limit: 160))")
        }
        sayLimits(settings)
        return 0
    }

    func sayLimits(_ settings: Settings) {
        say("\(style.dim(pad("Limits", 10)))files up to \(megabytes(settings.maxFileBytes)), \(settings.keep) snapshots, \(settings.maxAgeDays) days, \(megabytes(settings.maxStoreBytes)) per project")
        say("\(style.dim(pad("Prompts", 10)))\(settings.keepPrompts ? "their first words label snapshots (set prompts = off to stop)" : "not kept")")
        say("\(style.dim(pad("Settings", 10)))\(tilde(settings.dataHome, home: home))/config")
    }

    /// A limit as it was set, in megabytes (2^20 bytes), or gigabytes when it's a round number.
    func megabytes(_ bytes: Int64) -> String {
        let mb = bytes >> 20
        return mb >= 1000 && mb % 1000 == 0 ? "\(mb / 1000) GB" : "\(mb) MB"
    }

    func prune(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        var keep: Int?
        var days: Int?
        var index = 0
        while index < rest.count {
            guard index + 1 < rest.count, let value = Int(rest[index + 1]), value > 0 else {
                throw UndoError.usage("Use: mulligan prune [--keep COUNT] [--older-than DAYS]")
            }
            switch rest[index] {
            case "--keep": keep = value
            case "--older-than": days = value
            default: throw UndoError.usage("Use: mulligan prune [--keep COUNT] [--older-than DAYS]")
            }
            index += 2
        }
        let store = try open(root, settings, create: false)
        let result = try store.prune(keep: keep, olderThanDays: days)
        say("Dropped \(Text.count(result.removed.count, "snapshot")). The store went from \(Text.bytes(result.sizeBefore)) to \(Text.bytes(result.sizeAfter)).")
        return 0
    }

    func clear(_ rest: [String], root: String, settings: Settings) throws -> Int32 {
        let confirmed = rest == ["--yes"] || rest == ["-y"]
        guard confirmed || rest.isEmpty else { throw UndoError.usage("Use: mulligan clear [--yes]") }
        let store = try open(root, settings, create: false)
        let count = try store.snapshots().count
        if !confirmed {
            guard isatty(STDIN_FILENO) == 1 else {
                throw UndoError.usage("This deletes all \(count) snapshots of \(tilde(root, home: home)). Run `mulligan clear --yes` to go ahead.")
            }
            Swift.print("Delete all \(count) snapshots of \(tilde(root, home: home))? Your files aren't touched. [y/N] ", terminator: "")
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else {
                say("Nothing deleted.")
                return 0
            }
        }
        try store.clear()
        say("Deleted \(Text.count(count, "snapshot")) of \(tilde(root, home: home)). Your files weren't touched.")
        return 0
    }

    // MARK: - Agents

    /// Runs from an agent's hook. Prints nothing at all and always exits 0, so it can never
    /// block the agent or end up in its context (some agents read a hook's output). A problem
    /// is written to the data folder's hook log instead, which `mulligan status` shows.
    func hook(_ rest: [String], projectOption: String?) -> Int32 {
        guard let agent = rest.first else {
            warn("hook needs the agent's name, like `mulligan hook codex`.")
            return 0
        }
        if environment["MULLIGAN_DISABLE"] == "1" { return 0 }
        // An agent that gives up on a hook stops it with a signal; take the git it's running down
        // too, rather than leave it finishing on its own.
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] { signal(signalNumber, stopHook) }
        // Codex's notify passes its JSON as the last argument; the others pipe it in.
        var eventName: String?
        var payload: Data?
        if rest.count >= 2 {
            let last = rest[rest.count - 1]
            if last.hasPrefix("{") {
                payload = Data(last.utf8)
                if rest.count >= 3 { eventName = rest[1] }
            } else {
                eventName = rest[1]
            }
        }
        if payload == nil { payload = readStandardInput() }
        var settings: Settings?
        do {
            var loaded = try Settings.load(environment: environment)
            // Agents give a hook 30 seconds or more; give up well before that.
            loaded.lockTimeout = min(loaded.lockTimeout, 10)
            settings = loaded
            let event = Hooks.parse(payload, agent: agent, eventName: eventName, keepPrompts: loaded.keepPrompts)
            let start = try startFolder(projectOption ?? event.cwd)
            let root = try Project.root(from: start, settings: loaded, home: home)
            let store = try open(root, loaded, create: true)
            _ = try store.snapshot(SnapshotRequest(label: event.label, agent: agent, event: event.event))
        } catch let error as UndoError {
            if case .notAProject = error { return 0 }
            HookLog.record("\(agent): \(error.description)", settings: settings)
        } catch {
            HookLog.record("\(agent): \(error)", settings: settings)
        }
        return 0
    }

    /// Reads what an agent pipes to its hook, if anything. Stops as soon as it holds a whole JSON
    /// object, and gives up after a few seconds with what it has, so an agent that leaves the pipe
    /// open can't hang it. Reads the descriptor directly, so a closed or odd stdin is just empty.
    func readStandardInput() -> Data? {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0 else { return nil }
        let kind = Int(info.st_mode) & 0o170000
        // A pipe, a socket or a plain file; not a terminal, a folder or a device.
        guard kind == 0o010000 || kind == 0o140000 || kind == 0o100000 else { return nil }
        let box = InputBox()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while data.count <= Hooks.payloadLimit {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                data.append(contentsOf: buffer[0..<count])
                box.set(data)
                if data.last == UInt8(ascii: "}") || data.last == UInt8(ascii: "\n"),
                   (try? JSONSerialization.jsonObject(with: data)) != nil { break }
            }
            box.set(data)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 5)
        return box.get()
    }

    func setup(_ rest: [String]) throws -> Int32 {
        guard let agent = rest.first?.lowercased() else {
            say(Setup.overview)
            return 0
        }
        guard let text = Setup.instructions(for: agent) else {
            throw UndoError.usage("mulligan doesn't know “\(Text.safe(agent))”. It knows: \(Setup.names.joined(separator: ", ")).")
        }
        say(text)
        return 0
    }
}

final class InputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    func set(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func get() -> Data? { lock.lock(); defer { lock.unlock() }; return data }
}

/// Stops the running git and exits quietly, from a signal handler: only async-signal-safe calls.
private func stopHook(_: Int32) {
    let child = runningChild
    if child > 0 { kill(child, SIGTERM) }
    _exit(0)
}
