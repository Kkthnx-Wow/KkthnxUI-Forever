--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/SellJunk.lua
	Purpose:
		Sell grey (Poor) items the moment a merchant opens, through Blizzard's own
		bulk sell so it needs no bag frame of its own. This lives in Automation so it
		works even when the KkthnxUI bags are disabled and another bag addon is in use
		(GitHub #136). The toggle is re-checked on every merchant visit.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Automation")

local C_MerchantFrame = C_MerchantFrame
local ipairs = ipairs
local GetMoney = GetMoney
local GetCoinTextureString = C_CurrencyInfo.GetCoinTextureString

local POOR = Enum.ItemQuality and Enum.ItemQuality.Poor or 0
local IsSecret = K.IsSecret
-- Backpack, four bags and the reagent bag.
local LAST_BAG = 5
-- Seconds between individual sales. Each one is a packet to the server, so a full
-- set of bags is not sold in a single frame.
local SELL_GAP = 0.2

local sellQueue, selling = {}, false

local function SellNext(done)
	local entry = table.remove(sellQueue, 1)
	-- Stop if the merchant closes or combat starts, the rest stay in the bags.
	if not entry or not (_G.MerchantFrame and _G.MerchantFrame:IsShown()) or InCombatLockdown() then
		wipe(sellQueue)
		selling = false
		if done then
			done()
		end
		return
	end
	-- Re-read the slot, the bag may have changed since the queue was built.
	local info = C_Container.GetContainerItemInfo(entry.bag, entry.slot)
	if info and info.itemID and not IsSecret(info.itemID) and info.itemID == entry.itemID and not info.hasNoValue then
		C_Container.UseContainerItem(entry.bag, entry.slot)
	end
	if #sellQueue > 0 then
		C_Timer.After(SELL_GAP, function()
			SellNext(done)
		end)
	else
		selling = false
		if done then
			C_Timer.After(0.3, done)
		end
	end
end

-- The one junk seller, used by the auto sell here and by the bags' Sell button.
-- Grey items go through Blizzard's bulk sell, which takes every one of them,
-- including a piece whose look the character has not collected, so it is only
-- used when there is no such piece. Otherwise the greys are sold one by one and
-- those are skipped. A grey the player flagged as junk is sold either way, that
-- is their call. With includeFlagged, flagged items of any quality are sold too.
-- Everything sold one by one shares a single queue and timer, so two callers can
-- never double the sell rate. done runs once the selling has settled.
function K.SellJunkItems(includeFlagged, done)
	local greys, others, keptSome = {}, {}, false
	for bag = 0, LAST_BAG do
		for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			local itemID = info and info.itemID
			if info and info.hyperlink and not info.hasNoValue and itemID and not IsSecret(itemID) then
				local flagged = C.Bags and C.Bags.JunkList and C.Bags.JunkList[itemID]
				local entry = { bag = bag, slot = slot, itemID = itemID }
				if not IsSecret(info.quality) and info.quality == POOR then
					if not flagged and K.IsUncollectedAppearance(info.hyperlink) then
						keptSome = true
					else
						greys[#greys + 1] = entry
					end
				elseif flagged and includeFlagged then
					others[#others + 1] = entry
				end
			end
		end
	end

	local queue = others
	if keptSome then
		for _, entry in ipairs(greys) do
			queue[#queue + 1] = entry
		end
	elseif #greys > 0 and C_MerchantFrame and C_MerchantFrame.SellAllJunkItems then
		C_MerchantFrame.SellAllJunkItems()
	end

	if selling or #queue == 0 or not (_G.MerchantFrame and _G.MerchantFrame:IsShown()) or InCombatLockdown() then
		if done then
			C_Timer.After(0.3, done)
		end
		return
	end
	sellQueue = queue
	selling = true
	SellNext(done)
end

-- Greys only, the auto sell's rule.
function K.SellGreyItems(done)
	K.SellJunkItems(false, done)
end

function Module:MERCHANT_SHOW_SELLJUNK()
	if not C.Automation.SellJunk or not (C_MerchantFrame and C_MerchantFrame.SellAllJunkItems) then
		return
	end

	local before = GetMoney()
	K.SellGreyItems(function()
		local gained = GetMoney() - before
		if gained > 0 then
			K.Print("Sold junk for %s", GetCoinTextureString(gained))
		end
	end)
end

function Module:SetupSellJunk()
	self:RegisterEvent("MERCHANT_SHOW", "MERCHANT_SHOW_SELLJUNK")
end
