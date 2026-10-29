import Foundation

/// What to add to each agent's config so it calls `mulligan hook`. mulligan prints these
/// rather than editing the files itself: they're your config, and you should see what goes in.
public enum Setup {
    public static let names = ["codex", "claude", "gemini", "opencode", "cursor", "copilot", "qwen", "pi", "aider", "other"]

    public static let overview = """
    mulligan takes a snapshot each time your agent gets a prompt, is about to use a tool, or
    finishes a turn. Hook it up once, then use `mulligan list` and `mulligan undo`.

      mulligan setup codex      OpenAI Codex CLI 0.124 or later (hooks)
      mulligan setup claude     Claude Code (hooks)
      mulligan setup gemini     Gemini CLI 0.27 or later (hooks)
      mulligan setup opencode   OpenCode (a small plugin)
      mulligan setup cursor     Cursor's agent (hooks)
      mulligan setup copilot    GitHub Copilot CLI (hooks)
      mulligan setup qwen       Qwen Code (hooks)
      mulligan setup pi         Pi (an extension)
      mulligan setup aider      Aider (no hooks: use `mulligan run`)
      mulligan setup other      anything else

    Any agent works without setup, too: `mulligan run -- <agent>` snapshots whenever files
    change while it runs.
    """

    public static func instructions(for agent: String) -> String? {
        switch agent {
        case "codex", "openai": return codex
        case "claude", "claude-code": return claude
        case "gemini", "gemini-cli": return gemini
        case "opencode": return opencode
        case "cursor", "cursor-agent": return cursor
        case "copilot", "github-copilot": return copilot
        case "qwen", "qwen-code": return qwen
        case "pi": return pi
        case "aider": return aider
        case "other", "generic": return other
        default: return nil
        }
    }

    static let silentNote = """
    The hook prints nothing and always exits 0, so it can never block your agent or add to
    its context. If a snapshot fails, `mulligan status` says why.
    """

    public static let codex = """
    Codex CLI 0.124 or later runs hooks. Add this to ~/.codex/hooks.json (every project) or
    .codex/hooks.json in one project, merging it with any hooks you have:

    {
      "hooks": {
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "mulligan hook codex", "timeout": 30 }] }],
        "PreToolUse": [{ "matcher": "*", "hooks": [{ "type": "command", "command": "mulligan hook codex", "timeout": 30 }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "mulligan hook codex", "timeout": 30 }] }]
      }
    }

    Then open Codex, type /hooks and trust the three new hooks. Codex only runs hooks you've
    trusted, and asks again whenever a hook's command changes.

    On an older Codex, the `notify` setting works too, though it only fires when a turn ends.
    Put this at the top of ~/.codex/config.toml, before any [section]:

    notify = ["mulligan", "hook", "codex"]

    \(silentNote)
    """

    public static let claude = """
    Add this to ~/.claude/settings.json (every project), or .claude/settings.local.json in one
    project, merging it with any hooks you have:

    {
      "hooks": {
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "mulligan hook claude" }] }],
        "PreToolUse": [{ "matcher": "Bash|Edit|Write|NotebookEdit|PowerShell", "hooks": [{ "type": "command", "command": "mulligan hook claude" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "mulligan hook claude" }] }]
      }
    }

    Claude Code's own /rewind doesn't track files changed by shell commands. mulligan
    snapshots the files themselves, so those are covered too.

    \(silentNote)
    """

    public static let gemini = """
    Gemini CLI 0.27 or later runs hooks. Add this to ~/.gemini/settings.json (every project) or
    .gemini/settings.json in one project, merging it with any hooks you have:

    {
      "hooks": {
        "BeforeAgent": [{ "hooks": [{ "name": "mulligan", "type": "command", "command": "mulligan hook gemini", "timeout": 30000 }] }],
        "BeforeTool": [{ "matcher": "write_file|replace|run_shell_command", "hooks": [{ "name": "mulligan-tool", "type": "command", "command": "mulligan hook gemini", "timeout": 30000 }] }],
        "AfterAgent": [{ "hooks": [{ "name": "mulligan-end", "type": "command", "command": "mulligan hook gemini", "timeout": 30000 }] }]
      }
    }

    Add MCP tools that change files to the matcher (they're named mcp_<server>_<tool>), or use
    ".*" to snapshot before every tool.

    \(silentNote)
    """

    public static let opencode = """
    Save this as .opencode/plugins/mulligan.js in a project, or in
    ~/.config/opencode/plugins/ for every project:

    // Snapshots files with mulligan when a message comes in, before each tool that isn't a
    // read, and when the session goes idle.
    export const AgentUndo = async ({ $, directory }) => {
      const snap = () => $`mulligan hook opencode`.cwd(directory).quiet().nothrow();
      return {
        "chat.message": async () => { await snap(); },
        "tool.execute.before": async (input) => { if (input.tool !== "read") await snap(); },
        event: async ({ event }) => { if (event.type === "session.idle") await snap(); },
      };
    };

    That's for OpenCode 1.x. OpenCode 2 has a new plugin API; until mulligan has a plugin
    for it, use `mulligan run -- opencode`.
    """

    public static let cursor = """
    Add this to ~/.cursor/hooks.json (every project) or .cursor/hooks.json in one project,
    merging it with any hooks you have:

    {
      "version": 1,
      "hooks": {
        "sessionStart": [{ "command": "mulligan hook cursor" }],
        "beforeSubmitPrompt": [{ "command": "mulligan hook cursor" }],
        "afterFileEdit": [{ "command": "mulligan hook cursor" }],
        "afterShellExecution": [{ "command": "mulligan hook cursor" }],
        "stop": [{ "command": "mulligan hook cursor" }]
      }
    }

    Cursor's "before" hooks for shell commands have to answer with a permission, so mulligan
    snapshots after each edit and command instead, which marks the same points in time. Not
    every Cursor build runs every hook from the command line; if `mulligan list` stays empty,
    use `mulligan run -- cursor-agent`.
    """

    public static let copilot = """
    Save this as ~/.copilot/hooks/mulligan.json (every project) or
    .github/hooks/mulligan.json in one project:

    {
      "version": 1,
      "hooks": {
        "userPromptSubmitted": [{ "type": "command", "bash": "mulligan hook copilot", "timeoutSec": 30 }],
        "preToolUse": [{ "type": "command", "bash": "mulligan hook copilot", "timeoutSec": 30 }],
        "agentStop": [{ "type": "command", "bash": "mulligan hook copilot", "timeoutSec": 30 }]
      }
    }

    Copilot CLI also runs the hooks in .claude/settings.json. If you've set mulligan up there
    already, you don't need this too.

    \(silentNote)
    """

    public static let qwen = """
    Add this to .qwen/settings.json in a project (or your user settings), merging it with any
    hooks you have:

    {
      "hooks": {
        "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "mulligan hook qwen" }] }],
        "PreToolUse": [{ "matcher": "write_file|replace|run_shell_command", "hooks": [{ "type": "command", "command": "mulligan hook qwen" }] }],
        "Stop": [{ "hooks": [{ "type": "command", "command": "mulligan hook qwen" }] }]
      }
    }

    \(silentNote)
    """

    public static let pi = """
    Save this as ~/.pi/agent/extensions/mulligan.ts (every project) or
    .pi/extensions/mulligan.ts in one project:

    // Snapshots files with mulligan before each prompt, before each tool and after each run.
    export default function (pi) {
      const snap = () => pi.exec("mulligan", ["hook", "pi"], { timeout: 30000 });
      pi.on("before_agent_start", async () => { await snap(); });
      pi.on("tool_call", async () => { await snap(); });
      pi.on("agent_end", async () => { await snap(); });
    }
    """

    public static let aider = """
    Aider has no hooks, so start it through mulligan, which snapshots whenever files change
    while it runs:

    mulligan run -- aider

    To also mark the end of each reply, add this to .aider.conf.yml:

    notifications: true
    notifications-command: mulligan hook aider

    Aider's own /undo only takes back its last commit. mulligan also covers files it hasn't
    committed, files it created, and anything changed by /run.
    """

    public static let other = """
    Three ways, from most to least precise:

    1. If the agent has hooks, have them run `mulligan hook <name>` when a prompt arrives,
       before each tool, and when a turn ends. It reads the agent's JSON on stdin (it looks for
       cwd, prompt, tool_name and tool_input) and works without it too.
    2. Start the agent through mulligan, which snapshots whenever files change:
       mulligan run -- <agent> [args...]
    3. Leave `mulligan watch` running in another terminal in the project.

    And `mulligan snap -m "before the big refactor"` takes one by hand.
    """
}
