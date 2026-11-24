--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Strip.lua
	Purpose:
		A row of the character's equipped bag slots that lives on the bag window and
		folds out from the toolbar toggle. Each slot shows the bag icon, its free
		count, and a quality border, and takes a bag dropped onto it to swap it in.
		An empty bag slot shows the game's own empty slot art, and a quiver or ammo
		pouch shows how much ammo it holds instead of how many slots are free.

		Where the game has them, the strip also carries the keyring (opens its own
		window and takes a key dropped on it) and the ammo slot. The ammo slot only
		shows for a character that uses ammo and either has ammo equipped or carries
		a quiver, so it is not a dead box for a class that never fires anything.

		Swapping goes through the cursor and is blocked in combat, so it stays clean
		of the secure action path.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Bags")
if not Module then
	return
end

local ipairs = ipairs
local pcall = pcall
local select = select
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local CursorHasItem = CursorHasItem
local PickupInventoryItem = PickupInventoryItem
local GetInventoryItemTexture = GetInventoryItemTexture
local GetInventoryItemQuality = GetInventoryItemQuality
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemCount = GetInventoryItemCount
local GetInventorySlotInfo = GetInventorySlotInfo
local GetCVarBool = GetCVarBool
local C_Container = C_Container
local C_Item = C_Item
local IsSecret = K.IsSecret

local SLOT = 28
local PAD = 6
-- The stock keyring slot is narrower than a bag slot (33 against 45), so it keeps
-- that share here as well.
local KEYRING_WIDTH = math.floor(SLOT * 33 / 45 + 0.5)
-- The default pack icon, used for the backpack.
local DEFAULT_ICON = 133633

-- The keyring art the game uses on its own bag bar, the key once the player has ever
-- held one (the showKeyring setting), the plain small slot frame before that. Both
-- are 27 by 40, so they are drawn at that shape and not stretched square.
local KEYRING_ATLAS = "UI-HUD-ActionBar-Keyring-Small"
local KEYRING_EMPTY_ATLAS = "UI-HUD-ActionBar-IconFrame-Slot-Small"
local KEYRING_ASPECT = 27 / 40

-- Not bag ids, so they cannot collide with 0 to 5 or with the keyring's -1.
local AMMO = "ammo"
-- The ammo slot is inventory slot 0, the same number as the backpack's bag id.
local AMMO_SLOT = _G.INVSLOT_AMMO or 0

-- The inventory slot name each carried bag id answers to, so the game can say what
-- an empty one looks like. GetInventorySlotInfo returns the slot id and the empty
-- slot texture the character frame uses.
local BAG_SLOT_NAME = {
	[1] = "Bag0Slot",
	[2] = "Bag1Slot",
	[3] = "Bag2Slot",
	[4] = "Bag3Slot",
	[5] = "ReagentBag0Slot",
}
local AMMO_SLOT_NAME = "AmmoSlot"

local emptyArt = {}

-- Empty slot art from the game, looked up once. Returns nil if the client has no
-- slot of that name, and the caller falls back to the plain bag icon.
local function EmptyArt(slotName)
	if emptyArt[slotName] == nil then
		local ok, _, texture = pcall(GetInventorySlotInfo, slotName)
		emptyArt[slotName] = ok and texture or false
	end
	return emptyArt[slotName] or nil
end

-- Outer height of the attached strip panel.
Module.BagStripHeight = SLOT + PAD * 2

-- Backpack, the four carried bags, and the reagent pouch, then the keyring and the
-- ammo slot. Whether the keyring exists and whether the character uses ammo can
-- change, so those buttons are always built and only shown when they apply.
local function StripBags()
	return { 0, 1, 2, 3, 4, 5, Module.KeyringBag, AMMO }
end

local function UsesAmmo()
	return _G.UnitUsesAmmo and _G.UnitUsesAmmo("player") and true or false
end

-- A quiver or ammo pouch is told apart by item class, the same test the game's own
-- bag buttons use. Only the four ordinary bag slots can hold one.
local function IsQuiverLink(link)
	local classID = link and select(6, C_Item.GetItemInfoInstant(link))
	return classID ~= nil and classID == Enum.ItemClass.Quiver
end

local function EquippedBagLink(bag)
	local inv = C_Container.ContainerIDToInventoryID(bag)
	return inv and GetInventoryItemLink("player", inv) or nil
end

local function HasQuiver()
	for bag = 1, 4 do
		if IsQuiverLink(EquippedBagLink(bag)) then
			return true
		end
	end
	return false
end

-- Ammo goes where it applies. A character that uses ammo gets the slot while ammo is
-- equipped, or while a quiver is carried to receive it.
local function AmmoApplies()
	if not UsesAmmo() then
		return false
	end
	return GetInventoryItemTexture("player", AMMO_SLOT) ~= nil or HasQuiver()
end

-- How many projectiles a quiver holds, summed over its slots.
local function CountAmmo(bag)
	local total = 0
	for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
		local info = C_Container.GetContainerItemInfo(bag, slot)
		local stack = info and info.stackCount
		if stack and not IsSecret(stack) then
			total = total + stack
		end
	end
	return total
end

-- Seat the icon in its button. It sits one pixel down and right while the button is
-- held, which is the only pressed look a flat slot needs. The keyring art keeps its
-- own shape and is centred.
local function PlaceIcon(button, pressed)
	local icon = button.Icon
	local push = pressed and 1 or 0
	icon:ClearAllPoints()
	if button.bagID == Module.KeyringBag then
		local height = SLOT - 4
		icon:SetSize(math.floor(height * KEYRING_ASPECT + 0.5), height)
		icon:SetPoint("CENTER", button, "CENTER", push, -push)
	else
		icon:SetPoint("TOPLEFT", button, "TOPLEFT", 2 + push, -2 - push)
		icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2 + push, 2 - push)
	end
end

local function SwapBag(self)
	if InCombatLockdown() or not CursorHasItem() then
		return
	end
	local bag = self.bagID
	-- The backpack itself cannot be replaced.
	if not bag or bag == 0 then
		return
	end
	local inv = C_Container.ContainerIDToInventoryID(bag)
	if inv then
		PickupInventoryItem(inv)
	end
end

local function PickupBag(self)
	local bag = self.bagID
	if InCombatLockdown() or CursorHasItem() or not bag or bag == 0 then
		return
	end
	local inv = C_Container.ContainerIDToInventoryID(bag)
	if inv and GetInventoryItemTexture("player", inv) then
		PickupInventoryItem(inv)
	end
end

-- A key goes into the keyring through the game's own helper, and a plain click
-- opens or closes the keyring window, the same as the toolbar button.
local function KeyringClick()
	if CursorHasItem() then
		if not InCombatLockdown() and _G.PutKeyInKeyRing then
			_G.PutKeyInKeyRing()
		end
		return
	end
	Module:ToggleKeyring()
end

local function KeyringDrop()
	if not InCombatLockdown() and CursorHasItem() and _G.PutKeyInKeyRing then
		_G.PutKeyInKeyRing()
	end
end

-- Ammo dropped on the slot is equipped through the cursor, like a bag swap.
local function AmmoDrop()
	if InCombatLockdown() or not CursorHasItem() then
		return
	end
	PickupInventoryItem(AMMO_SLOT)
end

local function AddUsage(bag)
	local total = C_Container.GetContainerNumSlots(bag) or 0
	local free = C_Container.GetContainerNumFreeSlots(bag) or 0
	if total > 0 then
		GameTooltip:AddLine((total - free) .. " / " .. total, K.Colors.silver[1], K.Colors.silver[2], K.Colors.silver[3])
	end
end

local function OnEnter(self)
	K.SetBorderColor(self.KKUI_Border, 1, 1, 1, 1)
	local bag = self.bagID
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")

	if bag == AMMO then
		if not GameTooltip:SetInventoryItem("player", AMMO_SLOT) then
			GameTooltip:SetText(L["Ammo"], 1, 1, 1)
			GameTooltip:AddLine(L["Drop ammo here to equip it."], K.Colors.silver[1], K.Colors.silver[2], K.Colors.silver[3])
		end
		GameTooltip:Show()
		return
	end

	if bag == Module.KeyringBag then
		GameTooltip:SetText(L["Keyring"], 1, 1, 1)
		AddUsage(bag)
		GameTooltip:Show()
		return
	end

	if bag == 0 then
		GameTooltip:SetText(L["Backpack"], 1, 1, 1)
	else
		local link = EquippedBagLink(bag)
		local name = link and C_Item.GetItemInfo and C_Item.GetItemInfo(link)
		GameTooltip:SetText(name or L["Empty Bag Slot"], 1, 1, 1)
		if IsQuiverLink(link) then
			GameTooltip:AddLine(L["Ammunition"], K.Colors.silver[1], K.Colors.silver[2], K.Colors.silver[3])
		end
	end
	AddUsage(bag)
	GameTooltip:Show()
end

local function OnLeave(self)
	if self.__q then
		K.SetBorderColor(self.KKUI_Border, self.__q.r, self.__q.g, self.__q.b, 1)
	else
		K.ResetBorderColor(self.KKUI_Border)
	end
	GameTooltip:Hide()
end

-- Place the buttons that apply right now left to right and size the panel to fit.
-- The ammo slot drops out when it does not apply, and the keyring where the game
-- has none, so neither leaves a gap.
local function LayoutStrip(strip)
	local gap = C.Bags.Spacing
	local x = PAD
	local keyring = Module.HasKeyring()
	local ammo = AmmoApplies()
	for _, button in ipairs(strip.buttons) do
		if button.bagID == AMMO then
			button:SetShown(ammo)
		elseif button.bagID == Module.KeyringBag then
			button:SetShown(keyring)
		end
		if button:IsShown() then
			button:ClearAllPoints()
			button:SetPoint("LEFT", strip, "LEFT", x, 0)
			x = x + button:GetWidth() + gap
		end
	end
	-- Panel wide enough for the buttons plus padding, right-aligned under the frame
	-- and hanging just below its bottom edge.
	strip:SetWidth(math.max(SLOT + PAD * 2, x - gap + PAD))
end

-- Build the strip and its slot buttons once per container.
function Module:CreateBagStrip(f)
	if f.BagStrip then
		return f.BagStrip
	end
	-- Its own panel below the frame, wearing the same gradient and border so it
	-- reads as one piece flush against the bottom of the bags.
	local strip = CreateFrame("Frame", nil, f)
	strip:SetHeight(Module.BagStripHeight)
	K.CreateGradientBackground(strip, 0.95)
	K.CreateBorder(strip)
	strip:Hide()

	strip.buttons = {}
	for _, bag in ipairs(StripBags()) do
		local button = CreateFrame("Button", nil, strip)
		button:SetSize(bag == Module.KeyringBag and KEYRING_WIDTH or SLOT, SLOT)
		button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		button.bagID = bag
		K.CreateGradientBackground(button, 0.9)
		K.CreateBorder(button)
		K.StyleButtonStates(button, 2)

		local icon = button:CreateTexture(nil, "ARTWORK")
		button.Icon = icon
		-- An atlas carries its own coordinates, so only the plain icons get cropped.
		if bag ~= Module.KeyringBag then
			icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		end
		PlaceIcon(button)

		local count = button:CreateFontString(nil, "OVERLAY")
		K.SetFont(count, 11, K.FontOutlineStyle())
		count:SetPoint("BOTTOMRIGHT", -2, 2)
		button.Count = count

		button:SetScript("OnEnter", OnEnter)
		button:SetScript("OnLeave", OnLeave)
		button:HookScript("OnMouseDown", function(self)
			PlaceIcon(self, true)
		end)
		button:HookScript("OnMouseUp", function(self)
			PlaceIcon(self)
		end)
		if bag == AMMO then
			button:SetScript("OnReceiveDrag", AmmoDrop)
			button:HookScript("OnClick", AmmoDrop)
		elseif bag == Module.KeyringBag then
			button:SetScript("OnReceiveDrag", KeyringDrop)
			button:HookScript("OnClick", KeyringClick)
		else
			button:SetScript("OnReceiveDrag", SwapBag)
			button:HookScript("OnClick", SwapBag)
			-- Dragging a carried bag off the strip picks it up, the same as the
			-- game's own bag slot, so a bag can be taken off and not only swapped.
			if bag ~= 0 then
				button:RegisterForDrag("LeftButton")
				button:SetScript("OnDragStart", PickupBag)
			end
		end

		strip.buttons[#strip.buttons + 1] = button
	end

	LayoutStrip(strip)
	strip:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", 0, -6)

	f.BagStrip = strip
	return strip
end

-- Quality colour on a button's border, or the plain border when there is none.
local function SetQualityBorder(button, quality)
	if K.SetQualityBorder(button.KKUI_Border, quality) then
		local r, g, b = K.ItemQualityColor(quality)
		button.__q = { r = r, g = g, b = b }
	else
		button.__q = nil
	end
end

local function UpdateAmmoButton(button)
	local tex = GetInventoryItemTexture("player", AMMO_SLOT)
	-- Empty, it shows the game's own ammo slot art, dimmed so it reads as a place to
	-- drop ammo and not as a held item.
	button.Icon:SetTexture(tex or EmptyArt(AMMO_SLOT_NAME) or DEFAULT_ICON)
	button.Icon:SetAlpha(tex and 1 or 0.75)
	SetQualityBorder(button, tex and GetInventoryItemQuality("player", AMMO_SLOT))
	local ammo = tex and GetInventoryItemCount("player", AMMO_SLOT) or 0
	button.Count:SetText(ammo > 0 and ammo or "")
end

local function UpdateKeyringButton(button)
	-- Same rule as the game's bag bar, the key art once the player has held a key.
	button.Icon:SetAtlas(GetCVarBool("showKeyring") and KEYRING_ATLAS or KEYRING_EMPTY_ATLAS)
	button.Icon:SetAlpha(1)
	button.__q = nil
	K.ResetBorderColor(button.KKUI_Border)
	-- Free keyring slots are noise on a button, the tooltip carries the usage.
	button.Count:SetText("")
end

local function UpdateBagButton(button, bag)
	local total = C_Container.GetContainerNumSlots(bag) or 0
	local free = C_Container.GetContainerNumFreeSlots(bag) or 0

	if bag == 0 then
		button.Icon:SetTexture(DEFAULT_ICON)
		button.Icon:SetAlpha(1)
		button.__q = nil
		K.ResetBorderColor(button.KKUI_Border)
		button.Count:SetText(total > 0 and free or "")
		return
	end

	local inv = C_Container.ContainerIDToInventoryID(bag)
	local tex = inv and GetInventoryItemTexture("player", inv)
	if tex then
		button.Icon:SetTexture(tex)
		button.Icon:SetAlpha(1)
		SetQualityBorder(button, GetInventoryItemQuality("player", inv))
		-- A quiver is worth knowing the ammo of, a plain bag the room left.
		if IsQuiverLink(EquippedBagLink(bag)) then
			button.Count:SetText(CountAmmo(bag))
		else
			button.Count:SetText(total > 0 and free or "")
		end
	else
		-- Nothing carried here, so show the empty slot and not another full bag.
		button.Icon:SetTexture(EmptyArt(BAG_SLOT_NAME[bag]) or DEFAULT_ICON)
		button.Icon:SetAlpha(0.75)
		button.__q = nil
		K.ResetBorderColor(button.KKUI_Border)
		button.Count:SetText("")
	end
end

-- Refresh every slot's icon, free count, and quality border.
function Module:UpdateBagStrip(f)
	local strip = f.BagStrip
	if not strip or not strip:IsShown() then
		return
	end
	LayoutStrip(strip)

	for _, button in ipairs(strip.buttons) do
		local bag = button.bagID
		if bag == AMMO then
			UpdateAmmoButton(button)
		elseif bag == Module.KeyringBag then
			UpdateKeyringButton(button)
		else
			UpdateBagButton(button, bag)
		end
	end
end

-- Fold the strip in or out and relayout so the grid makes room for it. Handles the
-- carried-bag strip on the bags and the tab bar on the bank, whichever this window
-- carries.
function Module:ToggleBagStrip(f, show)
	local strip = f and (f.BagStrip or f.BankBar)
	if not strip then
		return
	end
	strip:SetShown(show)
	if show then
		if f.BagStrip then
			self:UpdateBagStrip(f)
		end
		if f.BankBar and self.UpdateBankBar then
			self:UpdateBankBar(f)
		end
	end
	self:LayoutContainer(f)
end
