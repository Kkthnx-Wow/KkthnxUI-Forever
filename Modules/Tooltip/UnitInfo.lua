--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Tooltip/UnitInfo.lua
	Purpose:
		Enrich the unit tooltip: class / reaction coloured name with faction crest,
		raid and role icons, a condensed identity block, guild rank, target line,
		mount, and "targeted by". Also colours the border by unit or
		item quality. All data hooks go through the modern TooltipDataProcessor and
		stay secret-value safe for Midnight.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Tooltip")

local _G = _G
local format = string.format
local select = select
local tconcat = table.concat

local UnitName = UnitName
local UnitPVPName = _G.UnitPVPName
local UnitClass = UnitClass
local UnitClassification = UnitClassification
local UnitIsPlayer = UnitIsPlayer
local UnitReaction = UnitReaction
local UnitCreatureType = UnitCreatureType
local UnitExists = UnitExists
local UnitLevel = UnitLevel
local UnitIsAFK = UnitIsAFK
local UnitIsDND = UnitIsDND
local UnitGroupRolesAssigned = UnitGroupRolesAssigned
local UnitIsUnit = UnitIsUnit
local UnitFactionGroup = _G.UnitFactionGroup
local GetRaidTargetIndex = _G.GetRaidTargetIndex
local IsInRaid = IsInRaid
local GetNumGroupMembers = GetNumGroupMembers
local GetGuildInfo = GetGuildInfo
local GetCreatureDifficultyColor = _G.GetCreatureDifficultyColor
local C_Item = C_Item
local C_MountJournal = C_MountJournal
local IsSecret = K.IsSecret

local classColors = CUSTOM_CLASS_COLORS or RAID_CLASS_COLORS
local ICON_LIST = _G.ICON_LIST

local FACTION_HORDE = _G.FACTION_HORDE
local FACTION_ALLIANCE = _G.FACTION_ALLIANCE
local LEVEL = _G.LEVEL

-- Faction crest markup, shown inline on the name line in place of the "Horde" /
-- "Alliance" text line (which we drop).
local FACTION_ICON = {
	Horde = "|A:CharacterSelection_Horde_Icon:14:11|a ",
	Alliance = "|A:CharacterSelection_Alliance_Icon:14:15|a ",
}

local ColorText = K.ColorText

-- Coloured classification suffix for the level line, from the palette.
local ELITE_TEXT = ColorText("highlight", _G.ELITE or "Elite")
local RARE_TEXT = ColorText("info", _G.ITEM_QUALITY3_DESC or "Rare")
local CLASSIFICATION = {
	elite = " " .. ELITE_TEXT,
	rare = " " .. RARE_TEXT,
	rareelite = " " .. RARE_TEXT .. " " .. ELITE_TEXT,
	worldboss = " " .. ColorText("negative", _G.BOSS or "Boss"),
}

-- "Label: value" with the label muted and the value in its own colour. Every
-- labelled line on the unit tooltip is built through this so they read alike.
local function Labelled(label, value)
	return ColorText("muted", label .. ":") .. " " .. value
end
Module.Labelled = Labelled

-- Class names as the player reads them, for spotting the class line the client
-- prints on its own (it is folded into the level line instead).
local CLASS_NAMES = {}
for _, list in ipairs({ _G.LOCALIZED_CLASS_NAMES_MALE or {}, _G.LOCALIZED_CLASS_NAMES_FEMALE or {} }) do
	for _, name in pairs(list) do
		CLASS_NAMES[name] = true
	end
end

-- Role icon markup from the LFG role atlas, sized for the name line.
local ROLE_ICON = {
	TANK = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:16:16:0:0:64:64:0:19:22:41|t",
	HEALER = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:16:16:0:0:64:64:20:39:1:20|t",
	DAMAGER = "|TInterface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES:16:16:0:0:64:64:20:39:22:41|t",
}

local function RGBText(r, g, b, text)
	return format("|cff%02x%02x%02x%s|r", r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5, text)
end

-- Find the first tooltip line (past the name) whose text matches a predicate.
local function FindLine(tt, predicate)
	for i = 2, tt:NumLines() do
		local fs = _G["GameTooltipTextLeft" .. i]
		local text = fs and fs:GetText()
		if text and not IsSecret(text) and predicate(text) then
			return fs, i
		end
	end
end

-- Colour for a unit: class colour for players, reaction colour otherwise.
local function UnitColor(unit)
	if UnitIsPlayer(unit) then
		local _, class = UnitClass(unit)
		-- The class token can be a secret on some units, and a secret can never be
		-- used as a table key, so skip the palette lookup when it is.
		if class and not IsSecret(class) then
			-- Prefer our custom class palette so the tooltip matches the frames.
			local color = K.oUF and K.oUF.colors.class[class]
			if color then
				return color:GetRGB()
			end
			color = classColors[class]
			if color then
				return color.r, color.g, color.b
			end
		end
	else
		local reaction = UnitReaction(unit, "player")
		if reaction and not IsSecret(reaction) then
			-- Read our custom reaction palette so the tooltip matches the frames,
			-- falling back to Blizzard's if ours has no entry for this reaction.
			local color = K.oUF and K.oUF.colors and K.oUF.colors.reaction and K.oUF.colors.reaction[reaction]
			if color then
				return color:GetRGB()
			end
			local fallback = _G.FACTION_BAR_COLORS and _G.FACTION_BAR_COLORS[reaction]
			if fallback then
				return fallback.r, fallback.g, fallback.b
			end
		end
	end
	return 1, 1, 1
end

function Module:OnUnitTooltip(tt)
	local _, unit = tt:GetUnit()
	-- The unit token itself can be a secret value in Midnight (world objects,
	-- arena opponents). Unit APIs reject secret arguments while our code runs
	-- tainted, so bail before touching it.
	if not unit or IsSecret(unit) then
		return
	end
	if not UnitExists(unit) then
		return
	end

	local db = C.Tooltip
	local line = _G.GameTooltipTextLeft1
	local isPlayer = UnitIsPlayer(unit)

	-- Class / reaction coloured name, with an AFK / DND flag for players.
	if db.ClassColorName and line then
		local r, g, b = UnitColor(unit)
		line:SetTextColor(r, g, b)
	end

	-- The border stays the configured border colour on a unit. Only an item's
	-- quality tints it (see the item post-call below).
	if isPlayer and line then
		local name = line:GetText()
		if name and not IsSecret(name) then
			-- Swap in the PvP name (which carries the player's title) if wanted.
			if db.ShowTitle then
				local pvpName = UnitPVPName(unit)
				if pvpName and not IsSecret(pvpName) and pvpName ~= "" then
					name = pvpName
				end
			end
			-- Append the realm for cross-realm players.
			if db.ShowRealm then
				local realm = select(2, UnitName(unit))
				if realm and not IsSecret(realm) and realm ~= "" then
					name = name .. "-" .. realm
				end
			end
			-- Faction crest ahead of the name, standing in for the text line.
			local prefix = ""
			if db.ShowFactionIcon then
				local faction = UnitFactionGroup(unit)
				if faction and not IsSecret(faction) and FACTION_ICON[faction] then
					prefix = FACTION_ICON[faction]
				end
			end
			-- Raid target marker (skull, star, ...) ahead of the name.
			if db.ShowRaidIcon and ICON_LIST then
				local mark = GetRaidTargetIndex(unit)
				if mark and not IsSecret(mark) and ICON_LIST[mark] then
					prefix = prefix .. ICON_LIST[mark] .. "14|t "
				end
			end
			-- Role icon prefix for group members.
			if db.ShowRole then
				-- Secret for a restricted member, and a secret can key nothing, so
				-- the icon is simply skipped when it cannot be read.
				local role = UnitGroupRolesAssigned(unit)
				if role and not IsSecret(role) and ROLE_ICON[role] then
					prefix = prefix .. ROLE_ICON[role] .. " "
				end
			end
			-- AFK / DND flag suffix.
			local afk, dnd = UnitIsAFK(unit), UnitIsDND(unit)
			local flag = ""
			if not IsSecret(afk) and afk then
				flag = " " .. ColorText("warning", CHAT_FLAG_AFK)
			elseif not IsSecret(dnd) and dnd then
				flag = " " .. ColorText("warning", CHAT_FLAG_DND)
			end
			line:SetText(prefix .. name .. flag)
		end
	end

	-- Guild and rank. Blizzard already prints the guild name on its own line, so
	-- we find that line (it holds the guild name, sometimes wrapped in <>) and
	-- rewrite it as "<Guild> (Rank)", the guild in the positive colour and the
	-- rank muted, rather than adding a duplicate.
	if db.ShowGuild and isPlayer then
		local guild, rank = GetGuildInfo(unit)
		if guild and not IsSecret(guild) then
			local guildLine = FindLine(tt, function(t)
				return t:find(guild, 1, true) ~= nil
			end)
			if guildLine then
				local text = ColorText("positive", "<" .. guild .. ">")
				if rank and not IsSecret(rank) and rank ~= "" then
					text = text .. " " .. ColorText("muted", "(" .. rank .. ")")
				end
				guildLine:SetText(text)
			end
		end
	end

	-- Colour the health bar to match and keep it anchored outside the tooltip.
	-- The unit is remembered for the health text, which the bar cannot give
	-- (its value is a secret).
	Module.tooltipUnit = unit
	local bar = _G.GameTooltipStatusBar
	if bar then
		local r, g, b = UnitColor(unit)
		Module.ColorHealthBar(bar, r, g, b)
		if Module.PositionHealthBar then
			Module.PositionHealthBar(bar)
		end
		if Module.UpdateHealthText then
			Module.UpdateHealthText(bar)
		end
	end

	-- Level line: recolour by difficulty, tidy the identity block. For creatures
	-- we add an Elite/Rare/Boss suffix, for players we drop the "(Player)" tag and
	-- class-colour the spec line just below so the identity reads as one block.
	local level = UnitLevel(unit)
	if level and not IsSecret(level) and LEVEL then
		local levelLine = FindLine(tt, function(t)
			return t:find(LEVEL, 1, true) ~= nil
		end)
		if levelLine and GetCreatureDifficultyColor then
			-- One identity line: the level in its difficulty colour, then the rest.
			-- The word "Level" goes, the number reads as a level on its own.
			local color = GetCreatureDifficultyColor(level)
			local levelText = level > 0 and tostring(level) or "??"
			if color then
				levelText = RGBText(color.r, color.g, color.b, levelText)
			end
			local text = levelLine:GetText()
			if isPlayer then
				-- "80 Orc Hunter": race in body text, class in its class colour. The
				-- client prints the class on a line of its own, which the line
				-- pre-call in SetupUnitInfo drops.
				local race = UnitRace(unit)
				local className, class = UnitClass(unit)
				-- The class token can be a secret, and a secret can never key a table.
				local cc = class and not IsSecret(class) and classColors[class]
				local parts = { levelText }
				if race and not IsSecret(race) then
					parts[#parts + 1] = race
				end
				if className and not IsSecret(className) then
					parts[#parts + 1] = cc and RGBText(cc.r, cc.g, cc.b, className) or className
				end
				levelLine:SetText(tconcat(parts, " "))
				levelLine:SetTextColor(K.Colors.text[1], K.Colors.text[2], K.Colors.text[3])
			elseif text and not IsSecret(text) then
				-- "5 Hostile Beast Elite": the creature line minus its "Level 5"
				-- opening. Forever sends a bare "Level 1" for many NPCs, which left
				-- the number alone on its line, so the creature type and the
				-- reaction are filled in from the unit when the line lacks them.
				local rest = text:gsub("^" .. LEVEL .. "%s+%S+%s*", "")
				local creature = UnitCreatureType(unit)
				if creature and not IsSecret(creature) and not rest:find(creature, 1, true) then
					rest = creature .. (rest ~= "" and (" " .. rest) or "")
				end
				local reaction = UnitReaction(unit, "player")
				local standing = reaction and not IsSecret(reaction) and _G["FACTION_STANDING_LABEL" .. reaction]
				if standing then
					local r, g, b = UnitColor(unit)
					rest = RGBText(r, g, b, standing) .. (rest ~= "" and (" " .. rest) or "")
				end
				local classify = UnitClassification(unit)
				local suffix = classify and not IsSecret(classify) and CLASSIFICATION[classify] or ""
				levelLine:SetText(levelText .. (rest ~= "" and (" " .. rest) or "") .. suffix)
				levelLine:SetTextColor(K.Colors.text[1], K.Colors.text[2], K.Colors.text[3])
			end
		end
	end

	-- Target line.
	if db.ShowTarget and UnitExists(unit .. "target") then
		local targetName = UnitName(unit .. "target")
		-- A secret name cannot be compared or formatted into a string while tainted,
		-- so the line is left out rather than erroring the whole tooltip.
		if targetName and not IsSecret(targetName) then
			local value
			if targetName == K.Name then
				value = ColorText("negative", ">" .. string.upper(YOU) .. "<")
			else
				local r, g, b = UnitColor(unit .. "target")
				value = RGBText(r, g, b, targetName)
			end
			tt:AddLine(Labelled(TARGET, value))
		end
	end

	-- Mount the unit is riding, from their buff list.
	if db.ShowMount and isPlayer and unit ~= "player" and C_MountJournal and C_MountJournal.GetMountFromSpell then
		for i = 1, 40 do
			local data = K.GetAuraData(unit, i, "HELPFUL")
			if not data then
				break
			end
			local spellID = data.spellId
			if spellID and not IsSecret(spellID) and C_MountJournal.GetMountFromSpell(spellID) then
				tt:AddLine(Labelled(_G.MOUNT or "Mount", ColorText("text", data.name)))
				break
			end
		end
	end

	-- Who in your group is currently targeting this unit.
	if db.ShowTargetedBy and GetNumGroupMembers and GetNumGroupMembers() > 0 then
		local prefix = IsInRaid() and "raid" or "party"
		local names = {}
		for i = 1, GetNumGroupMembers() do
			local member = prefix .. i
			if not UnitIsUnit(member, "player") then
				local isTarget = UnitIsUnit(member .. "target", unit)
				if not IsSecret(isTarget) and isTarget then
					local mname = UnitName(member)
					if mname and not IsSecret(mname) then
						local r, g, b = UnitColor(member)
						names[#names + 1] = RGBText(r, g, b, mname)
					end
				end
			end
		end
		if #names > 0 then
			tt:AddLine(Labelled(_G.TARGETED_BY or "Targeted by", tconcat(names, ", ")), nil, nil, nil, true)
		end
	end

	-- Item level and spec for players (async inspect, see Inspect.lua).
	-- Inspecting is the expensive part of this tooltip, so it can be put behind
	-- shift. The lookup runs as the tooltip is built, which means shift has to be
	-- down before you hover rather than pressed afterwards.
	local wantItemLevel = db.ShowItemLevel and (not db.ItemLevelOnShift or IsShiftKeyDown())
	if wantItemLevel and isPlayer and self.AddInspectInfo then
		self:AddInspectInfo(tt, unit)
	end
end

-- Strip the loud PvP line Blizzard adds.
function Module:HidePvPLine(tt)
	if not C.Tooltip.HidePvP then
		return
	end
	for i = 2, tt:NumLines() do
		local fsLine = _G["GameTooltipTextLeft" .. i]
		local text = fsLine and fsLine:GetText()
		if text and not IsSecret(text) and text == PVP_ENABLED then
			fsLine:SetText(nil)
		end
	end
end

function Module:SetupUnitInfo()
	if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall) then
		return
	end

	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Unit, function(tt)
		if tt == _G.GameTooltip then
			Module:OnUnitTooltip(tt)
			Module:HidePvPLine(tt)
		end
	end)

	-- Rebuild the tooltip when shift is pressed or released over a unit, so the
	-- shift-gated item level appears without having to move the cursor away and
	-- back. There is no refresh call on a tooltip, so the unit is simply set again,
	-- which re-runs the data provider and the post call above.
	--
	-- "mouseover" is used rather than the token GameTooltip:GetUnit hands back,
	-- because that one can be a secret on Midnight. If the cursor is over a unit at
	-- all then mouseover is that unit, and it stays readable.
	local modifierWatcher = CreateFrame("Frame")
	modifierWatcher:RegisterEvent("MODIFIER_STATE_CHANGED")
	modifierWatcher:SetScript("OnEvent", function(_, _, key)
		if not C.Tooltip.ItemLevelOnShift then
			return
		end
		if key ~= "LSHIFT" and key ~= "RSHIFT" then
			return
		end
		local tt = _G.GameTooltip
		if tt:IsShown() and UnitExists("mouseover") then
			tt:SetUnit("mouseover")
		end
	end)

	-- Drop the standalone "Horde" / "Alliance" faction line, we show a crest on
	-- the name line instead. Returning true from a line pre-call skips the line
	-- entirely, so no blank gap is left behind.
	if TooltipDataProcessor.AddLinePreCall and Enum.TooltipDataLineType then
		TooltipDataProcessor.AddLinePreCall(Enum.TooltipDataLineType.None, function(tt, lineData)
			if tt ~= _G.GameTooltip or not C.Tooltip.ShowFactionIcon then
				return
			end
			local text = lineData and lineData.leftText
			if text and not IsSecret(text) and (text == FACTION_HORDE or text == FACTION_ALLIANCE) then
				return true
			end
			-- The class on a line of its own, already shown on the level line.
			if text and not IsSecret(text) and CLASS_NAMES[text] then
				return true
			end
		end)
	end

	-- Colour the border by item quality on any of our skinned item tooltips,
	-- including the compare (shopping) tooltips, not just the main one.
	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt)
		local border = K.GetBorder(tt)
		if not C.Tooltip.BorderColor or not border then
			return
		end
		local _, link
		if tt.GetItem then
			_, link = tt:GetItem()
		end
		local quality = link and C_Item and C_Item.GetItemInfo and select(3, C_Item.GetItemInfo(link))
		if quality and quality > 1 and C_Item.GetItemQualityColor then
			local r, g, b = C_Item.GetItemQualityColor(quality)
			K.SetBorderColor(border, r, g, b)
		else
			K.ResetBorderColor(border)
		end
	end)

	-- The unit border colour is reset for the next tooltip from the anchor hook
	-- (Anchor.lua), a hooksecurefunc that stays taint free. An insecure OnTooltipCleared
	-- script hook runs inside the execution that built the tooltip, so on a map POI it
	-- would taint the widget set that follows and error (GitHub #138).
end
