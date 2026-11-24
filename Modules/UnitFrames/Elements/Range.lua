--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Elements/Range.lua
	Purpose:
		Fade a unit frame while its unit is out of reach.

		oUF's Range element only ever looks at party members, so a target, focus,
		boss or raid member outside your own subgroup was always drawn at full
		alpha. This replaces its update with one that works for every unit:
			group members   the game's group range check (about 40 yards)
			enemies         your own attack spells: in range of any of them
			friends         your own healing or buff spells
			anything else   follow distance, outside combat only
		A check that cannot be answered counts as in range, so a frame never
		fades on a guess.

		Range has no event for most units, so the frames that use it are polled
		together on one short ticker that only runs while at least one of them is
		shown, and the alpha is only touched when the answer changes.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")
local Build = Module.Build

local ipairs = ipairs
local next = next

local CheckInteractDistance = CheckInteractDistance
local InCombatLockdown = InCombatLockdown
local IsSpellInRange = C_Spell.IsSpellInRange
local IsSpellKnown = C_SpellBook.IsSpellKnown
local UnitCanAssist = UnitCanAssist
local UnitCanAttack = UnitCanAttack
local UnitExists = UnitExists
local UnitInRange = UnitInRange
local UnitIsConnected = UnitIsConnected
local UnitIsUnit = UnitIsUnit
local UnitPlayerOrPetInParty = UnitPlayerOrPetInParty
local UnitPlayerOrPetInRaid = UnitPlayerOrPetInRaid
local C_Timer_NewTicker = C_Timer.NewTicker

local IsSecret = K.IsSecret

local POLL = 0.2
-- CheckInteractDistance index 4 is follow distance, about 28 yards.
local FOLLOW = 4

-- Spells used as range probes, lowest rank. A unit counts as in range when any
-- known probe reaches it, so a hunter in melee is caught by Wing Clip and a
-- warrior at range by Shoot. Unknown spells are dropped when the list is built.
local HARM = {
	DRUID = { 5176, 8921, 6807 }, -- Wrath, Moonfire, Maul
	-- Auto Shot has a minimum range, so melee needs its own probe. Raptor Strike
	-- cannot be it. It is an on-next-swing ability, and its range check answers
	-- true at any distance on Forever, which kept every enemy at full alpha.
	-- Wing Clip, from level 12, covers melee.
	HUNTER = { 75, 2974 }, -- Auto Shot, Wing Clip
	MAGE = { 133, 116, 5143 }, -- Fireball, Frostbolt, Arcane Missiles
	PALADIN = { 20271, 853 }, -- Judgement, Hammer of Justice
	PRIEST = { 585, 589 }, -- Smite, Shadow Word: Pain
	ROGUE = { 1752, 2764, 3018 }, -- Sinister Strike, Throw, Shoot
	SHAMAN = { 403, 8042 }, -- Lightning Bolt, Earth Shock
	WARLOCK = { 686, 172 }, -- Shadow Bolt, Corruption
	WARRIOR = { 78, 100, 2764, 3018 }, -- Heroic Strike, Charge, Throw, Shoot
}

local HELP = {
	DRUID = { 5185, 774 }, -- Healing Touch, Rejuvenation
	MAGE = { 1459 }, -- Arcane Intellect
	PALADIN = { 635 }, -- Holy Light
	PRIEST = { 2050, 1243 }, -- Lesser Heal, Power Word: Fortitude
	SHAMAN = { 331 }, -- Healing Wave
	WARLOCK = { 5697 }, -- Unending Breath
}

local harm, help = {}, {}

local function Known(list, into)
	for i = #into, 1, -1 do
		into[i] = nil
	end
	for _, id in ipairs(list or {}) do
		if IsSpellKnown(id) then
			into[#into + 1] = id
		end
	end
end

local function RefreshProbes()
	Known(HARM[K.Class], harm)
	Known(HELP[K.Class], help)
end

-- true in range, false out of range, nil when the probes cannot tell.
local function Probe(list, unit)
	local answered = false
	for _, id in ipairs(list) do
		local inRange = IsSpellInRange(id, unit)
		if inRange ~= nil and not IsSecret(inRange) then
			if inRange then
				return true
			end
			answered = true
		end
	end
	if answered then
		return false
	end
end

-- Returns inRange, and a secret flag when the game will only hand back a
-- secret answer, which is then passed straight to SetAlphaFromBoolean.
local function UnitRange(unit)
	-- UnitIsUnit can be secret for compound tokens like targettarget, which this
	-- poll covers, so its answer is only used when it can be read.
	local isPlayer = UnitIsUnit(unit, "player")
	if not UnitExists(unit) or (not IsSecret(isPlayer) and isPlayer) or not UnitIsConnected(unit) then
		return true
	end

	if UnitPlayerOrPetInParty(unit) or UnitPlayerOrPetInRaid(unit) then
		local inRange, checked = UnitInRange(unit)
		-- Both returns can be secret, so either one being secret hands the
		-- game's answer straight through instead of reading it here.
		if IsSecret(inRange) or IsSecret(checked) then
			return inRange, true
		end
		if checked then
			return inRange and true or false
		end
	end

	local result
	if UnitCanAttack("player", unit) then
		result = Probe(harm, unit)
	elseif UnitCanAssist("player", unit) then
		result = Probe(help, unit)
	end
	if result == nil and not InCombatLockdown() then
		local near = CheckInteractDistance(unit, FOLLOW)
		if near ~= nil and not IsSecret(near) then
			result = near and true or false
		end
	end
	if result == nil then
		return true
	end
	return result
end

local StartPolling

local function Override(self)
	local element = self.Range
	local unit = self.unit
	if not element or not unit then
		return
	end
	-- oUF replaces the frame's OnShow script after the style runs, so a hook there
	-- is lost. Its own show and unit updates come through here instead, which is
	-- where the poll is woken after it went to sleep with nothing on screen.
	StartPolling()
	local inRange, secret = UnitRange(unit)
	if secret then
		element.__state = nil
		self:SetAlphaFromBoolean(inRange, element.insideAlpha, element.outsideAlpha)
		return
	end
	-- Only on a change. Setting the alpha every poll made 3D portraits flicker.
	if element.__state ~= inRange then
		element.__state = inRange
		self:SetAlpha(inRange and element.insideAlpha or element.outsideAlpha)
	end
end

-- ---------------------------------------------------------------------------
-- Polling
-- ---------------------------------------------------------------------------

local frames = {}
local ticker

local function Poll()
	local any = false
	for frame in next, frames do
		if frame:IsShown() and frame.unit then
			any = true
			Override(frame)
		end
	end
	if not any and ticker then
		ticker:Cancel()
		ticker = nil
	end
end

function StartPolling()
	if not ticker then
		ticker = C_Timer_NewTicker(POLL, Poll)
	end
end

local probeWatcher

-- Fade a frame while its unit is out of range, so an unreachable target or group
-- member reads as dimmed. oUF still owns the element and its events, this only
-- changes how the answer is worked out.
function Build.Range(self)
	if not C.Unitframe.RangeFade then
		return
	end
	if not probeWatcher then
		probeWatcher = CreateFrame("Frame")
		probeWatcher:RegisterEvent("PLAYER_LOGIN")
		probeWatcher:RegisterEvent("SPELLS_CHANGED")
		probeWatcher:SetScript("OnEvent", RefreshProbes)
		RefreshProbes()
	end

	self.Range = {
		insideAlpha = 1,
		outsideAlpha = C.Unitframe.RangeAlpha or 0.4,
		Override = Override,
	}
	frames[self] = true
	StartPolling()
	return self.Range
end
