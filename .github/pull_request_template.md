## What this changes



## Checklist

- [ ] `swift test` passes
- [ ] No networking, telemetry or new dependencies
- [ ] The project's own `.git` is still never read or written (apart from reading `info/exclude`)
- [ ] Files still change only through the one `read-tree -m -u` in `Restore.swift`, after a snapshot
- [ ] Nothing is deleted or overwritten that the snapshot taken first doesn't hold
- [ ] Hooks still print nothing and always exit 0
- [ ] Changes come with tests, in temporary folders with made-up files
