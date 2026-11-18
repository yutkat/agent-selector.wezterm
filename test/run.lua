-- Runs the plugin against a fake wezterm module: lua test/run.lua
local root = (arg and arg[0] or ""):match("^(.*)/test/run%.lua$") or "."
local fake = dofile(root .. "/test/fake_wezterm.lua")

local tests = {}
local function test(name, fn)
	table.insert(tests, { name = name, fn = fn })
end

local function show(value)
	if type(value) == "string" then
		return string.format("%q", value)
	end
	return tostring(value)
end

local function eq(actual, expected, what)
	if actual ~= expected then
		error(string.format("%s: expected %s, got %s", what or "value", show(expected), show(actual)), 2)
	end
end

local function same(actual, expected, what)
	for key, value in pairs(expected) do
		if actual[key] ~= value then
			error(string.format("%s[%s]: expected %s, got %s", what, show(key), show(value), show(actual[key])), 2)
		end
	end
	for key, value in pairs(actual) do
		if expected[key] == nil then
			error(string.format("%s[%s]: unexpected %s", what, show(key), show(value)), 2)
		end
	end
end

-- Loads a fresh plugin instance; windows as in fake.new.
local function load_plugin(windows, globals)
	local wezterm = fake.new(windows, globals)
	package.loaded.wezterm = nil
	package.preload.wezterm = function()
		return wezterm
	end
	local plugin = dofile(root .. "/plugin/init.lua")
	return plugin, wezterm
end

-- One window in the "default" workspace with one tab per pane.
local function tab_per_pane(panes)
	local tabs = {}
	for _, pane in ipairs(panes) do
		table.insert(tabs, { id = pane.id, panes = { pane } })
	end
	return { { workspace = "default", tabs = tabs } }
end

-- Distinct icons so the selector label reveals each pane's state.
local STATE_ICONS = { waiting = "W ", done = "D ", busy = "B ", idle = "I " }
local STATE_BY_ICON = { W = "waiting", D = "done", B = "busy", I = "idle" }

-- Runs a fresh scan through the selector; returns pane_id -> "state:name".
local function states(plugin)
	plugin.setup({ icons = STATE_ICONS })
	local window = fake.window()
	plugin.show_agent_selector(window, nil)
	local result = {}
	local action = window.actions[1]
	if action then
		for _, choice in ipairs(action.action.InputSelector.choices) do
			local icon, name = choice.label:match("^(%S+) (%S+)")
			result[tonumber(choice.id)] = STATE_BY_ICON[icon] .. ":" .. name
		end
	end
	return result
end

local function selector_labels(plugin)
	local window = fake.window()
	plugin.show_agent_selector(window, nil)
	local labels = {}
	for _, choice in ipairs(window.actions[1].action.InputSelector.choices) do
		labels[tonumber(choice.id)] = choice.label
	end
	return labels, window
end

local VERSIONED = "/home/u/.local/share/claude/versions/2.1.199"

-- Process detection

test("matches the comm name of a version-managed install", function()
	local info = fake.process("claude", { VERSIONED })
	info.executable = VERSIONED
	local plugin = load_plugin(tab_per_pane({ fake.pane({ id = 1, info = info }) }))
	same(states(plugin), { [1] = "idle:claude" }, "states")
end)

test("matches argv[0] when comm differs", function()
	local info = fake.process("2.1.199", { "claude", "--resume" })
	local plugin = load_plugin(tab_per_pane({ fake.pane({ id = 1, info = info }) }))
	same(states(plugin), { [1] = "idle:claude" }, "states")
end)

test("matches an agent running as a descendant of a wrapper", function()
	local wrapper = fake.process(
		"bash",
		{ "bash", "/home/u/.local/bin/agent-run", "claude" },
		{ [42] = fake.process("claude") }
	)
	local plugin = load_plugin(tab_per_pane({ fake.pane({ id = 1, info = wrapper }) }))
	same(states(plugin), { [1] = "idle:claude" }, "states")
end)

test("does not match an agent name in an editor's arguments", function()
	local nvim = fake.process("nvim", { "nvim", "codex.md" })
	local plugin = load_plugin(tab_per_pane({ fake.pane({ id = 1, info = nvim }) }))
	same(states(plugin), {}, "states")
end)

test("ignores panes without process information", function()
	local plugin = load_plugin(tab_per_pane({ fake.pane({ id = 1, title = "✳ Claude Code" }) }))
	same(states(plugin), {}, "states")
end)

-- Title states

local function claude_pane(id, title)
	return fake.pane({ id = id, info = fake.process("claude"), title = title })
end

local function codex_pane(id, title)
	return fake.pane({ id = id, info = fake.process("codex"), title = title })
end

test("reads claude's busy title prefixes; anything else is idle", function()
	local titles = { "◐ x", "◑ x", "> x", "✳ x", "* x", "plain title" }
	local panes = {}
	for i, title in ipairs(titles) do
		table.insert(panes, claude_pane(i, title))
	end
	local plugin = load_plugin(tab_per_pane(panes))
	same(states(plugin), {
		[1] = "busy:claude",
		[2] = "busy:claude",
		[3] = "busy:claude",
		[4] = "idle:claude",
		[5] = "idle:claude",
		[6] = "idle:claude",
	}, "states")
end)

test("reads codex's spinner and Action Required title prefixes", function()
	local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
	local panes = {}
	local expected = {}
	for i, frame in ipairs(frames) do
		table.insert(panes, codex_pane(i, frame .. " my-thread | proj"))
		expected[i] = "busy:codex"
	end
	table.insert(panes, codex_pane(11, "[ ! ] Action Required | proj"))
	table.insert(panes, codex_pane(12, "[ . ] Action Required"))
	table.insert(panes, codex_pane(13, "my-thread | proj"))
	expected[11] = "waiting:codex"
	expected[12] = "waiting:codex"
	expected[13] = "idle:codex"
	local plugin = load_plugin(tab_per_pane(panes))
	same(states(plugin), expected, "states")
end)

test("checks waiting_title before busy_title on any agent", function()
	local plugin = load_plugin(tab_per_pane({
		fake.pane({ id = 1, info = fake.process("myagent"), title = "! busy" }),
	}))
	plugin.setup({
		agents = { { name = "myagent", process = "myagent", busy_title = "busy", waiting_title = "^!" } },
	})
	same(states(plugin), { [1] = "waiting:myagent" }, "states")
end)

test("detects custom agents and counts them as idle without title patterns", function()
	local plugin = load_plugin(tab_per_pane({
		fake.pane({ id = 1, info = fake.process("opencode"), title = "⠋ working" }),
		fake.pane({ id = 2, info = fake.process("gemini"), title = "◐ x" }),
	}))
	same(states(plugin), {}, "not detected by default")
	plugin.setup({ agents = { { name = "opencode", process = "opencode" } } })
	same(states(plugin), { [1] = "idle:opencode" }, "states")
end)

-- Status summary

local function summary_windows()
	return tab_per_pane({
		claude_pane(1, "◐ x"),
		codex_pane(2, "[ ! ] Action Required"),
		claude_pane(3, "✳ x"),
		codex_pane(4, "my-thread"),
		fake.pane({ id = 5, info = fake.process("zsh") }),
	})
end

test("summarizes every non-zero state count in order", function()
	local plugin, wezterm = load_plugin(summary_windows())
	wezterm.emit("update-status")
	eq(plugin.summary(), "▲1 ●1 ○2", "summary")
end)

test("applies icon overrides per call and via setup", function()
	local plugin, wezterm = load_plugin(summary_windows())
	wezterm.emit("update-status")
	eq(plugin.summary({ icons = { busy = "B  " } }), "▲1 B1 ○2", "per-call override is trimmed")
	plugin.setup({ icons = { waiting = "!" } })
	eq(plugin.summary(), "!1 ●1 ○2", "setup override merged with the defaults")
end)

test("returns an empty summary before any scan or without agents", function()
	local plugin, wezterm = load_plugin(tab_per_pane({ fake.pane({ id = 1, info = fake.process("zsh") }) }))
	eq(plugin.summary(), "", "summary before scan")
	wezterm.emit("update-status")
	eq(plugin.summary(), "", "summary without agents")
end)

-- update-status throttling

test("throttles update-status scans by scan_interval", function()
	local now = 100
	-- The plugin calls os.time() at scan time; the runner restores it.
	-- selene: allow(incorrect_standard_library_use)
	os.time = function()
		return now
	end
	local windows = tab_per_pane({ fake.pane({ id = 1, info = fake.process("claude"), title = "◐ x" }) })
	local plugin, wezterm = load_plugin(windows)
	wezterm.emit("update-status")
	eq(plugin.summary(), "●1", "first scan")

	table.insert(windows[1].tabs, {
		id = 2,
		panes = { fake.pane({ id = 2, info = fake.process("claude"), title = "◐ x" }) },
	})
	wezterm.emit("update-status")
	eq(plugin.summary(), "●1", "same second: throttled")
	now = 101
	wezterm.emit("update-status")
	eq(plugin.summary(), "●2", "next second: rescanned")

	plugin.setup({ scan_interval = 5 })
	windows[1].tabs[2].panes[1].title = "✳ x"
	now = 105
	wezterm.emit("update-status")
	eq(plugin.summary(), "●2", "within scan_interval = 5")
	now = 106
	wezterm.emit("update-status")
	eq(plugin.summary(), "✓1 ●1", "after scan_interval = 5 (finished unseen)")
end)

-- Background tint

local TINT = "\27]11;#111111\27\\"
local RESET = "\27]111\27\\"

test("tints agent panes once and resets them when the agent leaves", function()
	local claude = fake.pane({ id = 1, info = fake.process("claude") })
	local codex = fake.pane({ id = 2, info = fake.process("codex") })
	local shell = fake.pane({ id = 3, info = fake.process("zsh") })
	local plugin, wezterm = load_plugin(tab_per_pane({ claude, codex, shell }))
	plugin.setup({ backgrounds = { claude = "#111111" } })

	wezterm.emit("update-status")
	eq(#claude.injected, 1, "claude injections")
	eq(claude.injected[1], TINT, "claude tint")
	eq(#codex.injected, 0, "codex has no color")
	eq(#shell.injected, 0, "shell is not an agent")
	eq(wezterm.GLOBAL.ai_agents_tinted, '{"1":"#111111"}', "GLOBAL is a JSON string")

	states(plugin)
	eq(#claude.injected, 1, "no re-inject while the color is unchanged")

	plugin.setup({ backgrounds = { claude = "#222222" } })
	states(plugin)
	eq(claude.injected[2], "\27]11;#222222\27\\", "re-inject after a color change")

	claude.info = fake.process("zsh")
	states(plugin)
	eq(claude.injected[3], RESET, "reset once the agent is gone")
	eq(wezterm.GLOBAL.ai_agents_tinted, "[]", "forgotten after reset")
end)

test("forgets closed panes without injecting", function()
	local claude = fake.pane({ id = 1, info = fake.process("claude") })
	local windows = tab_per_pane({ claude })
	local plugin, wezterm = load_plugin(windows)
	plugin.setup({ backgrounds = { claude = "#111111" } })
	states(plugin)
	windows[1].tabs = {}
	plugin.show_agent_selector(fake.window(), nil)
	eq(#claude.injected, 1, "only the initial tint")
	eq(wezterm.GLOBAL.ai_agents_tinted, "[]", "closed pane forgotten")
end)

test("keeps tint tracking across a config reload", function()
	local claude = fake.pane({ id = 1, info = fake.process("claude") })
	local windows = tab_per_pane({ claude })
	local globals = {}
	local plugin = load_plugin(windows, globals)
	plugin.setup({ backgrounds = { claude = "#111111" } })
	states(plugin)

	local reloaded = load_plugin(windows, globals)
	reloaded.setup({ backgrounds = { claude = "#111111" } })
	states(reloaded)
	eq(#claude.injected, 1, "no re-inject after reload")
end)

test("recovers from a corrupt GLOBAL value", function()
	local claude = fake.pane({ id = 1, info = fake.process("claude") })
	local plugin, wezterm = load_plugin(tab_per_pane({ claude }), { ai_agents_tinted = "not json" })
	plugin.setup({ backgrounds = { claude = "#111111" } })
	same(states(plugin), { [1] = "idle:claude" }, "states")
	eq(claude.injected[1], TINT, "tinted from scratch")
	eq(wezterm.GLOBAL.ai_agents_tinted, '{"1":"#111111"}', "GLOBAL rewritten")
end)

-- Selector

test("labels selector entries and jumps to the chosen pane", function()
	local busy = fake.pane({
		id = 1,
		info = fake.process("claude"),
		title = "◐ Fix bug",
		cwd = "/home/u/proj/",
	})
	local idle = fake.pane({ id = 2, info = fake.process("codex"), title = "codex" })
	local plugin, wezterm = load_plugin({
		{ workspace = "default", tabs = { { id = 1, title = "work tab", panes = { busy } } } },
		{ workspace = "other", tabs = { { id = 2, panes = { idle } } } },
	})
	local labels, window = selector_labels(plugin)
	same(labels, {
		[1] = "● claude  [proj]  default: work tab",
		[2] = "○ codex  other: codex",
	}, "labels")

	local selector = window.actions[1].action.InputSelector
	eq(selector.title, "Agents", "selector title")
	selector.action(fake.window("default"), nil, "2", labels[2])
	eq(wezterm.active_workspace, "other", "switched workspace")
	eq(idle.activated, 1, "pane activated")
	selector.action(fake.window("default"), nil, nil, nil)
	eq(idle.activated, 1, "cancel does nothing")
end)

test("shows a toast when there are no agents", function()
	local plugin = load_plugin(tab_per_pane({ fake.pane({ id = 1, info = fake.process("zsh") }) }))
	local window = fake.window()
	plugin.show_agent_selector(window, nil)
	eq(#window.actions, 0, "no selector")
	eq(window.toasts[1] and window.toasts[1].message, "No agent panes found", "toast")
end)

-- Notifications and jump

-- One focused GUI window whose active pane is seen_pane (nil: nothing seen).
local function focus(wezterm, seen_pane)
	local window = fake.window("default", true, seen_pane or fake.pane({ id = 999 }))
	wezterm.gui_window_list = { window }
	return window
end

local function toast_messages(window)
	local messages = {}
	for _, toast in ipairs(window.toasts) do
		table.insert(messages, toast.message)
	end
	return table.concat(messages, " | ")
end

test("notifies and marks done when an unseen agent finishes", function()
	local pane = claude_pane(1, "◐ x")
	local plugin, wezterm = load_plugin(tab_per_pane({ pane }))
	local gui = focus(wezterm)
	same(states(plugin), { [1] = "busy:claude" }, "busy")
	pane.title = "✳ x"
	same(states(plugin), { [1] = "done:claude" }, "done")
	eq(toast_messages(gui), "claude finished  default: ✳ x", "toast")
	eq(gui.toasts[1].title, "ai-agents", "toast title")
	eq(gui.toasts[1].timeout, nil, "no timeout: the notification daemon decides")
	plugin.setup({ icons = { done = "✓ " } })
	eq(plugin.summary(), "✓1", "summary counts done")
	eq(selector_labels(plugin)[1], "✓ claude  default: ✳ x", "selector label")
end)

test("does not notify or mark done while the pane is seen", function()
	local pane = claude_pane(1, "◐ x")
	local plugin, wezterm = load_plugin(tab_per_pane({ pane }))
	local gui = focus(wezterm, pane)
	states(plugin)
	pane.title = "✳ x"
	same(states(plugin), { [1] = "idle:claude" }, "idle")
	eq(#gui.toasts, 0, "no toast")
	gui.focused = false
	pane.title = "◐ x"
	states(plugin)
	pane.title = "✳ x"
	same(states(plugin), { [1] = "done:claude" }, "unfocused window does not count as seen")
end)

test("notifies when an unseen agent starts waiting", function()
	local pane = codex_pane(1, "my-thread")
	local plugin, wezterm = load_plugin(tab_per_pane({ pane }))
	local gui = focus(wezterm)
	states(plugin)
	pane.title = "[ ! ] Action Required"
	same(states(plugin), { [1] = "waiting:codex" }, "waiting")
	eq(toast_messages(gui), "codex needs you  default: [ ! ] Action Required", "toast")
end)

test("never notifies about panes new to the scan", function()
	local plugin, wezterm = load_plugin(tab_per_pane({
		claude_pane(1, "✳ x"),
		codex_pane(2, "[ ! ] Action Required"),
	}))
	local gui = focus(wezterm)
	same(states(plugin), { [1] = "idle:claude", [2] = "waiting:codex" }, "states")
	eq(#gui.toasts, 0, "no toast on the first scan")
end)

test("clears done when seen, busy again or gone", function()
	local panes = { claude_pane(1, "◐ x"), claude_pane(2, "◐ x"), claude_pane(3, "◐ x") }
	local windows = tab_per_pane(panes)
	local plugin, wezterm = load_plugin(windows)
	local gui = focus(wezterm)
	states(plugin)
	for _, pane in ipairs(panes) do
		pane.title = "✳ x"
	end
	same(states(plugin), { [1] = "done:claude", [2] = "done:claude", [3] = "done:claude" }, "all done")

	gui.pane = panes[1]
	panes[2].title = "◐ x"
	table.remove(windows[1].tabs, 3)
	same(states(plugin), { [1] = "idle:claude", [2] = "busy:claude" }, "seen and busy again")

	table.insert(windows[1].tabs, { id = 3, panes = { panes[3] } })
	same(states(plugin), { [1] = "idle:claude", [2] = "busy:claude", [3] = "idle:claude" }, "gone pane forgotten")
end)

test("tracks done without toasts when notify is false", function()
	local pane = claude_pane(1, "◐ x")
	local plugin, wezterm = load_plugin(tab_per_pane({ pane }))
	local gui = focus(wezterm)
	plugin.setup({ notify = false })
	states(plugin)
	pane.title = "✳ x"
	same(states(plugin), { [1] = "done:claude" }, "done")
	eq(#gui.toasts, 0, "no toast")
end)

test("jumps to waiting first, then the earliest done pane", function()
	local first = claude_pane(1, "◐ x")
	local second = claude_pane(2, "◐ x")
	local asking = codex_pane(3, "my-thread")
	local plugin, wezterm = load_plugin({
		{ workspace = "other", tabs = { { id = 1, panes = { first } } } },
		{ workspace = "default", tabs = { { id = 2, panes = { second } }, { id = 3, panes = { asking } } } },
	})
	focus(wezterm)
	states(plugin)
	first.title = "✳ x"
	states(plugin)
	second.title = "✳ x"
	states(plugin)
	asking.title = "[ ! ] Action Required"
	states(plugin)

	local window = fake.window("default")
	plugin.jump_to_attention(window, nil)
	eq(asking.activated, 1, "waiting pane first")
	eq(wezterm.active_workspace, nil, "same workspace: no switch")

	asking.title = "my-thread"
	plugin.jump_to_attention(window, nil)
	eq(first.activated, 1, "earliest done pane next")
	eq(second.activated, 0, "later done pane not yet")
	eq(wezterm.active_workspace, "other", "switched workspace")
end)

test("shows a toast when no agent needs attention", function()
	local plugin = load_plugin(tab_per_pane({ claude_pane(1, "◐ x") }))
	local window = fake.window()
	plugin.jump_to_attention(window, nil)
	eq(toast_messages(window), "No agents need attention", "toast")
	eq(window.toasts[1].timeout, 3000, "short timeout")
end)

test("orders selector entries waiting, done, busy, idle", function()
	local finishing = claude_pane(6, "◐ x")
	local plugin, wezterm = load_plugin(tab_per_pane({
		claude_pane(1, "✳ x"),
		claude_pane(2, "◐ x"),
		codex_pane(3, "[ ! ] Action Required"),
		claude_pane(4, "✳ x"),
		claude_pane(5, "◐ x"),
		finishing,
	}))
	focus(wezterm)
	states(plugin)
	finishing.title = "✳ x"
	local window = fake.window()
	plugin.show_agent_selector(window, nil)
	local ids = {}
	for _, choice in ipairs(window.actions[1].action.InputSelector.choices) do
		table.insert(ids, choice.id)
	end
	eq(table.concat(ids, ","), "3,6,2,5,1,4", "order")
end)

local real_time = os.time
local failed = 0
for _, t in ipairs(tests) do
	local ok, err = pcall(t.fn)
	-- selene: allow(incorrect_standard_library_use)
	os.time = real_time
	if ok then
		print("ok   " .. t.name)
	else
		failed = failed + 1
		print("FAIL " .. t.name .. "\n     " .. tostring(err))
	end
end
print(string.format("%d passed, %d failed", #tests - failed, failed))
if failed > 0 then
	os.exit(1)
end
