local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

M.config = {
	agents = {
		{
			name = "claude",
			process = "claude",
			-- Title prefix while working: a spinner, or > in the alternate mode
			-- (✳ / * when idle). Multibyte characters cannot go in a [] class.
			busy_title = { "^◐ ", "^◑ ", "^> " },
		},
		{
			name = "codex",
			process = "codex",
			-- With [tui] terminal_title including "spinner"/"activity" and
			-- tui.animations on: a braille spinner frame while working, and
			-- "[ ! ] Action Required" (blinking with "[ . ]") when blocked on the
			-- user. There is no idle prefix.
			busy_title = { "^⠋", "^⠙", "^⠹", "^⠸", "^⠼", "^⠴", "^⠦", "^⠧", "^⠇", "^⠏" },
			waiting_title = "^%[ [!.] %] Action Required",
		},
	},
	icons = { waiting = "▲ ", done = "✓ ", busy = "● ", idle = "○ " },
	scan_interval = 1,
	notify = true,
	backgrounds = {},
}

function M.setup(opts)
	opts = opts or {}
	if opts.agents then
		M.config.agents = opts.agents
	end
	if opts.icons then
		for state, icon in pairs(opts.icons) do
			M.config.icons[state] = icon
		end
	end
	if opts.scan_interval then
		M.config.scan_interval = opts.scan_interval
	end
	if opts.notify ~= nil then
		M.config.notify = opts.notify
	end
	if opts.backgrounds then
		for name, color in pairs(opts.backgrounds) do
			M.config.backgrounds[name] = color
		end
	end
end

local function basename(path)
	return path and path:match("([^/\\]+)$") or nil
end

-- Matches the agent's process name against the comm name, executable basename
-- and argv[0] of a process, then of its descendants. The executable alone is
-- not enough: version-managed installs resolve through symlinks (e.g.
-- ~/.local/bin/claude -> .../versions/2.1.199), so only comm and argv[0] keep
-- the invoked name. Descendants are checked because wrapper scripts that
-- cannot exec (e.g. ones doing post-processing) leave the agent as a child.
local function matches_process(agent, info)
	local candidates = { info.name, info.executable, info.argv and info.argv[1] }
	for _, candidate in pairs(candidates) do
		if basename(candidate) == agent.process then
			return true
		end
	end
	for _, child in pairs(info.children or {}) do
		if matches_process(agent, child) then
			return true
		end
	end
	return false
end

-- Returns the agent definition matching the pane's foreground process tree,
-- or nil. Panes without process information (e.g. ssh/mux domains) have none.
local function find_agent(pane)
	local ok, info = pcall(function()
		return pane:get_foreground_process_info()
	end)
	if not ok or info == nil then
		return nil
	end
	for _, agent in ipairs(M.config.agents) do
		if matches_process(agent, info) then
			return agent
		end
	end
	return nil
end

-- patterns is a Lua pattern or a list of them.
local function matches_any(text, patterns)
	if type(patterns) == "string" then
		patterns = { patterns }
	end
	for _, pattern in ipairs(patterns) do
		if text:find(pattern) then
			return true
		end
	end
	return false
end

local function cwd_basename(pane)
	local ok, url = pcall(function()
		return pane:get_current_working_dir()
	end)
	if not ok or url == nil then
		return nil
	end
	local path = url.file_path or tostring(url)
	return path:gsub("/+$", ""):match("([^/]+)$")
end

-- Display order of states in summary() and the selector. "done" is an idle
-- agent that finished while its pane was not seen.
local STATES = { "waiting", "done", "busy", "idle" }
local RANK = {}
for i, state in ipairs(STATES) do
	RANK[state] = i
end

-- Results of the last scan, read by summary().
local counts = {}
local last_scan = nil
-- Per pane_id from the previous scan: { state, unread, since }. since orders
-- transitions for jump_to_attention().
local tracked = {}
local transitions = 0

-- The state comes from the title prefix only. Anything else (an idle prefix,
-- titles disabled, tmux, or an agent without title patterns) means idle.
local function title_state(pane, agent)
	local title = pane:get_title() or ""
	if agent.waiting_title and matches_any(title, agent.waiting_title) then
		return "waiting"
	end
	if agent.busy_title and matches_any(title, agent.busy_title) then
		return "busy"
	end
	return "idle"
end

local function pane_state(pane)
	local agent = find_agent(pane)
	if agent == nil then
		return nil
	end
	return agent.name, title_state(pane, agent)
end

-- Tints agent panes per M.config.backgrounds with OSC 11 and resets them with
-- OSC 111 once they stop being agent panes. Tinted panes are kept in
-- wezterm.GLOBAL so a config reload does not lose them, stored as a JSON
-- string to avoid iterating GLOBAL's table proxies.
local function update_tints(entries)
	local ok, tinted = pcall(wezterm.json_parse, wezterm.GLOBAL.ai_agents_tinted)
	if not ok or type(tinted) ~= "table" then
		tinted = {}
	end
	local wanted = {}
	for _, entry in ipairs(entries) do
		local color = M.config.backgrounds[entry.name]
		if color then
			local id = tostring(entry.pane:pane_id())
			wanted[id] = true
			if tinted[id] ~= color then
				pcall(function()
					entry.pane:inject_output("\27]11;" .. color .. "\27\\")
				end)
				tinted[id] = color
			end
		end
	end
	for id in pairs(tinted) do
		if not wanted[id] then
			pcall(function()
				local pane = wezterm.mux.get_pane(tonumber(id))
				if pane then
					pane:inject_output("\27]111\27\\")
				end
			end)
			tinted[id] = nil
		end
	end
	wezterm.GLOBAL.ai_agents_tinted = wezterm.json_encode(tinted)
end

-- Panes the user is looking at: the active pane of a focused GUI window.
local function seen_panes()
	local seen = {}
	pcall(function()
		for _, window in ipairs(wezterm.gui.gui_windows()) do
			if window:is_focused() then
				seen[window:active_pane():pane_id()] = true
			end
		end
	end)
	return seen
end

-- "<head>  [dir]  workspace: tab title", shared by the selector and toasts.
local function label(entry, head)
	local parts = { head }
	if entry.dir then
		table.insert(parts, "[" .. entry.dir .. "]")
	end
	table.insert(parts, entry.workspace .. ": " .. entry.tab_title)
	return table.concat(parts, "  ")
end

-- Toasts on the focused GUI window, else the first one. No timeout, so the
-- notification daemon's default applies.
local function notify(message)
	pcall(function()
		local windows = wezterm.gui.gui_windows()
		local target = windows[1]
		for _, window in ipairs(windows) do
			if window:is_focused() then
				target = window
			end
		end
		if target then
			target:toast_notification("ai-agents", message, nil)
		end
	end)
end

-- Compares each entry's state with the previous scan: busy -> idle is
-- "finished" and anything -> waiting "needs you", notified unless the pane is
-- seen. A pane that finished unseen stays "done" until it is seen or leaves
-- idle. Panes new to the scan (e.g. right after loading) never notify.
local function track(entries)
	local seen = seen_panes()
	local new_tracked = {}
	for _, entry in ipairs(entries) do
		local id = entry.pane:pane_id()
		local prev = tracked[id]
		local current = { state = entry.state, unread = prev and prev.unread, since = prev and prev.since }
		local event = nil
		if prev == nil or prev.state ~= entry.state then
			transitions = transitions + 1
			current.since = transitions
			if prev and entry.state == "waiting" then
				event = "needs you"
			elseif prev and prev.state == "busy" and entry.state == "idle" then
				event = "finished"
				current.unread = true
			end
		end
		if seen[id] or entry.state ~= "idle" then
			current.unread = false
		end
		if event and not seen[id] and M.config.notify then
			notify(label(entry, entry.name .. " " .. event))
		end
		if current.unread then
			entry.state = "done"
		end
		entry.since = current.since
		new_tracked[id] = current
	end
	tracked = new_tracked
end

local function scan()
	local entries = {}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		local workspace = mux_win:get_workspace()
		for _, tab in ipairs(mux_win:tabs()) do
			for _, pane in ipairs(tab:panes()) do
				local ok, entry = pcall(function()
					local name, state = pane_state(pane)
					if name == nil then
						return nil
					end
					local title = tab:get_title()
					if title == nil or title == "" then
						title = pane:get_title() or ""
					end
					return {
						pane = pane,
						workspace = workspace,
						tab_title = title,
						name = name,
						state = state,
						dir = cwd_basename(pane),
					}
				end)
				if ok and entry then
					table.insert(entries, entry)
				end
			end
		end
	end
	track(entries)
	counts = {}
	for _, entry in ipairs(entries) do
		counts[entry.state] = (counts[entry.state] or 0) + 1
	end
	last_scan = os.time()
	update_tints(entries)
	return entries
end

-- update-status fires once per window, so the scan is throttled. Nothing is
-- drawn here: the status bar belongs to the user, who calls summary().
wezterm.on("update-status", function()
	if last_scan and os.time() - last_scan < M.config.scan_interval then
		return
	end
	scan()
end)

-- Icons are trimmed: summary() and the selector add their own spacing.
local function icon_for(state, opts)
	local icons = opts and opts.icons
	local icon = (icons and icons[state]) or M.config.icons[state]
	return (icon:gsub("%s+$", ""))
end

-- Returns the non-zero agent counts per state (e.g. "▲1 ●1 ○2") for use in a
-- status bar, or "" when there are no agents.
function M.summary(opts)
	local parts = {}
	for _, state in ipairs(STATES) do
		if counts[state] then
			table.insert(parts, icon_for(state, opts) .. counts[state])
		end
	end
	return table.concat(parts, " ")
end

local function activate(window, entry)
	if window:active_workspace() ~= entry.workspace then
		wezterm.mux.set_active_workspace(entry.workspace)
	end
	entry.pane:activate()
end

function M.show_agent_selector(window, pane)
	local entries = scan()
	if #entries == 0 then
		window:toast_notification("wezterm", "No agent panes found", nil, 3000)
		return
	end
	for i, entry in ipairs(entries) do
		entry.index = i
	end
	table.sort(entries, function(a, b)
		if RANK[a.state] ~= RANK[b.state] then
			return RANK[a.state] < RANK[b.state]
		end
		return a.index < b.index
	end)
	local choices = {}
	local by_id = {}
	for _, entry in ipairs(entries) do
		local id = tostring(entry.pane:pane_id())
		by_id[id] = entry
		table.insert(choices, { id = id, label = label(entry, icon_for(entry.state) .. " " .. entry.name) })
	end
	window:perform_action(
		act.InputSelector({
			title = "Agents",
			choices = choices,
			fuzzy = true,
			action = wezterm.action_callback(function(inner_window, _inner_pane, id, _label)
				local entry = id and by_id[id]
				if entry then
					activate(inner_window, entry)
				end
			end),
		}),
		pane
	)
end

-- Activates the agent pane needing attention: waiting first, then done; the
-- earliest transition first among equals.
function M.jump_to_attention(window, _pane)
	local best = nil
	for _, entry in ipairs(scan()) do
		if entry.state == "waiting" or entry.state == "done" then
			if
				best == nil
				or RANK[entry.state] < RANK[best.state]
				or (entry.state == best.state and entry.since < best.since)
			then
				best = entry
			end
		end
	end
	if best == nil then
		window:toast_notification("ai-agents", "No agents need attention", nil, 3000)
		return
	end
	activate(window, best)
end

M.action = {
	ShowAgentSelector = wezterm.action_callback(M.show_agent_selector),
	JumpToAttention = wezterm.action_callback(M.jump_to_attention),
}

return M
