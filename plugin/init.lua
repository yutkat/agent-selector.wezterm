local wezterm = require("wezterm")
local act = wezterm.action

local M = {}

-- Used when an agent has no busy_pattern: the two most common TUI
-- footers shown while an agent is generating.
local DEFAULT_BUSY_PATTERNS = { "[Ee]sc to interrupt", "[Ee]sc to cancel" }

M.config = {
	agents = {
		{ name = "claude", process = "claude", busy_pattern = "[Ee]sc to interrupt" },
		{ name = "codex", process = "codex", busy_pattern = "[Ee]sc to interrupt" },
		{ name = "opencode", process = "opencode", busy_pattern = "working" },
		{ name = "gemini", process = "gemini", busy_pattern = "[Ee]sc to cancel" },
		{ name = "copilot", process = "copilot" },
		{ name = "cursor-agent", process = "cursor-agent" },
		{ name = "amp", process = "amp" },
		{ name = "pi", process = "pi" },
		{ name = "droid", process = "droid" },
		{ name = "grok", process = "grok" },
		{ name = "kiro", process = "kiro" },
		{ name = "cline", process = "cline" },
	},
}

function M.setup(opts)
	opts = opts or {}
	if opts.agents then
		M.config.agents = opts.agents
	end
end

local INTERPRETERS = { node = true, bun = true, deno = true, python = true, ruby = true }

local function basename(path)
	return path and path:match("([^/\\]+)$") or nil
end

-- Interpreter-run scripts (e.g. `codex` -> codex.js via `#!/usr/bin/env node`)
-- keep the command name only in the script path: comm and argv[0] become the
-- interpreter itself. Match the script's extension-stripped stem, but only
-- behind a known interpreter so panes like `nvim codex.md` don't match.
local function script_stem_matches(argv, process)
	if argv == nil then
		return false
	end
	local interpreter = basename(argv[1])
	local script = basename(argv[2])
	if interpreter == nil or script == nil then
		return false
	end
	if not INTERPRETERS[interpreter:gsub("%d+$", "")] then
		return false
	end
	return script:gsub("%.%w+$", "") == process
end

-- Matches the agent's process name against the comm name, argv[0] and
-- executable path of the pane's foreground process. The executable path
-- alone is not enough: version-managed installs resolve through symlinks
-- (e.g. ~/.local/bin/claude -> .../versions/2.1.199), so only comm and
-- argv[0] keep the invoked name.
local function matches_process(agent, info, exe_path)
	local candidates = { exe_path }
	if info then
		table.insert(candidates, info.name)
		table.insert(candidates, info.executable)
		if info.argv then
			table.insert(candidates, info.argv[1])
		end
	end
	for _, candidate in ipairs(candidates) do
		if basename(candidate) == agent.process then
			return true
		end
	end
	return info ~= nil and script_stem_matches(info.argv, agent.process)
end

-- Whole-word title match, so short agent names like "pi" or "amp" do
-- not match inside words ("pipeline", "amplifier").
local function title_matches(title, name)
	local escaped = name:lower():gsub("%W", "%%%0")
	return title:find("%f[%w]" .. escaped .. "%f[%W]") ~= nil
end

-- Returns the agent definition matching the pane, or nil.
-- Falls back to a whole-word title match when no foreground process
-- information is available (e.g. ssh/mux domains).
local function find_agent(pane)
	local ok, info = pcall(function()
		return pane:get_foreground_process_info()
	end)
	if not ok then
		info = nil
	end
	local exe_path = pane:get_foreground_process_name()
	local title = (pane:get_title() or ""):lower()
	for _, agent in ipairs(M.config.agents) do
		if matches_process(agent, info, exe_path) then
			return agent
		end
		if info == nil and exe_path == nil and title_matches(title, agent.name) then
			return agent
		end
	end
	return nil
end

-- Only the bottom of the pane is scanned: the busy footer of every
-- supported agent lives there, and generic words like opencode's
-- "working" would otherwise match ordinary conversation text.
local BUSY_SCAN_LINES = 10

local function is_busy(pane, agent)
	local ok, text = pcall(function()
		return pane:get_lines_as_text()
	end)
	if not ok or text == nil then
		return false
	end
	local lines = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	while #lines > 0 and lines[#lines]:match("^%s*$") do
		table.remove(lines)
	end
	if #lines == 0 then
		return false
	end
	local tail = table.concat(lines, "\n", math.max(1, #lines - BUSY_SCAN_LINES + 1))
	local patterns = agent.busy_pattern or DEFAULT_BUSY_PATTERNS
	if type(patterns) == "string" then
		patterns = { patterns }
	end
	for _, pattern in ipairs(patterns) do
		if tail:find(pattern) then
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

local function collect_agent_panes()
	local entries = {}
	for _, mux_win in ipairs(wezterm.mux.all_windows()) do
		local workspace = mux_win:get_workspace()
		for _, tab in ipairs(mux_win:tabs()) do
			for _, pane in ipairs(tab:panes()) do
				local ok, entry = pcall(function()
					local agent = find_agent(pane)
					if agent == nil then
						return nil
					end
					local marker = is_busy(pane, agent) and "●" or "○"
					local title = tab:get_title()
					if title == nil or title == "" then
						title = pane:get_title() or ""
					end
					local parts = { marker .. " " .. agent.name }
					local dir = cwd_basename(pane)
					if dir then
						table.insert(parts, "[" .. dir .. "]")
					end
					table.insert(parts, workspace .. ": " .. title)
					return {
						pane = pane,
						workspace = workspace,
						label = table.concat(parts, "  "),
					}
				end)
				if ok and entry then
					table.insert(entries, entry)
				end
			end
		end
	end
	return entries
end

function M.show_agent_selector(window, pane)
	local entries = collect_agent_panes()
	if #entries == 0 then
		window:toast_notification("wezterm", "No agent panes found", nil, 3000)
		return
	end
	local choices = {}
	local by_id = {}
	for _, entry in ipairs(entries) do
		local id = tostring(entry.pane:pane_id())
		by_id[id] = entry
		table.insert(choices, { id = id, label = entry.label })
	end
	window:perform_action(
		act.InputSelector({
			title = "Agents",
			choices = choices,
			fuzzy = true,
			action = wezterm.action_callback(function(inner_window, _inner_pane, id, _label)
				if id == nil then
					return
				end
				local entry = by_id[id]
				if entry == nil then
					return
				end
				if inner_window:active_workspace() ~= entry.workspace then
					wezterm.mux.set_active_workspace(entry.workspace)
				end
				entry.pane:activate()
			end),
		}),
		pane
	)
end

M.action = {
	ShowAgentSelector = wezterm.action_callback(M.show_agent_selector),
}

return M
