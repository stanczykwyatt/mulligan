import Foundation
import UndoCore

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// `run` and `watch`: snapshots the project every few seconds while files change, for agents
/// without hooks. Changes made by any program are caught, since each snapshot is of the files
/// themselves.
struct Runner {
    let cli: CLI
    let root: String
    let settings: Settings

    /// Runs `COMMAND` in the terminal as if it were started directly, snapshotting before it
    /// starts, while it runs, and after it ends. Exits with the command's status.
    func run(_ rest: [String]) throws -> Int32 {
        let (interval, command) = try parse(rest, needsCommand: true)
        let store = try cli.open(root, settings, create: true)
        try snap(store, label: "before \(Text.line(command.joined(separator: " "), limit: 60))", event: .manual)

        // Ctrl-C belongs to the command. mulligan catches it rather than ignoring it, so the
        // command starts with the usual handling, and keeps going until the command exits. A
        // TERM or HUP sent to mulligan itself is passed on to the command.
        pendingSignal = 0
        signal(SIGINT, interrupted)
        signal(SIGQUIT, interrupted)
        signal(SIGTERM, interrupted)
        signal(SIGHUP, interrupted)

        var arguments: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        defer { arguments.forEach { free($0) } }
        var environment = ProcessInfo.processInfo.environment
        environment["MULLIGAN_RUNNING"] = "1"
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }

        var pid: pid_t = 0
        // mulligan ignores broken pipes for itself; the command must start with the default,
        // or every pipeline its shells run would behave differently.
        signal(SIGPIPE, SIG_DFL)
        let spawned = posix_spawnp(&pid, command[0], nil, nil, &arguments, &envp)
        signal(SIGPIPE, SIG_IGN)
        guard spawned == 0 else {
            throw UndoError.usage("Couldn't start \(Text.safe(command[0])): \(String(cString: strerror(spawned))).")
        }

        var status: Int32 = 0
        var lastSnap = Date()
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid { break }
            let forwarded = pendingSignal
            if forwarded == SIGTERM || forwarded == SIGHUP {
                pendingSignal = 0
                kill(pid, forwarded)
            }
            if waited == -1 && errno != EINTR { break }
            usleep(100_000)
            if Date().timeIntervalSince(lastSnap) >= interval {
                try? snap(store, label: "files changed", event: .watch, quiet: true)
                lastSnap = Date()
            }
        }
        try? snap(store, label: "after \(Text.line(command.joined(separator: " "), limit: 60))", event: .manual, quiet: true)
        if let latest = try? store.snapshots().last {
            cli.warn("snapshots are in place up to #\(latest.id). `mulligan list` shows them.")
        }
        // Exit as the command did. If a signal ended it, end the same way, so the shell sees it.
        if status & 0x7f == 0 { return (status >> 8) & 0xff }
        let signalNumber = status & 0x7f
        signal(signalNumber, SIG_DFL)
        kill(getpid(), signalNumber)
        return 128 + signalNumber
    }

    /// Snapshots whenever files change, until Ctrl-C.
    func watch(_ rest: [String]) throws -> Int32 {
        let (interval, _) = try parse(rest, needsCommand: false)
        let store = try cli.open(root, settings, create: true)
        pendingSignal = 0
        signal(SIGINT, interrupted)
        signal(SIGTERM, interrupted)
        try snap(store, label: "watch started", event: .manual)
        cli.say("Watching \(tilde(root, home: cli.home)), snapshotting every \(Int(interval)) s when files change. Ctrl-C stops.")
        while pendingSignal == 0 {
            usleep(100_000)
            var elapsed = 0.1
            while elapsed < interval, pendingSignal == 0 {
                usleep(100_000)
                elapsed += 0.1
            }
            if pendingSignal != 0 { break }
            do {
                let result = try store.snapshot(SnapshotRequest(label: "files changed", event: .watch))
                if result.created { cli.say(cli.style.dim("  #\(result.snapshot.id)  \(Text.ago(result.snapshot.date))")) }
            } catch {
                cli.warn("\(error)")
            }
        }
        cli.say("Stopped watching.")
        return 0
    }

    func parse(_ rest: [String], needsCommand: Bool) throws -> (Double, [String]) {
        var interval = 2.0
        var index = 0
        var command: [String] = []
        while index < rest.count {
            let word = rest[index]
            if word == "--" {
                command = Array(rest[(index + 1)...])
                break
            }
            if word == "--every" {
                guard index + 1 < rest.count, let value = Double(rest[index + 1]), value >= 0.5, value <= 3600 else {
                    throw UndoError.usage("--every needs a number of seconds from 0.5 to 3600.")
                }
                interval = value
                index += 2
                continue
            }
            if needsCommand, !word.hasPrefix("-") {
                command = Array(rest[index...])
                break
            }
            throw UndoError.usage(needsCommand ? "Use: mulligan run [--every SECONDS] -- COMMAND [ARG...]" : "Use: mulligan watch [--every SECONDS]")
        }
        if needsCommand, command.isEmpty {
            throw UndoError.usage("Use: mulligan run [--every SECONDS] -- COMMAND [ARG...]")
        }
        return (interval, command)
    }

    func snap(_ store: Store, label: String, event: Event, quiet: Bool = false) throws {
        let result = try store.snapshot(SnapshotRequest(label: label, agent: nil, event: event))
        if !quiet, result.created { cli.reportSkipped(result.skipped) }
    }
}

/// The last signal mulligan got, set from a signal handler and read by the loops. A plain
/// global set before any handler is installed, so the handler only stores a number.
nonisolated(unsafe) var pendingSignal: sig_atomic_t = 0

private func interrupted(_ signalNumber: Int32) {
    pendingSignal = signalNumber
}
