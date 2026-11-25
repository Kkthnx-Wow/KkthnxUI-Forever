--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/EasyFishing.lua
	Purpose:
		Double right-click on the world to cast Fishing.

		On the second right press, out of combat, the right mouse button is bound
		for that one release to a secure button that casts Fishing. The binding is
		cleared right after the cast, after a second if the release never came,
		and the moment combat starts. Nothing is bound while mounted, swimming,
		on a flight path, with a unit under the mouse, or without Fishing.

		Fishing is read from the profession list rather than a spell ID, since the
		classic ranks each have their own ID. Forever's own profession book takes
		the fourth return of GetProfessions as Fishing.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local Module = K:GetModule("QoL")

local _G = _G
local CreateFrame = CreateFrame
local GetTime = GetTime
local GetProfessions = GetProfessions
local GetProfessionInfo = GetProfessionInfo
local InCombatLockdown = InCombatLockdown
local IsMounted = IsMounted
local IsSwimming = IsSwimming
local UnitExists = UnitExists
local UnitOnTaxi = UnitOnTaxi
local SetOverrideBindingClick = SetOverrideBindingClick
local ClearOverrideBindings = ClearOverrideBindings
local C_SpellBook = C_SpellBook
local C_Timer = C_Timer

local BUTTON_NAME = "KKUI_EasyFishButton"
-- Two right presses closer than this count as a double click.
local DOUBLE_CLICK = 0.4
-- How long the binding may wait for the release before it is dropped.
local BINDING_TIMEOUT = 1

local button
local lastPress = 0
local bound = false

local function ClearBinding()
	if bound and not InCombatLockdown() then
		ClearOverrideBindings(button)
		bound = false
	end
end

-- Each bind gets a number, so a timeout left over from an earlier bind cannot
-- clear a newer one in the middle of its click.
local bindCount = 0

local function ClearAfterTimeout(count)
	if count == bindCount then
		ClearBinding()
	end
end

-- The Fishing cast from the spell book, highest rank. nil when not known.
local function FishingSpellID()
	local _, _, _, fishing = GetProfessions()
	if not fishing then
		return
	end
	local _, _, _, _, numSpells, spellOffset = GetProfessionInfo(fishing)
	if not numSpells or numSpells < 1 or not spellOffset then
		return
	end
	local info = C_SpellBook.GetSpellBookItemInfo(spellOffset + 1, Enum.SpellBookSpellBank.Player)
	if info and info.spellID and not info.isPassive then
		return info.spellID
	end
end

local function CanFish()
	return not InCombatLockdown() and not IsMounted() and not IsSwimming() and not UnitOnTaxi("player") and not UnitExists("mouseover")
end

local function OnWorldMouseDown(_, mouseButton)
	if mouseButton ~= "RightButton" then
		return
	end
	local now = GetTime()
	local isDouble = now - lastPress < DOUBLE_CLICK
	lastPress = now
	if not isDouble or bound or not CanFish() then
		return
	end

	local spellID = FishingSpellID()
	if not spellID then
		return
	end

	-- A third press should start a new pair, not chain off this one.
	lastPress = 0
	button:SetAttribute("spell", spellID)
	SetOverrideBindingClick(button, true, "BUTTON2", BUTTON_NAME)
	bound = true
	bindCount = bindCount + 1
	local count = bindCount
	C_Timer.After(BINDING_TIMEOUT, function()
		ClearAfterTimeout(count)
	end)
end

local function OnEvent()
	-- PLAYER_REGEN_DISABLED runs before the lockdown starts, so the clear is allowed.
	ClearBinding()
end

function Module:SetupEasyFishing()
	if button or not (GetProfessions and SetOverrideBindingClick and C_SpellBook and C_SpellBook.GetSpellBookItemInfo) then
		return
	end

	-- No anchor, so it is never drawn, but it is shown and can take the click.
	button = CreateFrame("Button", BUTTON_NAME, _G.UIParent, "SecureActionButtonTemplate")
	button:RegisterForClicks("AnyUp")
	button:SetAttribute("type", "spell")
	-- The press already went to the world, so cast on the release.
	button:SetAttribute("useOnKeyDown", false)
	button:HookScript("PostClick", ClearBinding)

	-- Events on a plain frame, so the secure button only ever gets its attributes.
	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("PLAYER_REGEN_DISABLED")
	watcher:SetScript("OnEvent", OnEvent)

	_G.WorldFrame:HookScript("OnMouseDown", OnWorldMouseDown)
end
