--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Colors.lua
	Purpose:
		Our own power and reaction palette, applied over the oUF colour tables so
		every health bar coloured by reaction and every power bar (unit frames and
		nameplates) uses them. Values live in the config so they can be tuned from
		the GUI. K.ApplyUnitColors re-reads them.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local oUF = K.oUF
local colors = oUF and oUF.colors
if not colors then
	return
end

local pairs = pairs
local Enum = Enum

-- The theme's class colours live in Core/Palette.lua. They are applied over the
-- oUF class table here.
local CLASS = K.ClassColors

-- Power tokens mapped to their numeric PowerType, so both the string lookup oUF
-- does first and the numeric fallback point at our colour.
local POWER_INDEX = {
	MANA = Enum.PowerType.Mana,
	RAGE = Enum.PowerType.Rage,
	FOCUS = Enum.PowerType.Focus,
	ENERGY = Enum.PowerType.Energy,
}

function K.ApplyUnitColors()
	local db = C.Unitframe
	if not db then
		return
	end

	if db.PowerColors then
		for token, c in pairs(db.PowerColors) do
			local color = oUF:CreateColor(c[1], c[2], c[3])
			colors.power[token] = color
			local index = POWER_INDEX[token]
			if index then
				colors.power[index] = color
			end
		end
	end

	if db.ReactionColors then
		for i, c in pairs(db.ReactionColors) do
			colors.reaction[i] = oUF:CreateColor(c[1], c[2], c[3])
		end
	end

	-- Class colours for players on every frame and nameplate.
	for token, c in pairs(CLASS) do
		colors.class[token] = oUF:CreateColor(c[1], c[2], c[3])
	end

	-- Keep the player's own accent (used by chat, AFK screen, etc.) in sync.
	local mine = CLASS[K.Class]
	if mine then
		K.ClassColor = { r = mine[1], g = mine[2], b = mine[3] }
	end
end
