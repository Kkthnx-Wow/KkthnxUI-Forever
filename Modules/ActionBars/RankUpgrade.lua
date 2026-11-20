--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/RankUpgrade.lua
	Purpose:
		When a new rank of a spell is learned, swap it into every action slot that
		still holds a lower rank of the same spell. Slots are only touched out of
		combat, so a rank learned mid-fight waits until combat ends. Slots that
		already hold the new rank (or that the game upgraded itself) are left
		alone, so this is a no-op wherever the game does the job.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("ActionBars")

local C_Spell = C_Spell
local C_SpellBook = C_SpellBook
local C_Timer = C_Timer
local ClearCursor = ClearCursor
local GetActionInfo = GetActionInfo
local GetCursorInfo = GetCursorInfo
local InCombatLockdown = InCombatLockdown
local IsSpellKnown = C_SpellBook.IsSpellKnown
local PickupSpell = C_Spell.PickupSpell
local PlaceAction = PlaceAction
local issecretvalue = issecretvalue
local next = next
local tonumber = tonumber

-- Main bar pages, the multibars and the form bonus bars all live below this.
-- Slots past what the client has simply report no action.
local LAST_SLOT = 252
local MAX_RETRIES = 3

-- New spell IDs waiting for a safe moment, mapped to how often we retried.
local pending = {}
local retryQueued = false

local function RankOf(spellID)
	local subtext = C_Spell.GetSpellSubtext(spellID)
	-- Empty until the spell data has loaded. The rank is the number in "Rank 3",
	-- which keeps it independent of the client language.
	return subtext and tonumber(subtext:match("%d+")) or nil
end

-- The rank of another rank of this spell sitting in the slot, if there is one.
local function SlotRank(slot, newID, name)
	local actionType, id = GetActionInfo(slot)
	if actionType ~= "spell" or not id or id == newID or (issecretvalue and issecretvalue(id)) then
		return nil
	end
	if C_Spell.GetSpellName(id) ~= name then
		return nil
	end
	return RankOf(id)
end

-- Returns true when the spell was fully handled and can leave the queue.
local function UpgradeSlots(newID)
	if not IsSpellKnown(newID) then
		return true
	end

	local name = C_Spell.GetSpellName(newID)
	local newRank = RankOf(newID)
	if not name or not newRank then
		return false
	end

	-- Only the highest lower rank on the bars is replaced. Anything below it was
	-- kept there on purpose, a downrank heal for one.
	local best = 0
	for slot = 1, LAST_SLOT do
		local rank = SlotRank(slot, newID, name)
		if rank and rank < newRank and rank > best then
			best = rank
		end
	end
	if best == 0 then
		return true
	end

	for slot = 1, LAST_SLOT do
		if SlotRank(slot, newID, name) == best then
			PickupSpell(newID)
			if GetCursorInfo() == "spell" then
				-- Placing swaps the old rank onto the cursor, which we drop.
				PlaceAction(slot)
			end
			ClearCursor()
		end
	end
	return true
end

local function QueueRetry()
	if retryQueued then
		return
	end
	retryQueued = true
	C_Timer.After(1, function()
		retryQueued = false
		Module:ProcessRankUpgrades()
	end)
end

function Module:ProcessRankUpgrades()
	if not next(pending) or InCombatLockdown() then
		return
	end
	-- Never clobber something the player is holding.
	if GetCursorInfo() then
		QueueRetry()
		return
	end

	local retry = false
	for spellID, tries in next, pending do
		if UpgradeSlots(spellID) then
			pending[spellID] = nil
		elseif tries >= MAX_RETRIES then
			pending[spellID] = nil
		else
			pending[spellID] = tries + 1
			retry = true
		end
	end
	if retry then
		QueueRetry()
	end
end

function Module:SetupRankUpgrade()
	if C.ActionBar.AutoUpgradeRanks == false then
		return
	end

	self:RegisterEvent("LEARNED_SPELL_IN_SKILL_LINE", function(_, _, spellID)
		if spellID then
			pending[spellID] = 0
		end
	end)
	-- Fires at the end of the frame the spell was learned in, once the spell
	-- data and spellbook are settled.
	self:RegisterEvent("SPELLS_CHANGED", "ProcessRankUpgrades")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "ProcessRankUpgrades")
end
