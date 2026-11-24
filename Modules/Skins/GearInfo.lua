--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/GearInfo.lua
	Purpose:
		Beside each equipment slot on the Character and Inspect windows: a red
		marker when an enchantable slot has no enchant, and the gems socketed in
		the item (an empty socket shows as such).

		Forever draws its own socket display only for timerunning characters, so
		normal characters would otherwise see no gems at all. Everything here is
		read from the item link and C_Item, with no tooltip scan, so it needs no
		extra data and nothing here can be secret except the link itself, which is
		checked first.

		Called from CharacterSlots.lua on every slot refresh. All widgets are ours,
		parented to the slot, and no Blizzard table is written to.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("CharacterSlots")

local _G = _G
local setmetatable = setmetatable
local strmatch = string.match
local tonumber = tonumber
local CreateFrame = CreateFrame
local C_Item = C_Item
local Item = Item
local GameTooltip = GameTooltip
local UnitLevel = UnitLevel
local GetInventoryItemLink = GetInventoryItemLink
local GetMaxLevelForPlayerExpansion = GetMaxLevelForPlayerExpansion
local IsSecret = K.IsSecret

local crimson = K.Colors.crimson

local ICON_SIZE = 14
local ICON_GAP = 6
local MAX_GEMS = 3
local MISSING_ICON = 134400 -- inv_misc_questionmark
local EMPTY_SOCKET_ATLAS = "character-emptysocket" -- Blizzard's own, used by the slot socket display

-- Slots that take a permanent enchant, by inventory slot id. This is the Retail
-- list (head, shoulder, chest, legs, feet, both rings, both weapons). UNKNOWN for
-- Forever. No source for its enchantable slots was found, so edit this one table
-- if the game differs and nothing else needs to change.
local ENCHANTABLE = {
	[1] = "HEADSLOT",
	[3] = "SHOULDERSLOT",
	[5] = "CHESTSLOT",
	[7] = "LEGSSLOT",
	[8] = "FEETSLOT",
	[11] = "FINGER0SLOT",
	[12] = "FINGER1SLOT",
	[16] = "MAINHANDSLOT",
	[17] = "SECONDARYHANDSLOT",
}

-- Which way the strip grows from a slot. Left column slots grow rightward, right
-- column slots leftward, and the weapon row grows rightward above its slots so it
-- never lands on the neighbouring weapon or the popout arrow.
local LEFT_COLUMN = { [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [9] = true, [15] = true, [19] = true }
local WEAPONS = { [16] = true, [17] = true, [18] = true }

-- Our widgets per slot, kept out of the Blizzard frames.
local overlays = setmetatable({}, { __mode = "k" })

local function Enabled()
	return C.Skins and C.Skins.GearInfo
end

-- ---------------------------------------------------------------------------
-- Widgets
-- ---------------------------------------------------------------------------

local function OnLeave()
	GameTooltip:Hide()
end

local function OnEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if self.gemID then
		GameTooltip:SetHyperlink("item:" .. self.gemID)
	elseif self.isMissing then
		GameTooltip:SetText(_G.ENCHANT_MISSING or "Missing Enchant", crimson[1], crimson[2], crimson[3])
		if self.slotName then
			GameTooltip:AddLine(self.slotName, 1, 1, 1)
		end
	else
		GameTooltip:SetText(_G.EMPTY_SOCKET_NO_COLOR or "Empty Socket", 1, 1, 1)
	end
	GameTooltip:Show()
end

-- One icon with a one pixel coloured edge. The frame owns the mouse so the
-- tooltip works, and the slot beneath is left alone.
local function NewIcon(slot)
	local frame = CreateFrame("Frame", nil, slot)
	frame:SetSize(ICON_SIZE, ICON_SIZE)
	frame:SetFrameLevel(slot:GetFrameLevel() + 3)
	frame:EnableMouse(true)
	frame:SetScript("OnEnter", OnEnter)
	frame:SetScript("OnLeave", OnLeave)

	frame.edge = frame:CreateTexture(nil, "BACKGROUND")
	frame.edge:SetAllPoints()
	frame.edge:SetColorTexture(0, 0, 0)

	frame.icon = frame:CreateTexture(nil, "ARTWORK")
	frame.icon:SetPoint("TOPLEFT", 1, -1)
	frame.icon:SetPoint("BOTTOMRIGHT", -1, 1)
	frame.icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
	frame:Hide()
	return frame
end

local function GetOverlay(slot)
	local overlay = overlays[slot]
	if overlay then
		return overlay
	end
	overlay = { used = 0 }
	for i = 1, MAX_GEMS + 1 do
		overlay[i] = NewIcon(slot)
	end
	overlays[slot] = overlay
	return overlay
end

-- Put the next free widget at the next position along the strip.
local function Place(slot, overlay, id)
	local index = overlay.used + 1
	overlay.used = index
	local frame = overlay[index]
	local step = (index - 1) * (ICON_SIZE + ICON_GAP)
	frame:ClearAllPoints()
	if WEAPONS[id] then
		frame:SetPoint("BOTTOMLEFT", slot, "TOPLEFT", step, ICON_GAP)
	elseif LEFT_COLUMN[id] then
		frame:SetPoint("TOPLEFT", slot, "TOPRIGHT", ICON_GAP + step, -2)
	else
		frame:SetPoint("TOPRIGHT", slot, "TOPLEFT", -ICON_GAP - step, -2)
	end
	frame.gemID, frame.isMissing, frame.slotName = nil, nil, nil
	frame:Show()
	return frame
end

-- ---------------------------------------------------------------------------
-- Update
-- ---------------------------------------------------------------------------

local function EnchantID(link)
	local text = strmatch(link, "item:%d+:(%d*)")
	local id = text and tonumber(text)
	return id and id > 0 and id or nil
end

-- A missing enchant is only worth a warning on a character at the level cap.
-- While leveling nearly every slot is unenchanted and the paper doll filled with
-- red markers. An unknown or hidden level counts as not at the cap.
local function AtLevelCap(unit)
	local level = unit and UnitLevel(unit)
	if not level or IsSecret(level) then
		return false
	end
	return level >= GetMaxLevelForPlayerExpansion()
end

local function Clear(overlay)
	overlay.used = 0
	for i = 1, MAX_GEMS + 1 do
		overlay[i].gemID = nil
		overlay[i]:Hide()
	end
end

-- Called with the link of the item in the slot, or nil when the slot is empty.
function Module.UpdateGear(slot, unit, id, link)
	if not Enabled() then
		return
	end
	local overlay = GetOverlay(slot)
	Clear(overlay)
	if not link then
		return
	end

	local slotGlobal = ENCHANTABLE[id]
	if slotGlobal and not EnchantID(link) and AtLevelCap(unit) then
		local frame = Place(slot, overlay, id)
		frame.isMissing = true
		frame.slotName = _G[slotGlobal]
		frame.edge:SetColorTexture(crimson[1], crimson[2], crimson[3])
		frame.icon:SetTexture(MISSING_ICON)
		frame.icon:SetVertexColor(crimson[1], crimson[2], crimson[3])
	end

	local sockets = C_Item.GetItemNumSockets and C_Item.GetItemNumSockets(link) or 0
	for socket = 1, sockets > MAX_GEMS and MAX_GEMS or sockets do
		local frame = Place(slot, overlay, id)
		frame.edge:SetColorTexture(0, 0, 0)
		frame.icon:SetVertexColor(1, 1, 1)

		local gemID = C_Item.GetItemGemID and C_Item.GetItemGemID(link, socket)
		if gemID and not IsSecret(gemID) then
			frame.gemID = gemID
			local texture = C_Item.GetItemIconByID(gemID)
			if texture then
				frame.icon:SetTexture(texture)
			else
				-- The gem is not cached yet. Show a placeholder and refresh the
				-- slot once its data arrives, as Blizzard's socket display does.
				frame.icon:SetTexture(MISSING_ICON)
				Item:CreateFromItemID(gemID):ContinueOnItemLoad(function()
					-- The slot may show another item or another player by now.
					if GetInventoryItemLink(unit, id) == link then
						Module.UpdateGear(slot, unit, id, link)
					end
				end)
			end
		else
			frame.icon:SetAtlas(EMPTY_SOCKET_ATLAS)
		end
	end
end
