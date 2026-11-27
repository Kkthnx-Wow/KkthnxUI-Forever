--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/BlizzardFixes.lua
	Purpose:
		Work around bugs in the game's own interface code. Each fix names the
		Blizzard file and function it covers, why it breaks, and when it can go.
		Fixes touch as little as possible and make no protected calls.
-----------------------------------------------------------------------------]]

local C_Timer = C_Timer
local C_AddOns = C_AddOns
local CreateFrame = CreateFrame
local UnitClassBase = UnitClassBase

--[[
	Gamepad pet button flash (Blizzard_GamepadActionBars/Camelot/PetActionFlyout.lua)

	For hunters and warlocks the game mixes PetActionFlyoutButtonMixin into
	GamepadMainActionBarFrame.PageUnit.LeftClassAction at login. Its SetFlashing
	also flashes self.popup.AttackButton, but self.popup is only set when
	UpdateFlyoutPopup runs. OnShow, OnHide, PET_BAR_UPDATE and UNIT_FLAGS all
	reach SetFlashing before that, so the pet attacking throws
	"attempt to index field 'popup' (a nil value)". When it throws inside the
	first ToggleFlash the ticker it just started keeps running and repeats the
	error every flash.

	The replacement below is the same logic with one change: the popup's attack
	button only flashes when a popup is attached. It is set on that one button,
	not on the shared mixin. Only UpdateFlash reads SetFlashing and only
	SetFlashing reads flashTicker, so no other Blizzard path reads a value we
	wrote. Nothing in it is protected, so it is safe to run in combat.

	Seen on build 1.60.1.70959. Remove once PetActionFlyout.lua guards self.popup.
]]
local function PetFlyoutSetFlashing(self, enabled)
	local function ToggleFlash(shouldShow)
		if shouldShow == nil then
			shouldShow = not self.Flash:IsShown()
		end

		local popup = self.popup
		local attackButton = popup and popup.AttackButton
		if attackButton and attackButton.Flash then
			attackButton.Flash:SetShown(shouldShow)
		end
		self.Flash:SetShown(shouldShow)
	end

	if enabled then
		if not self.flashTicker then
			self.flashTicker = C_Timer.NewTicker(ATTACK_BUTTON_FLASH_TIME or 0.4, function()
				ToggleFlash()
			end)
			ToggleFlash(true)
		end
	elseif self.flashTicker then
		self.flashTicker:Cancel()
		self.flashTicker = nil
		ToggleFlash(false)
	end
end

local petFlashFixed = false

local function FixGamepadPetFlash()
	if petFlashFixed then
		return
	end

	if not (C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_GamepadActionBars")) then
		return
	end

	local className = UnitClassBase and UnitClassBase("player")
	if className ~= "HUNTER" and className ~= "WARLOCK" then
		return
	end

	local bar = _G.GamepadMainActionBarFrame
	local page = bar and bar.PageUnit
	local button = page and page.LeftClassAction
	-- Only patch the button the game actually gave the pet flyout mixin to.
	if not (button and button.SetFlashing and button.UpdateFlash and button.IsPetAttacking and button.Flash) then
		return
	end

	petFlashFixed = true

	-- A ticker the broken version started before we got here would keep calling
	-- the old closure, so stop it and let the fixed version start over.
	local oldTicker = button.flashTicker
	if oldTicker then
		oldTicker:Cancel()
		button.flashTicker = nil
	end

	button.SetFlashing = PetFlyoutSetFlashing
	button:UpdateFlash()
end

-- The game applies the mixin from its own PLAYER_LOGIN callback. Waiting one
-- frame past login makes sure that has run whatever order the handlers fire in.
local loader = CreateFrame("Frame")
loader:RegisterEvent("PLAYER_LOGIN")
loader:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	self:SetScript("OnEvent", nil)
	C_Timer.After(0, FixGamepadPetFlash)
end)
