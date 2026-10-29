# Changelog

## 0.1.0 (2026-11-22)

First release.

- **A snapshot of your project** each time your agent gets a prompt, is about to use a tool, or ends a turn, through hooks for Codex, Claude Code, Gemini CLI, OpenCode, Cursor, Copilot CLI, Qwen Code and Pi. `mulligan setup <agent>` prints the config to add.
- **`mulligan run -- <agent>`** and **`mulligan watch`** for agents without hooks, like Aider, snapshotting whenever files change.
- **Catches changes made by shell commands,** formatters and generators, since snapshots are of the files themselves.
- **`list`, `diff`, `undo`, `redo` and `restore`,** to see the timeline, compare any two points, go back to any of them, and put back one file or folder.
- **Undo is undoable:** every restore takes a snapshot first, and stops without changing anything if it can't.
- **Never touches your repository,** and never deletes or overwrites a file it couldn't put back. Ignored files, files over 10 MB and nested repositories are left alone.
- **Limits** of 500 snapshots, 30 days and 2 GB per project, adjustable, and `prune` and `clear` to tidy up.
- One small binary for macOS and Linux, git as its only requirement, no network access and no telemetry.
