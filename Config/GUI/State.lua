--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Config/GUI/State.lua
	Purpose:
		What the options window remembers and what it can look up.

		New settings. A control may carry `since = "1.0.0-beta5"`, the release that
		added it. It counts as new until its page has been opened, and only when it
		is newer than the version the player first ran this tracking on, so a fresh
		install starts with nothing marked. The baseline is the version recorded by
		the installer for an existing player, or the running version for a new one.

		Search. Every setting the schema holds, flyout pages included, in one flat
		list, so a typed word finds the setting itself and not only its page.

		Modified. A setting counts as changed when it differs from the shipped
		default.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local GUI = K.GUI

local abs = math.abs
local ipairs = ipairs
local pairs = pairs
local tconcat = table.concat
local tonumber = tonumber
local tsort = table.sort
local type = type

-- ---------------------------------------------------------------------------
-- Versions
-- ---------------------------------------------------------------------------

-- Turn "1.0.0-beta4" into a number that sorts correctly. A pre-release sorts
-- below the release it leads up to, and a plain release sorts above them all.
function GUI.VersionKey(version)
	if type(version) ~= "string" then
		return 0
	end
	local major, minor, patch = version:match("^(%d+)%.(%d+)%.(%d+)")
	if not major then
		return 0
	end
	local key = tonumber(major) * 1e8 + tonumber(minor) * 1e6 + tonumber(patch) * 1e4
	local tag, number = version:match("%-(%a+)(%d*)")
	if not tag then
		return key + 9000
	end
	local base = (tag == "beta" and 100) or (tag == "rc" and 200) or 0
	return key + base + (tonumber(number) or 0)
end

-- ---------------------------------------------------------------------------
-- Saved state
-- ---------------------------------------------------------------------------

function GUI.State()
	if not KkthnxUIDB then
		return nil
	end
	local state = KkthnxUIDB.gui
	if type(state) ~= "table" then
		state = {}
		KkthnxUIDB.gui = state
	end
	state.seen = state.seen or {}
	-- Read at login, before the installer can overwrite installedVersion, so an
	-- upgrading player gets the version they upgraded from.
	if not state.baseline then
		state.baseline = KkthnxUIDB.installedVersion or K.Version
	end
	-- A baseline newer than the running version came from the old version scheme
	-- (11.1.1 before 1.0.0) and would hide every new setting for good. Fall back
	-- to the installed version, or the running one if that is no better.
	local current = GUI.VersionKey(K.Version)
	if GUI.VersionKey(state.baseline) > current then
		local installed = KkthnxUIDB.installedVersion
		if installed and GUI.VersionKey(installed) <= current then
			state.baseline = installed
		else
			state.baseline = K.Version
		end
	end
	return state
end

-- One chat line at login when there are new settings to look at. It only comes
-- back when the version changes or more settings turn up, so it never nags.
local function LoginHint()
	local state = GUI.State()
	if not state or not C.General.WelcomeMessage then
		return
	end
	local count = GUI.CountNewTotal()
	local last = state.hint
	if count > 0 and (not last or last.version ~= K.Version or count > (last.count or 0)) then
		K.Print(L["%d new settings since your last update. Type %s and open What's New."], count, K.ColorText("accent", "/kk"))
	end
	state.hint = { version = K.Version, count = count }
end

local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function(self)
	GUI.State()
	self:UnregisterAllEvents()
	-- After the welcome line, so the two read in order.
	C_Timer.After(2, LoginHint)
end)

-- ---------------------------------------------------------------------------
-- Control identity
-- ---------------------------------------------------------------------------

function GUI.ControlKey(control)
	if control.path then
		return tconcat(control.path, ".")
	end
	return "label:" .. tostring(control.label)
end

function GUI.IsNew(control)
	if not control.since then
		return false
	end
	local state = GUI.State()
	if not state or state.seen[GUI.ControlKey(control)] then
		return false
	end
	return GUI.VersionKey(control.since) > GUI.VersionKey(state.baseline)
end

-- ---------------------------------------------------------------------------
-- Index of every setting
-- ---------------------------------------------------------------------------

local index

local function Walk(category, controls, extra)
	local section
	for _, control in ipairs(controls) do
		if control.kind == "header" then
			section = control.label
		elseif control.kind ~= "description" and control.label then
			index[#index + 1] = {
				control = control,
				category = category,
				section = section,
				extra = extra,
				label = control.label,
				haystack = (control.label .. " " .. (control.tooltip or "") .. " " .. (section or "")):lower(),
			}
		end
		if control.searchControls then
			Walk(category, control.searchControls, control)
		end
	end
end

function GUI.Index()
	if index then
		return index
	end
	index = {}
	for _, category in ipairs(GUI.schema) do
		if category.controls then
			Walk(category, category.controls)
		end
	end
	return index
end

-- Settings matching every word of the query, best matches first, a label that
-- starts with the query, then a label that contains it, then a match elsewhere.
function GUI.Search(query, limit)
	local words = {}
	for word in query:lower():gmatch("%S+") do
		words[#words + 1] = word
	end
	if #words == 0 then
		return {}
	end
	local whole = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
	local results = {}
	for _, entry in ipairs(GUI.Index()) do
		local matches = true
		for _, word in ipairs(words) do
			if not entry.haystack:find(word, 1, true) then
				matches = false
				break
			end
		end
		if matches then
			local label = entry.label:lower()
			entry.rank = (label:sub(1, #whole) == whole and 1) or (label:find(whole, 1, true) and 2) or 3
			results[#results + 1] = entry
		end
	end
	tsort(results, function(a, b)
		if a.rank ~= b.rank then
			return a.rank < b.rank
		end
		return a.label < b.label
	end)
	for i = #results, (limit or 40) + 1, -1 do
		results[i] = nil
	end
	return results
end

-- ---------------------------------------------------------------------------
-- New and seen
-- ---------------------------------------------------------------------------

-- How many unseen new settings a page holds, flyout pages included.
function GUI.CountNew(category)
	local count = 0
	for _, entry in ipairs(GUI.Index()) do
		if entry.category == category and GUI.IsNew(entry.control) then
			count = count + 1
		end
	end
	return count
end

function GUI.CountNewTotal()
	local count = 0
	for _, entry in ipairs(GUI.Index()) do
		if GUI.IsNew(entry.control) then
			count = count + 1
		end
	end
	return count
end

-- Mark every new setting on a page as seen. Returns true when anything changed.
function GUI.MarkPageSeen(category)
	local state = GUI.State()
	if not state then
		return false
	end
	local changed = false
	for _, entry in ipairs(GUI.Index()) do
		if entry.category == category and GUI.IsNew(entry.control) then
			state.seen[GUI.ControlKey(entry.control)] = true
			changed = true
		end
	end
	return changed
end

function GUI.MarkAllSeen()
	local state = GUI.State()
	if not state then
		return
	end
	for _, entry in ipairs(GUI.Index()) do
		if entry.control.since then
			state.seen[GUI.ControlKey(entry.control)] = true
		end
	end
end

-- Every setting that carries a since tag, newest release first.
function GUI.ReleaseEntries()
	local list = {}
	for _, entry in ipairs(GUI.Index()) do
		if entry.control.since then
			list[#list + 1] = entry
		end
	end
	tsort(list, function(a, b)
		local ka, kb = GUI.VersionKey(a.control.since), GUI.VersionKey(b.control.since)
		if ka ~= kb then
			return ka > kb
		end
		if a.category.title ~= b.category.title then
			return a.category.title < b.category.title
		end
		return a.label < b.label
	end)
	return list
end

-- ---------------------------------------------------------------------------
-- Modified from default
-- ---------------------------------------------------------------------------

local function Same(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) == "number" then
		return abs(a - b) < 1e-6
	end
	if type(a) == "table" then
		for key, value in pairs(a) do
			if not Same(value, b[key]) then
				return false
			end
		end
		for key in pairs(b) do
			if a[key] == nil then
				return false
			end
		end
		return true
	end
	return a == b
end
GUI.SameValue = Same

function GUI.IsModified(control)
	if not control.path then
		return false
	end
	-- A value another setting manages is not the player's change.
	if control.disabledWhen and GUI.GetValue(control.disabledWhen) then
		return false
	end
	local default = GUI.GetDefault(control.path)
	if default == nil then
		return false
	end
	return not Same(GUI.GetValue(control.path), default)
end

-- Every setting that differs from its default, for the Changed view.
function GUI.ChangedEntries()
	local list = {}
	for _, entry in ipairs(GUI.Index()) do
		if GUI.IsModified(entry.control) then
			list[#list + 1] = entry
		end
	end
	return list
end
