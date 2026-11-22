--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/PetBar.lua
	Purpose:
		The pet action bar. Reuses Blizzard's pet buttons: reparent them onto our
		own bar, skin them, and lay them out in a row. Blizzard keeps driving the
		pet action state. Shown only while a pet with an action bar exists.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("ActionBars")

local _G = _G
local InCombatLockdown = InCombatLockdown
local max = math.max

local NUM_PET_SLOTS = NUM_PET_ACTION_SLOTS or 10

-- Blizzard hides an empty pet button unless the grid is showing, and its own bar
-- draws slot art behind it. Ours has none, so an empty slot left a hole in the
-- row. A plain frame under each button, anchored to it, draws the same empty slot
-- the other bars show. It is not protected, so the button's own show and hide in
-- combat is left alone.
local function CreateEmptySlot(bar, button)
	local backing = CreateFrame("Frame", nil, bar)
	backing:SetAllPoints(button)
	backing:SetFrameLevel(max(button:GetFrameLevel() - 1, 0))

	local slot = backing:CreateTexture(nil, "BACKGROUND", nil, -8)
	slot:SetPoint("TOPLEFT", backing, "TOPLEFT", -2, 2)
	slot:SetPoint("BOTTOMRIGHT", backing, "BOTTOMRIGHT", 2, -2)
	slot:SetAtlas("UI-HUD-ActionBar-IconFrame-Slot")

	K.CreateBorder(backing)
	return backing
end

function Module:CreatePetBar()
	local cfg = C.ActionBar.PetBar
	if not cfg or not cfg.Enable then
		return
	end

	local bar = CreateFrame("Frame", "KKUI_PetBar", UIParent, "SecureHandlerStateTemplate")
	bar.key = "PetBar"
	bar.buttons = {}

	for i = 1, NUM_PET_SLOTS do
		local button = _G["PetActionButton" .. i]
		if button then
			button:SetParent(bar)
			self:StyleAuxButton(button)
			if C.ActionBar.ShowGrid then
				CreateEmptySlot(bar, button)
			end
			bar.buttons[i] = button
		end
	end

	self.bars.PetBar = bar
	self:LayoutPetBar()

	K.CreateMover(bar, "PetBar", L["Pet Bar"], self:AuxBarDefaultPoint(), bar:GetWidth(), bar:GetHeight())

	-- Only visible with a controllable pet, and never in a pet battle or while an
	-- override, vehicle, possess, or shapeshift bar has taken over (some quests put
	-- a bonus bar on the pet state, which otherwise showed this bar spuriously).
	RegisterStateDriver(bar, "visibility", "[petbattle][overridebar][vehicleui][possessbar][shapeshift] hide; [pet] show; hide")
	self:ApplyAuxHotKeys(bar, cfg)
	self:SetupFade(bar, cfg)

	return bar
end

-- Lay the pet buttons out from the current settings. Out of combat only.
function Module:LayoutPetBar()
	local bar = self.bars.PetBar
	if not bar then
		return
	end
	if InCombatLockdown() then
		K.DeferCombat("PetBarLayout", function()
			Module:LayoutPetBar()
		end)
		return
	end
	self:LayoutAuxGrid(bar, C.ActionBar.PetBar)
end
