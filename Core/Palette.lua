--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/Palette.lua
	Purpose:
		The one palette every colour the UI draws comes from, and helpers to
		write text in it. Loaded right after Core/API.lua so every later file,
		including ones that build coloured strings while they load, can use it.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local format = string.format
local type = type
local pairs = pairs
local setmetatable = setmetatable

-- ---------------------------------------------------------------------------
-- Palette ("Steel")
-- ---------------------------------------------------------------------------
-- Every colour the UI draws itself comes from these fourteen. Game data keeps
-- its own colours (class, item quality, reaction, level difficulty), everything
-- else picks a token by what it means, not by how it looks:
--
--   surfaces  bg        the backdrop behind everything
--             panel     a panel or tooltip body
--             raised    a control sitting on a panel (button, box)
--             line      hairlines and dividers
--   text      text      body text
--             secondary softer body text
--             muted     labels, hints, descriptions
--             disabled  greyed out or unavailable
--   meaning   accent    the theme colour: headings, focus, selection
--             highlight a value worth reading first (item level, gold)
--             positive  good, done, friendly, on
--             warning   caution, changed, needs attention
--             negative  danger, error, hostile, off
--             info      clickable hints and information
--
-- The older names below the tokens point at the same tables, so a retune here
-- reaches every call site.
local P = {
	bg = { 0.059, 0.075, 0.094 }, -- #0F1318
	panel = { 0.090, 0.114, 0.149 }, -- #171D26
	raised = { 0.122, 0.153, 0.200 }, -- #1F2733
	line = { 0.169, 0.212, 0.282 }, -- #2B3648
	text = { 0.925, 0.933, 0.949 }, -- #ECEEF2
	secondary = { 0.773, 0.835, 0.910 }, -- #C5D5E8
	muted = { 0.620, 0.655, 0.710 }, -- #9EA7B5
	disabled = { 0.451, 0.478, 0.529 }, -- #737A87
	accent = { 0.361, 0.545, 0.812 }, -- #5C8BCF
	highlight = { 0.953, 0.690, 0.263 }, -- #F3B043
	positive = { 0.306, 0.741, 0.529 }, -- #4EBD87
	warning = { 0.902, 0.502, 0.235 }, -- #E6803C
	negative = { 0.898, 0.325, 0.325 }, -- #E55353
	info = { 0.600, 0.800, 1.000 }, -- #99CCFF
}

K.Colors = P
P.gold = P.highlight
P.silver = P.secondary
P.voidDark = P.bg
P.borderSubtle = P.line
P.borderFocus = { 0.259, 0.329, 0.439 } -- #425470, a line that has focus
P.crimson = P.negative
P.jade = P.positive
P.ember = P.warning
P.offWhite = P.text

-- "|cffRRGGBB" for a token (or any colour table), for text built with markup.
-- Built once per colour and kept, since tooltips ask for these on every show.
local hexCache = setmetatable({}, { __mode = "k" })
function K.ColorHex(color)
	if type(color) == "string" then
		color = P[color]
	end
	local hex = hexCache[color]
	if not hex then
		hex = format("|cff%02x%02x%02x", color[1] * 255 + 0.5, color[2] * 255 + 0.5, color[3] * 255 + 0.5)
		hexCache[color] = hex
	end
	return hex
end

-- Wrap text in a token's colour.
function K.ColorText(color, text)
	return K.ColorHex(color) .. text .. "|r"
end

-- ---------------------------------------------------------------------------
-- Class colours
-- ---------------------------------------------------------------------------

-- The class colours are the client's own, read from RAID_CLASS_COLORS, so a class
-- reads the exact shade players know from the default UI. Mage in particular must
-- stay cyan, a darker blue reads as Shaman and as the mana bar. The table below is
-- Blizzard's published values, used only if the client table is missing a class.
-- Every class colour in the UI comes from here, so a name reads the same shade in
-- chat, tooltips, the friends list and on the frames.
local CLASS_FALLBACK = {
	DRUID = { 1.000, 0.486, 0.039 },
	HUNTER = { 0.667, 0.827, 0.447 },
	MAGE = { 0.247, 0.780, 0.922 },
	PALADIN = { 0.957, 0.549, 0.729 },
	PRIEST = { 1.000, 1.000, 1.000 },
	ROGUE = { 1.000, 0.957, 0.408 },
	SHAMAN = { 0.000, 0.439, 0.867 },
	WARLOCK = { 0.529, 0.533, 0.933 },
	WARRIOR = { 0.776, 0.608, 0.427 },
}

K.ClassColors = {}
do
	local live = _G.RAID_CLASS_COLORS
	for class, fallback in pairs(CLASS_FALLBACK) do
		local c = live and live[class]
		K.ClassColors[class] = c and { c.r, c.g, c.b } or fallback
	end
end

-- ---------------------------------------------------------------------------
-- Game state colours
-- ---------------------------------------------------------------------------
-- Colours that mean the same thing as one in the default UI keep Blizzard's hue,
-- with pure primaries softened so they do not glare on the dark bars. The same
-- treatment as the power and reaction colours in the config defaults.

-- Cast bars, as Blizzard paints them. Gold while casting, green while channelling,
-- grey when it cannot be interrupted, red when it fails or is interrupted. Shared
-- by the unit frame and nameplate castbars and the mirror timers.
K.CastColors = {
	cast = { 0.85, 0.65, 0.13 },
	channel = { 0.25, 0.72, 0.30 },
	noInterrupt = { 0.60, 0.60, 0.65 },
	fail = { 0.84, 0.27, 0.22 },
}

-- Combo points, one colour per point, climbing from the hostile red to the
-- friendly green of the reaction palette so a full bar reads as ready. Points past
-- the fifth take the last colour.
K.ComboColors = {
	{ 0.84, 0.27, 0.22 },
	{ 0.86, 0.45, 0.12 },
	{ 0.93, 0.76, 0.15 },
	{ 0.62, 0.76, 0.26 },
	{ 0.25, 0.72, 0.30 },
}

-- r, g, b for a class file name ("MAGE"). White for an unknown or secret one.
function K.ClassColorRGB(class)
	local c = class and not K.IsSecret(class) and K.ClassColors[class]
	if c then
		return c[1], c[2], c[3]
	end
	return 1, 1, 1
end

-- "|cffRRGGBB" for a class file name, for text built with markup.
function K.ClassColorHex(class)
	local c = class and not K.IsSecret(class) and K.ClassColors[class]
	return c and K.ColorHex(c) or "|cffffffff"
end

-- Wrap text in a class colour.
function K.ClassColorText(class, text)
	return K.ClassColorHex(class) .. text .. "|r"
end

-- The class file name for a localised class name ("Warlock" -> "WARLOCK"), as the
-- friends list and the who list hand them over. A class file passes through.
local classFileByName
function K.ClassFileFromName(name)
	if not name or K.IsSecret(name) then
		return nil
	end
	if K.ClassColors[name] then
		return name
	end
	if not classFileByName then
		classFileByName = {}
		for file, localized in pairs(_G.LOCALIZED_CLASS_NAMES_MALE or {}) do
			classFileByName[localized] = file
		end
		for file, localized in pairs(_G.LOCALIZED_CLASS_NAMES_FEMALE or {}) do
			classFileByName[localized] = file
		end
	end
	return classFileByName[name]
end

-- The player's own class colour, used as an accent by chat, the GCD bar, the
-- cursor trail and others.
do
	local r, g, b = K.ClassColorRGB(K.Class)
	K.ClassColor = { r = r, g = g, b = b }
end
