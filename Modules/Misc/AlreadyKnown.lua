--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/AlreadyKnown.lua
	Purpose:
		Tint items you already know a soft green so you can skip re-buying them.
		Covers recipes, pets, toys, mounts, and cosmetic appearances across:
		  * the Merchant frame (and its Buyback tab)
		  * the Auction House browse results
		  * the Guild Bank

		"Known" is resolved from the collection APIs where they exist (pets,
		transmog appearances) and falls back to a structured
		tooltip scan for the COLLECTED / already-known lines. Uncached items are
		re-checked once their data loads.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("AlreadyKnown")

local _G = _G
local select = select
local tonumber = tonumber
local strmatch = string.match
local strfind = string.find
local format = string.format
local ceil = math.ceil

local C_AddOns = C_AddOns
local Item = Item
local SetItemButtonTextureVertexColor = SetItemButtonTextureVertexColor
local GetMerchantNumItems, GetMerchantItemLink = GetMerchantNumItems, GetMerchantItemLink
local GetNumBuybackItems, GetBuybackItemInfo, GetBuybackItemLink = GetNumBuybackItems, GetBuybackItemInfo, GetBuybackItemLink
local GetCurrentGuildBankTab, GetGuildBankItemInfo, GetGuildBankItemLink = GetCurrentGuildBankTab, GetGuildBankItemInfo, GetGuildBankItemLink
local C_MerchantFrame_GetItemInfo = C_MerchantFrame.GetItemInfo
local C_Item_GetItemInfo = C_Item.GetItemInfo
local C_Item_IsCosmeticItem = C_Item.IsCosmeticItem
local C_TooltipInfo_GetHyperlink = C_TooltipInfo.GetHyperlink
local C_TooltipInfo_GetGuildBankItem = C_TooltipInfo.GetGuildBankItem
-- Not in the Forever API docs, so it is nil there and pets fall back to the tooltip scan.
local C_PetJournal_GetNumCollectedInfo = C_PetJournal and C_PetJournal.GetNumCollectedInfo
local C_TransmogCollection_GetItemInfo = C_TransmogCollection and C_TransmogCollection.GetItemInfo
local C_TransmogCollection_PlayerHasTransmogItemModifiedAppearance = C_TransmogCollection and C_TransmogCollection.PlayerHasTransmogItemModifiedAppearance

local MERCHANT_ITEMS_PER_PAGE = _G.MERCHANT_ITEMS_PER_PAGE or 10
local BUYBACK_ITEMS_PER_PAGE = _G.BUYBACK_ITEMS_PER_PAGE or 12
local MAX_GUILDBANK_SLOTS_PER_TAB = _G.MAX_GUILDBANK_SLOTS_PER_TAB or 98
local NUM_SLOTS_PER_GUILDBANK_GROUP = _G.NUM_SLOTS_PER_GUILDBANK_GROUP or 14
local COLLECTED = _G.COLLECTED
local ITEM_SPELL_KNOWN = _G.ITEM_SPELL_KNOWN

-- Known items take the UI's success green so the vendor tint flows with the
-- rest of the addon rather than a flat lime.
local TINT = { r = K.Colors.jade[1], g = K.Colors.jade[2], b = K.Colors.jade[3] }
-- Item classes whose "known" state is worth a tooltip scan.
local knowables = {
	[Enum.ItemClass.Consumable] = true,
	[Enum.ItemClass.Recipe] = true,
	[Enum.ItemClass.Miscellaneous] = true,
	[Enum.ItemClass.ItemEnhancement] = true,
}

-- Memoise links already proven known (cheap to keep for the session).
local knowns = {}

local function IsActive()
	return C.AlreadyKnown and C.AlreadyKnown.Enable
end

-- Repaint whatever collection surface is currently open. Forward-declared so the
-- item-data recache below can call it.
local RefreshVisibleItems

-- Ask the client to load an item's data, then repaint once it arrives, so an
-- uncached vendor/AH item still tints on the same viewing.
local pendingItems = {}
local function RequestItemData(itemID)
	if not itemID or pendingItems[itemID] or not Item then
		return
	end
	pendingItems[itemID] = true
	local item = Item:CreateFromItemID(itemID)
	item:ContinueOnItemLoad(function()
		pendingItems[itemID] = nil
		if IsActive() then
			RefreshVisibleItems()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Detection
-- ---------------------------------------------------------------------------
local function IsPetCollected(speciesID)
	if not speciesID or speciesID == 0 then
		return
	end
	if not C_PetJournal_GetNumCollectedInfo then
		return
	end
	local numOwned = C_PetJournal_GetNumCollectedInfo(speciesID)
	return numOwned and numOwned > 0
end

-- Cosmetic / transmog appearances do not report known through the tooltip lines,
-- so resolve the transmog source and ask the collection. Source-based, since the
-- by-item lookup over-claims for items with link variants. Returns true/false
-- when resolved, or nil to fall back to the tooltip scan.
local function IsCosmeticCollected(link)
	if not (C_TransmogCollection_GetItemInfo and C_TransmogCollection_PlayerHasTransmogItemModifiedAppearance) then
		return
	end
	local _, sourceID = C_TransmogCollection_GetItemInfo(link)
	if sourceID and sourceID ~= 0 then
		return C_TransmogCollection_PlayerHasTransmogItemModifiedAppearance(sourceID) and true or false
	end
end

local function IsAlreadyKnown(link, index)
	if not link then
		return
	end

	local linkType, linkID = strmatch(link, "|H(%a+):(%d+)")
	linkID = tonumber(linkID)

	if linkType == "battlepet" then
		return IsPetCollected(linkID)
	elseif linkType == "item" then
		local name, _, _, _, _, _, _, _, _, _, _, itemClassID = C_Item_GetItemInfo(link)
		if not name then
			RequestItemData(linkID)
			return
		end

		if knowns[link] then
			return true
		end

		-- Caged battle pets in the guild bank carry their species in tooltip data.
		if itemClassID == Enum.ItemClass.Battlepet and index then
			local data = C_TooltipInfo_GetGuildBankItem(GetCurrentGuildBankTab(), index)
			if data then
				return data.battlePetSpeciesID and IsPetCollected(data.battlePetSpeciesID)
			end
			return
		end

		if C_Item_IsCosmeticItem(link) then
			local collected = IsCosmeticCollected(link)
			if collected ~= nil then
				if collected then
					knowns[link] = true
				end
				return collected
			end
		end

		if not knowables[itemClassID] and not C_Item_IsCosmeticItem(link) then
			return
		end

		local data = C_TooltipInfo_GetHyperlink(link, nil, nil, true)
		if data then
			for i = 1, #data.lines do
				local text = data.lines[i] and data.lines[i].leftText
				if text and ((COLLECTED and strfind(text, COLLECTED)) or text == ITEM_SPELL_KNOWN) then
					knowns[link] = true
					return true
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Merchant frame
-- ---------------------------------------------------------------------------
local function UpdateMerchantInfo()
	if not IsActive() then
		return
	end
	local numItems = GetMerchantNumItems()
	for i = 1, MERCHANT_ITEMS_PER_PAGE do
		local index = (_G.MerchantFrame.page - 1) * MERCHANT_ITEMS_PER_PAGE + i
		if index > numItems then
			return
		end
		local button = _G["MerchantItem" .. i .. "ItemButton"]
		if button and button:IsShown() then
			local info = C_MerchantFrame_GetItemInfo(index)
			if info and info.isUsable and IsAlreadyKnown(GetMerchantItemLink(index)) then
				local r, g, b = TINT.r, TINT.g, TINT.b
				if info.numAvailable == 0 then
					r, g, b = r * 0.5, g * 0.5, b * 0.5
				end
				SetItemButtonTextureVertexColor(button, r, g, b)
			end
		end
	end
end

local function UpdateBuybackInfo()
	if not IsActive() then
		return
	end
	local numItems = GetNumBuybackItems()
	for index = 1, BUYBACK_ITEMS_PER_PAGE do
		if index > numItems then
			return
		end
		local button = _G["MerchantItem" .. index .. "ItemButton"]
		if button and button:IsShown() then
			local isUsable = select(6, GetBuybackItemInfo(index))
			if isUsable and IsAlreadyKnown(GetBuybackItemLink(index)) then
				SetItemButtonTextureVertexColor(button, TINT.r, TINT.g, TINT.b)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Auction House (load-on-demand)
-- ---------------------------------------------------------------------------
local function UpdateAuctionItems(self)
	if not IsActive() then
		return
	end
	for i = 1, self.ScrollTarget:GetNumChildren() do
		local child = select(i, self.ScrollTarget:GetChildren())
		if child.cells then
			local button = child.cells[2]
			local itemKey = button and button.rowData and button.rowData.itemKey
			if itemKey and itemKey.itemID then
				local itemLink
				if itemKey.itemID == 82800 then -- Pet Cage
					itemLink = format("|Hbattlepet:%d::::::|h[Dummy]|h", itemKey.battlePetSpeciesID)
				else
					itemLink = format("|Hitem:%d", itemKey.itemID)
				end

				if itemLink and IsAlreadyKnown(itemLink) then
					child.SelectedHighlight:Show()
					child.SelectedHighlight:SetVertexColor(TINT.r, TINT.g, TINT.b)
					child.SelectedHighlight:SetAlpha(0.25)
					button.Icon:SetVertexColor(TINT.r, TINT.g, TINT.b)
					button.IconBorder:SetVertexColor(TINT.r, TINT.g, TINT.b)
				else
					child.SelectedHighlight:SetVertexColor(1, 1, 1)
					button.Icon:SetVertexColor(1, 1, 1)
					button.IconBorder:SetVertexColor(1, 1, 1)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Guild Bank (load-on-demand)
-- ---------------------------------------------------------------------------
local function UpdateGuildBank(self)
	if not IsActive() or self.mode ~= "bank" then
		return
	end
	local tab = GetCurrentGuildBankTab()
	for i = 1, MAX_GUILDBANK_SLOTS_PER_TAB do
		local index = i % NUM_SLOTS_PER_GUILDBANK_GROUP
		if index == 0 then
			index = NUM_SLOTS_PER_GUILDBANK_GROUP
		end
		local column = ceil((i - 0.5) / NUM_SLOTS_PER_GUILDBANK_GROUP)
		local button = self.Columns[column].Buttons[index]
		if button and button:IsShown() then
			local texture, _, locked = GetGuildBankItemInfo(tab, i)
			if texture and not locked then
				if IsAlreadyKnown(GetGuildBankItemLink(tab, i), i) then
					SetItemButtonTextureVertexColor(button, TINT.r, TINT.g, TINT.b)
				else
					SetItemButtonTextureVertexColor(button, 1, 1, 1)
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Repaint dispatch
-- ---------------------------------------------------------------------------
function RefreshVisibleItems()
	local MerchantFrame = _G.MerchantFrame
	if MerchantFrame and MerchantFrame:IsShown() then
		UpdateMerchantInfo()
		UpdateBuybackInfo()
	end

	local ah = _G.AuctionHouseFrame
	local list = ah and ah:IsShown() and ah.BrowseResultsFrame and ah.BrowseResultsFrame.ItemList
	if list and list.ScrollBox and list.ScrollBox.ScrollTarget then
		UpdateAuctionItems(list.ScrollBox)
	end

	local GuildBankFrame = _G.GuildBankFrame
	if GuildBankFrame and GuildBankFrame:IsShown() then
		UpdateGuildBank(GuildBankFrame)
	end
end

-- ---------------------------------------------------------------------------
-- Hook installation / lifecycle
-- ---------------------------------------------------------------------------
function Module:HookAuctionHouse()
	if self.auctionHooked then
		return
	end
	local ah = _G.AuctionHouseFrame
	local list = ah and ah.BrowseResultsFrame and ah.BrowseResultsFrame.ItemList
	if list and list.ScrollBox then
		hooksecurefunc(list.ScrollBox, "Update", UpdateAuctionItems)
		self.auctionHooked = true
	end
end

function Module:HookGuildBank()
	if self.guildBankHooked then
		return
	end
	if _G.GuildBankFrame then
		hooksecurefunc(_G.GuildBankFrame, "Update", UpdateGuildBank)
		self.guildBankHooked = true
	end
end

function Module:ADDON_LOADED(_, addon)
	if addon == "Blizzard_AuctionHouseUI" then
		self:HookAuctionHouse()
	elseif addon == "Blizzard_GuildBankUI" then
		self:HookGuildBank()
	end
end

function Module:OnEnable()
	if not IsActive() or self.setupDone then
		return
	end
	self.setupDone = true

	-- Merchant + Buyback live in base FrameXML, so hook straight away.
	hooksecurefunc("MerchantFrame_UpdateMerchantInfo", UpdateMerchantInfo)
	hooksecurefunc("MerchantFrame_UpdateBuybackInfo", UpdateBuybackInfo)

	-- The AH and Guild Bank are load-on-demand, hook now if present, else wait.
	if C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then
		self:HookAuctionHouse()
	end
	if C_AddOns.IsAddOnLoaded("Blizzard_GuildBankUI") then
		self:HookGuildBank()
	end
	self:RegisterEvent("ADDON_LOADED")

end
