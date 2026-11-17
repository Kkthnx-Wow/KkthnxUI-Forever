--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/AuraWatchList.lua
	Purpose:
		The default tracked auras for the corner Aura Watch on party and raid
		frames. Keyed by class, then by spell id. Each entry places a small dot
		or icon in one corner of the frame, so a healer can read heals over time,
		shields and other key buffs at a glance.

		Entry fields:
			corner - "TOPLEFT" | "TOPRIGHT" | "BOTTOMLEFT" | "BOTTOMRIGHT" | "CENTER"
			color  - dot colour {r, g, b} (dot style only)
			style  - "dot" (default) or "icon" (shows the spell icon and its swipe)
			mine   - true to only light up when the aura is ours
			debuff - true for a harmful aura, which is looked up under HARMFUL

		Forever runs classic era spells, each rank with its own ID. An entry
		names any one rank and the element matches every rank by the spell's
		name, so a higher rank lights the same corner. Every ID here was checked
		to exist on the Forever client on 2026-11-16. That dropped the later
		expansion heals (Lifebloom, Wild Growth, Prayer of Mending, Atonement,
		Riptide, the Beacons) the client does not have.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

-- Shorthand dot colours so the table below reads cleanly.
local GREEN = { 0.4, 0.85, 0.4 }
local BLUE = { 0.4, 0.7, 1 }
local GOLD = { 0.95, 0.75, 0.35 }
local PINK = { 0.95, 0.5, 0.75 }
local TEAL = { 0.35, 0.85, 0.8 }

K.AuraWatchList = {
	DRUID = {
		[774] = { corner = "TOPLEFT", color = GREEN, mine = true }, -- Rejuvenation
		[8936] = { corner = "TOPRIGHT", color = GOLD, mine = true }, -- Regrowth
		[2893] = { corner = "BOTTOMLEFT", color = TEAL, mine = true }, -- Abolish Poison
		[29166] = { corner = "BOTTOMRIGHT", color = BLUE }, -- Innervate
	},
	PRIEST = {
		[139] = { corner = "TOPLEFT", color = GREEN, mine = true }, -- Renew
		[17] = { corner = "TOPRIGHT", color = GOLD }, -- Power Word: Shield, any priest's
		[6346] = { corner = "BOTTOMLEFT", color = BLUE }, -- Fear Ward
		[6788] = { corner = "BOTTOMRIGHT", color = PINK, debuff = true }, -- Weakened Soul, no shield yet
	},
	SHAMAN = {
		[974] = { corner = "TOPLEFT", color = GOLD, mine = true }, -- Earth Shield
		[16177] = { corner = "TOPRIGHT", color = TEAL, mine = true }, -- Ancestral Fortitude
	},
	PALADIN = {
		[1022] = { corner = "TOPLEFT", color = GOLD }, -- Blessing of Protection
		[1044] = { corner = "TOPRIGHT", color = TEAL }, -- Blessing of Freedom
		[6940] = { corner = "BOTTOMLEFT", color = PINK, mine = true }, -- Blessing of Sacrifice
	},
	MAGE = {
		[1008] = { corner = "TOPLEFT", color = BLUE, mine = true }, -- Amplify Magic
		[604] = { corner = "TOPRIGHT", color = TEAL, mine = true }, -- Dampen Magic
	},
	WARLOCK = {
		[20707] = { corner = "TOPLEFT", color = PINK }, -- Soulstone Resurrection
	},
}

-- The active list for the player's class, or an empty table for classes with no
-- defaults, so the element can index it without a nil check.
K.AuraWatch = K.AuraWatchList[K.Class] or {}
