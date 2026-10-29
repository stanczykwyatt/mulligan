# Security

mulligan puts files in your project back the way they were, which means it deletes and overwrites files. So it's built to fail safe: it never changes a file it couldn't change back, never touches your own git repository, and stops with a clear message whenever it isn't sure.

## Reporting a vulnerability

Please report security problems privately through **Security → Report a vulnerability** on this repository, not in a public issue. You'll get a reply within a few days.

## What mulligan can access

| | |
|---|---|
| **Your project's files** | It reads every file git would see in the project (your `.gitignore` rules apply) to snapshot it, and writes files only when you run `undo`, `redo` or `restore`. |
| **Its own data folder** | `~/.local/share/mulligan` (or `$XDG_DATA_HOME/mulligan`, or `MULLIGAN_HOME`). It holds one snapshot repository per project, its `config` file and a small hook log. Folders are created readable only by you. |
| **Two files of your git setup, read only** | The project's `.git/info/exclude` and your global git ignore file, so the same files are left out as git would leave out. Nothing else in your `.git` or your git config is read. |
| **What a hook is given** | An agent's hook passes JSON on standard input. mulligan reads the working folder, the event's name, the tool's name, a command or file path, and the prompt's first words, for the snapshot's label. Nothing else is kept. |

## What it can't do

- **Go online.** It has no networking code. Every git command it runs has `protocol.allow=never`, so git can't fetch or push either. CI checks the source for networking APIs and URLs, and the built binary for networking imports.
- **Collect anything.** No telemetry, analytics, crash reporting or update checks.
- **Change your repository.** It never runs `checkout`, `reset`, `stash`, `commit` or any other command in your repository. CI checks that no git command that changes a work tree or talks to another repository appears in the source, and that project files are changed in exactly one place.
- **Run something from your project or your git config.** See below.

## How it keeps your repository out of it

Every git command runs with `GIT_DIR` set to mulligan's own repository for the project and `GIT_WORK_TREE` set to the project, and with any `GIT_*` variables it inherited removed. So git never looks for, reads or writes the project's `.git`, even when an agent runs the hook from inside a git hook.

Git also gets an empty folder as `HOME`, `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_NOSYSTEM=1`, so your global and system git config aren't read. That matters because git config can run programs: hooks, `core.fsmonitor`, filters, diff tools, credential helpers. On top of that, every command sets `core.hooksPath` to a folder that doesn't exist, turns `core.fsmonitor` off, and forbids every transport.

The snapshot repository's `info/attributes` turns off line-ending conversion, filters, `ident` and working-tree encodings for every file, and it outranks any `.gitattributes` in your project. So a `.gitattributes` can't change the bytes that are saved or put back, and can't name a filter to run: none is defined, since only mulligan's own config is read.

## How it keeps your files safe

- **A snapshot first, every time.** `undo`, `redo` and `restore` all take a snapshot of your files before changing anything. If that fails, for a full disk or anything else, they stop and change nothing.
- **Only what can be put back.** Files are moved from that snapshot to the one you chose with git's two-tree update (`read-tree -m -u`), which replaces or removes only files whose contents are in one of the two. Before that, mulligan checks every path it's about to write. Anything on disk the first snapshot doesn't hold, like an ignored file, a file over the size limit, a pipe or socket, a nested repository, or a folder holding any of those, is taken out of the plan and left exactly as it is, and you're told which and why.
- **No writing through links.** Symbolic links are saved as links, never followed. If a link to somewhere outside the project now sits where a folder used to be, the link is replaced by the folder, not written through. The link itself is in the first snapshot, so it can be put back.
- **Fails closed if files change mid-restore.** If something writes to a file between the snapshot and the update, git notices the file doesn't match and refuses, and nothing changes. If anything still differs afterwards, you're told the snapshot that holds your files as they were.
- **Nested repositories are left alone.** A folder with its own `.git`, including submodules, is never snapshotted and never touched by a restore. Snapshot it on its own by running mulligan inside it.
- **Big, special and unreadable files are left out.** Files over the size limit (10 MB by default), anything that isn't a regular file or a link, files it isn't allowed to read, and names git refuses to store (like `git~1`) aren't saved, and the rest of the snapshot goes ahead. A file that grows past the limit is dropped from later snapshots rather than kept as an old copy. Like ignored files, these are never replaced by a restore.
- **Paths are taken literally.** File names are passed to git separated by NUL bytes and marked literal, so a name with spaces, a newline, a leading dash or pattern characters can't be read as an option or a pattern. Paths outside the project, or in its `.git`, are refused.
- **Names are printed safely.** File names, prompts and commands have control characters and invisible direction marks removed before they're shown, so a hostile file name can't rewrite your terminal.

## Where it refuses to run

It works on the nearest folder with a `.git`, or one you set up with `mulligan init`. It refuses:

- `/`, your home folder, any folder holding your home folder, and system folders like `/usr`, `/etc`, `/tmp` and `/Users`. A dotfiles repository in your home folder doesn't make your home folder a project.
- A project that contains mulligan's data folder, or sits inside it, since it would snapshot itself.

## Concurrency

Each project has a lock file. Every snapshot, undo, redo, restore, prune and clear holds it, so hooks firing at the same moment take their snapshots one after another, and a restore can't interleave with a snapshot. A hook waits at most 10 seconds for the lock, other commands 30. Git commands always run in the project's top folder, so a command or hook started in a subfolder covers the whole project.

If git is killed partway (a full disk, Ctrl-C), it can leave a lock file that would block every later snapshot. Lock files made by mulligan's own git, which has exited by the time mulligan looks, are cleared at once; any older one is cleared after ten minutes, in case it belongs to a git still finishing for a mulligan that was itself stopped. A hook that its agent stops with a signal stops its git too. Automatic clean-up only removes unreferenced data after an hour, so it can never remove a snapshot that's still being written.

## Hooks

`mulligan hook` prints nothing and always exits 0, whatever happens, because several agents read a hook's output into the model's context or block on a nonzero exit. A problem is written to `hook-errors.log` in the data folder instead (at most 64 KB), and `mulligan status` shows the latest. `MULLIGAN_DISABLE=1` turns hooks off. mulligan prints the config to add for each agent rather than editing your agents' config files itself.

## What's kept, and for how long

Snapshots hold copies of your project's files, compressed, in the data folder, readable only by you. They're dropped after 30 days, past 500 per project, or when a project's snapshots pass 2 GB, all adjustable in the `config` file. The newest five are always kept, even if they alone pass the size limit. Prompts' first 60 characters label snapshots; set `prompts = off` to keep them out. `mulligan clear` deletes every snapshot of a project, and deleting the data folder deletes them all. Your project's files are never touched by either.

Ignored files, such as `.env` files in `.gitignore`, aren't snapshotted at all. Files with secrets that aren't ignored are snapshotted like any other file, the same as git would commit them.

## Limits

- On a case-insensitive disk (the macOS default), a change of only a file name's case isn't seen as a change, just as git doesn't see one. The file's contents are still tracked.
- File names that aren't valid UTF-8, and on Linux two names that differ only in Unicode normalization, may not be handled correctly. Both are rare; macOS file systems require UTF-8.
- Restored files get git's usual permissions: readable by others unless your umask says otherwise, and executable if they were. A file you'd made private with `chmod 600` comes back with your default permissions.
- mulligan is a safety net for agent sessions, not a backup. Keep committing your work.
