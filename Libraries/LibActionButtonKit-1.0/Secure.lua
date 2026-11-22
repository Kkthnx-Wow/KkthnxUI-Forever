--[[-----------------------------------------------------------------------------
	LibActionButtonKit-1.0
	File: Secure.lua

	Everything that decides what a click or a drag does: paging and drag and drop.

	Paging follows Blizzard's own model (Blizzard_FrameXML/SecureTemplates.lua,
	CalculateAction). A button with an ID resolves its slot as
	ID + (actionpage - 1) * 12, and reads actionpage from its parent because the
	button carries useparent-actionpage. So the bar only has to set actionpage,
	and its state snippet does that in restricted code, which is allowed in
	combat. Addon code never computes the slot a click uses.

	Drag and drop runs in restricted code too, through SecureHandlerWrapScript
	(Blizzard_RestrictedAddOnEnvironment/SecureHandlers.lua, Wrapped_Drag). A
	drag snippet that returns "action", slot makes the game call PickupAction on
	that slot itself, which also places whatever the cursor holds. That works in
	combat, the same as the stock bars.

	Restricted code cannot read CVars, so the action bar lock is copied onto
	each button as the attribute "kit-locked", out of combat.

	Key presses and mouse clicks: the secure template's own OnClick cannot tell
	them apart, so with "cast on key press" on, the mouse press that starts a
	drag would cast. Hosts bind keys with the virtual mouse button "Keybind"
	(SetOverrideBindingClick(owner, false, key, buttonName, "Keybind")). A
	snippet wrapped on OnClick then sets useOnKeyDown for that one press: the
	key down setting for "Keybind", always release for the mouse. A drag never
	sends the release to the button, so it never casts. This is how Blizzard's
	own buttons behave (isSecureMousePress in SecureActionButton_OnClick).
-----------------------------------------------------------------------------]]

local Kit = LibStub("LibActionButtonKit-1.0")
if Kit.Secure then
	return
end

local format, pairs, tonumber = format, pairs, tonumber
local CreateFrame = CreateFrame
local RegisterStateDriver = RegisterStateDriver
local UnregisterStateDriver = UnregisterStateDriver
local SecureCmdOptionParse = SecureCmdOptionParse
local SecureHandlerWrapScript = SecureHandlerWrapScript
local SecureHandlerSetFrameRef = SecureHandlerSetFrameRef
-- The native API where the client has it. The global of the same name is a Lua
-- wrapper around it on newer clients and the native call on older ones.
local GetCVarBool = (C_CVar and C_CVar.GetCVarBool) or GetCVarBool

local Secure = {}
Kit.Secure = Secure

-- ---------------------------------------------------------------------------
-- Snippets (restricted code)
-- ---------------------------------------------------------------------------

-- On every page change. newstate is what the driver conditions picked, a page
-- number as text. A page change swaps the actions under the buttons, so an open
-- flyout no longer matches what it was opened from and closes.
local PAGE_SNIPPET = [[
	local page = tonumber(newstate)
	if page and page > 0 then
		self:SetAttribute("actionpage", page)
		local flyout = self:GetFrameRef("kit-flyout")
		if flyout and flyout:IsShown() then
			flyout:Hide()
		end
	end
]]

-- The slot under a button, the same formula CalculateAction uses. %d is the
-- number of slots on a page, filled in once below.
local SLOT_SNIPPET = [[
	local page = tonumber(self:GetParent():GetAttribute("actionpage"))
	local slot = page and (self:GetID() + (page - 1) * %d)
]]

-- Picking an action up. A locked bar only gives one up with the pickup modifier
-- held (shift by default), like the stock bars. Returning false does nothing.
local DRAG_START_SNIPPET = format(SLOT_SNIPPET, Kit.SLOTS_PER_PAGE) .. [[
	if not slot or not HasAction(slot) then
		return false
	end
	if self:GetAttribute("kit-locked") and not IsModifiedClick("PICKUPACTION") then
		return false
	end
	return "action", slot
]]

-- Dropping onto a button. kind is what the cursor holds. PickupAction on the
-- slot places it and picks up whatever was there, so slots swap.
local RECEIVE_DRAG_SNIPPET = format(SLOT_SNIPPET, Kit.SLOTS_PER_PAGE) .. [[
	if not slot or not kind then
		return false
	end
	return "action", slot
]]

-- Before every click. Decides, for this press only, whether the action fires on
-- the press or the release. "kit-keydown" is the host's choice (true, false, or
-- unset to follow the game setting copied into "kit-cvarkeydown").
local CLICK_SNIPPET = [[
	if button == "Keybind" then
		local keyDown = self:GetAttribute("kit-keydown")
		if keyDown == nil then
			keyDown = self:GetAttribute("kit-cvarkeydown")
		end
		self:SetAttribute("useOnKeyDown", keyDown and true or false)
	else
		self:SetAttribute("useOnKeyDown", false)
	end
]]

-- ---------------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------------

-- Redraw a bar's buttons when its page changes. The hook only reads: the
-- attribute was already set by restricted code. Called once per bar from
-- CreateButton, out of combat.
function Secure.WatchBar(bar)
	SecureHandlerSetFrameRef(bar, "kit-flyout", Kit.Flyout.frame)
	bar:HookScript("OnAttributeChanged", function(self, name)
		if name == "actionpage" then
			Kit.Events.ResolveBar(self)
		end
	end)
end

-- Page a bar from macro conditions, for example "[bonusbar:1] 7; [bar:2] 2; 1".
-- Every result must be a page number. Out of combat only, queued otherwise.
function Kit:SetPaging(bar, conditions)
	Kit:RunOutOfCombat(bar, function()
		bar:SetAttribute("_onstate-page", PAGE_SNIPPET)
		RegisterStateDriver(bar, "page", conditions)
		-- The driver only writes on a change, so set the page it would pick now.
		local page = tonumber((SecureCmdOptionParse(conditions)))
		bar:SetAttribute("actionpage", page or 1)
	end)
end

-- Fix a bar to one page of the action table.
function Kit:SetFixedPage(bar, page)
	Kit:RunOutOfCombat(bar, function()
		UnregisterStateDriver(bar, "page")
		bar:SetAttribute("actionpage", page)
	end)
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

-- Game settings the snippets need, by the attribute they are copied into.
local SETTINGS = {
	["kit-locked"] = "lockActionBars",
	["kit-cvarkeydown"] = "ActionButtonUseKeyDown",
}

local function CopySettings(button)
	for attribute, cvar in pairs(SETTINGS) do
		button:SetAttribute(attribute, GetCVarBool(cvar) and true or false)
	end
end

-- Wrap the click and drag scripts with the bar as the secure header. Called once
-- per button, from CreateButton, which is already out of combat.
function Secure.SetupButton(button)
	local bar = Kit.data[button].bar
	SecureHandlerWrapScript(button, "OnClick", bar, CLICK_SNIPPET)
	SecureHandlerWrapScript(button, "OnDragStart", bar, DRAG_START_SNIPPET)
	SecureHandlerWrapScript(button, "OnReceiveDrag", bar, RECEIVE_DRAG_SNIPPET)
	CopySettings(button)
end

-- Whether a key press fires the action on the press (true), the release
-- (false), or as the game setting says (nil). Mouse clicks always fire on the
-- release. Out of combat, queued otherwise.
function Kit:SetKeyDown(button, value)
	Kit:RunOutOfCombat(button, function()
		button:SetAttribute("kit-keydown", value)
	end)
end

-- Keep the copied settings in step. A change made in combat lands once combat
-- ends. CVAR_UPDATE names the setting by CVar on newer clients and by its old
-- text key on some older ones.
local WATCHED = {
	lockActionBars = true,
	LOCK_ACTIONBAR_TEXT = true,
	ActionButtonUseKeyDown = true,
	ACTION_BUTTON_USE_KEY_DOWN = true,
}

local settingsWatcher = CreateFrame("Frame")
settingsWatcher:RegisterEvent("CVAR_UPDATE")
settingsWatcher:SetScript("OnEvent", function(_, _, name)
	if not WATCHED[name] then
		return
	end
	Kit:RunOutOfCombat("kit-settings", function()
		for button in pairs(Kit.data) do
			CopySettings(button)
		end
	end)
end)
