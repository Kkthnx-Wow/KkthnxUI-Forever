--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Test.lua
	Purpose:
		Config mode. Instead of drawing throwaway mock frames, this forces the real
		frames to show with the player's own data, which is the sturdiest way to
		preview them. Individual frames (player, target, boss, and the rest) are pointed at
		the player and their unit watch is forced on. Group headers (party and raid)
		get a negative starting index so the secure header spawns its full set of
		phantom frames while solo, and each child is forced on the same way. Toggling
		off restores every frame, and nothing here runs in combat.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")

local ipairs = ipairs
local math_floor = math.floor
local math_min = math.min
local math_random = math.random
local CreateColor = CreateColor
local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc
local AbbreviateNumbers = AbbreviateNumbers
local InCombatLockdown = InCombatLockdown
local RegisterStateDriver = RegisterStateDriver
local RegisterUnitWatch = RegisterUnitWatch
local UnregisterUnitWatch = UnregisterUnitWatch

-- The standalone frames, by module key. Boss frames live in a numbered list and
-- are handled alongside these.
local INDIVIDUAL = { "Player", "Target", "TargetOfTarget", "Pet", "Focus", "FocusTarget" }

-- Header show gates cleared during config mode so the header renders phantom frames
-- while solo, then restored on the way out.
local GATES = { "showRaid", "showParty", "showSolo" }

-- ---------------------------------------------------------------------------
-- Stand-in content
-- ---------------------------------------------------------------------------
-- The aura rows are drawn by Blizzard and castbars only exist while something is
-- casting, so a forced frame would show neither. These put fake ones where the
-- real ones go, built from the same sizes and anchors, so spacing, wrapping and
-- overlap can be judged without a group, a pull or a caster. Everything here is
-- cosmetic: it is torn down on exit and never touches a real aura or cast.

local FAKE_ICONS = {
	"Interface\\Icons\\Spell_Holy_PowerWordShield",
	"Interface\\Icons\\Spell_Nature_Rejuvenation",
	"Interface\\Icons\\Spell_Shadow_ShadowWordPain",
	"Interface\\Icons\\Spell_Fire_FlameBolt",
	"Interface\\Icons\\Spell_Frost_FrostBolt02",
	"Interface\\Icons\\Spell_Holy_Renew",
	"Interface\\Icons\\Spell_Nature_Regeneration",
	"Interface\\Icons\\Spell_Shadow_CurseOfTounges",
}
-- Magic, curse, poison, disease, then an undispellable one.
local FAKE_DISPEL = { { 0.2, 0.6, 1 }, { 0.6, 0, 1 }, { 0, 0.6, 0 }, { 0.6, 0.4, 0 }, { 0.8, 0, 0 } }

local fakeIndex = 0

local function NewFakeAura(host, size, harmful, i, shadow)
	local button = CreateFrame("Frame", nil, host)
	button:SetSize(size, size)
	local c = FAKE_DISPEL[(i - 1) % #FAKE_DISPEL + 1]
	if shadow then
		-- Nameplate icons wear the soft shadow, tinted by dispel school the way the
		-- real ones are. The undispellable stand-in keeps the plain black shadow,
		-- as a real debuff with no school does.
		K.CreateShadow(button, 3)
		if harmful and i % #FAKE_DISPEL ~= 0 then
			K.SetShadowColor(button, c[1], c[2], c[3], 1)
		end
	else
		-- The addon's own border, with a debuff tinting its segments by dispel
		-- school the way the real ones do.
		K.CreateBorder(button)
		local border = button.KKUI_Border
		if harmful and border then
			for _, part in ipairs({ "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT", "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
				if border[part] then
					border[part]:SetVertexColor(c[1], c[2], c[3], 1)
				end
			end
		end
	end
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 1, -1)
	icon:SetPoint("BOTTOMRIGHT", -1, 1)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	icon:SetTexture(FAKE_ICONS[(i - 1) % #FAKE_ICONS + 1])
	local count = button:CreateFontString(nil, "OVERLAY")
	K.SetFont(count, 10, K.FontOutlineStyle())
	count:SetPoint("BOTTOMRIGHT", 2, -1)
	count:SetText(i % 3 == 0 and (i % 5 + 2) or "")
	local time = button:CreateFontString(nil, "OVERLAY")
	K.SetFont(time, 10, K.FontOutlineStyle())
	time:SetPoint("CENTER", 0, 0)
	time:SetText(i % 2 == 0 and (i * 7) or "")
	return button
end

-- Lay stand-in icons out the way the flow layout does: from the anchor corner,
-- along the horizontal growth, wrapping to the vertical growth after perRow.
local function PreviewContainer(container)
	local opts = container.__kkuiOpts
	if not opts then
		return
	end
	local size, spacing = opts.size or 26, opts.spacing or 6
	local perRow = opts.perRow or 8
	local total = 0
	for _, slot in ipairs(opts.slots or {}) do
		total = total + (slot.max or 8)
	end
	local count = math_min(total, perRow * 2)
	if count < 1 then
		return
	end

	local fakes = container.__kkuiFakes
	if not fakes then
		fakes = {}
		container.__kkuiFakes = fakes
		local first = opts.slots and opts.slots[1]
		local harmful = first and type(first.filter) == "string" and first.filter:find("HARMFUL", 1, true) ~= nil
		local stepX = (size + spacing) * (opts.growthH == "Left" and -1 or 1)
		local stepY = (size + spacing) * (opts.growthV == "Up" and 1 or -1)
		local anchor = opts.anchorPoint or "TOPLEFT"
		for i = 1, count do
			local fake = NewFakeAura(container, size, harmful, i, opts.shadow)
			fake:SetPoint(anchor, container, anchor, ((i - 1) % perRow) * stepX, math_floor((i - 1) / perRow) * stepY)
			fakes[i] = fake
		end
	end
	-- Above the real icons, which are hidden so the two never double up.
	container:SetAlpha(0)
	local parent = container:GetParent()
	local level = (parent and parent:GetFrameLevel() or 1) + 12
	for _, fake in ipairs(fakes) do
		fake:SetFrameLevel(level)
		fake:SetIgnoreParentAlpha(true)
		fake:Show()
	end
	container.__kkuiFakesShown = true
end

local function ClearContainer(container)
	if not container.__kkuiFakesShown then
		return
	end
	container.__kkuiFakesShown = nil
	container:SetAlpha(1)
	for _, fake in ipairs(container.__kkuiFakes or {}) do
		fake:Hide()
	end
end

-- Gives the castbar its oUF OnUpdate back. That OnUpdate hides a bar with no cast
-- in progress, so it is held off while the stand-in is shown.
local function ReleaseCast(cast)
	cast.__kkuiFake = nil
	if cast.__kkuiHeldUpdate then
		cast:SetScript("OnUpdate", cast.__kkuiHeldUpdate)
		cast.__kkuiHeldUpdate = nil
	end
end

-- A half finished cast, held still. Hidden again on exit, and a real cast starting
-- takes over through oUF as usual.
local function PreviewCast(cast, spell)
	if not cast then
		return
	end
	if not cast.__kkuiFake then
		cast.__kkuiHeldUpdate = cast:GetScript("OnUpdate")
		cast:SetScript("OnUpdate", nil)
	end
	if not cast.__kkuiCastHooked and cast.PostCastStart then
		cast.__kkuiCastHooked = true
		hooksecurefunc(cast, "PostCastStart", ReleaseCast)
	end
	cast:SetMinMaxValues(0, 1)
	cast:SetValue(0.6)
	local castColor = K.CastColors.cast
	cast:SetStatusBarColor(castColor[1], castColor[2], castColor[3])
	if cast.Text then
		cast.Text:SetText(spell or "Fake Spell Name")
	end
	if cast.Time then
		cast.Time:SetText("1.2")
	end
	if cast.Icon then
		cast.Icon:SetTexture(FAKE_ICONS[2])
	end
	cast.__kkuiFake = true
	cast:Show()
end

local function ClearCast(cast)
	if cast and cast.__kkuiFake then
		ReleaseCast(cast)
		cast:Hide()
	end
end

-- Health bar and value at a spread of fill levels, so the missing health, percent
-- and current looks all have something to show. Group frames only, since the
-- others already read well off the player's own numbers.
local FAKE_LEVELS = { 100, 73, 45, 18, 88, 60, 32, 96 }
local FAKE_MAX = 58300

local function SampleHealthText(mode, pct)
	local cur = math_floor(FAKE_MAX * pct / 100)
	if mode == "Deficit" then
		return pct >= 100 and "" or ("-" .. AbbreviateNumbers(FAKE_MAX - cur))
	elseif mode == "Percent" then
		return pct .. "%"
	elseif mode == "Current" then
		return AbbreviateNumbers(cur)
	end
	-- No mode of its own, so it follows the shared Health Format.
	local shared = C.Unitframe.HealthFormat
	if shared == "Current" then
		return AbbreviateNumbers(cur)
	elseif shared == "Percent" then
		return pct .. "%"
	end
	return pct >= 100 and AbbreviateNumbers(cur) or (AbbreviateNumbers(cur) .. " - " .. pct .. "%")
end

-- Made up members for the group frames: a random class, name, role, health and
-- the odd leader, marker, dead, offline or dispellable member, different every
-- time test mode is switched on. Frames are all pointed at the player, so this
-- paints over the pieces that would otherwise read the same everywhere. Names go
-- through the live trimming rules, so Name Length can be judged on long ones.
local FAKE_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local FAKE_NAMES = {
	"Al", "Bob", "Thrall", "Mograine", "Xanthippe", "Arthanasius", "Lightbringer", "Zul'jin",
	"Wolfenstein", "Eowyn", "Grimtotem", "Sylvanas", "Jaina", "Tyrande", "Bartholomew", "Kaz",
	"Nightshade", "Ironforge", "Highmountain", "Pyromancer",
}
-- Which role a class tends to fill, so the icon and the class agree most of the time.
local FAKE_ROLES = { WARRIOR = "TANK", PALADIN = "HEALER", PRIEST = "HEALER", DRUID = "HEALER", SHAMAN = "HEALER" }
local FAKE_DISPEL_COLORS = { { 0.2, 0.6, 1 }, { 0.6, 0, 1 }, { 0, 0.6, 0 }, { 0.6, 0.4, 0 } }
-- Mana for casters, rage for warriors, energy for rogues, focus for hunters.
-- Hunters use mana on Forever, focus is only on their pet.
local FAKE_POWER = { WARRIOR = "RAGE", ROGUE = "ENERGY" }

local function Pick(list)
	return list[math_random(#list)]
end

local function PreviewMember(frame)
	local health = frame.Health
	if not health or (frame.style ~= "KkthnxUI_Party" and frame.style ~= "KkthnxUI_Raid") then
		return
	end
	fakeIndex = fakeIndex + 1

	local class = Pick(FAKE_CLASSES)
	local name = Pick(FAKE_NAMES)
	local color = frame.colors and frame.colors.class and frame.colors.class[class]
	local pct = FAKE_LEVELS[math_random(#FAKE_LEVELS)]
	local roll = math_random(100)
	local dead, offline = roll <= 8, roll > 8 and roll <= 14
	if dead then
		pct = 0
	end

	-- Health fill, and its class colour when the bars are class coloured.
	health:SetMinMaxValues(0, 100)
	health:SetValue(pct)
	if color and C.Unitframe.ClassHealth then
		health:SetStatusBarColor(color:GetRGB())
		if health.__shaded then
			Module.ShadeBar(health)
		end
	end
	if health.__kkuiText then
		health.__kkuiText:SetAlpha(1)
		health.__kkuiText:SetText(dead and DEAD or offline and PLAYER_OFFLINE or SampleHealthText(health.__kkuiMode, pct))
	end

	-- Name, coloured by class only when the bar is not already carrying it.
	if frame.Name then
		local text = frame.style == "KkthnxUI_Raid" and K.FormatRaidName(name) or K.FormatPartyName(name)
		if color and C.Unitframe.NameColor and not C.Unitframe.ClassHealth then
			text = color:GenerateHexColorMarkup() .. text .. "|r"
		end
		frame.Name:SetText(text)
	end

	-- A power bar in the colour and fill that class would show.
	local power = frame.Power
	if power and power:IsShown() then
		-- Our power palette, the one the live frames draw with.
		local powers = frame.colors and frame.colors.power
		local pcolor = powers and powers[FAKE_POWER[class] or "MANA"]
		power:SetMinMaxValues(0, 100)
		power:SetValue(FAKE_POWER[class] == "RAGE" and math_random(0, 60) or math_random(30, 100))
		local texture = power:GetStatusBarTexture()
		if pcolor and texture and not texture:GetAtlas() then
			power:SetStatusBarColor(pcolor:GetRGB())
			if power.PostUpdateColor == Module.ShadeBar then
				Module.ShadeBar(power)
			end
		end
	end

	-- Role, with the tank and healer icons shown and damage left blank like the
	-- real thing.
	local role = FAKE_ROLES[class] or "DAMAGER"
	if fakeIndex == 1 then
		role = "TANK"
	end
	local roleIcon = frame.GroupRoleIndicator
	if roleIcon then
		if role == "TANK" then
			roleIcon:SetAtlas("icons_16x16_tank")
			roleIcon:Show()
		elseif role == "HEALER" then
			roleIcon:SetAtlas("icons_16x16_heal")
			roleIcon:Show()
		else
			roleIcon:Hide()
		end
	end

	-- The first member leads, a few carry a raid marker.
	if frame.LeaderIndicator then
		frame.LeaderIndicator:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
		frame.LeaderIndicator:SetShown(fakeIndex == 1)
	end
	if frame.RaidTargetIndicator and SetRaidTargetIconTexture then
		if math_random(100) <= 30 then
			SetRaidTargetIconTexture(frame.RaidTargetIndicator, math_random(8))
			frame.RaidTargetIndicator:Show()
		else
			frame.RaidTargetIndicator:Hide()
		end
	end

	-- Class on the border, and a dispellable debuff colour on a quarter of them.
	frame.__unitColor = color or frame.__unitColor
	if frame.DispelHighlight and math_random(100) <= 25 then
		local c = Pick(FAKE_DISPEL_COLORS)
		frame.__dispelColor = CreateColor(c[1], c[2], c[3])
	end
	Module.RefreshHealthBorder(frame)
end

-- One dot in each corner, so the spots the watch uses can be checked for overlap
-- with the role, leader and marker icons.
local WATCH_CORNERS = { "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }

local function PreviewWatch(frame, on)
	local watch = frame.AuraWatch
	if not watch or not watch.corners or not Module.GetWatchCorner then
		return
	end
	for _, corner in ipairs(WATCH_CORNERS) do
		local button = Module.GetWatchCorner(watch, corner)
		if on then
			button.Icon:Hide()
			button.Cooldown:Hide()
			button.Dot:SetVertexColor(0.3, 1, 0.3)
			button.Dot:Show()
			button.Count:SetText("")
			button:Show()
		else
			button:Hide()
		end
	end
end

-- Boss frames: a random boss, mostly long names, since those are what clip. The
-- bar is the hostile red, the level reads as a skull-level "??", and the cast is
-- an ability name rather than a placeholder.
local FAKE_BOSSES = {
	"Ragnaros", "Onyxia", "Nefarian", "Kel'Thuzad", "Illidan Stormrage", "Archimonde", "Kil'jaeden",
	"Lady Vashj", "Gruul the Dragonkiller", "Magtheridon", "Hakkar the Soulflayer", "C'Thun",
	"Prince Malchezaar", "High Astromancer Solarian", "Lord Marrowgar", "Mandokir", "Edwin VanCleef",
	"Chromaggus", "Vaelastrasz the Corrupt", "Patchwerk",
}
local FAKE_BOSS_SPELLS = {
	"Shadow Bolt Volley", "Rain of Fire", "Cleave", "Frost Nova", "Mass Fear", "Flame Breath",
	"Chain Lightning", "Soul Rend", "Corrupted Blood", "Arcane Explosion", "Summon Adds",
}

local function PreviewBoss(frame)
	local health = frame.Health
	if not health or frame.style ~= "KkthnxUI_Boss" then
		return
	end
	local pct = math_random(15, 100)
	health:SetMinMaxValues(0, 100)
	health:SetValue(pct)
	local hostile = frame.colors and frame.colors.reaction and frame.colors.reaction[2]
	if hostile and C.Unitframe.ClassHealth then
		health:SetStatusBarColor(hostile:GetRGB())
		if health.__shaded then
			Module.ShadeBar(health)
		end
		frame.__unitColor = hostile
		Module.RefreshHealthBorder(frame)
	end
	if health.__kkuiText then
		health.__kkuiText:SetAlpha(1)
		health.__kkuiText:SetText(SampleHealthText(health.__kkuiMode, pct))
	end
	if frame.Name then
		frame.Name:SetText(K.FormatName(Pick(FAKE_BOSSES)))
	end
	if frame.LevelText then
		frame.LevelText:SetText("|cffff2020??|r")
	end
	local power = frame.Power
	if power and power:IsShown() then
		power:SetMinMaxValues(0, 100)
		power:SetValue(math_random(20, 100))
	end
	-- A different ability on each bar.
	PreviewCast(frame.Castbar, Pick(FAKE_BOSS_SPELLS))
end

local function PreviewFrame(frame)
	if frame.KKUI_Debuffs then
		PreviewContainer(frame.KKUI_Debuffs)
	end
	if frame.KKUI_Buffs then
		PreviewContainer(frame.KKUI_Buffs)
	end
	-- Boss frames pick their own cast text below.
	if frame.style ~= "KkthnxUI_Boss" then
		PreviewCast(frame.Castbar)
	end
	PreviewWatch(frame, true)
	PreviewBoss(frame)
	PreviewMember(frame)
end

local function ClearPreview(frame)
	if frame.KKUI_Debuffs then
		ClearContainer(frame.KKUI_Debuffs)
	end
	if frame.KKUI_Buffs then
		ClearContainer(frame.KKUI_Buffs)
	end
	ClearCast(frame.Castbar)
	PreviewWatch(frame, false)
end

-- The nameplate preview draws its stand-ins the same way.
Module.PreviewFrame = PreviewFrame
Module.ClearPreview = ClearPreview

-- ---------------------------------------------------------------------------
-- Force a single frame
-- ---------------------------------------------------------------------------

-- Point a frame at the player, keep it shown through a forced unit watch, and
-- refresh its elements so it fills with live data.
local function ForceFrame(frame)
	if not frame or frame.__kkuiForced then
		return
	end
	frame.__kkuiForced = true
	frame.__realUnit = frame.unit
	frame.unit = "player"
	frame.__unit = "player"
	frame:EnableMouse(false)
	UnregisterUnitWatch(frame)
	RegisterUnitWatch(frame, true)
	frame:Show()
	if frame.UpdateAllElements then
		frame:UpdateAllElements("KKUI_ConfigMode")
	end
	PreviewFrame(frame)
end

local function UnforceFrame(frame)
	if not frame or not frame.__kkuiForced then
		return
	end
	ClearPreview(frame)
	frame.__kkuiForced = nil
	frame.unit = frame.__realUnit
	frame.__unit = frame.__realUnit
	frame.__realUnit = nil
	frame:EnableMouse(true)
	UnregisterUnitWatch(frame)
	RegisterUnitWatch(frame)
	if frame.UpdateAllElements then
		frame:UpdateAllElements("KKUI_ConfigMode")
	end
end

-- ---------------------------------------------------------------------------
-- Group headers
-- ---------------------------------------------------------------------------

-- The secure header stores its children as child1..childN attributes, which is the
-- reliable way to walk them (GetChildren would also catch non-frames and miss any
-- that spawn on the same frame).
local function ForEachChild(header, func)
	local i = 1
	local child = header:GetAttribute("child" .. i)
	while child do
		func(child)
		i = i + 1
		child = header:GetAttribute("child" .. i)
	end
end

local function ForceHeader(header)
	if not header then
		return
	end
	header.__cfgSaved = {}
	for _, key in ipairs(GATES) do
		header.__cfgSaved[key] = header:GetAttribute(key)
		header:SetAttribute(key, nil)
	end
	header.__cfgStart = header:GetAttribute("startingIndex")

	RegisterStateDriver(header, "visibility", "show")
	header:Show()
	-- Negative index -> the header lays out its full phantom set.
	header:SetAttribute("startingIndex", header.__testStart or -4)
	ForEachChild(header, ForceFrame)
	-- The secure header can finish spawning its children on the next frame, so sweep
	-- once more then. ForceFrame is idempotent, so already-forced children are left
	-- alone, and the guard means a sweep after exit does nothing.
	C_Timer.After(0, function()
		-- ForceFrame touches secure header children, which is blocked in combat, so a
		-- pull that starts in this frame skips the sweep.
		if header.__cfgSaved and not InCombatLockdown() then
			ForEachChild(header, ForceFrame)
		end
	end)
end

local function UnforceHeader(header, visibility)
	if not header then
		return
	end
	ForEachChild(header, UnforceFrame)
	if header.__cfgSaved then
		for _, key in ipairs(GATES) do
			header:SetAttribute(key, header.__cfgSaved[key])
		end
		header.__cfgSaved = nil
	end
	header:SetAttribute("startingIndex", header.__cfgStart or 1)
	header.__cfgStart = nil
	RegisterStateDriver(header, "visibility", visibility)
end

-- The real visibility drivers, rebuilt so the headers go back to normal on exit.
local function PartyVisibility()
	local visibility = "[group:party,nogroup:raid] show; hide"
	if C.Unitframe.Party.ShowSolo then
		visibility = "[nogroup] show; " .. visibility
	end
	return visibility
end

-- ---------------------------------------------------------------------------
-- Enter / exit
-- ---------------------------------------------------------------------------

function Module:EnterConfigMode()
	if InCombatLockdown() then
		return
	end
	fakeIndex = 0
	for _, key in ipairs(INDIVIDUAL) do
		ForceFrame(self[key])
	end
	if self.Boss then
		for _, frame in ipairs(self.Boss) do
			ForceFrame(frame)
		end
	end
	ForceHeader(self.Party)
	ForceHeader(self.Raid)
end

function Module:ExitConfigMode()
	if InCombatLockdown() then
		return
	end
	for _, key in ipairs(INDIVIDUAL) do
		UnforceFrame(self[key])
	end
	if self.Boss then
		for _, frame in ipairs(self.Boss) do
			UnforceFrame(frame)
		end
	end
	UnforceHeader(self.Party, PartyVisibility())
	UnforceHeader(self.Raid, "[group:raid] show; hide")
end
