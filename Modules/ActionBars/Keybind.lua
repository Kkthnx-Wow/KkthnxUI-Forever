--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/Keybind.lua
	Purpose:
		Shorten hotkey text so it fits the small corner of a button. The library and
		the Blizzard pet, stance and possess buttons write the HotKey font string
		with GetBindingText, so we hook its SetText and rewrite the result.

		GetBindingText only abbreviates modifiers ("s-", "c-", "a-"). Every other key
		comes through as its full localized name, such as "Mouse Button 5". Those
		names differ in word order between locales, so instead of pattern matching we
		ask the client for the exact name of each key and look it up whole.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("ActionBars")

local _G = _G
local GetBindingText = GetBindingText
local ipairs = ipairs
local pairs = pairs
local string_sub = string.sub
local type = type

-- Binding key tokens and the label shown for them. Keys not listed (letters,
-- digits, F keys, punctuation) are already short and pass through unchanged.
local SHORT = {
	MOUSEWHEELUP = "MU",
	MOUSEWHEELDOWN = "MD",
	NUMPADDECIMAL = "N.",
	NUMPADDIVIDE = "N/",
	NUMPADMINUS = "N-",
	NUMPADMULTIPLY = "N*",
	NUMPADPLUS = "N+",
	NUMLOCK = "NL",
	PAGEUP = "PU",
	PAGEDOWN = "PD",
	HOME = "Hm",
	END = "End",
	INSERT = "Ins",
	DELETE = "Del",
	BACKSPACE = "BS",
	TAB = "Tab",
	ESCAPE = "Esc",
	SPACE = "Sp",
	CAPSLOCK = "CL",
	ENTER = "Ent",
	UP = "Up",
	DOWN = "Dn",
	LEFT = "Lt",
	RIGHT = "Rt",
	PRINTSCREEN = "PS",
	SCROLLLOCK = "SL",
	PAUSE = "Pa",
}
for i = 1, 31 do
	SHORT["BUTTON" .. i] = "M" .. i
end
for i = 0, 9 do
	SHORT["NUMPAD" .. i] = "N" .. i
end

-- Display name -> label. Filled from the raw token, the KEY_ global and what
-- GetBindingText returns, so it matches whichever form reaches the font string.
local keyLabel = {}
for token, label in pairs(SHORT) do
	keyLabel[token] = label
	local name = _G["KEY_" .. token]
	if type(name) == "string" and name ~= "" then
		keyLabel[name] = label
	end
	local shown = GetBindingText(token, true)
	if type(shown) == "string" and shown ~= "" then
		keyLabel[shown] = label
	end
	shown = GetBindingText(token)
	if type(shown) == "string" and shown ~= "" then
		keyLabel[shown] = label
	end
end

-- Modifier prefixes as they can appear in hotkey text, each with our letter.
-- Some locales share an abbreviation (French uses "m" for both Shift and Meta),
-- so the first claim wins and Shift is listed ahead of Meta.
local MODIFIERS = {
	{ "SHIFT", "s" },
	{ "CTRL", "c" },
	{ "ALT", "a" },
	{ "META", "m" },
}
local prefixes = {}
do
	local taken = {}
	local function Add(prefix, letter)
		if type(prefix) == "string" and prefix ~= "-" and not taken[prefix] then
			taken[prefix] = true
			prefixes[#prefixes + 1] = { prefix, #prefix, letter }
		end
	end
	for _, mod in ipairs(MODIFIERS) do
		local token, letter = mod[1], mod[2]
		Add(token .. "-", letter)
		Add((_G[token .. "_KEY_TEXT_ABBR"] or "") .. "-", letter)
		Add((_G[token .. "_KEY_TEXT"] or "") .. "-", letter)
	end
end

-- Strip leading modifier prefixes into letters, then look the key up whole.
local function Build(text)
	local mods = ""
	local matched = true
	while matched do
		matched = false
		for _, entry in ipairs(prefixes) do
			local prefix, length = entry[1], entry[2]
			-- Keep at least one character so the minus key itself is never eaten.
			if #text > length and string_sub(text, 1, length) == prefix then
				mods = mods .. entry[3]
				text = string_sub(text, length + 1)
				matched = true
				break
			end
		end
	end
	return mods .. (keyLabel[text] or text)
end

-- Keys come from a small fixed set, so each distinct text is worked out once.
local abbreviated = {}

local function Shorten(text)
	local short = abbreviated[text]
	if short == nil then
		if text == _G.RANGE_INDICATOR then
			short = ""
		else
			short = Build(text)
		end
		abbreviated[text] = short
	end
	return short
end

-- Abbreviate the given hotkey font string. Called as a SetText hook, so it
-- guards against recursion with a flag.
local function Abbreviate(hotkey)
	if hotkey.__setting then
		return
	end
	local text = hotkey:GetText()
	if not text or text == "" then
		return
	end
	-- In the hotkey range mode the dot is the out-of-range signal on a button with
	-- no key shown, so it must survive. Otherwise it is blanked like stock art.
	if text == _G.RANGE_INDICATOR and C.ActionBar.RangeColoring == "hotkey" then
		return
	end

	local short = Shorten(text)
	if short == text then
		return
	end

	hotkey.__setting = true
	hotkey:SetText(short)
	hotkey.__setting = false
end

-- Apply abbreviation to a button's hotkey and keep it applied on rebind.
function Module:StyleHotKey(button)
	local hotkey = button.HotKey
	if not hotkey or hotkey.__abbrevHooked then
		return
	end
	hotkey.__abbrevHooked = true
	Abbreviate(hotkey)
	hooksecurefunc(hotkey, "SetText", Abbreviate)
end
