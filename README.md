# ai-agents.wezterm

A WezTerm plugin for keeping track of panes that run AI coding agents
(Claude Code, Codex, ...) across all workspaces. It detects agent panes,
tracks whether each agent is busy, idle or waiting for you, and shows
that where you want it. Inspired by [herdr](https://herdr.dev/).

1. [Agent selector](#1-agent-selector): a popup listing every agent pane;
   pick one to jump to it.
2. [Status summary](#2-status-summary): show how many agents are
   waiting, busy and idle in the status bar.
3. [Background tint](#3-background-tint): color the background of panes
   while an agent runs in them.
4. [Notifications and jump](#4-notifications-and-jump): get a toast when
   an agent you are not looking at finishes or needs you, and jump to it.

## Installation

```lua
local agents = wezterm.plugin.require("https://github.com/yutkat/ai-agents.wezterm")
```

Requiring the plugin registers an `update-status` handler that scans
the panes for agents. It does not touch your status bar; the features
below are opt-in. `agents.setup({ ... })` is optional (see the
[configuration reference](#configuration-reference)).

## Features

### 1. Agent selector

Opens a fuzzy popup that lists every agent pane in all workspaces,
ordered waiting, done, busy, idle. Choosing an entry activates that
pane, switching workspace if needed.
The list is built from a fresh scan each time it opens; with no agent
panes, a toast says so.

```lua
config.keys = {
 { key = "g", mods = "ALT", action = agents.action.ShowAgentSelector },
}
```

Each entry shows the state icon, the agent name, the name of
the pane's working directory and `workspace: tab title`, e.g.
`● claude  [proj]  default: Fix bug`. It is also available as a
function, `agents.show_agent_selector(window, pane)`.

### 2. Status summary

`agents.summary()` returns the number of agents per state, e.g.
`"▲1 ●1 ○2"`, for use in the status bar, or `""` when there are no
agents.

```lua
wezterm.on("update-status", function(window, pane)
 window:set_right_status(agents.summary())
end)
```

| Icon | State                                                                                      |
| ---- | ------------------------------------------------------------------------------------------ |
| `▲`  | waiting for you (Codex's "Action Required")                                                |
| `✓`  | done: finished while you were not looking (see [notifications](#4-notifications-and-jump)) |
| `●`  | busy                                                                                       |
| `○`  | idle, or the state is unknown (see [limits](#state-from-the-title))                        |

Options:

- `icons`: icon per state, merged with the defaults
  `{ waiting = "▲ ", done = "✓ ", busy = "● ", idle = "○ " }`. Trailing whitespace is
  trimmed; the selector uses the same icons.
- `scan_interval`: the counts are refreshed at most once per this many
  seconds (default `1`), so they can lag by that much.

Icons can also be overridden per call:

```lua
agents.summary({ icons = { idle = "-" } })
```

### 3. Background tint

Sets the background color of a pane while it runs a given agent, and
resets it once the agent is gone. Off by default.

```lua
agents.setup({
 backgrounds = { claude = "#3b332e", codex = "#2d3838" },
})
```

- `backgrounds`: color per agent name, merged with the defaults (empty).
- Based on [process detection](#how-agents-and-states-are-detected), so
  no wrapper scripts are needed to tint the pane.
- Sent as OSC 11 (set) and OSC 111 (reset) with `pane:inject_output`,
  which only works for local panes.
- Applied by the scan, so it lags by up to `scan_interval`. Tinted panes
  are remembered across config reloads.

### 4. Notifications and jump

Each scan compares every agent's state with the previous one. When an
agent finishes (busy → idle) or starts waiting for you, and its pane is
not the active pane of a focused window, a toast like
`claude finished  [proj]  default: Fix bug` appears.

A pane that finished unseen is shown as done (`✓`) until you look at it
or it gets busy again. `agents.action.JumpToAttention` activates the
pane that needs you most: waiting first, then done, the earliest first
among equals. With nothing to jump to, a toast says so.

```lua
config.keys = {
 { key = "g", mods = "ALT|SHIFT", action = agents.action.JumpToAttention },
}
```

- `notify`: set to `false` to turn off the toasts (default `true`); done
  is still tracked.
- Toasts and done lag by up to `scan_interval`. Agents already running
  when the config loads do not notify until their state changes.
- Claude Code cannot report waiting through its title, so a permission
  prompt shows as "finished".
- It is also available as a function,
  `agents.jump_to_attention(window, pane)`.

## How agents and states are detected

A pane is an agent pane when its foreground process, or one of its
descendants, matches an entry in [`agents`](#agent-entries) (claude and
codex by default):

- The comm name, `argv[0]` or executable basename must equal `process`.
  The executable alone is not enough for version-managed installs, which
  resolve to paths like `.../versions/2.1.199`.
- Descendants are checked so agents started by wrapper scripts are found.
- Panes without process information (e.g. ssh or mux domains) are never
  agent panes.

### State from the title

The state comes only from the pane title, matched against the agent's
`waiting_title`, then `busy_title`; anything else is idle.

- Claude Code prefixes its title with `◐` / `◑` while working (`>` in
  its alternate mode); its idle prefixes `✳` / `*` count as idle.
- Codex starts its title with a braille spinner (`⠋`, `⠙`, ...) while
  working and with `[ ! ] Action Required` when it needs you (e.g. an
  approval). This needs `[tui] terminal_title` in Codex's config to
  include `"spinner"` or `"activity"` (the default does) and
  `tui.animations = true` for the spinner.
- Agents without title patterns are always idle.
- Under tmux (the title is static) or with titles disabled, every agent
  shows as idle.

## Configuration reference

All options are optional.

| Option          | Default                                                     | Description                                                                                            |
| --------------- | ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `icons`         | `{ waiting = "▲ ", done = "✓ ", busy = "● ", idle = "○ " }` | Icon per state, merged per key. See [status summary](#2-status-summary).                               |
| `scan_interval` | `1`                                                         | Minimum seconds between background scans. The selector and the jump action always scan afresh.         |
| `backgrounds`   | `{}`                                                        | Background color per agent name, merged per key. See [background tint](#3-background-tint).            |
| `notify`        | `true`                                                      | Toast when an unseen agent finishes or starts waiting. See [notifications](#4-notifications-and-jump). |
| `agents`        | claude, codex                                               | Agents to detect. Setting this **replaces** the whole list.                                            |

### Agent entries

| Field           | Description                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `name`          | Shown in the selector; key for `backgrounds`.                                                                             |
| `process`       | Process name to match (see [detection](#how-agents-and-states-are-detected)).                                             |
| `waiting_title` | Optional Lua pattern or list of patterns; a match on the pane title means waiting. Checked first.                         |
| `busy_title`    | Optional Lua pattern or list of patterns; checked after `waiting_title`, a match means busy. Otherwise the agent is idle. |

Lua patterns work on bytes, so put multibyte characters such as `◐` in
separate patterns rather than inside a `[]` class.

To track other agents, add them to `agents`. They are detected and
counted, but show as idle unless given `busy_title` / `waiting_title`.
Setting `agents` replaces the defaults, so copy the claude and codex
entries from [`plugin/init.lua`](plugin/init.lua) to keep them.

Full example:

```lua
agents.setup({
 icons = { idle = "- " },
 scan_interval = 1,
 backgrounds = { claude = "#3b332e", codex = "#2d3838" },
 agents = {
  {
   name = "claude",
   process = "claude",
   busy_title = { "^◐ ", "^◑ ", "^> " },
  },
  { name = "opencode", process = "opencode" },
  { name = "myagent", process = "myagent" },
 },
})
```

## Development

The tests run the plugin against a fake `wezterm` module
([`test/fake_wezterm.lua`](test/fake_wezterm.lua)) and need only a
plain Lua interpreter (5.4, which WezTerm uses; LuaJIT works too):

```sh
lua5.4 test/run.lua
```

CI runs them along with `stylua --check plugin test` and
`selene plugin test`.
