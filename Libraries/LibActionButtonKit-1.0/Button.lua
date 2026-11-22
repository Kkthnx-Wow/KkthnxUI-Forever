--[[-----------------------------------------------------------------------------
	LibActionButtonKit-1.0
	File: Button.lua

	Creates the buttons and their regions.

	The button inherits SecureActionButtonTemplate and nothing else. The regions
	Blizzard's ActionButtonTemplate would add are built here instead, because
	that template carries a mixin and an OnAttributeChanged script that run
	Blizzard's flyout code on the frame. Building them also makes the button the
	same on every client.

	Regions are exposed as fields so the host can style them. Secure code never
	reads these fields. The library's own state is kept in Kit.data.
-----------------------------------------------------------------------------]]

local Kit = LibStub("LibActionButtonKit-1.0")
if Kit.Button then
	return
end

local pairs, next, type, assert = pairs, next, type, assert
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GameTooltip = GameTooltip
local GameTooltip_SetDefaultAnchor = GameTooltip_SetDefaultAnchor
local C_Texture = C_Texture

local Button = {}
Kit.Button = Button

local DEFAULT_SIZE = 36
local FLYOUT_ARROW_ATLAS = "UI-Journeys-Delve-Arrow-Big-Left"

-- Option defaults. A host passes only what it changes.
Kit.defaults = {
	showGrid = false,
	rangeTint = "icon",
	showCount = true,
	showMacroName = true,
	showHotKey = true,
	bindingName = nil,
	colors = {
		range = { 0.8, 0.1, 0.1 },
		mana = { 0.5, 0.5, 1.0 },
		unusable = { 0.4, 0.4, 0.4 },
	},
}

-- Copy defaults under the host's options without touching either table.
local function MergeOptions(options)
	local merged = {}
	for key, value in pairs(Kit.defaults) do
		merged[key] = value
	end
	merged.colors = {}
	for key, value in pairs(Kit.defaults.colors) do
		merged.colors[key] = value
	end
	if options then
		for key, value in pairs(options) do
			if key == "colors" then
				for colorKey, color in pairs(value) do
					merged.colors[colorKey] = color
				end
			else
				merged[key] = value
			end
		end
	end
	return merged
end
Kit.MergeOptions = MergeOptions

-- ---------------------------------------------------------------------------
-- Regions
-- ---------------------------------------------------------------------------

local function NewCooldown(button, drawEdge)
	local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
	cooldown:SetAllPoints(button)
	cooldown:SetDrawEdge(drawEdge)
	return cooldown
end

local function BuildRegions(button)
	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetAllPoints()
	button.icon = icon

	local flash = button:CreateTexture(nil, "ARTWORK")
	flash:SetAllPoints()
	flash:SetColorTexture(1, 0, 0, 0.35)
	flash:Hide()
	button.Flash = flash

	-- A light green wash over an equipped item. Hosts usually restyle it.
	local border = button:CreateTexture(nil, "OVERLAY")
	border:SetAllPoints()
	border:SetColorTexture(0, 1, 0, 0.35)
	border:Hide()
	button.Border = border

	button.cooldown = NewCooldown(button, true)
	button.chargeCooldown = NewCooldown(button, true)
	button.chargeCooldown:SetDrawSwipe(false)
	button.lossOfControlCooldown = NewCooldown(button, false)

	-- Text sits on its own frame above the cooldowns so a swipe never covers it.
	local text = CreateFrame("Frame", nil, button)
	text:SetAllPoints()
	text:SetFrameLevel(button.cooldown:GetFrameLevel() + 2)
	button.TextOverlay = text

	local hotkey = text:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmallGray")
	hotkey:SetPoint("TOPRIGHT", -2, -2)
	hotkey:SetJustifyH("RIGHT")
	button.HotKey = hotkey

	local count = text:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
	count:SetPoint("BOTTOMRIGHT", -2, 2)
	count:SetJustifyH("RIGHT")
	button.Count = count

	local name = text:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmallOutline")
	name:SetPoint("BOTTOMLEFT", 2, 2)
	name:SetPoint("BOTTOMRIGHT", -2, 2)
	name:SetWordWrap(false)
	button.Name = name

	-- Marks a button whose action is a flyout. Placed and turned by Update.
	-- baseTurn is the turn that makes the art point up, since the art sets differ.
	local arrow = text:CreateTexture(nil, "OVERLAY")
	local hasAtlas = C_Texture and C_Texture.GetAtlasInfo
	if hasAtlas and C_Texture.GetAtlasInfo(FLYOUT_ARROW_ATLAS) then
		-- Points left.
		arrow:SetAtlas(FLYOUT_ARROW_ATLAS)
		arrow:SetSize(12, 19)
		arrow.baseTurn = -math.pi / 2
	elseif hasAtlas and C_Texture.GetAtlasInfo("UI-HUD-ActionBar-Flyout") then
		arrow:SetAtlas("UI-HUD-ActionBar-Flyout", true)
		arrow.baseTurn = 0
	else
		arrow:SetTexture("Interface\\Buttons\\ActionBarFlyoutButton")
		arrow:SetTexCoord(0.625, 0.984375, 0.7421875, 0.828125)
		arrow:SetSize(18, 8)
		arrow.baseTurn = 0
	end
	arrow:Hide()
	button.FlyoutArrow = arrow

	button:SetNormalTexture(0)
	button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	button:SetCheckedTexture("Interface\\Buttons\\CheckButtonHilight")
	button:GetCheckedTexture():SetBlendMode("ADD")
end

-- ---------------------------------------------------------------------------
-- Scripts
-- ---------------------------------------------------------------------------

local function OnEnter(self)
	local data = Kit.data[self]
	local slot = data and data.slot
	if not slot or GameTooltip:IsForbidden() then
		return
	end
	GameTooltip_SetDefaultAnchor(GameTooltip, self)
	GameTooltip:SetAction(slot)
	GameTooltip:Show()
end

local function OnLeave(self)
	if not GameTooltip:IsForbidden() and GameTooltip:GetOwner() == self then
		GameTooltip:Hide()
	end
end

-- ---------------------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------------------

-- Create a button on a bar. The bar must be a protected frame that inherits
-- SecureHandlerStateTemplate. index is the button's place on a page, 1 to 12,
-- and becomes its ID, which Blizzard's CalculateAction pairs with the bar's
-- actionpage attribute. name is the button's global name and is required.
-- Out of combat only.
function Kit:CreateButton(bar, index, name, options)
	assert(not InCombatLockdown(), "LibActionButtonKit: CreateButton is not allowed in combat")
	assert(bar and bar.IsProtected and bar:IsProtected(), "LibActionButtonKit: the bar must be a protected frame")
	assert(
		type(index) == "number" and index >= 1 and index <= Kit.SLOTS_PER_PAGE,
		"LibActionButtonKit: index must be 1 to " .. Kit.SLOTS_PER_PAGE
	)
	-- The flyout's restricted code knows which button opened it only by name.
	assert(type(name) == "string" and name ~= "", "LibActionButtonKit: a button needs a global name")

	local button = CreateFrame("CheckButton", name, bar, "SecureActionButtonTemplate")
	button:SetSize(DEFAULT_SIZE, DEFAULT_SIZE)
	button:SetID(index)

	-- The same attributes Blizzard's ActionBarActionButtonMixin:OnLoad sets.
	button:SetAttribute("type", "action")
	button:SetAttribute("typerelease", "actionrelease")
	button:SetAttribute("useparent-actionpage", true)
	button:SetAttribute("checkselfcast", true)
	button:SetAttribute("checkfocuscast", true)
	button:SetAttribute("checkmouseovercast", true)
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:RegisterForDrag("LeftButton", "RightButton")

	BuildRegions(button)

	button:SetScript("OnEnter", OnEnter)
	button:SetScript("OnLeave", OnLeave)

	Kit.data[button] = {
		bar = bar,
		index = index,
		options = MergeOptions(options),
		-- Starts known as not glowing, so only real changes fire a callback.
		glowing = false,
	}

	local list = Kit.barButtons[bar]
	if not list then
		list = {}
		Kit.barButtons[bar] = list
		Kit.Secure.WatchBar(bar)
	end
	list[#list + 1] = button

	Kit.Secure.SetupButton(button)
	Kit.Flyout.SetupButton(button)
	Kit.Events.Resolve(button)

	Kit:Fire("ButtonCreated", button)
	return button
end

-- Replace a button's options and redraw it. Safe in combat: options only change
-- what is drawn, never an attribute.
function Kit:SetOptions(button, options)
	local data = Kit.data[button]
	if not data then
		return
	end
	data.options = MergeOptions(options)
	Kit.Update.Refresh(button)
end

-- The action slot a button shows right now, or nil when its bar has no page yet.
function Kit:GetSlot(button)
	local data = Kit.data[button]
	return data and data.slot
end

-- Every button the library made, for hosts that iterate them. Yields buttons
-- only, never the library's own data.
function Kit:IterateButtons()
	local button
	return function()
		button = next(Kit.data, button)
		return button
	end
end
