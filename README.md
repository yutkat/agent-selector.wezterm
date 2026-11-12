# agent-selector.wezterm

A WezTerm plugin that shows a popup listing every pane running an AI
coding agent (Claude Code, Codex, ...) across all workspaces, with a
busy/idle indicator and the pane's working directory. Selecting an
entry jumps to that pane, switching workspace if needed. Inspired by
[herdr](https://herdr.dev/).

- `●` the agent is busy (its busy footer, e.g. "esc to interrupt", is visible)
- `○` the agent is idle / waiting for input

## Usage

```lua
local wezterm = require("wezterm")
local agent_selector = wezterm.plugin.require("https://github.com/yutkat/agent-selector.wezterm")

config.keys = {
 { key = "g", mods = "ALT", action = agent_selector.action.ShowAgentSelector },
}
```

## Configuration

Optional. The defaults cover claude, codex, opencode, gemini, copilot,
cursor-agent, amp, pi, droid, grok, kiro and cline. Override the list to
add or replace agents:

```lua
agent_selector.setup({
 agents = {
  { name = "claude", process = "claude", busy_pattern = "[Ee]sc to interrupt" },
  { name = "opencode", process = "opencode", busy_pattern = "working" },
  { name = "myagent", process = "myagent" },
 },
})
```

- `name`: shown in the popup label; also matched (case-insensitive,
  whole-word) against the pane title when the foreground process name
  is unavailable (e.g. ssh domains).
- `process`: compared with the comm name, `argv[0]` and executable
  basename of the pane's foreground process (version-managed installs
  resolve the executable through symlinks like `.../versions/2.1.199`,
  so the invoked name only survives in comm/argv). For scripts run by a
  known interpreter (node, bun, deno, python, ruby) the script's
  extension-stripped basename is also compared, so an npm-installed
  `codex` (`node .../codex.js`) still matches. Descendants of the
  foreground process are matched too, so agents started via wrapper
  scripts (e.g. a bash wrapper that runs `claude` as a child) are found.
- `busy_pattern`: optional Lua pattern (or list of patterns) matched
  against the last 10 non-empty lines of the visible pane text (agent
  busy footers live at the bottom; scanning the whole screen would
  false-positive on generic words like "working" appearing in
  conversation text). When omitted, the common footers
  `[Ee]sc to interrupt` and `[Ee]sc to cancel` are tried.
