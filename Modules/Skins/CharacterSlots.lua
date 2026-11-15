--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/CharacterSlots.lua
	Purpose:
		Equipment slots on the Character and Inspect frames, in our look: a
		square icon in our border, the border tinted by item quality, and the item
		level on the slot.

		WoW Forever has its own character frame with sockets drawn by the slot
		itself, so this does not move or resize anything. It only restyles the
		regions of each slot and reacts to the game's own slot update, which means
		it needs no events of its own and never touches secure state.

		Inspect is load on demand, so its slots are picked up when its addon loads.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("CharacterSlots")

local _G = _G
local ipairs = ipairs
local strfind = string.find
local hooksecurefunc = hooksecurefunc
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemQuality = GetInventoryItemQuality
local C_Item = C_Item
local IsSecret = K.IsSecret

local SLOT_NAMES = {
	"Head",
	"Neck",
	"Shoulder",
	"Back",
	"Chest",
	"Shirt",
	"Tabard",
	"Wrist",
	"Hands",
	"Waist",
	"Legs",
	"Feet",
	"Finger0",
	"Finger1",
	"Trinket0",
	"Trinket1",
	"MainHand",
	"SecondaryHand",
	"Ranged",
	"Ammo",
}

-- Inventory ids where an item level means nothing (shirt and tabard).
-- Ammo is id 0 and stacks, so it has no level either.
local NO_LEVEL = { [0] = true, [4] = true, [19] = true }

local ILVL_SIZE = 11

local function Enabled()
	return C.Skins and C.Skins.CharacterSlots
end

-- Blizzard's slot update calls SetItemButtonTexture, which puts the crop back to
-- the full texture every time. A crop set once at setup is gone after the first
-- update, so it is applied again on every refresh.
local function CropIcon(slot)
	local icon = slot.icon or (slot:GetName() and _G[slot:GetName() .. "IconTexture"])
	if icon then
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	end
end

-- ---------------------------------------------------------------------------
-- Skinning
-- ---------------------------------------------------------------------------

-- One time: take the stock slot art off, crop the icon, and add our border and
-- item level text. The icon is kept, the game draws the item into it.
local function Style(slot)
	if slot.KKUI_Styled then
		return
	end
	slot.KKUI_Styled = true

	if slot.SetNormalTexture then
		slot:SetNormalTexture(0)
	end
	local normal = slot.GetNormalTexture and slot:GetNormalTexture()
	if normal then
		normal:SetAlpha(0)
	end
	if slot.IconBorder then
		slot.IconBorder:Hide()
	end
	if slot.IconOverlay then
		slot.IconOverlay:Hide()
	end
	-- Forever draws the ornate slot frame on a child frame, separate from the
	-- button's own textures.
	if slot.BorderFrame then
		slot.BorderFrame:SetAlpha(0)
	end
	-- The ammo slot has no BorderFrame, its frame art is a texture on the button
	-- itself, so any slot art of that family is found by atlas name.
	for _, region in ipairs({ slot:GetRegions() }) do
		local atlas = region.GetAtlas and region:GetAtlas()
		if atlas and strfind(atlas, "UI%-Character%-Info%-GearSlot") then
			region:SetAlpha(0)
		end
	end

	local icon = slot.icon or (slot:GetName() and _G[slot:GetName() .. "IconTexture"])
	if icon then
		-- The template rounds the icon with a mask, which reads as a second frame
		-- inside our square border, so the mask comes off.
		if slot.Mask and icon.RemoveMaskTexture then
			icon:RemoveMaskTexture(slot.Mask)
		end
		icon:ClearAllPoints()
		icon:SetPoint("TOPLEFT", slot, "TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", slot, "BOTTOMRIGHT", -1, 1)
	end

	K.CreateBackground(slot, 0.06, 0.06, 0.06, 0.9)
	K.CreateBorder(slot)

	local level = slot:CreateFontString(nil, "OVERLAY")
	K.SetFont(level, ILVL_SIZE, K.FontOutlineStyle())
	level:SetWordWrap(false)
	level:SetPoint("TOPLEFT", slot, "TOPLEFT", 3, -3)
	slot.KKUI_ItemLevel = level
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

local function SlotUnit(slot)
	local name = slot:GetName() or ""
	if strfind(name, "^Inspect") then
		return _G.InspectFrame and _G.InspectFrame.unit
	end
	return "player"
end

local function Refresh(slot)
	if not slot or not Enabled() then
		return
	end
	Style(slot)
	CropIcon(slot)

	-- The game shows its own quality frame every time it updates the slot.
	if slot.IconBorder then
		slot.IconBorder:Hide()
	end

	local unit = SlotUnit(slot)
	local id = slot:GetID()
	local link = unit and GetInventoryItemLink(unit, id)

	-- Gems and the missing enchant marker (GearInfo.lua), cleared when the slot is empty.
	if Module.UpdateGear then
		Module.UpdateGear(slot, unit, id, link and not IsSecret(link) and link or nil)
	end

	local border = slot.KKUI_Border
	local level = slot.KKUI_ItemLevel
	if not link or IsSecret(link) then
		if border then
			local c = C.General.BorderColor
			border:SetVertexColor(c[1], c[2], c[3], 1)
		end
		if level then
			level:SetText("")
		end
		return
	end

	local quality = GetInventoryItemQuality(unit, id)
	local r, g, b
	if quality and not IsSecret(quality) and quality > 1 then
		r, g, b = C_Item.GetItemQualityColor(quality)
	end
	if border then
		if r then
			border:SetVertexColor(r, g, b, 1)
		else
			local c = C.General.BorderColor
			border:SetVertexColor(c[1], c[2], c[3], 1)
		end
	end

	if level then
		local ilvl = not NO_LEVEL[id] and C_Item.GetDetailedItemLevelInfo and C_Item.GetDetailedItemLevelInfo(link)
		if ilvl and not IsSecret(ilvl) and ilvl > 1 then
			level:SetText(ilvl)
			level:SetTextColor(r or 1, g or 1, b or 1)
		else
			level:SetText("")
		end
	end
end

-- Every slot of one frame, found by name.
local function RefreshAll(prefix)
	for _, name in ipairs(SLOT_NAMES) do
		local slot = _G[prefix .. name .. "Slot"]
		if slot then
			Refresh(slot)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Hooks
-- ---------------------------------------------------------------------------

local inspectHooked = false

local function HookInspect()
	if inspectHooked or not _G.InspectPaperDollItemSlotButton_Update then
		return
	end
	inspectHooked = true
	hooksecurefunc("InspectPaperDollItemSlotButton_Update", Refresh)
	-- Item data for another player arrives a moment after the frame opens, so the
	-- first pass can miss levels. One more pass once the frame has settled.
	if _G.InspectFrame then
		_G.InspectFrame:HookScript("OnShow", function()
			C_Timer.After(0.5, function()
				RefreshAll("Inspect")
			end)
		end)
	end
	RefreshAll("Inspect")
end

function Module:OnEnable()
	if not Enabled() then
		return
	end

	if _G.PaperDollItemSlotButton_Update then
		hooksecurefunc("PaperDollItemSlotButton_Update", Refresh)
	end
	RefreshAll("Character")

	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_InspectUI") then
		HookInspect()
	else
		self:RegisterEvent("ADDON_LOADED")
	end
end

function Module:ADDON_LOADED(_, addon)
	if addon == "Blizzard_InspectUI" then
		HookInspect()
		self:UnregisterEvent("ADDON_LOADED")
	end
end
