-- A minimal stand-in for the parts of the wezterm module the plugin uses.
local M = {}

-- A foreground process as returned by pane:get_foreground_process_info().
-- children is keyed by pid, like WezTerm's LocalProcessInfo.
function M.process(name, argv, children)
	return {
		name = name,
		executable = "/usr/bin/" .. name,
		argv = argv or { name },
		children = children or {},
	}
end

function M.pane(opts)
	local pane = {
		id = opts.id,
		title = opts.title or "",
		info = opts.info,
		cwd = opts.cwd,
		injected = {},
		activated = 0,
	}
	function pane.pane_id(self)
		return self.id
	end
	function pane.get_title(self)
		return self.title
	end
	function pane.get_foreground_process_info(self)
		return self.info
	end
	function pane.get_current_working_dir(self)
		if self.cwd then
			return { file_path = self.cwd }
		end
		return nil
	end
	function pane.inject_output(self, text)
		table.insert(self.injected, text)
	end
	function pane.activate(self)
		self.activated = self.activated + 1
	end
	return pane
end

-- A GUI window as passed to action callbacks or listed by
-- wezterm.gui.gui_windows(); focused and active_pane decide which pane is seen.
function M.window(workspace, focused, active_pane)
	local window =
		{ workspace = workspace or "default", focused = focused, pane = active_pane, toasts = {}, actions = {} }
	function window.active_workspace(self)
		return self.workspace
	end
	function window.is_focused(self)
		return self.focused
	end
	function window.active_pane(self)
		return self.pane
	end
	function window.toast_notification(self, title, message, _url, timeout)
		table.insert(self.toasts, { title = title, message = message, timeout = timeout })
	end
	function window.perform_action(self, action, pane)
		table.insert(self.actions, { action = action, pane = pane })
	end
	return window
end

-- Flat string -> string maps only, which is all the plugin stores. An empty
-- table encodes as "[]" because WezTerm cannot tell an empty object from an
-- empty array.
local function json_encode(value)
	local keys = {}
	for key, item in pairs(value) do
		assert(type(key) == "string" and type(item) == "string", "fake json_encode: flat string maps only")
		table.insert(keys, key)
	end
	if #keys == 0 then
		return "[]"
	end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do
		table.insert(parts, string.format('"%s":"%s"', key, value[key]))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

local function json_parse(text)
	if type(text) ~= "string" then
		error("fake json_parse: expected a string, got " .. type(text))
	end
	if text == "[]" or text == "{}" then
		return {}
	end
	if not text:match("^{.*}$") then
		error("fake json_parse: invalid JSON " .. text)
	end
	local result = {}
	for key, item in text:gmatch('"([^"]*)"%s*:%s*"([^"]*)"') do
		result[key] = item
	end
	return result
end

-- windows: list of { workspace = ..., tabs = { { id = ..., title = ..., panes = { pane, ... } } } }.
-- The tables stay live, so tests can add, remove or change panes between scans.
-- Pass globals to share wezterm.GLOBAL across instances (simulates a config reload).
-- Set wezterm.gui_window_list to the GUI windows (none by default).
function M.new(windows, globals)
	local wezterm = { GLOBAL = globals or {}, handlers = {}, active_workspace = nil, gui_window_list = {} }
	wezterm.gui = {
		gui_windows = function()
			return wezterm.gui_window_list
		end,
	}

	function wezterm.on(event, handler)
		wezterm.handlers[event] = wezterm.handlers[event] or {}
		table.insert(wezterm.handlers[event], handler)
	end

	function wezterm.emit(event, ...)
		for _, handler in ipairs(wezterm.handlers[event] or {}) do
			handler(...)
		end
	end

	wezterm.action = {
		InputSelector = function(args)
			return { InputSelector = args }
		end,
	}
	function wezterm.action_callback(callback)
		return callback
	end
	wezterm.json_encode = json_encode
	wezterm.json_parse = json_parse

	local function mux_tab(tab)
		return {
			tab_id = function()
				return tab.id
			end,
			get_title = function()
				return tab.title or ""
			end,
			panes = function()
				return tab.panes
			end,
		}
	end

	wezterm.mux = {
		all_windows = function()
			local result = {}
			for _, window in ipairs(windows) do
				table.insert(result, {
					get_workspace = function()
						return window.workspace or "default"
					end,
					tabs = function()
						local tabs = {}
						for _, tab in ipairs(window.tabs) do
							table.insert(tabs, mux_tab(tab))
						end
						return tabs
					end,
				})
			end
			return result
		end,
		get_pane = function(id)
			for _, window in ipairs(windows) do
				for _, tab in ipairs(window.tabs) do
					for _, pane in ipairs(tab.panes) do
						if pane.id == id then
							return pane
						end
					end
				end
			end
			return nil
		end,
		set_active_workspace = function(name)
			wezterm.active_workspace = name
		end,
	}

	return wezterm
end

return M
