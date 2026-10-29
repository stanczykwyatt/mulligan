import Foundation

/// What clearing out old snapshots did.
public struct PruneResult: Sendable {
    public let removed: [Int]
    public let sizeBefore: Int64
    public let sizeAfter: Int64
}

extension Store {
    /// How much the store's objects take, from git's own count, which is quick.
    func objectsSize() -> Int64 {
        guard let text = try? git.text(["count-objects", "-v"]) else { return size() }
        var kib: Int64 = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, parts[0] == "size" || parts[0] == "size-pack" || parts[0] == "size-garbage" {
                kib += Int64(parts[1]) ?? 0
            }
        }
        return kib * 1024
    }

    /// Run after each new snapshot: drops snapshots over the count or past the age limit, and
    /// now and then packs the store and checks its size.
    func pruneLocked(now: Date, after id: Int) throws {
        let all = try snapshots()
        var drop = overLimits(all, now: now, keep: settings.keep, maxAgeDays: settings.maxAgeDays)
        let checkSize = id % 25 == 0
        if !drop.isEmpty {
            try delete(drop)
            if let position = readPosition(), drop.contains(position.id) { clearPosition() }
        }
        if checkSize || drop.count >= 20 {
            try git.run(["gc", "--quiet", "--prune=1.hour.ago"])
        }
        if checkSize, objectsSize() > settings.maxStoreBytes {
            // Pruning waits an hour here, in case a git from an mulligan that was killed is still
            // writing, so the space comes back on a later check.
            drop = try shrink(toFit: settings.maxStoreBytes)
        }
    }

    /// Snapshots past the count or age limits, oldest first. The newest is always kept.
    func overLimits(_ all: [Snapshot], now: Date, keep: Int, maxAgeDays: Int) -> [Int] {
        guard all.count > 1 else { return [] }
        let candidates = all.dropLast()
        var drop = Set<Int>()
        if all.count > keep {
            for snapshot in all.prefix(all.count - max(keep, 1)) { drop.insert(snapshot.id) }
        }
        let cutoff = now.addingTimeInterval(-Double(maxAgeDays) * 86_400)
        for snapshot in candidates where snapshot.date < cutoff { drop.insert(snapshot.id) }
        return drop.sorted()
    }

    /// Drops the oldest snapshots until the store fits, always keeping the newest few, so one
    /// snapshot bigger than the limit can't wipe out the rest of the timeline.
    func shrink(toFit limit: Int64, prune: String = "1.hour.ago") throws -> [Int] {
        var removed: [Int] = []
        let alwaysKept = 5
        while objectsSize() > limit {
            let all = try snapshots()
            guard all.count > alwaysKept else { break }
            let batch = all.dropLast(alwaysKept).prefix(max(1, all.count / 4)).map(\.id)
            try delete(batch)
            removed += batch
            try git.run(["gc", "--quiet", "--prune=\(prune)"])
            // With a grace period the space doesn't come back yet, so one batch per check.
            if prune != "now" { break }
        }
        return removed
    }

    func delete(_ ids: [Int]) throws {
        guard !ids.isEmpty else { return }
        let commands = ids.map { "delete \(Self.refName($0))\n" }.joined()
        try git.run(["update-ref", "--stdin"], input: Data(commands.utf8))
    }

    /// Drops snapshots past the limits now, or more if asked, and packs the store. Asked for by
    /// hand, so space is given back at once rather than after the hour automatic pruning waits.
    public func prune(now: Date = Date(), keep: Int? = nil, olderThanDays: Int? = nil) throws -> PruneResult {
        guard exists else { throw UndoError.noSnapshots(root) }
        return try withLock {
            let sizeBefore = size()
            let all = try snapshots()
            var drop = overLimits(all, now: now, keep: keep ?? settings.keep, maxAgeDays: olderThanDays ?? settings.maxAgeDays)
            try delete(drop)
            try git.run(["gc", "--quiet", "--prune=now"])
            if objectsSize() > settings.maxStoreBytes { drop += try shrink(toFit: settings.maxStoreBytes, prune: "now") }
            if let position = readPosition(), drop.contains(position.id) { clearPosition() }
            return PruneResult(removed: drop.sorted(), sizeBefore: sizeBefore, sizeAfter: size())
        }
    }

    /// Deletes every snapshot of this project, and the store itself. Your files aren't touched.
    public func clear() throws {
        guard exists else { return }
        // The lock file stays, so anything waiting on it still shares it with whatever comes next.
        try withLock {
            try FileManager.default.removeItem(atPath: projectFile)
            try FileManager.default.removeItem(atPath: gitDir)
            for name in ["next-id", "position", "home"] {
                try? FileManager.default.removeItem(atPath: folder + "/" + name)
            }
        }
    }
}
