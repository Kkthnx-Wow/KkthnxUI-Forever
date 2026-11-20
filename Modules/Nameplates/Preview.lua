--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Nameplates/Preview.lua
	Purpose:
		Test plates. Real nameplates only exist for units in view, so judging the
		layout means standing next to mobs. This spawns three frames through the
		real nameplate style (an enemy, a targeted enemy and a friendly name-only
		plate) pointed at the player, and fills them with stand-in content: debuff
		icons, a cast, a quest marker, an elite badge, a raid marker and private
		aura boxes. Because they are built by the same style they follow every
		nameplate setting, so spacing, overlap and clipping show up here first.

		The frames are cosmetic. They sit under a plain holder that is hidden on
		exit and whenever combat starts, since a secure frame cannot be hidden
		directly in combat but its non-secure parent can.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Nameplates")
local oUF = K.oUF

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local UnregisterUnitWatch = UnregisterUnitWatch
local ipairs = ipairs

local TARGET_ACCENT = { 1, 0.9, 0.2 }

-- x is the offset from screen centre. Wide enough apart that a full row of
-- debuffs on one plate never reaches the next.
local VARIANTS = {
	{ x = -240, pct = 62, enemy = true, elite = true, quest = true },
	{ x = 0, pct = 35, enemy = true, target = true, marker = true, private = true },
	{ x = 240, nameOnly = true },
}

local preview

-- Blizzard draws private auras into anchors we hand it, so there is nothing to
-- fill. Plain boxes at the same size and spacing show where the row will sit.
local function ShowPrivateBoxes(frame, on)
	frame.__fakeBoxes = frame.__fakeBoxes or {}
	for i = 1, frame.num or 3 do
		local box = frame.__fakeBoxes[i]
		if not box then
			box = frame:CreateTexture(nil, "ARTWORK")
			box:SetColorTexture(0.55, 0.3, 0.85, 0.9)
			frame.__fakeBoxes[i] = box
		end
		box:ClearAllPoints()
		box:SetSize(frame.size, frame.size)
		box:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", (i - 1) * (frame.size + frame.spacing), 0)
		box:SetShown(on)
	end
end

local function Decorate(plate, variant)
	local UnitFrames = K:GetModule("UnitFrames", true)

	plate:UpdateAllElements("KKUI_Preview")

	if variant.nameOnly then
		local guild = plate.GuildName
		if guild then
			local text = guild:GetText()
			if not text or text == "" then
				guild:SetText("<Guild Name>")
			end
		end
		return
	end

	local health = plate.Health
	health:SetMinMaxValues(0, 100)
	health:SetValue(variant.pct)
	-- The live hostile colour, so the preview follows the reaction palette.
	local hostile = variant.enemy and oUF.colors.reaction[2]
	if hostile then
		health:SetStatusBarColor(hostile:GetRGB())
	end
	if plate.HealthText then
		plate.HealthText:SetText(variant.pct .. "%")
	end

	if variant.elite and plate.Classification then
		plate.Classification:SetAtlas("nameplates-icon-elite-gold")
		plate.Classification.__kind = "gold"
		plate.Classification:Show()
	end
	if variant.quest and plate.QuestIcon then
		plate.QuestIcon:Show()
		plate.QuestCount:SetText("3/7")
	end
	if variant.marker and plate.RaidTargetIndicator and SetRaidTargetIconTexture then
		SetRaidTargetIconTexture(plate.RaidTargetIndicator, 8)
		plate.RaidTargetIndicator:Show()
	end
	if variant.target and plate.KKUI_Shadow then
		plate.KKUI_Shadow:SetBackdropBorderColor(TARGET_ACCENT[1], TARGET_ACCENT[2], TARGET_ACCENT[3], 1)
	end
	if plate.PrivateAuras then
		ShowPrivateBoxes(plate.PrivateAuras, variant.private == true)
	end

	-- Debuff icons and the cast come from the unit frame test mode's stand-ins.
	if UnitFrames and UnitFrames.PreviewFrame then
		UnitFrames.PreviewFrame(plate)
	end
end

local function Build()
	local db = C.Nameplate
	local holder = CreateFrame("Frame", nil, UIParent)
	holder:SetSize(1, 1)
	holder:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	holder:SetFrameStrata("MEDIUM")
	holder:Hide()
	-- A secure child cannot be hidden in combat, its plain parent can.
	holder:RegisterEvent("PLAYER_REGEN_DISABLED")
	holder:SetScript("OnEvent", function(self)
		Module:HidePreview()
		self:Hide()
	end)

	oUF:SetActiveStyle("KkthnxUI_NamePlate")
	local plates = {}
	for i, variant in ipairs(VARIANTS) do
		local plate = oUF:Spawn("player", "KKUI_NamePlatePreview" .. i)
		-- The unit watch would keep the frame on and fight the holder.
		UnregisterUnitWatch(plate)
		plate:SetParent(holder)
		plate:SetSize(db.Width, db.Height + 24)
		plate:SetPoint("CENTER", holder, "CENTER", variant.x, 0)
		plate:EnableMouse(false)
		plate.__previewNameOnly = variant.nameOnly or false
		plate:Show()
		plates[i] = plate
	end
	return { holder = holder, plates = plates }
end

function Module:HidePreview()
	if not preview or not preview.holder:IsShown() then
		return
	end
	local UnitFrames = K:GetModule("UnitFrames", true)
	for _, plate in ipairs(preview.plates) do
		if UnitFrames and UnitFrames.ClearPreview then
			UnitFrames.ClearPreview(plate)
		end
		if plate.PrivateAuras then
			ShowPrivateBoxes(plate.PrivateAuras, false)
		end
	end
	preview.holder:Hide()
end

function Module:TogglePreview()
	if InCombatLockdown() then
		K.Print("Cannot show the test plates in combat.")
		return
	end
	if not self.driver then
		K.Print("Nameplates are turned off, so there is nothing to preview.")
		return
	end

	if preview and preview.holder:IsShown() then
		self:HidePreview()
		K.Print("Test plates OFF.")
		return
	end

	-- Spawned on first use, so it costs nothing until it is asked for.
	preview = preview or Build()
	preview.holder:Show()
	for i, plate in ipairs(preview.plates) do
		Decorate(plate, VARIANTS[i])
	end
	K.Print("Test plates ON. They follow your nameplate settings. Run the command again to hide them.")
end
