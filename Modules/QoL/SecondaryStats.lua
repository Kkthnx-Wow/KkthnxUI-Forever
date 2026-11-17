--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/SecondaryStats.lua
	Purpose:
		A small movable readout of the combat stats that matter for your class,
		so they can be watched without opening the character sheet.

		Forever runs Classic Era content, where mastery and versatility do not
		exist and haste barely appears on gear. The readout shows attack power,
		spell power, healing, crit, hit and dodge instead, picked by class: a
		warrior sees no spell power and a mage sees no attack power.

		The game can hide stats from addons while unit stats are restricted. A
		hidden value keeps its last reading and catches up once readable again.
		Updates are driven by the stat events and by changes to your own buffs,
		gathered into one refresh a fraction of a second later.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local IsSecret = K.IsSecret
local format = string.format
local max = math.max
local concat = table.concat
local ipairs = ipairs
local UnitClass = UnitClass
local UnitAttackPower = UnitAttackPower
local UnitRangedAttackPower = UnitRangedAttackPower
local GetCritChance, GetSpellCritChance, GetRangedCritChance = GetCritChance, GetSpellCritChance, GetRangedCritChance
local GetSpellBonusDamage, GetSpellBonusHealing = GetSpellBonusDamage, GetSpellBonusHealing
local GetHitModifier, GetSpellHitModifier = GetHitModifier, GetSpellHitModifier
local GetDodgeChance = GetDodgeChance

-- Spell schools from holy (2) to arcane (7). Physical (1) has no spell bonus.
local FIRST_SCHOOL, LAST_SCHOOL = 2, 7
local DELAY = 0.2

local frame
local queued
local shown
local values = {}

-- Read one stat. Returns nil while it is hidden or the call is missing, so the
-- old value stays on screen.
local function Read(fn, ...)
	if not fn then
		return nil
	end
	local value = fn(...)
	if value == nil or IsSecret(value) then
		return nil
	end
	return value
end

-- Attack power as the sheet shows it, base plus buffs minus debuffs.
local function TotalPower(fn)
	if not fn then
		return nil
	end
	local base, pos, neg = fn("player")
	if base == nil or IsSecret(base) or IsSecret(pos) or IsSecret(neg) then
		return nil
	end
	return base + (pos or 0) + (neg or 0)
end

-- The best value across the spell schools, which is what a caster cares about.
local function BestSchool(fn)
	if not fn then
		return nil
	end
	local best
	for school = FIRST_SCHOOL, LAST_SCHOOL do
		local value = fn(school)
		if value ~= nil and not IsSecret(value) then
			best = best and max(best, value) or value
		end
	end
	return best
end

-- Each stat: how to read it, its label, its colour and how to print it.
local STATS = {
	ap = { read = function() return TotalPower(UnitAttackPower) end, label = L["Attack Power"], color = K.Colors.warning, fmt = "%d" },
	rap = { read = function() return TotalPower(UnitRangedAttackPower) end, label = L["Ranged Power"], color = K.Colors.warning, fmt = "%d" },
	sp = { read = function() return BestSchool(GetSpellBonusDamage) end, label = L["Spell Power"], color = K.Colors.accent, fmt = "%d" },
	heal = { read = function() return Read(GetSpellBonusHealing) end, label = L["Healing"], color = K.Colors.positive, fmt = "%d" },
	crit = { read = function() return Read(GetCritChance) end, label = L["Crit"], color = K.Colors.highlight, fmt = "%.2f%%" },
	rcrit = { read = function() return Read(GetRangedCritChance) end, label = L["Crit"], color = K.Colors.highlight, fmt = "%.2f%%" },
	spellcrit = { read = function() return BestSchool(GetSpellCritChance) end, label = L["Spell Crit"], color = K.Colors.highlight, fmt = "%.2f%%" },
	hit = { read = function() return Read(GetHitModifier) end, label = L["Hit"], color = K.Colors.info, fmt = "%.2f%%" },
	spellhit = { read = function() return Read(GetSpellHitModifier) end, label = L["Spell Hit"], color = K.Colors.info, fmt = "%.2f%%" },
	dodge = { read = function() return Read(GetDodgeChance) end, label = L["Dodge"], color = K.Colors.secondary, fmt = "%.2f%%" },
}

-- Which stats each class sees, in display order. Hybrids get both sides, since a
-- druid or paladin may be either depending on gear and talents.
local PHYSICAL = { "ap", "crit", "hit", "dodge" }
local CASTER = { "sp", "spellcrit", "spellhit" }
local HEALER_CASTER = { "sp", "heal", "spellcrit", "spellhit" }
local HYBRID = { "ap", "crit", "hit", "sp", "heal", "spellcrit" }
local BY_CLASS = {
	WARRIOR = PHYSICAL,
	ROGUE = PHYSICAL,
	HUNTER = { "rap", "rcrit", "hit", "dodge" },
	MAGE = CASTER,
	WARLOCK = CASTER,
	PRIEST = HEALER_CASTER,
	PALADIN = HYBRID,
	SHAMAN = HYBRID,
	DRUID = HYBRID,
}

local function Collect()
	for _, key in ipairs(shown) do
		local value = STATS[key].read()
		if value ~= nil then
			values[key] = value
		end
	end
end

local function Render()
	local lines = {}
	for index, key in ipairs(shown) do
		local stat = STATS[key]
		local c = stat.color
		lines[index] = format("|cff%02x%02x%02x%s|r  " .. stat.fmt, c[1] * 255, c[2] * 255, c[3] * 255, stat.label, values[key] or 0)
	end
	frame.Text:SetText(concat(lines, "\n"))
	frame:SetSize(frame.Text:GetStringWidth() + 4, frame.Text:GetStringHeight() + 4)
end

local function Refresh()
	queued = nil
	Collect()
	Render()
end

local function Queue()
	if not queued then
		queued = true
		C_Timer.After(DELAY, Refresh)
	end
end

function Module:RestyleStats()
	if frame then
		K.SetFont(frame.Text, C.QoL.StatsSize or 13, "OUTLINE")
		Render()
	end
end

-- Some of these events only exist on certain clients. Registering an unknown one
-- is an error, so each is checked first where the client can say.
local function SafeRegister(watcher, event, unit)
	local util = C_EventUtils
	if util and util.IsEventValid and not util.IsEventValid(event) then
		return
	end
	if unit then
		watcher:RegisterUnitEvent(event, unit)
	else
		watcher:RegisterEvent(event)
	end
end

function Module:SetupSecondaryStats()
	local _, class = UnitClass("player")
	shown = BY_CLASS[class] or HYBRID

	frame = CreateFrame("Frame", nil, UIParent)
	frame:SetSize(120, 60)
	frame:EnableMouse(false)
	frame.Text = frame:CreateFontString(nil, "OVERLAY")
	frame.Text:SetPoint("TOPLEFT", 2, -2)
	frame.Text:SetJustifyH("LEFT")
	frame.Text:SetSpacing(2)
	K.CreateMover(frame, "SecondaryStats", L["Character Stats"], { "TOPLEFT", UIParent, "TOPLEFT", 12, -240 })
	self:RestyleStats()

	local watcher = CreateFrame("Frame")
	for _, event in ipairs({ "COMBAT_RATING_UPDATE", "PLAYER_DAMAGE_DONE_MODS", "SPELL_POWER_CHANGED", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_ENTERING_WORLD", "PLAYER_LEVEL_UP", "CHARACTER_POINTS_CHANGED" }) do
		SafeRegister(watcher, event)
	end
	-- Only your own stats are of interest, so the unit events listen to the
	-- player alone rather than to every unit in the game.
	for _, event in ipairs({ "UNIT_AURA", "UNIT_STATS", "UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER" }) do
		SafeRegister(watcher, event, "player")
	end
	watcher:SetScript("OnEvent", Queue)

	Refresh()
end
