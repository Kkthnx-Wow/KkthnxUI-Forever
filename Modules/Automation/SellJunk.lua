--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/SellJunk.lua
	Purpose:
		Sell junk at a merchant: grey (Poor) items, the items the player flagged
		as junk, and, when asked, soulbound gear the character has outgrown. This
		lives in Automation so it works even when the KkthnxUI bags are disabled
		and another bag addon is in use (GitHub #136). The toggles are re-checked
		on every merchant visit.

		Greys go through Blizzard's own bulk sell when nothing needs protecting.
		Everything else is sold one item at a time on a short timer. Safe selling
		stops at the size of the buyback list, so every sale can be bought back.
		One line in chat sums up each run.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Automation")

local _G = _G
local C_Container = C_Container
local C_Item = C_Item
local C_MerchantFrame = C_MerchantFrame
local C_Timer = C_Timer
local Enum = Enum
local ItemLocation = ItemLocation
local GetMoney = GetMoney
local InCombatLockdown = InCombatLockdown
local GetCoinTextureString = C_CurrencyInfo.GetCoinTextureString
local format = string.format
local CreateFrame = CreateFrame
local ipairs = ipairs
local tconcat = table.concat
local tremove = table.remove
local wipe = wipe

local POOR = Enum.ItemQuality and Enum.ItemQuality.Poor or 0
local COMMON = Enum.ItemQuality and Enum.ItemQuality.Common or 1
local RARE = Enum.ItemQuality and Enum.ItemQuality.Rare or 3
local WEAPON = Enum.ItemClass and Enum.ItemClass.Weapon
local ARMOR = Enum.ItemClass and Enum.ItemClass.Armor
local FISHING_POLE = Enum.ItemWeaponSubclass and Enum.ItemWeaponSubclass.Fishingpole
local IsSecret = K.IsSecret
-- Backpack, four bags and the reagent bag.
local LAST_BAG = 5
-- Seconds between individual sales. Each one is a packet to the server, so a full
-- set of bags is not sold in a single frame.
local SELL_GAP = 0.2
-- The merchant only keeps this many sales to buy back.
local BUYBACK_SIZE = _G.BUYBACK_ITEMS_PER_PAGE or 12

-- Equipment slots per equip location, shared with the quest reward picker.
local SLOTS_FOR = K.GearSlotsFor

local sellQueue, selling = {}, false
local soldThisVisit = 0
-- What the current run has sold, for the line in chat at the end.
local report = { items = 0, held = 0, money = 0, byQuality = {} }

local function ResetReport()
	report.items, report.held, report.money = 0, 0, GetMoney()
	wipe(report.byQuality)
end

local function Count(quality, stack)
	report.items = report.items + stack
	if quality then
		report.byQuality[quality] = (report.byQuality[quality] or 0) + stack
	end
end

local function PrintReport()
	local gained = GetMoney() - report.money
	if gained > 0 and report.items > 0 then
		local parts = {}
		for quality = POOR, RARE do
			local n = report.byQuality[quality]
			if n then
				local r, g, b = C_Item.GetItemQualityColor(quality)
				local name = _G["ITEM_QUALITY" .. quality .. "_DESC"] or ""
				parts[#parts + 1] = format("|cff%02x%02x%02x%d %s|r", (r or 1) * 255, (g or 1) * 255, (b or 1) * 255, n, name)
			end
		end
		K.Print(L["Sold %d items for %s (%s)."], report.items, GetCoinTextureString(gained), tconcat(parts, ", "))
	end
	if report.held > 0 then
		K.Print(L["Safe selling kept %d more junk items, open the merchant again to sell them."], report.held)
	end
end

local function Finish(done)
	selling = false
	C_Timer.After(0.5, function()
		PrintReport()
		if done then
			done()
		end
	end)
end

local function SellNext(done)
	local entry = tremove(sellQueue, 1)
	-- Stop if the merchant closes or combat starts, the rest stay in the bags.
	if not entry or not (_G.MerchantFrame and _G.MerchantFrame:IsShown()) or InCombatLockdown() then
		wipe(sellQueue)
		Finish(done)
		return
	end
	if C.Automation.SellSafe and soldThisVisit >= BUYBACK_SIZE then
		report.held = report.held + 1 + #sellQueue
		wipe(sellQueue)
		Finish(done)
		return
	end
	-- Re-read the slot, the bag may have changed since the queue was built.
	local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
	if info and info.itemID and not IsSecret(info.itemID) and info.itemID == entry.itemID and not info.hasNoValue and not info.isLocked then
		C_Container.UseContainerItem(entry.bag, entry.slot)
		soldThisVisit = soldThisVisit + 1
		Count(entry.quality, info.stackCount or 1)
	end
	if #sellQueue > 0 then
		C_Timer.After(SELL_GAP, function()
			SellNext(done)
		end)
	else
		Finish(done)
	end
end

-- Soulbound weapons and armor the character has outgrown. Only Common to Rare,
-- never anything in an equipment set or with a look not yet collected, and only
-- when every slot it would go in holds an item and each of those is well above
-- it. An empty slot means the piece may still be wanted, so it is kept.
local function IsOutgrownGear(bag, slot, info)
	if not C.Automation.SellOldGear or IsSecret(info.isBound) or not info.isBound then
		return false
	end
	local quality = info.quality
	if not quality or IsSecret(quality) or quality < COMMON or quality > RARE then
		return false
	end
	local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(info.itemID)
	if classID ~= WEAPON and classID ~= ARMOR then
		return false
	end
	if classID == WEAPON and subclassID == FISHING_POLE then
		return false
	end
	local slots = SLOTS_FOR[equipLoc]
	if not slots then
		return false
	end
	if C_Container.GetContainerItemEquipmentSetInfo and C_Container.GetContainerItemEquipmentSetInfo(bag, slot) then
		return false
	end
	if K.IsUncollectedAppearance(info.hyperlink) then
		return false
	end
	local level = C_Item.GetCurrentItemLevel(ItemLocation:CreateFromBagAndSlot(bag, slot))
	if not level or IsSecret(level) then
		return false
	end
	local ratio = (C.Automation.SellOldGearPercent or 50) / 100
	for _, invSlot in ipairs(slots) do
		local worn = ItemLocation:CreateFromEquipmentSlot(invSlot)
		if not C_Item.DoesItemExist(worn) then
			return false
		end
		local wornLevel = C_Item.GetCurrentItemLevel(worn)
		if not wornLevel or IsSecret(wornLevel) or level >= wornLevel * ratio then
			return false
		end
	end
	return true
end

-- The one junk seller, used by the auto sell, the bags' Sell button and the key
-- binding. Grey items go through Blizzard's bulk sell, which takes every one of
-- them, including a piece whose look the character has not collected, so it is
-- only used when there is no such piece and safe selling is off. Otherwise the
-- greys are sold one by one and those are skipped. A grey the player flagged as
-- junk is sold either way, that is their call. With includeFlagged, flagged
-- items of any quality are sold too. Everything sold one by one shares a single
-- queue and timer, so two callers can never double the sell rate. done runs
-- once the selling has settled.
function K.SellJunkItems(includeFlagged, done)
	local safe = C.Automation.SellSafe
	local greys, others, keptSome = {}, {}, false
	local greyCount = 0
	for bag = 0, LAST_BAG do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if info and info.hyperlink and not info.hasNoValue and itemID and not IsSecret(itemID) then
				local flagged = C.Bags and C.Bags.JunkList and C.Bags.JunkList[itemID]
				local quality = not IsSecret(info.quality) and info.quality or nil
				local entry = { bag = bag, slot = slot, itemID = itemID, quality = quality }
				if quality == POOR then
					if not flagged and K.IsUncollectedAppearance(info.hyperlink) then
						keptSome = true
					else
						greys[#greys + 1] = entry
						greyCount = greyCount + (info.stackCount or 1)
					end
				elseif (flagged and includeFlagged) or IsOutgrownGear(bag, slot, info) then
					others[#others + 1] = entry
				end
			end
		end
	end

	if not selling then
		ResetReport()
	end

	-- Greys first, they are the clearest junk when safe selling has to stop.
	local queue = {}
	if keptSome or safe then
		for _, entry in ipairs(greys) do
			queue[#queue + 1] = entry
		end
	-- While a run is going its own bulk sale already took the greys, so a second
	-- call would sell nothing and only count them twice.
	elseif #greys > 0 and not selling and C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
		C_MerchantFrame.SellAllJunkItems()
		report.items = report.items + greyCount
		report.byQuality[POOR] = (report.byQuality[POOR] or 0) + greyCount
	end
	for _, entry in ipairs(others) do
		queue[#queue + 1] = entry
	end

	-- Already selling, so join the running queue rather than drop these. A slot
	-- queued twice is harmless, SellNext re-reads it and finds it empty.
	if selling then
		for _, entry in ipairs(queue) do
			sellQueue[#sellQueue + 1] = entry
		end
		return
	end
	if #queue == 0 or not (_G.MerchantFrame and _G.MerchantFrame:IsShown()) or InCombatLockdown() then
		Finish(done)
		return
	end
	sellQueue = queue
	selling = true
	SellNext(done)
end

-- Greys only, plus flagged items and outgrown gear when those are switched on.
function K.SellGreyItems(done)
	K.SellJunkItems(C.Automation.SellFlagged, done)
end

-- The key binding. Sells everything the Sell button would, at an open merchant.
function K.SellJunkKey()
	if _G.MerchantFrame and _G.MerchantFrame:IsShown() then
		K.SellJunkItems(true)
	end
end

_G.BINDING_NAME_KKUI_SELLJUNK = L["Sell Junk"]

-- The safe selling count starts over at each merchant visit. Its own listener,
-- since the bags' Sell button uses the cap even with Automation switched off.
local visitWatcher = CreateFrame("Frame")
visitWatcher:RegisterEvent("MERCHANT_SHOW")
visitWatcher:SetScript("OnEvent", function()
	soldThisVisit = 0
end)

function Module:MERCHANT_SHOW_SELLJUNK()
	if not C.Automation.SellJunk or not (C_MerchantFrame and C_MerchantFrame.SellAllJunkItems) then
		return
	end
	-- Reset here too, since the order the two MERCHANT_SHOW listeners run in is
	-- not fixed and the first sale happens right away.
	soldThisVisit = 0
	K.SellGreyItems()
end

function Module:SetupSellJunk()
	self:RegisterEvent("MERCHANT_SHOW", "MERCHANT_SHOW_SELLJUNK")
end
