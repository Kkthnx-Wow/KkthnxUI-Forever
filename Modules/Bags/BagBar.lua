--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/BagBar.lua
	Purpose:
		A compact, movable bag bar. The backpack, bag slots, and reagent bag are
		reparented onto our own bar, sized to a row, given a slot background and our
		border, and their icons squared off (the stock round CircleMask is hidden).
		Blizzard re-applies its own skin on UpdateTextures and re-lays the BagsBar,
		so both are hooked to keep our look.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("BagBar")

local _G = _G
local pcall = pcall
local hooksecurefunc = hooksecurefunc
local InCombatLockdown = InCombatLockdown
local C_Timer_After = C_Timer.After
local GetItemButtonIconTexture = GetItemButtonIconTexture
local GetInventoryItemCount = GetInventoryItemCount
local band = bit.band
local IsSecret = K.IsSecret

local BUTTONS = {
	"MainMenuBarBackpackButton",
	"CharacterBag0Slot",
	"CharacterBag1Slot",
	"CharacterBag2Slot",
	"CharacterBag3Slot",
	"CharacterReagentBag0Slot",
	"KeyRingButton",
}
local KEYRING = "KeyRingButton"
local KEYRING_SHARE = 33 / 45 -- the stock keyring slot against a stock bag slot
-- What the game uses for the keyring when it has not set one yet (it does so on
-- the first bag update), so the slot never shows empty.
local KEYRING_ATLAS = "UI-HUD-ActionBar-Keyring-Small"

-- Stand-in bag icon for the backpack (and any empty slot), so it never reads as a
-- blank square. The client hands empty slots this default texture id.
local BACKPACK_ICON = 133633 -- INV_Misc_Bag_07
local DEFAULT_TEX = 1721259

local bar

local function IconOf(btn, name)
	return (GetItemButtonIconTexture and GetItemButtonIconTexture(btn)) or _G[name .. "IconTexture"] or btn.icon or btn.Icon
end

-- Square off and fit the icon. Bag swaps and Blizzard's UpdateTextures reset this,
-- so it is re-applied from those hooks. The icon sits one pixel down and right
-- while the button is held, which is the only pressed look the flat slot needs.
local function CropIcon(btn, name)
	local icon = IconOf(btn, name)
	if not icon then
		return
	end
	local push = btn.__kkuiDown and 1 or 0
	icon:ClearAllPoints()
	icon:SetPoint("TOPLEFT", btn, "TOPLEFT", 1 + push, -1 - push)
	icon:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1 + push, 1 - push)
	-- The keyring icon is an atlas the game swaps as keys come and go. Replacing it
	-- or setting texture coordinates would break the atlas, so only the fit is ours.
	if name == KEYRING then
		if not (icon:GetAtlas() or icon:GetTexture()) then
			icon:SetAtlas(KEYRING_ATLAS)
		end
		icon:Show()
		return
	end
	local tex = icon:GetTexture()
	if name == "MainMenuBarBackpackButton" then
		icon:SetTexture(BACKPACK_ICON)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	elseif not tex or tex == DEFAULT_TEX then
		-- An empty bag slot keeps the game's own empty bag art, drawn whole.
		icon:SetTexture(DEFAULT_TEX)
		icon:SetTexCoord(0, 1, 0, 1)
	else
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
	icon:Show()
end

-- Re-hide the art Blizzard restores on UpdateTextures (the round mask especially).
local function StripStock(btn)
	local nt = btn.GetNormalTexture and btn:GetNormalTexture()
	if nt then
		nt:SetAlpha(0)
	end
	-- The stock highlight is the round frame ring, so the border set's hover,
	-- pressed and checked looks replace it. Re-applied with the rest, since
	-- UpdateTextures puts the stock art back.
	K.StyleButtonStates(btn, 1)
	-- Retail buttons mask the icon with CircleMask, Forever's with SquareMask.
	if btn.CircleMask then
		btn.CircleMask:Hide()
	end
	if btn.SquareMask then
		btn.SquareMask:Hide()
	end
	if btn.IconBorder then
		btn.IconBorder:SetAlpha(0)
	end
	if btn.SlotHighlightTexture then
		btn.SlotHighlightTexture:SetAlpha(0)
	end
end

-- Free general slots in the backpack and the four bags, drawn on the backpack
-- button. The count is ours because the game's own one is hidden whenever its free
-- bag slots setting is off, which left the button bare. It is the game's own
-- number, such as quivers, ammo pouches and other special bags (bag family not 0) and the
-- reagent bag are left out, since an ordinary item cannot go in them.
local function CountFreeGeneral()
	if C_Container.CalculateTotalNumberOfFreeBagSlots then
		return C_Container.CalculateTotalNumberOfFreeBagSlots() or 0
	end
	local free = 0
	for id = 0, 4 do
		local slots, family = C_Container.GetContainerNumFreeSlots(id)
		if (family or 0) == 0 then
			free = free + (slots or 0)
		end
	end
	return free
end

local function UpdateFree()
	local pack = _G.MainMenuBarBackpackButton
	local text = pack and pack.__kkuiFree
	if not text then
		return
	end
	local free = CountFreeGeneral()
	text:SetText(free)
	local key = free == 0 and "negative" or (free <= 3 and "warning" or "text")
	local color = K.Colors[key] or K.Colors.text
	if color then
		text:SetTextColor(color[1], color[2], color[3])
	end
end

-- A quiver or ammo pouch counts only what it holds, and the game writes "*" past
-- 999. The ammo you have equipped is the type you shoot, so its count across
-- every bag goes on the quiver instead. Bag families 1 and 2 are arrows and
-- bullets.
local AMMO_FAMILIES = 3
local AMMO_SLOT = _G.INVSLOT_AMMO or 0

local function UpdateAmmo()
	if not C.BagBar.AmmoTotal then
		return
	end
	local total = GetInventoryItemCount("player", AMMO_SLOT) or 0
	if IsSecret(total) then
		return
	end
	for index = 1, 4 do
		local btn = _G["CharacterBag" .. (index - 1) .. "Slot"]
		if btn and btn.__kkuiBag then
			local _, family = C_Container.GetContainerNumFreeSlots(index)
			local isAmmoBag = family and band(family, AMMO_FAMILIES) > 0
			local text = btn.__kkuiAmmo
			if isAmmoBag and not text then
				text = btn:CreateFontString(nil, "OVERLAY")
				K.SetFont(text, 12, K.FontOutlineStyle())
				text:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 2)
				btn.__kkuiAmmo = text
			end
			if text then
				text:SetText(isAmmoBag and total > 0 and K.ShortValue(total) or "")
				text:SetShown(isAmmoBag and true or false)
			end
			-- The game's own held count would sit under ours.
			if btn.Count then
				btn.Count:SetAlpha(isAmmoBag and 0 or 1)
			end
		end
	end
end

local function ReapplyIcons()
	UpdateFree()
	UpdateAmmo()
	for _, name in ipairs(BUTTONS) do
		local btn = _G[name]
		if btn and btn.__kkuiBag then
			StripStock(btn)
			CropIcon(btn, name)
		end
	end
end

local function Layout()
	if not bar then
		return
	end
	local cfg = C.BagBar
	local size = cfg.ButtonSize
	local space = cfg.Spacing
	local vertical = cfg.Orientation == "VERTICAL"

	local list, count = {}, 0
	for _, name in ipairs(BUTTONS) do
		local btn = _G[name]
		-- The keyring only exists in some clients and the game hides it when it has
		-- none, so a hidden button leaves no gap.
		if btn and btn.__kkuiBag and (name ~= KEYRING or btn:IsShown()) then
			count = count + 1
			list[count] = btn
		end
	end

	local reverse = cfg.Order == "REVERSE"
	local keyring = _G[KEYRING]
	local pos = 0
	for i = 1, count do
		local btn = list[reverse and (count - i + 1) or i]
		-- Re-assert the parent. Blizzard's BagsBar layout reparents the buttons
		-- back to itself, which is what made them snap away.
		if btn:GetParent() ~= bar then
			btn:SetParent(bar)
		end
		btn:ClearAllPoints()
		-- The keyring is a narrow slot in the stock bar (33 wide against 45), so it
		-- takes that share of the bag size along the bar's direction.
		local step = size
		if btn == keyring then
			step = K.Round(size * KEYRING_SHARE)
		end
		if vertical then
			btn:SetSize(size, step)
			btn:SetPoint("TOP", bar, "TOP", 0, -pos)
		else
			btn:SetSize(step, size)
			btn:SetPoint("LEFT", bar, "LEFT", pos, 0)
		end
		pos = pos + step + space
	end

	local length = math.max(1, pos - space)
	if vertical then
		bar:SetSize(size, length)
	else
		bar:SetSize(length, size)
	end
	return count
end

-- Reparenting is blocked in combat, so the layout is put back once it ends.
local function RelayoutNow()
	if InCombatLockdown() then
		K.DeferCombat("BagBarLayout", function()
			Layout()
			ReapplyIcons()
		end)
	else
		Layout()
	end
end

-- Coalesces bursts (every item pickup fires OnExpandChanged) into one re-layout
-- that runs after Blizzard's own Layout has finished.
local relayoutQueued
local function QueueRelayout()
	if relayoutQueued then
		return
	end
	relayoutQueued = true
	C_Timer_After(0, function()
		relayoutQueued = false
		RelayoutNow()
	end)
end

local function Skin(btn, name)
	if btn.__kkuiBag then
		return
	end
	btn.__kkuiBag = true

	btn:SetParent(bar)
	StripStock(btn)
	K.CreateBackground(btn, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.9)
	CropIcon(btn, name)

	if not btn.KKUI_Border then
		K.CreateBorder(btn)
	end

	btn:HookScript("OnMouseDown", function(self)
		self.__kkuiDown = true
		CropIcon(self, self:GetName())
	end)
	btn:HookScript("OnMouseUp", function(self)
		self.__kkuiDown = nil
		CropIcon(self, self:GetName())
	end)

	-- Blizzard restores its skin (round mask, normal texture) here, re-apply ours.
	if btn.UpdateTextures and not btn.__kkuiHook then
		btn.__kkuiHook = true
		hooksecurefunc(btn, "UpdateTextures", function(self)
			StripStock(self)
			CropIcon(self, self:GetName())
		end)
	end
end

function Module:Setup()
	if self.setupDone then
		return
	end
	self.setupDone = true

	local hidden = K.HiddenParent

	bar = CreateFrame("Frame", "KKUI_BagBar", UIParent)
	bar:SetSize(200, C.BagBar.ButtonSize)

	-- Take the Blizzard container out of play. BagsBar:Layout cannot be stopped
	-- without editing Blizzard's shared EventRegistry (taint), so it is left to run
	-- and our layout is put back after it instead. Two paths reach it:
	--   1. Direct calls (self:Layout()), caught by the hook below.
	--   2. The EventRegistry callback "MainMenuBarManager.OnExpandChanged", which
	--      fires on every cursor pickup. Blizzard stored the original Layout
	--      function there, so the hook never sees it. We register our own callback
	--      under our own owner (the supported addon path, run through
	--      securecallfunction) and re-lay one tick later, because the order of
	--      callbacks within one event is not guaranteed.
	local bagsBar = _G.BagsBar
	if bagsBar then
		bagsBar:UnregisterAllEvents()
		if bagsBar.Layout then
			hooksecurefunc(bagsBar, "Layout", RelayoutNow)
		end
		bagsBar:SetParent(hidden)
	end
	if _G.EventRegistry then
		_G.EventRegistry:RegisterCallback("MainMenuBarManager.OnExpandChanged", QueueRelayout, self)
	end

	local toggle = _G.BagBarExpandToggle
	if toggle then
		toggle:UnregisterAllEvents()
		toggle:SetParent(hidden)
		toggle:Hide()
	end

	for _, name in ipairs(BUTTONS) do
		local btn = _G[name]
		-- Skip the keyring when the option is off or the game has hidden it, so it
		-- stays on the hidden Blizzard bar.
		if btn and (name ~= KEYRING or (C.BagBar.ShowKeyring and btn:IsShown())) then
			pcall(Skin, btn, name)
		end
	end

	-- The backpack free-slot count. Ours replaces the game's, which is silent
	-- when its setting is off, so the stock one is faded out to avoid doubling.
	local pack = _G.MainMenuBarBackpackButton
	if pack and C.BagBar.ShowFreeSlots then
		-- The game draws its count in FreeSlots and shows it by the displayFreeBagSlots
		-- CVar, so alpha keeps it out of the way without fighting that.
		if pack.FreeSlots then
			pack.FreeSlots:SetAlpha(0)
		end
		local text = pack:CreateFontString(nil, "OVERLAY")
		K.SetFont(text, 12, K.FontOutlineStyle())
		text:SetPoint("BOTTOM", pack, "BOTTOM", 0, 2)
		pack.__kkuiFree = text
		UpdateFree()
	end

	Layout()
	-- Sit 6px above the micro menu, right-aligned. Falls back to the corner if the
	-- micro menu is off.
	local micro = _G.KKUI_MicroMenu
	local point = micro and { "BOTTOMRIGHT", micro, "TOPRIGHT", 0, 6 } or { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -4, 34 }
	K.CreateMover(bar, "BagBar", L["Bag Bar"], point, bar:GetWidth(), bar:GetHeight())

	self:RegisterEvent("BAG_UPDATE_DELAYED", ReapplyIcons)
	if C.BagBar.AmmoTotal then
		-- Switching to another ammo type changes the count without a bag update.
		self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", UpdateAmmo)
		UpdateAmmo()
	end
end

function Module:OnEnable()
	if not C.BagBar.Enable then
		-- With ours off, the stock bag bar is parked on the hidden parent when the
		-- player asked for that, and left as the game made it otherwise. Its events
		-- and layout are left alone either way.
		local stock = C.BagBar.HideStock and _G.BagsBar
		if stock then
			local hidden = K.HiddenParent
			if InCombatLockdown() then
				K.DeferCombat("BagBarStockHide", function()
					stock:SetParent(hidden)
				end)
			else
				stock:SetParent(hidden)
			end
		end
		return
	end
	self:Setup()
end
