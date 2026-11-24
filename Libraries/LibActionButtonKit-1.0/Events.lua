--[[-----------------------------------------------------------------------------
	LibActionButtonKit-1.0
	File: Events.lua

	One event frame for every button, and an index from action slot to the
	buttons showing it, so a slot event only touches the buttons it concerns.

	Range checks are switched on per slot with C_ActionBar.EnableActionRangeCheck.
	Blizzard's own range watcher does not count how many buttons share a slot, so
	one button can switch the check off for another. Here each slot keeps a count
	and the check is only switched off when no button shows the slot any more.

	Style: a handler with its own body is written `function handlers.EVENT()`.
	`handlers.A = handlers.B` only ever means event A reuses B's handler.
-----------------------------------------------------------------------------]]

local Kit = LibStub("LibActionButtonKit-1.0")
if Kit.Events then
	return
end

local pairs, next, type, tonumber, pcall = pairs, next, type, tonumber, pcall
local CreateFrame = CreateFrame
local issecretvalue = _G.issecretvalue or function()
	return false
end

local Events = {}
Kit.Events = Events

local api = Kit.api
local features = Kit.features
local data = Kit.data
local Update = Kit.Update

-- slot -> { [button] = true }
local bySlot = {}
-- slot -> number of buttons that asked for range checks on it
local rangeRefs = {}

-- ---------------------------------------------------------------------------
-- Slot index
-- ---------------------------------------------------------------------------

local function AddRange(slot)
	local count = (rangeRefs[slot] or 0) + 1
	rangeRefs[slot] = count
	if count == 1 and features.rangeEvent then
		api.EnableActionRangeCheck(slot, true)
	end
end

local function RemoveRange(slot)
	local count = (rangeRefs[slot] or 0) - 1
	if count > 0 then
		rangeRefs[slot] = count
		return
	end
	rangeRefs[slot] = nil
	if features.rangeEvent then
		api.EnableActionRangeCheck(slot, false)
	end
end

local function Index(button, slot)
	local set = bySlot[slot]
	if not set then
		set = {}
		bySlot[slot] = set
	end
	if not set[button] then
		set[button] = true
		AddRange(slot)
	end
end

local function Unindex(button, slot)
	local set = bySlot[slot]
	if not (set and set[button]) then
		return
	end
	set[button] = nil
	if not next(set) then
		bySlot[slot] = nil
	end
	RemoveRange(slot)
end

-- The slot a button shows, worked out the way Blizzard's CalculateAction does
-- for the click: ID + (actionpage - 1) * 12, with actionpage read from the bar.
local function SlotFor(buttonData)
	local page = tonumber(buttonData.bar:GetAttribute("actionpage"))
	if not page then
		return nil
	end
	return buttonData.index + (page - 1) * Kit.SLOTS_PER_PAGE
end

-- Recompute a button's slot, move it in the index and redraw it.
function Events.Resolve(button)
	local buttonData = data[button]
	if not buttonData then
		return
	end
	local slot = SlotFor(buttonData)
	if slot ~= buttonData.slot then
		if buttonData.slot then
			Unindex(button, buttonData.slot)
		end
		buttonData.slot = slot
		buttonData.inRange = nil
		if slot then
			Index(button, slot)
		end
	end
	Update.Refresh(button)
end

function Events.ResolveBar(bar)
	local list = Kit.barButtons[bar]
	if not list then
		return
	end
	for i = 1, #list do
		Events.Resolve(list[i])
	end
end

-- ---------------------------------------------------------------------------
-- Dispatch
-- ---------------------------------------------------------------------------

local function ForSlot(slot, fn, ...)
	local set = bySlot[slot]
	if set then
		for button in pairs(set) do
			fn(button, ...)
		end
	end
end

local function ForAll(fn, ...)
	for button in pairs(data) do
		fn(button, ...)
	end
end

-- ---------------------------------------------------------------------------
-- Handlers
-- ---------------------------------------------------------------------------

local handlers = {}

function handlers.PLAYER_ENTERING_WORLD()
	ForAll(Update.Refresh)
end

-- slot is 0 when the whole action table changed.
function handlers.ACTIONBAR_SLOT_CHANGED(slot)
	if not slot or slot == 0 then
		ForAll(Update.Refresh)
	else
		ForSlot(slot, Update.Refresh)
	end
end

-- Some spells change icon with the form or a talent.
function handlers.UPDATE_SHAPESHIFT_FORM()
	ForAll(Update.Icon)
end
handlers.SPELL_UPDATE_ICON = handlers.UPDATE_SHAPESHIFT_FORM

function handlers.UPDATE_BINDINGS()
	ForAll(Update.HotKey)
end
handlers.GAME_PAD_ACTIVE_CHANGED = handlers.UPDATE_BINDINGS

-- Checked state and the attack flash follow the same changes.
function handlers.ACTIONBAR_UPDATE_STATE()
	ForAll(Update.Checked)
	ForAll(Update.Flash)
end
handlers.TRADE_SKILL_SHOW = handlers.ACTIONBAR_UPDATE_STATE
handlers.TRADE_SKILL_CLOSE = handlers.ACTIONBAR_UPDATE_STATE
handlers.PLAYER_ENTER_COMBAT = handlers.ACTIONBAR_UPDATE_STATE
handlers.PLAYER_LEAVE_COMBAT = handlers.ACTIONBAR_UPDATE_STATE
handlers.START_AUTOREPEAT_SPELL = handlers.ACTIONBAR_UPDATE_STATE
handlers.STOP_AUTOREPEAT_SPELL = handlers.ACTIONBAR_UPDATE_STATE
-- Entering or leaving a vehicle and mounting change what reads as checked, as on
-- the game's own buttons. The vehicle events are registered for the player only.
handlers.UNIT_ENTERED_VEHICLE = handlers.ACTIONBAR_UPDATE_STATE
handlers.UNIT_EXITED_VEHICLE = handlers.ACTIONBAR_UPDATE_STATE
function handlers.COMPANION_UPDATE(kind)
	if kind == "MOUNT" then
		handlers.ACTIONBAR_UPDATE_STATE()
	end
end

function handlers.ACTIONBAR_UPDATE_COOLDOWN()
	ForAll(Update.Cooldown)
end
handlers.LOSS_OF_CONTROL_ADDED = handlers.ACTIONBAR_UPDATE_COOLDOWN
handlers.LOSS_OF_CONTROL_UPDATE = handlers.ACTIONBAR_UPDATE_COOLDOWN

function handlers.SPELL_UPDATE_CHARGES()
	ForAll(Update.Cooldown)
	ForAll(Update.Count)
end

-- Payload: a list of { slot, usable, noMana }. Values may be secret, they are
-- passed through untouched.
function handlers.ACTION_USABLE_CHANGED(changes)
	if type(changes) ~= "table" then
		ForAll(Update.Usable)
		return
	end
	for _, change in pairs(changes) do
		ForSlot(change.slot, Update.Usable, change.usable, change.noMana)
	end
end

-- Older clients, and a mount change, only say "something changed".
function handlers.ACTIONBAR_UPDATE_USABLE()
	ForAll(Update.Usable)
end
handlers.PLAYER_MOUNT_DISPLAY_CHANGED = handlers.ACTIONBAR_UPDATE_USABLE

-- Payload: slot, isInRange, checksRange. A secret answer cannot be tested, so it
-- counts as no range information rather than risk an error.
function handlers.ACTION_RANGE_CHECK_UPDATE(slot, isInRange, checksRange)
	local inRange
	if checksRange and not issecretvalue(checksRange) and not issecretvalue(isInRange) then
		inRange = isInRange and true or false
	end
	ForSlot(slot, Update.Range, inRange)
end

function handlers.BAG_UPDATE_DELAYED()
	ForAll(Update.Count)
end

-- Registered for the player only, below.
function handlers.UNIT_INVENTORY_CHANGED()
	ForAll(Update.Count)
	ForAll(Update.Equipped)
end

function handlers.PLAYER_EQUIPMENT_CHANGED()
	ForAll(Update.Equipped)
end

function handlers.UPDATE_MACROS()
	ForAll(Update.Icon)
	ForAll(Update.Text)
end

-- The cursor picked up or dropped something that could go on a bar.
function handlers.ACTIONBAR_SHOWGRID()
	Update.SetDragging(true)
end

function handlers.ACTIONBAR_HIDEGRID()
	Update.SetDragging(false)
end

function handlers.SPELL_ACTIVATION_OVERLAY_GLOW_SHOW(spellID)
	ForAll(Update.Glow, spellID, true)
end

function handlers.SPELL_ACTIVATION_OVERLAY_GLOW_HIDE(spellID)
	ForAll(Update.Glow, spellID, false)
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

local UNIT_EVENTS = {
	UNIT_INVENTORY_CHANGED = "player",
	UNIT_ENTERED_VEHICLE = "player",
	UNIT_EXITED_VEHICLE = "player",
	-- Only the player's own loss of control touches the action cooldowns.
	LOSS_OF_CONTROL_ADDED = "player",
	LOSS_OF_CONTROL_UPDATE = "player",
}

local frame = CreateFrame("Frame")
Events.frame = frame

for event in pairs(handlers) do
	-- A client without an event refuses to register it, and that event is simply
	-- skipped. This is how the usable path picks itself per client.
	local unit = UNIT_EVENTS[event]
	if unit then
		pcall(frame.RegisterUnitEvent, frame, event, unit)
	else
		pcall(frame.RegisterEvent, frame, event)
	end
end
if features.usableEvent then
	frame:UnregisterEvent("ACTIONBAR_UPDATE_USABLE")
end

frame:SetScript("OnEvent", function(_, event, ...)
	handlers[event](...)
end)

-- ---------------------------------------------------------------------------
-- Range polling, only on clients without ACTION_RANGE_CHECK_UPDATE
-- ---------------------------------------------------------------------------

if not features.rangeEvent and api.IsActionInRange then
	local POLL_SECONDS = 0.2
	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < POLL_SECONDS then
			return
		end
		elapsed = 0
		for slot in pairs(bySlot) do
			-- nil when the action has no range, true or false otherwise.
			local inRange = api.IsActionInRange(slot)
			if inRange ~= nil then
				inRange = inRange and true or false
			end
			ForSlot(slot, Update.Range, inRange)
		end
	end)
end
