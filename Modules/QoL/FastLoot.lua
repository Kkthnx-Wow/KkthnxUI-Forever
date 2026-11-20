--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/FastLoot.lua
	Purpose:
		Take everything the moment a corpse or container is ready to loot, instead
		of waiting on the game's own auto loot to work down the list.

		Only runs when the game would auto loot anyway, so the Auto Loot setting
		and its modifier key keep working the way they always have. Slots that are
		locked (a group roll, or an item someone else is looting) are left alone,
		and a bind on pickup item still asks through the game's own dialog.

		Our loot window holds off for a moment while this runs and only opens if
		something is left, such as when the bags are full.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("QoL")

local GetLootSlotInfo = GetLootSlotInfo
local GetNumLootItems = GetNumLootItems
local GetTime = GetTime
local LootSlot = LootSlot

-- LOOT_READY can fire twice for one loot. The second pass would only ask for
-- slots that are already on their way.
local REPEAT_GAP = 0.3
local lastRun = 0

local function OnLootReady(_, _, autoLoot)
	if not autoLoot or not C.QoL.FastLoot then
		return
	end
	local now = GetTime()
	if now - lastRun < REPEAT_GAP then
		return
	end
	lastRun = now

	-- Last to first, so a slot that empties never shifts the ones still to come.
	for i = GetNumLootItems(), 1, -1 do
		local _, _, _, _, _, locked = GetLootSlotInfo(i)
		if not locked then
			LootSlot(i)
		end
	end
end

function Module:SetupFastLoot()
	self:RegisterEvent("LOOT_READY", OnLootReady)
end
