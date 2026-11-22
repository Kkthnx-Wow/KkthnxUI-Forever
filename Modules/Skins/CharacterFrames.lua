--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/CharacterFrames.lua
	Purpose:
		Improve the Character and Inspect windows without restyling them. The
		stock frame, tabs and stat panel stay as Blizzard draws them. We add three
		things: a class background behind the model, more width for the paper doll,
		and on Inspect an item level line. The equipment slots get our border from
		CharacterSlots.lua.

		Built against the WoW Forever 1.60.1 frame source, which is not the Retail
		layout. The Character window is a portrait frame holding a LeftPaneHost and
		a RightPaneHost and sizes itself in UpdateSize. The Inspect window is still
		a button frame with an Inset and a PlayerModel.

		Nothing here runs inside a Blizzard code path. The first character window
		after login showed Blizzard's own status bar text failing on a secret value
		because addon code had run in the panel show chain, so this file hooks no
		Blizzard function and writes no field on a Blizzard table. The one job that
		must follow Blizzard (the width that UpdateSize resets) runs from a watcher
		frame parented to the window, which only ticks while the window is open.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("CharacterFrames")

local _G = _G
local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc
local InCombatLockdown = InCombatLockdown
local UnitClass = UnitClass
local IsSecret = K.IsSecret

-- Extra pixels given to the paper doll tab. The model, its background and both
-- slot columns are anchored to the pane edges, so they follow on their own.
local CHARACTER_EXTRA = 60
local INSPECT_EXTRA = 60

-- Blizzard's own width constants, with the 1.60.1 values as a fallback.
local FRAME_WIDTH = _G.CHARACTER_FRAME_WIDTH or 631
local FRAME_COLLAPSED_WIDTH = _G.CHARACTER_FRAME_COLLAPSED_WIDTH or 398
local INSPECT_WIDTH = 338
-- The inspect window is 60 shorter than the character window by template, which
-- pushed its slot columns up under the level line and down beside the weapon row.
-- It takes the character window's height so the same layout fits.
local INSPECT_HEIGHT = _G.CHARACTER_FRAME_HEIGHT or 484

-- Inspect slot offsets, measured in game from the character window so the two
-- line up: columns 9 in from the window sides and 79 down from the top, weapon
-- row 9 up from the bottom. The columns hang off the inset, which sits 4 in and
-- 60 down, hence the numbers below.
local INSPECT_SLOT_X = 5
local INSPECT_SLOT_Y = -20
local INSPECT_WEAPON_BOTTOM = 10
-- The character slots are spaced 6 apart, the inspect ones 4 (both read live).
local INSPECT_SLOT_GAP = -6
local INSPECT_CHAINED = {
	"Neck", "Shoulder", "Back", "Chest", "Shirt", "Tabard", "Wrist",
	"Waist", "Legs", "Feet", "Finger0", "Finger1", "Trinket0", "Trinket1",
}

local ILVL_SIZE = 12

-- The class dressing room art is an atlas per class (checked in the 1.60.1
-- client), already cropped to the painted area. Retail uses the same names.
local CLASS_ART = "dressingroom-background-"

local function Enabled()
	return C.Skins and C.Skins.CharacterFrames
end

local function Wide()
	return C.Skins and C.Skins.CharacterFramesWide
end

-- Our own edited dressing room art, one file per class in Media\Skins, named
-- DressingRoom<Class>.blp. The painting fills the top left 480 by 502 of each
-- 512 square file. A class with no file of ours keeps Blizzard's atlas.
local SKIN_ART = K.MediaFolder .. "Skins\\DressingRoom"
local SKIN_ART_FILES = {
	DRUID = "Druid",
	HUNTER = "Hunter",
	MAGE = "Mage",
	PALADIN = "Paladin",
	PRIEST = "Priest",
	ROGUE = "Rogue",
	SHAMAN = "Shaman",
	WARLOCK = "Warlock",
	WARRIOR = "Warrior",
}
local SKIN_ART_RIGHT = 480 / 512
local SKIN_ART_BOTTOM = 502 / 512
-- Our art is dimmed a little so the lit stonework does not outshine the
-- character, and it sits closer to the dark stats pane beside it. Picked by eye
-- in game against 100 and 65 percent.
local SKIN_ART_SHADE = 0.8

local function SetClassArt(texture, class)
	local file = SKIN_ART_FILES[class]
	if file then
		texture:SetTexture(SKIN_ART .. file)
		texture:SetTexCoord(0, SKIN_ART_RIGHT, 0, SKIN_ART_BOTTOM)
		texture:SetVertexColor(SKIN_ART_SHADE, SKIN_ART_SHADE, SKIN_ART_SHADE)
	else
		texture:SetTexCoord(0, 1, 0, 1)
		texture:SetVertexColor(1, 1, 1)
		texture:SetAtlas(CLASS_ART .. class)
	end
end

-- ---------------------------------------------------------------------------
-- Character window
-- ---------------------------------------------------------------------------

local leftBase

-- The width the window should have right now. UpdateSize resets it to the stock
-- value whenever the tab or the details pane changes, so this is recomputed
-- from the same two facts Blizzard uses rather than remembered.
local function CharacterTargets(frame)
	local detailsShown = frame.RightPaneHost and frame.RightPaneHost:IsShown()
	local base = detailsShown and FRAME_WIDTH or FRAME_COLLAPSED_WIDTH
	local extra = (Wide() and frame.activeSubframe == "PaperDollFrame") and CHARACTER_EXTRA or 0
	return base + extra, leftBase + extra
end

local function ApplyCharacterWidth(frame)
	if InCombatLockdown() then
		K.DeferCombat("CharacterWidth", function()
			ApplyCharacterWidth(frame)
		end)
		return
	end
	local width, leftWidth = CharacterTargets(frame)
	if frame:GetWidth() ~= width then
		frame:SetWidth(width)
	end
	local host = frame.LeftPaneHost
	if host and host:GetWidth() ~= leftWidth then
		host:SetWidth(leftWidth)
	end
end

-- Retail sits the slot columns close to the window edge and the weapon row close
-- to the bottom. Forever leaves 24px on the left, 20 on the right and 30 below.
local SLOT_EDGE = 10
local WEAPON_BOTTOM = 10

-- Move one slot's single anchor, keeping whatever else about it Blizzard chose.
-- Each column hangs off its first slot and the rest are chained, so moving the
-- first one moves the lot. Nil leaves that offset as it is.
local function NudgeSlot(slot, x, y)
	if not slot or slot:GetNumPoints() ~= 1 then
		return
	end
	local point, relativeTo, relativePoint, offsetX, offsetY = slot:GetPoint(1)
	slot:ClearAllPoints()
	slot:SetPoint(point, relativeTo, relativePoint, x or offsetX, y or offsetY)
end

local characterStyled

local function StyleCharacterFrame()
	if characterStyled then
		return
	end
	local frame = _G.CharacterFrame
	local scene = _G.CharacterModelScene
	if not (frame and frame.LeftPaneHost and scene) then
		return
	end
	characterStyled = true

	leftBase = frame.LeftPaneHost:GetWidth()

	-- Head starts the left column, Hands the right one, main hand the weapon row.
	NudgeSlot(_G.CharacterHeadSlot, SLOT_EDGE)
	NudgeSlot(_G.CharacterHandsSlot, -SLOT_EDGE)
	NudgeSlot(_G.CharacterMainHandSlot, nil, WEAPON_BOTTOM)

	-- The race background is four pieces, which Blizzard only ever gives a new
	-- texture, so hiding each one by alpha holds.
	for _, key in ipairs({ "BackgroundTopLeft", "BackgroundTopRight", "BackgroundBotLeft", "BackgroundBotRight" }) do
		local piece = scene[key]
		if piece then
			piece:SetAlpha(0)
		end
	end

	-- The darkening overlay is not hidden by alpha: SetPaperDollBackground sets its
	-- alpha back to 0.85 every time the paper doll updates, which dimmed our art to
	-- near black. It is the only region on the scene's border layer, so the whole
	-- layer is switched off instead.
	scene:DisableDrawLayer("BORDER")

	local _, class = UnitClass("player")
	if class then
		local art = scene:CreateTexture(nil, "BACKGROUND", nil, -8)
		art:SetAllPoints()
		SetClassArt(art, class)
		Module.characterArt = art
	end

	if Wide() then
		-- UpdateSize is the only thing that puts the stock width back (on show, on a
		-- tab change and on the details toggle), and ShowSubFrame decides which tab
		-- gets the extra width, so the width is re-applied after either instead of
		-- being checked every frame.
		local function Reapply()
			ApplyCharacterWidth(frame)
		end
		if frame.UpdateSize then
			hooksecurefunc(frame, "UpdateSize", Reapply)
		end
		if frame.ShowSubFrame then
			hooksecurefunc(frame, "ShowSubFrame", Reapply)
		end
		frame:HookScript("OnShow", Reapply)
		if frame:IsShown() then
			Reapply()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Inspect window (Blizzard_InspectUI, load on demand)
-- ---------------------------------------------------------------------------

local inspectStyled
local inspectArt, inspectLevel, inspectClass

local function ApplyInspectWidth(frame)
	if InCombatLockdown() then
		K.DeferCombat("InspectWidth", function()
			ApplyInspectWidth(frame)
		end)
		return
	end
	local paperDollShown = _G.InspectPaperDollFrame and _G.InspectPaperDollFrame:IsShown()
	local width = INSPECT_WIDTH + ((Wide() and paperDollShown) and INSPECT_EXTRA or 0)
	if frame:GetWidth() ~= width then
		frame:SetWidth(width)
	end
	if frame:GetHeight() ~= INSPECT_HEIGHT then
		frame:SetHeight(INSPECT_HEIGHT)
	end
end

-- Follow the inspected player: class art from their class, item level from the
-- inspect data. Both are cheap reads, done on the watcher's slow tick. The art
-- is only shown on the Character tab, the other tabs keep the stock inset.
local function RefreshInspectInfo(frame)
	local paperDoll = _G.InspectPaperDollFrame
	inspectArt:SetShown(paperDoll and paperDoll:IsShown() or false)

	local unit = frame.unit
	if not unit then
		return
	end

	local _, class = UnitClass(unit)
	if class and not IsSecret(class) and class ~= inspectClass then
		inspectClass = class
		SetClassArt(inspectArt, class)
	end

	local api = _G.C_PaperDollInfo
	local ilvl = api and api.GetInspectItemLevel and api.GetInspectItemLevel(unit)
	if ilvl and not IsSecret(ilvl) and ilvl > 0 then
		inspectLevel:SetFormattedText("%s: %d", _G.STAT_AVERAGE_ITEM_LEVEL or "Item Level", ilvl)
	else
		inspectLevel:SetText("")
	end
end

local function StyleInspectFrame()
	if inspectStyled then
		return
	end
	local frame = _G.InspectFrame
	local model = _G.InspectModelFrame
	local inset = frame and frame.Inset
	if not (frame and model and inset) then
		return
	end
	inspectStyled = true

	-- Class art sits over the inset's marble, so the marble is never touched.
	inspectArt = inset:CreateTexture(nil, "BACKGROUND", nil, -4)
	inspectArt:SetAllPoints()
	local _, class = UnitClass("player")
	if class then
		SetClassArt(inspectArt, class)
	end

	-- The race background pieces, the overlay and the ornate corner borders.
	model:DisableDrawLayer("BACKGROUND")
	model:DisableDrawLayer("BORDER")
	model:DisableDrawLayer("OVERLAY")

	if _G.InspectGuildFrameBG then
		_G.InspectGuildFrameBG:SetAlpha(0)
	end

	-- Our own item level line, between the model and the weapon row.
	local paperDoll = _G.InspectPaperDollFrame
	inspectLevel = (paperDoll or frame):CreateFontString(nil, "OVERLAY")
	K.SetFont(inspectLevel, ILVL_SIZE, K.FontOutlineStyle())
	inspectLevel:SetJustifyH("CENTER")
	inspectLevel:SetPoint("BOTTOM", inset, "BOTTOM", 0, 32)

	-- Head starts the left column and Hands the right one, the rest are chained.
	NudgeSlot(_G.InspectHeadSlot, INSPECT_SLOT_X, INSPECT_SLOT_Y)
	NudgeSlot(_G.InspectHandsSlot, -INSPECT_SLOT_X, INSPECT_SLOT_Y)
	NudgeSlot(_G.InspectMainHandSlot, nil, INSPECT_WEAPON_BOTTOM)
	for _, name in ipairs(INSPECT_CHAINED) do
		NudgeSlot(_G["Inspect" .. name .. "Slot"], nil, INSPECT_SLOT_GAP)
	end

	-- The wider layout re-centres the model and the weapon row. Done once: both
	-- are anchored to the window, so they follow the width from then on.
	if Wide() then
		model:ClearAllPoints()
		model:SetPoint("TOPLEFT", inset, "TOPLEFT", 46, -4)
		model:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -46, 48)

		local main, off, ranged = _G.InspectMainHandSlot, _G.InspectSecondaryHandSlot, _G.InspectRangedSlot
		if main and off and ranged then
			-- Three slots 37 wide with a 5 gap, centred as a row on the window.
			main:ClearAllPoints()
			main:SetPoint("BOTTOM", frame, "BOTTOM", -42, INSPECT_WEAPON_BOTTOM)
			off:ClearAllPoints()
			off:SetPoint("LEFT", main, "RIGHT", 5, 0)
			ranged:ClearAllPoints()
			ranged:SetPoint("LEFT", off, "RIGHT", 5, 0)
		end
	end

	-- The panel manager places windows from their size before showing them, so a
	-- size applied after the window opens comes too late: with the character window
	-- already up, inspect opened at the stock width and the two overlapped. Blizzard
	-- switches to the character tab through InspectSwitchTabs before ShowUIPanel,
	-- and tab clicks use it too, so the size is applied there. Always, for the
	-- height. The width only grows when the wide layout is on.
	if _G.InspectSwitchTabs then
		hooksecurefunc("InspectSwitchTabs", function()
			ApplyInspectWidth(frame)
		end)
	end
	ApplyInspectWidth(frame)

	local watcher = CreateFrame("Frame", nil, frame)
	local elapsed = 0.5
	watcher:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed >= 0.5 then
			elapsed = 0
			RefreshInspectInfo(frame)
		end
	end)
	Module.inspectWatcher = watcher
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function Module:ADDON_LOADED(_, addon)
	if addon == "Blizzard_InspectUI" then
		StyleInspectFrame()
		self:UnregisterEvent("ADDON_LOADED")
	end
end

function Module:OnEnable()
	if not Enabled() then
		return
	end

	StyleCharacterFrame()

	if C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_InspectUI") then
		StyleInspectFrame()
	else
		self:RegisterEvent("ADDON_LOADED")
	end
end
