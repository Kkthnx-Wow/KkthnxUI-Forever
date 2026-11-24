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

local IsSecret = K.IsSecret
local UnitReaction = UnitReaction
local UnitSelectionType = UnitSelectionType

-- Selection types 0 to 3 (hostile, unfriendly, neutral, friendly) mapped onto
-- our reaction palette slots.
local SELECTION_REACTION = { [0] = 2, [1] = 3, [2] = 4, [3] = 5 }

-- Palette slot for an NPC's colour. The game's selection type wins over raw
-- reaction because it is what Blizzard colours by: a hated NPC that will not
-- attack you reads unfriendly orange, and turns red once it fights you.
function K.UnitReactionIndex(unit)
	local selection = UnitSelectionType and UnitSelectionType(unit, true)
	if selection and not IsSecret(selection) then
		local index = SELECTION_REACTION[selection]
		if index then
			return index
		end
	end
	local reaction = UnitReaction(unit, "player")
	if reaction and not IsSecret(reaction) then
		return reaction
	end
end

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
