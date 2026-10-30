# Contributing

Thanks for helping out! Bug reports, ideas and pull requests are all welcome.

## Reporting a bad undo

If a snapshot missed something, or an undo put back the wrong thing, open a [bug report](https://github.com/stanczykwyatt/mulligan/issues/new?template=bug.yml) with the commands you ran, `mulligan list` from before and after, your agent and how it's set up, and your system and git version. Please describe files rather than pasting them, like "a symlink to a folder outside the project" or "a file that became ignored after the snapshot". Never paste secrets or private code.

## Adding an agent

Hooks for more agents are very welcome. A new agent needs:

- the config to print, in `Sources/UndoCore/Setup.swift`, with the events that fire when a prompt arrives, before a tool runs and when a turn ends;
- any field names its JSON uses that `Hooks.parse` doesn't know yet, in `Sources/UndoCore/Hooks.swift`;
- a test with a made-up payload in `Tests/UndoCoreTests/BasicsTests.swift`, and, for JSON config, an entry in the snippet tests, which run each printed hook command the way the agent would.

Link the agent's own documentation for its hooks in the pull request. Please don't add anything that edits an agent's config files: mulligan prints what to add, and you add it.

## Getting started

You need Swift 6.1 or later (Xcode 16 or the Command Line Tools on a Mac, or from swift.org on Linux) and git.

```bash
swift test                     # run the tests
swift build -c release         # build .build/release/mulligan
scripts/build-release.sh       # a universal Mac binary and archives in ./build
```

`Sources/UndoCore` holds everything: finding the project (`Project.swift`), the snapshot store and its lock (`Store.swift`), taking snapshots (`Snapshots.swift`), undo, redo and restore (`Restore.swift`), limits (`Maintenance.swift`), reading hook payloads (`Hooks.swift`) and the setup text (`Setup.swift`). `Sources/mulligan` is the command line on top of it, with `run` and `watch` in `Runner.swift`. `Sources/LineBuffer` is one C function that line-buffers standard output, which Swift 6 can't do on Linux.

The tests use real git and real files, always in a new temporary folder with its own HOME and data folder, so they never read your agent configs, your git config or any of your projects. They cover edits, deletes, renames, binary files, symlinks, `.gitignore`, nested repositories and submodules, odd file names, a dirty index and stash in the project (checked byte for byte afterwards), concurrent hooks, a full disk and the size limits.

To redraw the art: `swift scripts/make-art.swift`.

## Ground rules

- **Never touch the project's `.git`.** Every git command goes through `Git` in `Git.swift`, which points git at mulligan's own repository.
- **Change files in one place only:** the `read-tree -m -u` in `Restore.swift`, after a snapshot, with the protected paths taken out. CI checks this.
- **Never delete or overwrite what can't be put back.** If you're not sure, stop with a message.
- **Hooks print nothing and exit 0.**
- **No network access, ever,** and no telemetry. Pull requests that add either won't be merged.
- **No dependencies** without a very good reason. It has none today, which keeps it easy to audit.
- **Made-up files only** in tests, art and bug reports.
- Run `swift test` before opening a pull request, and add tests for what you change.
- Keep commits small, with a short message saying what changed and why.

## Security issues

Please don't open public issues for vulnerabilities. See [SECURITY.md](SECURITY.md).
