--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Bank.lua
	Purpose:
		The bank window. It reuses the shared container, layout and item buttons
		from Core.lua and Slots.lua, pointed at the bank's containers.

		Built against the WoW Forever 1.60.1 bank (the Camelot BankFrame). That
		bank is one base container plus bag slots you buy and fill with bags, all
		reported through C_Bank as "tabs". Only the character bank can be viewed on
		this client, so there is no bank type switch here.

		The stock BankFrame keeps running. It is parked out of sight but still
		shown, so Blizzard goes on tracking the active bank type itself and a right
		click on a bag item deposits into the bank. Nothing here writes to the stock
		frame or its panel: a value of ours there would be read by Blizzard's
		protected item use and block it.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Bags")

local _G = _G
local ipairs = ipairs

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local C_Bank = C_Bank
local Enum = Enum

-- The bank needs the tab based bank API. Without it the stock bank stays in use.
if not (C_Bank and C_Bank.FetchPurchasedBankTabIDs and Enum.BankType) then
	return
end

local CHARACTER = Enum.BankType.Character

-- Height of the row under the title band that holds the deposit button.
local ACTION_ROW = 26

-- Read by Gold.lua and BankBar.lua. Always the character bank on this client.
Module.bankType = CHARACTER

-- The container ids that make up the bank, the base container, then one per bag
-- slot that has been bought. Read fresh so a new bag shows without a reload.
function Module:GetBankBags()
	local ids = {}
	local tabs = C_Bank.FetchPurchasedBankTabIDs(CHARACTER)
	if tabs then
		for i, id in ipairs(tabs) do
			ids[i] = id
		end
	end
	return ids
end

-- Point the bank window at the current containers and relayout.
function Module:RefreshBankBags()
	local f = self.BankFrame
	if not f then
		return
	end
	f.bags = self:GetBankBags()
	if f:IsShown() then
		self:LayoutContainer(f)
	end
	if self.UpdateBankBar then
		self:UpdateBankBar(f)
	end
end

-- The deposit button only exists where the game can sort bag items into the bank
-- by itself. Decided when the bank opens, since the answer is not reliable before
-- a banker is in range.
local function UpdateDepositButton(f)
	local supported = C_Bank.DoesBankTypeSupportAutoDeposit and C_Bank.AutoDepositItemsIntoBank and C_Bank.DoesBankTypeSupportAutoDeposit(CHARACTER)
	f.Deposit:SetShown(supported and true or false)
	f.extraTop = supported and ACTION_ROW or 0
	return supported
end

function Module:SetupBank()
	local f = self:CreateContainer("KKUI_BankFrame", L["Bank"], {}, C.Bags.BankPerRow)
	f.isBank = true
	f.extraTop = 0
	self.BankFrame = f

	-- Closing our window by hand has to end the bank interaction, or the banker
	-- stays engaged until you walk away. Skipped when the client already closed it.
	f:HookScript("OnHide", function()
		local manager = _G.C_PlayerInteractionManager
		local types = Enum.PlayerInteractionType
		if not (manager and manager.IsInteractingWithNpcOfType and types and C_Bank.CloseBankFrame) then
			return
		end
		if manager.IsInteractingWithNpcOfType(types.Banker) then
			C_Bank.CloseBankFrame()
		end
	end)

	-- Deposit button, under the search box. 8px below it, matching the grid gap.
	local deposit = CreateFrame("Button", "$parentDeposit", f)
	deposit:SetSize(90, 20)
	deposit:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -38)
	deposit.Text = deposit:CreateFontString(nil, "OVERLAY")
	K.SetFont(deposit.Text, 12, K.FontOutlineStyle())
	deposit.Text:SetPoint("CENTER")
	deposit.Text:SetText(L["Deposit All"])
	deposit:SetScript("OnClick", function()
		C_Bank.AutoDepositItemsIntoBank(CHARACTER)
	end)
	K.SkinButton(deposit)
	deposit:Hide()
	f.Deposit = deposit

	K.CreateMover(f, "Bank", L["Bank"], { "TOPLEFT", UIParent, "TOPLEFT", 60, -60 }, f:GetWidth(), f:GetHeight())
	K.EnableFrameDrag(f)

	-- Per character gold breakdown on hover of the money text.
	if self.AttachGoldTooltip then
		self:AttachGoldTooltip(f)
	end

	-- The bag slot bar, below the bank window.
	if self.CreateBankBar then
		self:CreateBankBar(f)
	end

	-- Park the stock bank. It stays shown under the sink, so BankFrame still reports
	-- its active bank type and the bank stays open server side.
	if _G.BankFrame and not InCombatLockdown() then
		_G.BankFrame:SetParent(self:GetBlizzardSink())
	end

	self:RegisterEvent("BANKFRAME_OPENED", function()
		if self.CaptureGold then
			self:CaptureGold()
		end
		self:OpenBank()
	end)
	self:RegisterEvent("BANKFRAME_CLOSED", function()
		self:CloseBank()
	end)
	self:RegisterEvent("PLAYERBANKSLOTS_CHANGED", "MarkDirty")
	-- A bag slot was bought, or a bag was put in or taken out of one.
	self:RegisterEvent("BANK_TABS_CHANGED", function()
		self:RefreshBankBags()
	end)
	self:RegisterEvent("BAG_CONTAINER_UPDATE", function()
		if self.BankFrame:IsShown() then
			self:RefreshBankBags()
		end
	end)
end

function Module:OpenBank()
	local f = self.BankFrame
	if not f then
		return
	end
	local canDeposit = UpdateDepositButton(f)
	f.bags = self:GetBankBags()
	f:Show()
	self:RefreshBankBags()
	-- Show the bags alongside the bank, the way the default UI does.
	self:OpenBags()

	if canDeposit and C.Bags.AutoDepositReagents then
		C_Bank.AutoDepositItemsIntoBank(CHARACTER)
	end
end

function Module:CloseBank()
	if self.BankFrame then
		self.BankFrame:Hide()
	end
	self:CloseBags()
end
