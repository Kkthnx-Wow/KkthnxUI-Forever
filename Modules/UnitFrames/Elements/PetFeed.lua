--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Elements/PetFeed.lua
	Purpose:
		Turn the hunter pet's happiness icon into a feed button. Hovering it shows
		the pet's mood, damage and diet. Clicking it opens a row of the foods in
		your bags that the pet will eat, and clicking a food feeds it.

		Each food is a secure button that casts Feed Pet aimed at that item, so
		the feeding itself runs through Blizzard's secure action code. Secure
		buttons cannot change in combat, so the row only opens out of combat and
		closes the moment combat starts. PLAYER_REGEN_DISABLED fires just before
		the lockdown, which is the last chance to hide it.
-----------------------------------------------------------------------------]]

local K, L = KkthnxUI[1], KkthnxUI[3]

local Module = K:GetModule("UnitFrames")

local _G = _G
local format = string.format
local concat = table.concat
local ceil = math.ceil
local floor = math.floor
local wipe = wipe

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local InCombatLockdown = InCombatLockdown
local UIParent = UIParent
local UnitExists = UnitExists
local C_PetInfo = C_PetInfo
local C_Spell = C_Spell
local C_SpellBook = C_SpellBook
local GetContainerItemID = C_Container.GetContainerItemID
local GetContainerNumSlots = C_Container.GetContainerNumSlots
local GetItemCount = C_Item.GetItemCount
local GetItemIcon = C_Item.GetItemIconByID

-- Blizzard strings for the pet tooltip, read once.
local PET_DAMAGE_PERCENTAGE = _G.PET_DAMAGE_PERCENTAGE
local PET_DIET_TEMPLATE = _G.PET_DIET_TEMPLATE
local PET_FOOD_DELIMIT = _G.PET_FOOD_DELIMIT
local GAINING_LOYALTY = _G.GAINING_LOYALTY
local LOSING_LOYALTY = _G.LOSING_LOYALTY

local FEED_PET = 6991
local LAST_BAG = NUM_BAG_SLOTS or 4
local MAX_FOODS = 12
local PER_ROW = 6
local BUTTON_SIZE = 30
local SPACING = 6

local menu
local toggle
local buttons = {}
local foods = {}
local seen = {}

-- Every distinct food in the bags, in bag order, up to MAX_FOODS. Bag order
-- keeps the row stable while you feed, instead of reshuffling by count.
local function CollectFoods()
	wipe(foods)
	wipe(seen)
	for bag = 0, LAST_BAG do
		for slot = 1, GetContainerNumSlots(bag) do
			local itemID = GetContainerItemID(bag, slot)
			if itemID and not seen[itemID] then
				seen[itemID] = true
				if C_PetInfo.CanPetEatItem(itemID) then
					foods[#foods + 1] = itemID
					if #foods >= MAX_FOODS then
						return foods
					end
				end
			end
		end
	end
	return foods
end

local function FeedPetKnown()
	return C_SpellBook.IsSpellKnown(FEED_PET) and true or false
end

-- ---------------------------------------------------------------------------
-- Food row
-- ---------------------------------------------------------------------------

local function FoodOnEnter(self)
	if not self.itemID then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:SetItemByID(self.itemID)
	GameTooltip:Show()
end

local function FoodOnLeave()
	GameTooltip:Hide()
end

local function HideMenu()
	if menu and menu:IsShown() and not InCombatLockdown() then
		menu:Hide()
	end
end

local function CreateFoodButton(index)
	local button = CreateFrame("Button", "KKUI_PetFeed" .. index, menu, "SecureActionButtonTemplate")
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	-- Up only. A mouse press acts on release, and PostClick hides the row, so
	-- a down click that hid it would leave the release with nothing to land on.
	button:RegisterForClicks("AnyUp")

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 1, -1)
	icon:SetPoint("BOTTOMRIGHT", -1, 1)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	button.Icon = icon

	local count = button:CreateFontString(nil, "OVERLAY")
	K.SetFont(count, 11, K.FontOutlineStyle())
	count:SetPoint("BOTTOMRIGHT", -1, 2)
	button.Count = count

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints(icon)
	highlight:SetColorTexture(1, 1, 1, K.GradientAlpha.hover)

	K.CreateBorder(button)
	button:SetScript("OnEnter", FoodOnEnter)
	button:SetScript("OnLeave", FoodOnLeave)
	-- Runs after the secure click, outside the restricted code.
	button:SetScript("PostClick", HideMenu)
	buttons[index] = button
	return button
end

-- Fill the row from the bags. Out of combat only, since it sets secure
-- attributes and shows or hides secure buttons. Returns how many foods it found.
local function Fill()
	local list = CollectFoods()
	local spellName = C_Spell.GetSpellName(FEED_PET)
	local count = #list

	for i = 1, count do
		local itemID = list[i]
		local button = buttons[i] or CreateFoodButton(i)
		button.itemID = itemID
		button:SetAttribute("type", "spell")
		button:SetAttribute("spell", spellName)
		button:SetAttribute("target-item", "item:" .. itemID)
		button.Icon:SetTexture(GetItemIcon(itemID))
		local owned = GetItemCount(itemID) or 0
		button.Count:SetText(owned > 1 and owned or "")

		local column = (i - 1) % PER_ROW
		local row = floor((i - 1) / PER_ROW)
		button:ClearAllPoints()
		button:SetPoint("BOTTOMLEFT", menu, "BOTTOMLEFT", column * (BUTTON_SIZE + SPACING), row * (BUTTON_SIZE + SPACING))
		button:Show()
	end
	for i = count + 1, #buttons do
		buttons[i].itemID = nil
		buttons[i]:Hide()
	end

	local across = count < PER_ROW and count or PER_ROW
	local rows = ceil(count / PER_ROW)
	menu:SetSize(
		across > 0 and (across * BUTTON_SIZE + (across - 1) * SPACING) or BUTTON_SIZE,
		rows > 0 and (rows * BUTTON_SIZE + (rows - 1) * SPACING) or BUTTON_SIZE
	)
	return count
end

local function MenuOnEvent(self, event, arg1)
	if event == "PLAYER_REGEN_DISABLED" then
		self:Hide()
	elseif event == "UNIT_PET" then
		if not UnitExists("pet") then
			HideMenu()
		end
	elseif event == "BAG_UPDATE_DELAYED" then
		if not InCombatLockdown() and Fill() == 0 then
			self:Hide()
		end
	elseif event == "GLOBAL_MOUSE_DOWN" then
		-- A click anywhere else closes the row, like a dropdown.
		if not self:IsMouseOver() and not (toggle and toggle:IsMouseOver()) then
			HideMenu()
		end
	end
end

-- The row only listens while it is open.
local function MenuOnShow(self)
	self:RegisterEvent("PLAYER_REGEN_DISABLED")
	self:RegisterEvent("BAG_UPDATE_DELAYED")
	self:RegisterEvent("GLOBAL_MOUSE_DOWN")
	self:RegisterUnitEvent("UNIT_PET", "player")
end

local function MenuOnHide(self)
	self:UnregisterAllEvents()
end

local function CreateMenu(anchor)
	menu = CreateFrame("Frame", "KKUI_PetFeedMenu", UIParent)
	menu:SetFrameStrata("DIALOG")
	menu:SetClampedToScreen(true)
	menu:SetPoint("BOTTOM", anchor, "TOP", 0, SPACING)
	menu:Hide()
	menu:SetScript("OnEvent", MenuOnEvent)
	menu:SetScript("OnShow", MenuOnShow)
	menu:SetScript("OnHide", MenuOnHide)
end

-- ---------------------------------------------------------------------------
-- Happiness icon
-- ---------------------------------------------------------------------------

local function AddMuted(text)
	local muted = K.Colors.muted
	GameTooltip:AddLine(text, muted[1], muted[2], muted[3], true)
end

local function ToggleOnEnter(self)
	local happiness, damage, loyalty = C_PetInfo.GetPetHappiness()
	if not happiness then
		return
	end

	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(_G["PET_HAPPINESS" .. happiness] or NONE, 1, 1, 1)
	if damage and PET_DAMAGE_PERCENTAGE then
		GameTooltip:AddLine(format(PET_DAMAGE_PERCENTAGE, damage), 1, 0.82, 0)
	end
	if loyalty and loyalty < 0 and LOSING_LOYALTY then
		GameTooltip:AddLine(LOSING_LOYALTY, 1, 0.82, 0)
	elseif loyalty and loyalty > 0 and GAINING_LOYALTY then
		GameTooltip:AddLine(GAINING_LOYALTY, 1, 0.82, 0)
	end
	local diet = C_PetInfo.GetPetFoodTypes()
	if PET_DIET_TEMPLATE then
		local list = (diet and #diet > 0) and concat(diet, PET_FOOD_DELIMIT or ", ") or NONE
		GameTooltip:AddLine(format(PET_DIET_TEMPLATE, list), 1, 0.82, 0, true)
	end

	GameTooltip:AddLine(" ")
	if not FeedPetKnown() then
		AddMuted(L["Learn Feed Pet to feed from here."])
	elseif InCombatLockdown() then
		AddMuted(L["Feeding from here works out of combat."])
	elseif #CollectFoods() == 0 then
		AddMuted(L["No food your pet will eat in your bags."])
	else
		AddMuted(L["Click to pick a food."])
	end
	GameTooltip:Show()
end

local function ToggleOnLeave()
	GameTooltip:Hide()
end

local function ToggleOnClick(self)
	if InCombatLockdown() or not FeedPetKnown() then
		return
	end
	if menu:IsShown() then
		menu:Hide()
		return
	end
	if Fill() > 0 then
		GameTooltip:Hide()
		menu:Show()
	end
end

-- Called from Build.PetHappiness with the oUF frame and its happiness icon.
function Module.AttachPetFeed(frame, icon)
	if toggle or not (C_PetInfo and C_PetInfo.CanPetEatItem) then
		return
	end

	CreateMenu(icon)

	-- A plain button over the icon. It is not secure, so it may show and hide
	-- in combat along with the icon, and it only opens the row out of combat.
	toggle = CreateFrame("Button", nil, frame.Health)
	toggle:SetAllPoints(icon)
	toggle:SetHitRectInsets(-3, -3, -3, -3)
	toggle:SetFrameLevel(frame.Health:GetFrameLevel() + 5)
	toggle:RegisterForClicks("LeftButtonUp")
	toggle:SetScript("OnEnter", ToggleOnEnter)
	toggle:SetScript("OnLeave", ToggleOnLeave)
	toggle:SetScript("OnClick", ToggleOnClick)
	toggle:Hide()

	icon.PostUpdate = function(_, happiness)
		toggle:SetShown(happiness ~= nil)
		if not happiness then
			HideMenu()
		end
	end
end
