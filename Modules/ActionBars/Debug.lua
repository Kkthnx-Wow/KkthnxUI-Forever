--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/Debug.lua
	Purpose:
		Read what the cooldown APIs really hand back for our action buttons, so the
		library's cooldown path can be matched to the client instead of guessed.

		For every library button with an action it records which cooldown APIs
		exist, what GetActionCooldown, GetActionCharges and the duration getters
		return, which of those values are secret, and what the button's cooldown
		frames show. Secret values are never printed or compared, only flagged.

			put a spell on cooldown, use a charge spell, get stunned
			/kkdebug actioncd
			/kkdebug dump actioncd
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local Debug = K.Debug

local pairs, ipairs, pcall, type, tostring, select = pairs, ipairs, pcall, type, tostring, select
local unpack, maxn, sort, concat, wipe = unpack, table.maxn, table.sort, table.concat, wipe
local format = string.format
local CreateFrame = CreateFrame
local LibStub = LibStub
local InCombatLockdown = InCombatLockdown
local C_ActionBar = C_ActionBar

local issecretvalue = _G.issecretvalue or function()
	return false
end

local stream = Debug.Register("actioncd", "Action button cooldown values, one pass per /kkdebug actioncd")

-- A value as text, or a marker when it is secret.
local function Show(value)
	if issecretvalue(value) then
		return "<secret>"
	end
	return tostring(value)
end

-- Every field of an info table in a stable order, or the loose values.
local function Describe(...)
	local first = ...
	if type(first) == "table" and not issecretvalue(first) then
		local keys = {}
		for key in pairs(first) do
			keys[#keys + 1] = key
		end
		sort(keys)
		local parts = {}
		for i = 1, #keys do
			parts[i] = keys[i] .. "=" .. Show(first[keys[i]])
		end
		return "{" .. concat(parts, " ") .. "}"
	end
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = Show((select(i, ...)))
	end
	return concat(parts, ", ")
end

-- Run a getter, so one that errors on this client reports instead of stopping
-- the pass.
local function Call(fn, ...)
	if not fn then
		return "missing"
	end
	local result = { pcall(fn, ...) }
	if not result[1] then
		return "error: " .. tostring(result[2])
	end
	return Describe(unpack(result, 2, maxn(result)))
end

local function Has(object, name)
	return object and object[name] ~= nil and "yes" or "no"
end

local scratchCooldown

local function Probe()
	local kit = LibStub and LibStub("LibActionButtonKit-1.0", true)
	if not kit then
		K.Print("LibActionButtonKit is not loaded.")
		return
	end

	-- Each pass replaces the last, so a dump reads one moment.
	wipe(stream.lines)
	-- One scratch cooldown, made on the first dump and reused after.
	scratchCooldown = scratchCooldown or CreateFrame("Cooldown")
	local scratch = scratchCooldown
	stream:Push(format(
		"apis: GetActionCooldownDuration=%s GetActionChargeDuration=%s GetActionLossOfControlCooldownDuration=%s SetCooldownFromDurationObject=%s issecretvalue=%s combat=%s",
		Has(C_ActionBar, "GetActionCooldownDuration"),
		Has(C_ActionBar, "GetActionChargeDuration"),
		Has(C_ActionBar, "GetActionLossOfControlCooldownDuration"),
		Has(scratch, "SetCooldownFromDurationObject"),
		_G.issecretvalue and "yes" or "no",
		tostring(InCombatLockdown())
	))
	stream:Push("library path: " .. (kit.features.durationObjects and "duration objects" or "start and duration values"))

	local api = kit.api
	local count = 0
	for button in kit:IterateButtons() do
		local slot = kit:GetSlot(button)
		if slot and api.HasAction(slot) and button:IsVisible() then
			count = count + 1
			stream:Push(format("%s slot %d", button:GetName(), slot))
			stream:Push("  GetActionCooldown " .. Call(api.GetActionCooldown, slot))
			stream:Push("  GetActionCharges " .. Call(api.GetActionCharges, slot))
			stream:Push("  GetActionLossOfControlCooldownInfo " .. Call(api.GetActionLossOfControlCooldownInfo, slot))
			stream:Push("  GetActionCooldownDuration " .. Call(api.GetActionCooldownDuration, slot))
			stream:Push("  GetActionChargeDuration " .. Call(api.GetActionChargeDuration, slot))
			stream:Push("  GetActionLossOfControlCooldownDuration " .. Call(api.GetActionLossOfControlCooldownDuration, slot))
			for _, key in ipairs({ "cooldown", "chargeCooldown", "lossOfControlCooldown" }) do
				local cooldown = button[key]
				stream:Push(format("  %s shown=%s times %s", key, Show(cooldown:IsShown()), Call(cooldown.GetCooldownTimes, cooldown)))
			end
		end
	end

	K.Print(format("Action cooldowns read for %d buttons. /kkdebug dump actioncd to see them.", count))
end

Debug.Command("actioncd", "Read the cooldown values our action buttons get from the game", Probe)
