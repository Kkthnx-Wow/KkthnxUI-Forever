--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/BankBar.lua
	Purpose:
		The bank window's bag slot bar. One button per bank bag slot, and a buy
		button for the next slot. It hangs below the bank frame the same way the
		carried bag strip hangs below the bags.

		On WoW Forever the bank's "tabs" are the base bank plus bag slots. Tab 1 is
		the base bank and has no slot. Slots 2 and up are bought one at a time and
		then hold a bag, which sits in the Characterbanktab container at the slot's
		own index. A bought slot takes a click or a drop to put a bag in or take it
		out, a slot not bought yet shows a lock.

		The buy button inherits Blizzard's purchase button template, so the purchase
		runs through its confirm popup and never from our code.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Bags")
if not (Module and Module.SetupBank) then
	return
end

local ipairs = ipairs
local max = math.max
local CreateFrame = CreateFrame
local C_Bank = C_Bank
local C_Container = C_Container
local C_Item = C_Item
local GameTooltip = GameTooltip
local GetCoinTextureString = C_CurrencyInfo.GetCoinTextureString
local IsSecret = K.IsSecret

local SLOT = 28
local PAD = 6

local CHARACTER = Enum.BankType.Character
-- The container that holds the bank's bags, one per bag slot.
local BAG_HOLDER = Enum.BagIndex.Characterbanktab
-- The first tab is the base bank, so bag slots start at the second.
local FIRST_BAG_SLOT = 2

local LOCK_ATLAS = "bankslot-icon-lock" -- Blizzard's own, from its bank bag slots
local EMPTY_BAG_ICON = 133633 -- inv_misc_bag_08, dimmed, for a bought slot with no bag

-- ---------------------------------------------------------------------------
-- Buy button
-- ---------------------------------------------------------------------------

-- Inheriting Blizzard's template hands the buy to its own code: its OnClick opens
-- the confirm popup, whose accept does the purchase. overrideBankType is all we set.
local function MakeBuyButton(parent)
	local button = CreateFrame("Button", nil, parent, "BankPanelPurchaseButtonScriptTemplate")
	button:SetAttribute("overrideBankType", CHARACTER)
	button:SetSize(SLOT, SLOT)
	K.CreateGradientBackground(button, 0.9)
	K.CreateBorder(button)

	local plus = button:CreateFontString(nil, "OVERLAY")
	K.SetFont(plus, 20, K.FontOutlineStyle())
	plus:SetPoint("CENTER")
	plus:SetText("+")
	plus:SetTextColor(K.Colors.gold[1], K.Colors.gold[2], K.Colors.gold[3])

	button:HookScript("OnEnter", function(self)
		self.KKUI_Border:SetVertexColor(1, 1, 1, 1)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L["Buy Bank Bag Slot"], 1, 1, 1)
		local data = C_Bank.FetchNextPurchasableBankTabData(CHARACTER)
		if data and data.tabCost then
			local g = data.canAfford and 1 or 0.3
			GameTooltip:AddLine(GetCoinTextureString(data.tabCost), 1, g, g)
		end
		GameTooltip:Show()
	end)
	button:HookScript("OnLeave", function(self)
		K.ResetBorderColor(self.KKUI_Border)
		GameTooltip:Hide()
	end)
	button:Hide()
	return button
end

-- ---------------------------------------------------------------------------
-- Bag slot buttons
-- ---------------------------------------------------------------------------

local function SlotOnEnter(self)
	self.KKUI_Border:SetVertexColor(1, 1, 1, 1)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if not self.bought then
		GameTooltip:SetText(_G.BANK_BAG_PURCHASE or L["Buy Bank Bag Slot"], 1, 1, 1)
	elseif not (self.hasBag and GameTooltip:SetBagItem(BAG_HOLDER, self.slot)) then
		GameTooltip:SetText(_G.BANK_BAG or L["Bank Bag"], 1, 1, 1)
	end
	GameTooltip:Show()
end

local function SlotOnLeave(self)
	K.ResetBorderColor(self.KKUI_Border)
	GameTooltip:Hide()
end

-- Pick up the bag in the slot, or drop the bag on the cursor into it. The same
-- call Blizzard's own bank bag slot makes for a click, a drag and a drop.
local function SlotPickup(self)
	if self.bought then
		C_Container.PickupContainerItem(BAG_HOLDER, self.slot)
	end
end

local function AcquireSlot(bar, index)
	local button = bar.slots[index]
	if not button then
		button = CreateFrame("Button", nil, bar)
		button:SetSize(SLOT, SLOT)
		K.CreateGradientBackground(button, 0.9)
		K.CreateBorder(button)
		local icon = button:CreateTexture(nil, "ARTWORK")
		icon:SetPoint("TOPLEFT", 2, -2)
		icon:SetPoint("BOTTOMRIGHT", -2, 2)
		button.Icon = icon
		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		button:RegisterForDrag("LeftButton")
		button:SetScript("OnEnter", SlotOnEnter)
		button:SetScript("OnLeave", SlotOnLeave)
		button:SetScript("OnClick", SlotPickup)
		button:SetScript("OnDragStart", SlotPickup)
		button:SetScript("OnReceiveDrag", SlotPickup)
		bar.slots[index] = button
	end
	return button
end

local function UpdateSlot(button, slot, bought)
	button.slot = slot
	button.bought = bought
	button.hasBag = false

	local icon = button.Icon
	icon:SetDesaturated(false)
	icon:SetAlpha(1)
	K.ResetBorderColor(button.KKUI_Border)

	if not bought then
		icon:SetAtlas(LOCK_ATLAS)
		return
	end

	local info = C_Container.GetContainerItemInfo(BAG_HOLDER, slot)
	local texture = info and info.iconFileID
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	if texture then
		button.hasBag = true
		icon:SetTexture(texture)
		local quality = info.quality
		if quality and not IsSecret(quality) and quality > 1 then
			local r, g, b = C_Item.GetItemQualityColor(quality)
			if r then
				button.KKUI_Border:SetVertexColor(r, g, b, 1)
			end
		end
	else
		-- Bought, nothing in it yet.
		icon:SetTexture(EMPTY_BAG_ICON)
		icon:SetDesaturated(true)
		icon:SetAlpha(0.35)
	end
end

-- ---------------------------------------------------------------------------
-- Build and refresh
-- ---------------------------------------------------------------------------

function Module:CreateBankBar(f)
	if not f or f.BankBar then
		return f and f.BankBar
	end

	local bar = CreateFrame("Frame", nil, f)
	bar:SetHeight(SLOT + PAD * 2)
	K.CreateGradientBackground(bar, 0.95)
	K.CreateBorder(bar)
	bar:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -6)
	bar.slots = {}
	bar.buy = MakeBuyButton(bar)

	bar:SetShown(C.Bags.ShowBagBar)
	f.BankBar = bar
	self:UpdateBankBar(f)
	return bar
end

-- Lay out every bag slot the bank can have, bought ones first by nature of the
-- order they are sold in, then the buy button while a slot can still be bought.
function Module:UpdateBankBar(f)
	local bar = f and f.BankBar
	if not bar then
		return
	end

	for _, button in ipairs(bar.slots) do
		button:Hide()
	end
	bar.buy:Hide()

	local maxTabs = C_Bank.FetchMaxNumBankTabs(CHARACTER) or 0
	local bought = C_Bank.FetchNumPurchasedBankTabs(CHARACTER) or 0

	local x = PAD
	local index = 0
	for slot = FIRST_BAG_SLOT, maxTabs do
		index = index + 1
		local button = AcquireSlot(bar, index)
		button:ClearAllPoints()
		button:SetPoint("LEFT", bar, "LEFT", x, 0)
		-- A texture set by atlas keeps the atlas coordinates until told otherwise,
		-- so each state sets its own crop in UpdateSlot.
		button.Icon:SetTexCoord(0, 1, 0, 1)
		UpdateSlot(button, slot, slot <= bought)
		button:Show()
		x = x + SLOT + C.Bags.Spacing
	end

	if bought < maxTabs and C_Bank.CanPurchaseBankTab(CHARACTER) then
		bar.buy:ClearAllPoints()
		bar.buy:SetPoint("LEFT", bar, "LEFT", x, 0)
		bar.buy:Show()
		x = x + SLOT + C.Bags.Spacing
	end

	bar:SetWidth(max(x - C.Bags.Spacing + PAD, SLOT + PAD * 2))
end
