--[[-----------------------------------------------------------------------------
	LibActionButtonKit-1.0
	File: Core.lua

	Registration, feature detection, shared state and callbacks. Every other file
	of the library reads what it needs from the table returned here through
	LibStub, so this file loads first.

	Design and the source each rule rests on: README.md next to this file.
-----------------------------------------------------------------------------]]

local MAJOR, MINOR = "LibActionButtonKit-1.0", 1

local Kit = LibStub:NewLibrary(MAJOR, MINOR)
if not Kit then
	return
end

local _G = _G
local pairs, pcall = pairs, pcall
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local C_ActionBar = C_ActionBar

-- ---------------------------------------------------------------------------
-- Private state
-- ---------------------------------------------------------------------------

-- Everything the library knows about a button lives here, keyed by the button.
-- Nothing is written onto the button table that Blizzard's secure click reads,
-- so a click never meets a value the library wrote.
Kit.data = Kit.data or {}

-- Buttons by bar, in creation order.
Kit.barButtons = Kit.barButtons or {}

-- ---------------------------------------------------------------------------
-- Feature detection
-- ---------------------------------------------------------------------------

-- Pick an API from C_ActionBar first, then the old global of the same name.
-- Classic clients keep some action functions as globals only.
local function Pick(name)
	local fromNamespace = C_ActionBar and C_ActionBar[name]
	return fromNamespace or _G[name]
end

Kit.api = {
	GetActionTexture = Pick("GetActionTexture"),
	HasAction = Pick("HasAction"),
	GetActionInfo = Pick("GetActionInfo"),
	GetActionText = Pick("GetActionText"),
	GetActionCount = Pick("GetActionCount"),
	GetActionDisplayCount = C_ActionBar and C_ActionBar.GetActionDisplayCount,
	GetActionCharges = Pick("GetActionCharges"),
	GetActionCooldown = Pick("GetActionCooldown"),
	GetActionCooldownDuration = C_ActionBar and C_ActionBar.GetActionCooldownDuration,
	GetActionChargeDuration = C_ActionBar and C_ActionBar.GetActionChargeDuration,
	GetActionLossOfControlCooldownInfo = Pick("GetActionLossOfControlCooldownInfo"),
	GetActionLossOfControlCooldownDuration = C_ActionBar and C_ActionBar.GetActionLossOfControlCooldownDuration,
	IsUsableAction = Pick("IsUsableAction"),
	IsCurrentAction = Pick("IsCurrentAction"),
	IsAutoRepeatAction = Pick("IsAutoRepeatAction"),
	IsAttackAction = Pick("IsAttackAction"),
	IsEquippedAction = Pick("IsEquippedAction"),
	IsConsumableAction = Pick("IsConsumableAction"),
	IsStackableAction = Pick("IsStackableAction"),
	IsItemAction = Pick("IsItemAction"),
	IsActionInRange = Pick("IsActionInRange"),
	EnableActionRangeCheck = C_ActionBar and C_ActionBar.EnableActionRangeCheck,
	PickupAction = Pick("PickupAction"),
	PlaceAction = Pick("PlaceAction"),
}

local api = Kit.api

-- One flag per optional feature. Checked once, here, never by client name.
Kit.features = {
	-- ACTION_USABLE_CHANGED replaced ACTIONBAR_UPDATE_USABLE in the shared
	-- ActionButton.lua. The event is probed by registering it on a scratch frame.
	usableEvent = false,
	-- Range arrives as ACTION_RANGE_CHECK_UPDATE once a slot is switched on.
	rangeEvent = api.EnableActionRangeCheck ~= nil,
	-- 12.x hands cooldowns out as duration objects that may hold secret values.
	durationObjects = api.GetActionCooldownDuration ~= nil,
}

-- One frame for the combat queue below, also used once here to ask whether the
-- client knows the event, so the probe leaves no frame behind.
local queueFrame = Kit.queueFrame or CreateFrame("Frame")
Kit.queueFrame = queueFrame

if pcall(queueFrame.RegisterEvent, queueFrame, "ACTION_USABLE_CHANGED") then
	Kit.features.usableEvent = true
	queueFrame:UnregisterEvent("ACTION_USABLE_CHANGED")
end

-- Blizzard's paging formula uses this constant. 12 on every client so far.
Kit.SLOTS_PER_PAGE = _G.NUM_ACTIONBAR_BUTTONS or 12

-- ---------------------------------------------------------------------------
-- Callbacks
-- ---------------------------------------------------------------------------

-- ButtonCreated(button), ButtonUpdated(button), GlowShown(button),
-- GlowHidden(button). Fired from addon code, never from a secure path.
local CallbackHandler = LibStub("CallbackHandler-1.0")
Kit.callbacks = Kit.callbacks or CallbackHandler:New(Kit)

function Kit:Fire(event, ...)
	self.callbacks:Fire(event, ...)
end

-- ---------------------------------------------------------------------------
-- Combat queue
-- ---------------------------------------------------------------------------

-- Anything that changes attributes, IDs, parents, points or script wraps waits
-- for combat to end. Keyed so a repeated request replaces the earlier one.
Kit.pending = Kit.pending or {}

queueFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
queueFrame:SetScript("OnEvent", function()
	local pending = Kit.pending
	for key, fn in pairs(pending) do
		pending[key] = nil
		fn()
	end
end)

-- Run fn now if out of combat, otherwise once combat ends. Returns true when it
-- ran right away.
function Kit:RunOutOfCombat(key, fn)
	if InCombatLockdown() then
		self.pending[key] = fn
		return false
	end
	fn()
	return true
end
