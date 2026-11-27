--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/FastLoot.lua
	Purpose:
		Take everything the moment a corpse or container is ready to loot, instead
		of waiting on the game's own auto loot to work down the list.

		Only runs when the game would auto loot anyway, so the Auto Loot setting
		and its modifier key keep working the way they always have. Left alone:
		slots that are locked (a roll, or an item someone else is looting), items
		at or above the group's loot threshold under group, need before greed or
		master loot, which belong to the roll or the loot master, and items that
		will not fit in the bags. Asking for an item with no room only gets an
		"Inventory is full" back from the server for every slot.

		Our loot window holds off for a moment while this runs and only opens if
		something is left, so whatever was skipped is there to take by hand.

		A bind on pickup item asks through the game's own dialog, unless the
		option to confirm it while solo is on. In a group it always asks, so an
		item never binds to you without a word while others might want it.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local band = bit.band
local select = select
local C_Container = C_Container
local C_Item = C_Item
local C_PartyInfo = C_PartyInfo
local C_Timer = C_Timer
local Enum = Enum
local ConfirmLootSlot = ConfirmLootSlot
local GetLootSlotInfo = GetLootSlotInfo
local GetLootSlotLink = GetLootSlotLink
local GetLootSlotType = GetLootSlotType
local GetLootThreshold = GetLootThreshold
local GetNumLootItems = GetNumLootItems
local GetTime = GetTime
local IsInGroup = IsInGroup
local LootSlot = LootSlot
local IsSecret = K.IsSecret

-- LOOT_READY can fire twice for one loot. The second pass would only ask for
-- slots that are already on their way.
local REPEAT_GAP = 0.3
local lastRun = 0

local SLOT_ITEM = Enum.LootSlotType and Enum.LootSlotType.Item or 1
-- Backpack and the four bags. The reagent bag only takes reagents and the
-- keyring only keys, so neither is counted as room for any item.
local LAST_BAG = 4

-- Loot methods where items at or above the threshold go to a roll or to the
-- loot master, not to whoever opens the corpse.
local THRESHOLD_METHODS = {}
if Enum.LootMethod then
	THRESHOLD_METHODS[Enum.LootMethod.Group] = true
	THRESHOLD_METHODS[Enum.LootMethod.Needbeforegreed] = true
	THRESHOLD_METHODS[Enum.LootMethod.Masterlooter] = true
end

local function GroupThreshold()
	if not IsInGroup() or not (C_PartyInfo and C_PartyInfo.GetLootMethod) then
		return nil
	end
	local method = C_PartyInfo.GetLootMethod()
	if method and THRESHOLD_METHODS[method] then
		return GetLootThreshold()
	end
	return nil
end

-- Whether the bags have room. A partly filled stack of the same item counts,
-- and a special bag counts only for items of its kind. An item the client has
-- not loaded yet is let through, the server has the final word anyway.
local function HasRoom(link, quantity)
	if not link or IsSecret(link) then
		return true
	end
	local stackSize = select(8, C_Item.GetItemInfo(link))
	if not stackSize then
		return true
	end
	if stackSize > 1 then
		local held = C_Item.GetItemCount(link)
		local partial = held % stackSize
		if partial > 0 and stackSize - partial >= (quantity or 1) then
			return true
		end
	end
	local itemFamily = C_Item.GetItemFamily(link) or 0
	for bag = 0, LAST_BAG do
		local free, bagFamily = C_Container.GetContainerNumFreeSlots(bag)
		if free and free > 0 and (not bagFamily or bagFamily == 0 or band(itemFamily, bagFamily) > 0) then
			return true
		end
	end
	return false
end

local function OnLootReady(_, _, autoLoot)
	if not autoLoot or not C.QoL.FastLoot then
		return
	end
	local now = GetTime()
	if now - lastRun < REPEAT_GAP then
		return
	end
	lastRun = now

	local threshold = GroupThreshold()
	local leftForSpace = false
	-- Last to first, so a slot that empties never shifts the ones still to come.
	for i = GetNumLootItems(), 1, -1 do
		local _, _, quantity, _, quality, locked = GetLootSlotInfo(i)
		local isItem = GetLootSlotType(i) == SLOT_ITEM
		-- At or above the threshold the roll or the loot master decides.
		local forRoll = isItem and threshold and quality and not IsSecret(quality) and quality >= threshold
		if not locked and not forRoll then
			if isItem and not HasRoom(GetLootSlotLink(i), quantity) then
				leftForSpace = true
			else
				LootSlot(i)
			end
		end
	end
	if leftForSpace then
		K.Print(L["Your bags are full. The rest is left in the loot window."])
	end
end

-- Bind on pickup, confirmed for you while solo. The game's own popup may still
-- open from the same event, so it is put away a moment later.
local function OnBindConfirm(_, _, slot)
	if not C.QoL.ConfirmBoPSolo or IsInGroup() or not slot then
		return
	end
	ConfirmLootSlot(slot)
	C_Timer.After(0, function()
		_G.StaticPopup_Hide("LOOT_BIND")
	end)
end

function Module:SetupFastLoot()
	self:RegisterEvent("LOOT_READY", OnLootReady)
end

-- Its own switch, so it also works with the normal loot speed.
function Module:SetupBoPConfirm()
	self:RegisterEvent("LOOT_BIND_CONFIRM", OnBindConfirm)
end
