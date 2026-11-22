--[[-----------------------------------------------------------------------------
	LibActionButtonKit-1.0
	File: Flyout.lua

	Flyout actions (Summon Demon, Blessings, Shapeshift and so on) open the
	library's own secure flyout, never Blizzard's SpellFlyout.

	Why not SpellFlyout: a secure click on a flyout action calls
	(self.popup or SpellFlyout):Toggle(self, ...) (SecureTemplates.lua), and
	Toggle then calls back into the owner button (TogglePopup and its popup
	fields). On an addon button those are addon values, so SpellFlyout's own
	state would be written under taint, and its popup buttons cast through Lua
	that reads that state. One flyout click could break casting from it.

	How it works:
	- Out of combat, the known spells of every flyout are stored as attributes
	  on one secure frame: "fly-<id>-n" is the count, "fly-<id>-<i>" each spell.
	  Enough secure spell buttons are made to hold the longest flyout.
	- Each library button's OnClick is wrapped in restricted code. When its slot
	  holds a flyout, the snippet fills, places and shows the flyout buttons and
	  stops the normal click. Any other action clicks as usual.
	- A flyout button casts its spell like any secure spell button, then closes
	  the flyout.
-----------------------------------------------------------------------------]]

local Kit = LibStub("LibActionButtonKit-1.0")
if Kit.Flyout then
	return
end

local _G = _G
local format, max, pcall, tostring = format, math.max, pcall, tostring
local CreateFrame = CreateFrame
local SecureHandlerWrapScript = SecureHandlerWrapScript
local SecureHandlerSetFrameRef = SecureHandlerSetFrameRef
local GetNumFlyouts, GetFlyoutID = GetNumFlyouts, GetFlyoutID
local GetFlyoutInfo, GetFlyoutSlotInfo = GetFlyoutInfo, GetFlyoutSlotInfo
local GetSpellTexture = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
local GameTooltip = GameTooltip

local Flyout = {}
Kit.Flyout = Flyout

local GAP = 4

-- ---------------------------------------------------------------------------
-- Snippets (restricted code)
-- ---------------------------------------------------------------------------

-- On a library button's click. self is the button, owner the flyout frame.
-- Returning nothing lets the click go on to the button's action, returning
-- false stops it.
local OPEN_SNIPPET = format([[
	local page = tonumber(self:GetParent():GetAttribute("actionpage"))
	local slot = page and (self:GetID() + (page - 1) * %d)
	local kind, id
	if slot then
		kind, id = GetActionInfo(slot)
	end
	if kind ~= "flyout" then
		-- Any other action closes an open flyout, as the stock bars do.
		if owner:IsShown() then
			owner:Hide()
		end
		return
	end
	-- One toggle per press: act on the release only.
	if down then
		return false
	end
	if owner:IsShown() and owner:GetAttribute("kit-opener") == self:GetName() then
		owner:Hide()
		return false
	end
	local key = "fly-" .. id .. "-"
	local count = owner:GetAttribute(key .. "n") or 0
	if count == 0 then
		owner:Hide()
		return false
	end
	owner:SetAttribute("kit-opener", self:GetName())

	local direction = self:GetParent():GetAttribute("kit-flyoutdir") or "UP"
	local size = self:GetWidth()
	local previous = self
	for i = 1, owner:GetAttribute("kit-buttons") or 0 do
		local button = owner:GetFrameRef("b" .. i)
		if i <= count then
			button:SetAttribute("spell", owner:GetAttribute(key .. i))
			button:SetWidth(size)
			button:SetHeight(size)
			button:ClearAllPoints()
			if direction == "DOWN" then
				button:SetPoint("TOP", previous, "BOTTOM", 0, -%d)
			elseif direction == "LEFT" then
				button:SetPoint("RIGHT", previous, "LEFT", -%d, 0)
			elseif direction == "RIGHT" then
				button:SetPoint("LEFT", previous, "RIGHT", %d, 0)
			else
				button:SetPoint("BOTTOM", previous, "TOP", 0, %d)
			end
			button:Show()
			previous = button
		else
			button:Hide()
		end
	end
	owner:Show()
	return false
]], Kit.SLOTS_PER_PAGE, GAP, GAP, GAP, GAP)

-- After a flyout button's click has cast, close the flyout.
local CLOSE_SNIPPET = [[
	owner:Hide()
]]

-- When the button that opened the flyout hides (its bar gave way to a vehicle,
-- or the host hid it), the flyout would float on with nothing under it.
local OPENER_HIDE_SNIPPET = [[
	if owner:IsShown() and owner:GetAttribute("kit-opener") == self:GetName() then
		owner:Hide()
	end
]]

-- ---------------------------------------------------------------------------
-- The flyout frame and its buttons
-- ---------------------------------------------------------------------------

local frame = CreateFrame("Frame", "LibActionButtonKitFlyout", UIParent, "SecureHandlerBaseTemplate")
frame:SetSize(1, 1)
frame:SetPoint("CENTER")
frame:SetFrameStrata("DIALOG")
frame:Hide()
Flyout.frame = frame
Flyout.buttons = {}

local function ButtonOnEnter(self)
	local spell = self:GetAttribute("spell")
	if spell and not GameTooltip:IsForbidden() then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetSpellByID(spell)
		GameTooltip:Show()
	end
end

local function ButtonOnLeave(self)
	if not GameTooltip:IsForbidden() and GameTooltip:GetOwner() == self then
		GameTooltip:Hide()
	end
end

-- The snippet sets "spell", this draws it. Only reads.
local function ButtonOnAttributeChanged(self, name, value)
	if name == "spell" then
		self.icon:SetTexture(value and GetSpellTexture(value) or nil)
	end
end

local function NewButton(index)
	local name = "LibActionButtonKitFlyoutButton" .. index
	local button = CreateFrame("CheckButton", name, frame, "SecureActionButtonTemplate")
	button:SetSize(36, 36)
	button:SetAttribute("type", "spell")
	-- One click per press, released, so the close after it never races the cast.
	button:RegisterForClicks("AnyUp")
	button:SetAttribute("useOnKeyDown", false)
	button:Hide()

	local icon = button:CreateTexture(nil, "BACKGROUND")
	icon:SetAllPoints()
	button.icon = icon
	button:SetPushedTexture("Interface\\Buttons\\UI-Quickslot-Depress")
	button:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")

	button:SetScript("OnEnter", ButtonOnEnter)
	button:SetScript("OnLeave", ButtonOnLeave)
	button:HookScript("OnAttributeChanged", ButtonOnAttributeChanged)

	SecureHandlerSetFrameRef(frame, "b" .. index, button)
	-- This client rejects a nil pre-body, and the post-body only runs when the
	-- pre-body returns a message, so pass one through unchanged.
	SecureHandlerWrapScript(button, "OnClick", frame, "return nil, true", CLOSE_SNIPPET)

	Flyout.buttons[index] = button
	Kit:Fire("FlyoutButtonCreated", button)
	return button
end

-- ---------------------------------------------------------------------------
-- Spell data
-- ---------------------------------------------------------------------------

-- Store the known spells of every flyout on the frame, and make enough buttons
-- for the longest one. Out of combat, queued while fighting.
local function Rebuild()
	if not (GetNumFlyouts and GetFlyoutID and GetFlyoutInfo and GetFlyoutSlotInfo) then
		return
	end
	local longest = 0
	for f = 1, GetNumFlyouts() do
		local id = GetFlyoutID(f)
		local _, _, numSlots = GetFlyoutInfo(id)
		local count = 0
		for s = 1, numSlots or 0 do
			local spellID, overrideSpellID, isKnown = GetFlyoutSlotInfo(id, s)
			if isKnown and spellID then
				count = count + 1
				frame:SetAttribute(format("fly-%d-%d", id, count), overrideSpellID or spellID)
			end
		end
		frame:SetAttribute(format("fly-%d-n", id), count)
		longest = max(longest, count)
	end
	for i = #Flyout.buttons + 1, longest do
		NewButton(i)
	end
	frame:SetAttribute("kit-buttons", #Flyout.buttons)
end

function Flyout.Rebuild()
	Kit:RunOutOfCombat("kit-flyouts", Rebuild)
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:RegisterEvent("SPELLS_CHANGED")
pcall(watcher.RegisterEvent, watcher, "SPELL_FLYOUT_UPDATE")
watcher:SetScript("OnEvent", Flyout.Rebuild)

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

-- Wrap a library button's click so a flyout action opens our flyout, and its
-- hide so the flyout closes with it. Called once per button from CreateButton,
-- out of combat.
function Flyout.SetupButton(button)
	SecureHandlerWrapScript(button, "OnClick", frame, OPEN_SNIPPET)
	SecureHandlerWrapScript(button, "OnHide", frame, OPENER_HIDE_SNIPPET)
end

-- ---------------------------------------------------------------------------
-- Telling the host
-- ---------------------------------------------------------------------------

-- The button the open flyout belongs to, or nil. Kept from addon code that only
-- reads the frame, so a host can keep that button's bar shown while the pointer
-- is on the flyout. FlyoutShown(opener) and FlyoutHidden(opener) fire on change.
Flyout.opener = nil

local function SyncOpener()
	local name = frame:IsShown() and frame:GetAttribute("kit-opener")
	local opener = name and _G[name] or nil
	local previous = Flyout.opener
	if opener == previous then
		return
	end
	Flyout.opener = opener
	if previous then
		Kit:Fire("FlyoutHidden", previous)
	end
	if opener then
		Kit:Fire("FlyoutShown", opener)
	end
end

frame:HookScript("OnShow", SyncOpener)
frame:HookScript("OnHide", SyncOpener)
-- Opening from a second button while the flyout is up only changes the opener.
frame:HookScript("OnAttributeChanged", function(_, name)
	if name == "kit-opener" then
		SyncOpener()
	end
end)

function Kit:GetFlyoutOpener()
	return Flyout.opener
end

-- True while the pointer is on a shown flyout button. The flyout frame itself
-- is a 1 by 1 anchor, so its own IsMouseOver says nothing.
function Kit:IsMouseOverFlyout()
	if not frame:IsShown() then
		return false
	end
	local buttons = Flyout.buttons
	for i = 1, #buttons do
		local button = buttons[i]
		if button:IsShown() and button:IsMouseOver() then
			return true
		end
	end
	return false
end

-- Which way a bar's flyouts open: "UP", "DOWN", "LEFT" or "RIGHT".
function Kit:SetFlyoutDirection(bar, direction)
	Kit:RunOutOfCombat("kit-flyoutdir-" .. tostring(bar), function()
		bar:SetAttribute("kit-flyoutdir", direction)
		Kit.Events.ResolveBar(bar)
	end)
end
