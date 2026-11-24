--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/ExpRep.lua
	Purpose:
		One movable bar that replaces the Blizzard status tracker and shows the most
		relevant progress: levelling experience (with a rested overlay), tracked
		house favor, watched reputation or honor tracked as experience. Levelling XP
		wins, then house XP, then reputation, then honor.
		The tooltip lists every applicable section regardless of which one owns the
		bar. Alt right click reports the visible bar to party chat.

		Paragon, renown and Azerite power belong to later expansions and are not
		read here. All the progress reads are plain numbers, so no secret guarding
		is needed beyond the AFK flag path.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("ExpRep")

local _G = _G
local format = string.format
local math_huge = math.huge
local math_min = math.min

local CreateFrame = CreateFrame
local GetTime = GetTime
local UIParent = UIParent
local UnitLevel = UnitLevel
local UnitXP = UnitXP
local UnitXPMax = UnitXPMax
local GetXPExhaustion = GetXPExhaustion
local IsLevelAtEffectiveMaxLevel = IsLevelAtEffectiveMaxLevel
local GetMaxLevelForPlayerExpansion = GetMaxLevelForPlayerExpansion
local IsXPUserDisabled = IsXPUserDisabled
local IsRestrictedAccount = IsRestrictedAccount
local IsTrialAccount = IsTrialAccount
local IsVeteranTrialAccount = IsVeteranTrialAccount
local IsWatchingHonorAsXP = IsWatchingHonorAsXP
local IsAltKeyDown = IsAltKeyDown
local IsInGroup = IsInGroup
local SendChatMessage = C_ChatInfo and C_ChatInfo.SendChatMessage
local UnitHonor = UnitHonor
local UnitHonorMax = UnitHonorMax
local UnitHonorLevel = UnitHonorLevel
local UnitExists = UnitExists
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local UIFrameFadeIn = UIFrameFadeIn
local UIFrameFadeOut = UIFrameFadeOut
local UIFrameFadeRemoveFrame = UIFrameFadeRemoveFrame
local hooksecurefunc = hooksecurefunc
local IsSecret = K.IsSecret

local C_Reputation_GetWatchedFactionData = C_Reputation and C_Reputation.GetWatchedFactionData
local C_GossipInfo_GetFriendshipReputation = C_GossipInfo and C_GossipInfo.GetFriendshipReputation

-- Midnight housing. GetCurrentHouseLevelFavor is a request, it returns nothing and
-- the client answers later with HOUSE_LEVEL_FAVOR_UPDATED, whose payload we cache.
local C_Housing = _G.C_Housing
local C_Housing_GetTrackedHouseGuid = C_Housing and C_Housing.GetTrackedHouseGuid
local C_Housing_GetHouseLevelFavorForLevel = C_Housing and C_Housing.GetHouseLevelFavorForLevel
local C_Housing_GetMaxHouseLevel = C_Housing and C_Housing.GetMaxHouseLevel
local C_NeighborhoodInitiative = _G.C_NeighborhoodInitiative

local SPARK = C.Media.Textures.Spark
local REPORT_COOLDOWN = 10
local INFO_COLOR = K.ColorHex("info")
-- Blizzard's experience blue and rested purple, and its honor orange softened
-- the same way as the power colours.
local XP_COLOR = { 0.00, 0.39, 0.88 }
local RESTED_COLOR = { 0.58, 0.00, 0.55 }
local HONOR_COLOR = { 0.90, 0.30, 0.10 }

local function BarTexture()
	return K.GetTexture(C.Unitframe and C.Unitframe.Texture or "KkthnxUI")
end


local bar
local displayText = ""
local reportLabel = ""
local lastReport = 0

local xpState, repState, honorState, housingState = {}, {}, {}, {}
-- Never filled on Forever (no housing), which keeps the housing state unavailable.
local housingData -- luacheck: ignore 221

local function CreateFS(parent, size)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(fs, size, K.FontOutlineStyle())
	return fs
end

-- ---------------------------------------------------------------------------
-- Tooltip divider
-- ---------------------------------------------------------------------------
local DIVIDER_TEXTURE = "Interface\\Common\\UI-TooltipDivider-Transparent"
local dividerPool, dividerUsed = {}, 0

local function ReleaseDividers()
	for i = 1, dividerUsed do
		dividerPool[i]:Hide()
	end
	dividerUsed = 0
end

local function AcquireDivider()
	dividerUsed = dividerUsed + 1
	local tex = dividerPool[dividerUsed]
	if not tex then
		tex = _G.GameTooltip:CreateTexture(nil, "OVERLAY")
		tex:SetTexture(DIVIDER_TEXTURE)
		tex:SetHeight(8)
		dividerPool[dividerUsed] = tex
	end
	return tex
end

local function AddTooltipDivider()
	local tt = _G.GameTooltip
	tt:AddLine(" ")
	local line = _G["GameTooltipTextLeft" .. tt:NumLines()]
	if not line then
		return
	end
	local tex = AcquireDivider()
	tex:ClearAllPoints()
	tex:SetPoint("LEFT", tt, "LEFT", 10, 0)
	tex:SetPoint("RIGHT", tt, "RIGHT", -10, 0)
	tex:SetPoint("TOP", line, "TOP", 0, 0)
	tex:Show()
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local function IsMaxLevel()
	local level = UnitLevel("player")
	-- Modern retail dropped IsLevelAtEffectiveMaxLevel for GameRulesUtil. Without
	-- this the max-level check silently failed and the XP bar kept showing a stale
	-- 0 / 100m at the cap.
	local rules = _G.GameRulesUtil
	if rules and rules.IsPlayerAtEffectiveMaxLevel and rules.IsPlayerAtEffectiveMaxLevel() then
		return true
	end
	if GetMaxLevelForPlayerExpansion and level >= GetMaxLevelForPlayerExpansion() then
		return true
	end
	if IsLevelAtEffectiveMaxLevel and IsLevelAtEffectiveMaxLevel(level) then
		return true
	end
	if IsXPUserDisabled and IsXPUserDisabled() then
		return true
	end
	if (IsRestrictedAccount() or IsTrialAccount() or IsVeteranTrialAccount()) and level == 20 then
		return true
	end
	return false
end

local function SetBarValues(statusbar, minValue, maxValue, value)
	-- Midnight can hand back secret reputation numbers, which cannot be compared or
	-- adjusted in Lua. The status bar C setters accept them, so pass them straight
	-- through and let the bar fill without any arithmetic here.
	if IsSecret and (IsSecret(minValue) or IsSecret(maxValue) or IsSecret(value)) then
		statusbar:SetMinMaxValues(minValue, maxValue)
		statusbar:SetValue(value)
		return
	end
	if maxValue <= minValue then
		maxValue = minValue + 1
	end
	statusbar:SetMinMaxValues(minValue, maxValue)
	statusbar:SetValue(value)
end

local function Progress(minValue, maxValue, value)
	if not maxValue or maxValue <= 0 then
		return 0, 1, 0, true, 0
	end
	local current = (value or 0) - (minValue or 0)
	local maximum = maxValue - (minValue or 0)
	if maximum <= 0 then
		maximum = 1
	end
	if current < 0 then
		current = 0
	elseif current > maximum then
		current = maximum
	end
	local percent = (current / maximum) * 100
	return current, maximum, percent, (current >= maximum), (maximum - current)
end

local function AddRemainingLine(state)
	local cur, maxV, remaining = state.cur, state.max, state.remaining
	remaining = remaining or ((maxV or 0) - (cur or 0))
	if remaining < 0 then
		remaining = 0
	end
	local percent = maxV and maxV > 0 and (remaining / maxV * 100) or 0
	local bars = maxV and maxV > 0 and (remaining / maxV * 20) or 0
	_G.GameTooltip:AddDoubleLine(L["Remaining"], format("%s (%.1f%% - %.1f %s)", K.ShortValue(remaining), percent, bars, L["Bars"]), 1, 1, 1)
end

-- The same reaction palette the unit frames use, so a standing reads the same
-- shade on the bar as on an NPC of that faction. Blizzard's table covers any
-- standing ours does not list.
local function ReactionColor(reaction)
	local ours = C.Unitframe and C.Unitframe.ReactionColors and C.Unitframe.ReactionColors[reaction]
	if ours then
		return ours[1], ours[2], ours[3]
	end
	local color = _G.FACTION_BAR_COLORS and _G.FACTION_BAR_COLORS[reaction]
	if color then
		return color.r, color.g, color.b
	end
	return 1, 1, 1
end

local function HideVisibleBar()
	displayText = ""
	reportLabel = ""
	bar.text:SetText("")
	bar.rest:Hide()
	bar:Hide()
end

-- ---------------------------------------------------------------------------
-- Fade behaviour
-- ---------------------------------------------------------------------------
local FADE_DURATION = 0.25
local FADE_OUT_DELAY = 0.75
local fadeEventFrame
local hideTimer
local isMouseOver = false

local function FadeForced()
	local cfg = C.ExpRep
	if cfg.FadeCombat and InCombatLockdown() then
		return true
	end
	if cfg.FadeTarget and (UnitExists("target") or UnitExists("focus")) then
		return true
	end
	return false
end

local function FadeBarIn()
	if hideTimer then
		hideTimer:Cancel()
	end
	hideTimer = nil
	if bar then
		UIFrameFadeIn(bar, FADE_DURATION, bar:GetAlpha(), 1)
	end
end

local function FadeBarOut()
	hideTimer = nil
	if bar then
		UIFrameFadeOut(bar, FADE_DURATION, bar:GetAlpha(), (C.ExpRep.FadeOpacity or 0) / 100)
	end
end

local function ApplyFadeState()
	if not bar then
		return
	end
	if hideTimer then
		hideTimer:Cancel()
	end
	hideTimer = nil

	if not C.ExpRep.Fade then
		if UIFrameFadeRemoveFrame then
			UIFrameFadeRemoveFrame(bar)
		end
		bar:SetAlpha(1)
		return
	end

	if isMouseOver or FadeForced() then
		FadeBarIn()
	else
		FadeBarOut()
	end
end

local function RefreshFade()
	if not fadeEventFrame then
		fadeEventFrame = CreateFrame("Frame")
		fadeEventFrame:SetScript("OnEvent", ApplyFadeState)
	end
	fadeEventFrame:UnregisterAllEvents()

	local cfg = C.ExpRep
	if cfg.Fade then
		if cfg.FadeCombat then
			fadeEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
			fadeEventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
		end
		if cfg.FadeTarget then
			fadeEventFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
			fadeEventFrame:RegisterEvent("PLAYER_FOCUS_CHANGED")
		end
	end
	ApplyFadeState()
end

-- ---------------------------------------------------------------------------
-- Data builders
-- ---------------------------------------------------------------------------
local function BuildExperienceState()
	if IsMaxLevel() then
		xpState.available = nil
		return false
	end

	local cur = UnitXP("player") or 0
	local maxXP = UnitXPMax("player") or 1
	local rested = GetXPExhaustion() or 0
	if maxXP <= 0 then
		maxXP = 1
	end
	local percent = (cur / maxXP) * 100

	xpState.available = true
	xpState.cur, xpState.max, xpState.percent = cur, maxXP, percent
	xpState.rested, xpState.remaining = rested, maxXP - cur
	xpState.display = format("%s - %s (%.1f%%)", K.ShortValue(cur), K.ShortValue(maxXP), percent)
	return true
end

local function BuildReputationState(data)
	data = data or (C_Reputation_GetWatchedFactionData and C_Reputation_GetWatchedFactionData())
	if not data or not data.name then
		repState.available = nil
		return false
	end

	local name = data.name
	local reaction = data.reaction or 1
	local curThreshold = data.currentReactionThreshold or 0
	local nextThreshold = data.nextReactionThreshold or 1
	local standing = data.currentStanding or 0
	local factionID = data.factionID
	local label

	if factionID and C_GossipInfo_GetFriendshipReputation then
		local friend = C_GossipInfo_GetFriendshipReputation(factionID)
		if friend and friend.friendshipFactionID and friend.friendshipFactionID > 0 then
			label = friend.reaction
			curThreshold = friend.reactionThreshold or 0
			nextThreshold = friend.nextThreshold or math_huge
			standing = friend.standing or standing
		end
	end

	if not label then
		label = _G["FACTION_STANDING_LABEL" .. reaction] or _G.UNKNOWN
	end

	repState.available = true
	repState.name, repState.label = name, label
	repState.reaction = reaction

	-- When the standing or thresholds are secret, no Lua comparison or arithmetic
	-- is allowed on them, so hand the raw numbers to the bar (its C setters take
	-- them) and drop the percent from the text rather than erroring the whole
	-- update, which left the bar blank.
	repState.secret = IsSecret and (IsSecret(standing) or IsSecret(curThreshold) or IsSecret(nextThreshold)) or nil
	if repState.secret then
		repState.minValue, repState.maxValue, repState.value = curThreshold, nextThreshold, standing
		repState.cur, repState.max, repState.percent, repState.remaining, repState.capped = 0, 1, 0, 0, false
		repState.display = format("%s [%s]", name, label)
		return true
	end

	repState.minValue = (nextThreshold == math_huge or curThreshold == nextThreshold) and 0 or curThreshold
	repState.maxValue = (nextThreshold == math_huge) and 1 or nextThreshold
	repState.value = standing

	if nextThreshold == math_huge then
		repState.cur, repState.max, repState.percent, repState.remaining, repState.capped = 0, 1, 100, 0, true
		repState.display = format("%s: [%s]", name, label)
	else
		local cur, maxP, pct, capped, remaining = Progress(curThreshold, nextThreshold, standing)
		repState.cur, repState.max, repState.percent, repState.remaining, repState.capped = cur, maxP, pct, remaining, capped
		repState.display = format("%s: %s - %s (%.1f%%) [%s]", name, K.ShortValue(cur), K.ShortValue(maxP), pct, label)
	end
	return true
end

local function BuildHonorState()
	if not (IsWatchingHonorAsXP and IsWatchingHonorAsXP()) then
		honorState.available = nil
		return false
	end

	local cur = UnitHonor("player") or 0
	local maxHonor = UnitHonorMax("player") or 1
	local level = UnitHonorLevel("player") or 0
	if maxHonor <= 0 then
		maxHonor = 1
	end
	local percent = (cur / maxHonor) * 100

	honorState.available = true
	honorState.cur, honorState.max, honorState.percent = cur, maxHonor, percent
	honorState.level, honorState.remaining = level, maxHonor - cur
	honorState.display = format("%s - %s (%.1f%%) [%s]", K.ShortValue(cur), K.ShortValue(maxHonor), percent, level)
	return true
end

-- WoW Forever has no housing, so nothing here asks the server for housing favor
-- or neighbourhood initiative data. Its own UI never does either, it loads no
-- housing addon and its status bars have no house favor bar. The state builders
-- below only read, and return nothing when there is no tracked house.

local function GetEndeavorProgress()
	if not (C_NeighborhoodInitiative and C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo) then
		return nil
	end
	local info = C_NeighborhoodInitiative.GetNeighborhoodInitiativeInfo()
	if not info or not info.isLoaded or info.initiativeID == 0 then
		return nil
	end
	local milestones = info.milestones
	local maxProgress = milestones and #milestones > 0 and milestones[#milestones].requiredContributionAmount or info.progressRequired
	if not maxProgress or maxProgress <= 0 then
		return nil
	end
	local pct = (info.currentProgress or 0) / maxProgress * 100
	return pct > 100 and 100 or pct
end

local function BuildHousingState()
	if not (C_Housing_GetTrackedHouseGuid and C_Housing_GetHouseLevelFavorForLevel) then
		housingState.available = nil
		return false
	end

	local guid = C_Housing_GetTrackedHouseGuid()
	if not guid or not housingData or housingData.houseGUID ~= guid then
		housingState.available = nil
		return false
	end

	local level = housingData.houseLevel or 1
	local favor = housingData.houseFavor or 0
	local minBar = C_Housing_GetHouseLevelFavorForLevel(level) or 0
	local nextBar = C_Housing_GetHouseLevelFavorForLevel(level + 1) or minBar
	local maxLevel = C_Housing_GetMaxHouseLevel and C_Housing_GetMaxHouseLevel()
	local atMax = (maxLevel and level >= maxLevel) or nextBar <= minBar

	housingState.available = true
	housingState.level = level
	housingState.capped = atMax

	if atMax then
		housingState.cur, housingState.max, housingState.percent, housingState.remaining = 1, 1, 100, 0
		housingState.display = format("%s [%s %d]", _G.MAXIMUM or "Maximum", _G.LEVEL or "Level", level)
	else
		local cur, maxP, pct, capped, remaining = Progress(0, nextBar, favor)
		housingState.cur, housingState.max, housingState.percent = cur, maxP, pct
		housingState.remaining, housingState.capped = remaining, capped
		housingState.display = format("%s - %s (%.1f%%)", K.ShortValue(cur), K.ShortValue(maxP), pct)
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Visible bar modes
-- ---------------------------------------------------------------------------
local function ShowExperience()
	reportLabel = _G.COMBAT_XP_GAIN or "Experience"
	displayText = xpState.display or ""

	bar.fill:SetStatusBarColor(XP_COLOR[1], XP_COLOR[2], XP_COLOR[3], 1)
	SetBarValues(bar.fill, 0, xpState.max, xpState.cur)

	local showRested = C.ExpRep.ShowRested and xpState.rested and xpState.rested > 0
	if showRested then
		bar.rest:SetStatusBarColor(RESTED_COLOR[1], RESTED_COLOR[2], RESTED_COLOR[3], 0.6)
		SetBarValues(bar.rest, 0, xpState.max, math_min(xpState.cur + xpState.rested, xpState.max))
	end

	bar.rest:SetShown(showRested)
	bar.text:SetText(displayText)
	bar:Show()
end

local function ShowReputation()
	reportLabel = _G.REPUTATION or "Reputation"
	displayText = repState.display

	local r, g, b = ReactionColor(repState.reaction)
	bar.fill:SetStatusBarColor(r, g, b, 1)
	SetBarValues(bar.fill, repState.minValue, repState.maxValue, repState.value)

	bar.rest:Hide()
	bar.text:SetText(displayText)
	bar:Show()
end

local function ShowHonor()
	reportLabel = _G.HONOR or "Honor"
	displayText = honorState.display or ""

	bar.fill:SetStatusBarColor(HONOR_COLOR[1], HONOR_COLOR[2], HONOR_COLOR[3], 1)
	SetBarValues(bar.fill, 0, honorState.max, honorState.cur)

	bar.rest:Hide()
	bar.text:SetText(displayText)
	bar:Show()
end

local function ShowHousing()
	reportLabel = L["Housing Experience"]
	displayText = housingState.display

	bar.fill:SetStatusBarColor(1.0, 0.82, 0.0, 1)
	SetBarValues(bar.fill, 0, housingState.max, housingState.cur)

	bar.rest:Hide()
	bar.text:SetText(displayText)
	bar:Show()
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------
local function AddExperienceTooltip()
	if not xpState.available then
		return false
	end
	_G.GameTooltip:AddDoubleLine(K.ColorText("accent", _G.COMBAT_XP_GAIN or "Experience"), format("%s %d", _G.LEVEL or "Level", UnitLevel("player")))
	_G.GameTooltip:AddLine(" ")
	_G.GameTooltip:AddDoubleLine(L["XP"], format("%s - %s (%.1f%%)", K.ShortValue(xpState.cur), K.ShortValue(xpState.max), xpState.percent or 0), 1, 1, 1)
	AddRemainingLine(xpState)
	if xpState.rested and xpState.rested > 0 then
		local pct = xpState.max and xpState.max > 0 and (xpState.rested / xpState.max * 100) or 0
		_G.GameTooltip:AddDoubleLine(L["Rested"], format("+%s (%.1f%%)", K.ShortValue(xpState.rested), pct), 1, 1, 1)
	end
	return true
end

local function AddReputationTooltip(addSpacing)
	if not repState.available then
		return false
	end
	if addSpacing then
		AddTooltipDivider()
	end
	_G.GameTooltip:AddDoubleLine(K.ColorText("accent", repState.name or ""), repState.label or "", 1, 1, 1)
	_G.GameTooltip:AddLine(" ")
	if repState.capped then
		_G.GameTooltip:AddLine(repState.display, 1, 1, 1, true)
	else
		_G.GameTooltip:AddDoubleLine(_G.REPUTATION or "Reputation", format("%s - %s (%.1f%%)", K.ShortValue(repState.cur), K.ShortValue(repState.max), repState.percent or 0), 1, 1, 1)
		AddRemainingLine(repState)
	end
	return true
end

local function AddHonorTooltip(addSpacing)
	if not honorState.available then
		return false
	end
	if addSpacing then
		AddTooltipDivider()
	end
	local levelText = (_G.LEVEL or "Level") .. " " .. (honorState.level or 0)
	_G.GameTooltip:AddDoubleLine(K.ColorText("accent", _G.HONOR or "Honor"), levelText)
	_G.GameTooltip:AddLine(" ")
	_G.GameTooltip:AddDoubleLine(L["Honor XP"], format("%s - %s (%.1f%%)", K.ShortValue(honorState.cur), K.ShortValue(honorState.max), honorState.percent or 0), 1, 1, 1)
	AddRemainingLine(honorState)
	return true
end

local function AddHousingTooltip(addSpacing)
	if not housingState.available then
		return false
	end
	if addSpacing then
		AddTooltipDivider()
	end
	_G.GameTooltip:AddDoubleLine(K.ColorText("accent", L["Housing Experience"]), format("%s %d", _G.LEVEL or "Level", housingState.level or 1))
	_G.GameTooltip:AddLine(" ")
	if housingState.capped then
		_G.GameTooltip:AddLine(housingState.display, 1, 1, 1, true)
	else
		_G.GameTooltip:AddDoubleLine(L["XP"], format("%s - %s (%.1f%%)", K.ShortValue(housingState.cur), K.ShortValue(housingState.max), housingState.percent or 0), 1, 1, 1)
		AddRemainingLine(housingState)
	end

	local endeavorPct = GetEndeavorProgress()
	if endeavorPct then
		_G.GameTooltip:AddDoubleLine(L["Endeavor Progress"], format("%.2f%%", endeavorPct), 1, 1, 1)
	end
	return true
end

local function OnEnter()
	isMouseOver = true
	if C.ExpRep.Fade then
		FadeBarIn()
	end
	if _G.GameTooltip:IsForbidden() then
		return
	end
	_G.GameTooltip:ClearLines()
	ReleaseDividers()
	_G.GameTooltip:SetOwner(bar, "ANCHOR_CURSOR")

	local any = AddExperienceTooltip()
	local addedHousing = AddHousingTooltip(any)
	any = any or addedHousing
	local addedRep = AddReputationTooltip(any)
	any = any or addedRep
	local addedHonor = AddHonorTooltip(any)
	any = any or addedHonor

	if any then
		_G.GameTooltip:AddLine(" ")
	end
	_G.GameTooltip:AddLine(INFO_COLOR .. L["Alt + Right-Click to report to party chat."] .. "|r")
	_G.GameTooltip:Show()
end

local function OnLeave()
	isMouseOver = false
	if C.ExpRep.Fade and not FadeForced() then
		if hideTimer then
			hideTimer:Cancel()
		end
		hideTimer = C_Timer.NewTimer(FADE_OUT_DELAY, FadeBarOut)
	end
	ReleaseDividers()
	if not _G.GameTooltip:IsForbidden() then
		_G.GameTooltip:Hide()
	end
end

local function OnMouseUp(_, button)
	if not (IsAltKeyDown() and button == "RightButton") then
		return
	end
	if displayText == "" then
		return
	end
	if (GetTime() - lastReport) < REPORT_COOLDOWN then
		return
	end
	if not IsInGroup() then
		K.Print(_G.ERR_QUEST_PUSH_NOT_IN_PARTY_S or "Not in a party.")
		return
	end
	lastReport = GetTime()
	if SendChatMessage then
		SendChatMessage(reportLabel .. ": " .. displayText, "PARTY")
	end
end

-- ---------------------------------------------------------------------------
-- Update / appearance
-- ---------------------------------------------------------------------------
local function UpdateBar(_, _, unit)
	if not C.ExpRep.Enable or not bar then
		return
	end
	if unit and unit ~= "player" then
		return
	end

	BuildExperienceState()
	BuildHousingState()
	BuildReputationState()
	BuildHonorState()

	if xpState.available then
		ShowExperience()
	elseif housingState.available then
		ShowHousing()
	elseif repState.available then
		ShowReputation()
	elseif honorState.available then
		ShowHonor()
	else
		HideVisibleBar()
	end

	if C.ExpRep.Fade and bar:IsShown() then
		ApplyFadeState()
	end
end

-- Bursty events (UPDATE_FACTION, gear swaps) coalesce into one end-of-frame rebuild.
local queueScheduled
local function QueueBarUpdate()
	if queueScheduled then
		return
	end
	queueScheduled = true
	C_Timer.After(0, function()
		queueScheduled = false
		UpdateBar()
	end)
end

local function ApplyAppearance()
	if not bar then
		return
	end
	local cfg = C.ExpRep
	bar:SetSize(cfg.Width, cfg.Height)
	bar.spark:SetHeight(cfg.Height + 6)
	K.SetFont(bar.text, cfg.FontSize, K.FontOutlineStyle())
	bar.text:SetShown(cfg.ShowText)
	RefreshFade()
end

local EVENTS = {
	"PLAYER_ENTERING_WORLD",
	"PLAYER_LEVEL_UP",
	"UPDATE_EXHAUSTION",
	"PLAYER_XP_UPDATE",
	"ENABLE_XP_GAIN",
	"DISABLE_XP_GAIN",
	"UPDATE_FACTION",
	"QUEST_FINISHED",
	"HONOR_XP_UPDATE",
	"PLAYER_FLAGS_CHANGED",
	"PLAYER_EQUIPMENT_CHANGED",
}

local function OnBarEvent()
	QueueBarUpdate()
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------
local function BuildBar()
	if bar then
		return bar
	end

	local f = CreateFrame("Frame", "KKUI_ExpRepBar", UIParent)
	f:SetFrameStrata("LOW")
	f:EnableMouse(true)

	local base = f:GetFrameLevel()

	local trough = f:CreateTexture(nil, "BACKGROUND")
	trough:SetAllPoints()
	trough:SetColorTexture(0, 0, 0, 0.6)
	f.trough = trough

	local rest = CreateFrame("StatusBar", nil, f)
	rest:SetAllPoints()
	rest:SetFrameLevel(base + 1)
	rest:SetStatusBarTexture(BarTexture())
	rest:SetStatusBarColor(RESTED_COLOR[1], RESTED_COLOR[2], RESTED_COLOR[3], 0.6)
	rest:Hide()
	f.rest = rest

	local fill = CreateFrame("StatusBar", nil, f)
	fill:SetAllPoints()
	fill:SetFrameLevel(base + 3)
	fill:SetStatusBarTexture(BarTexture())
	f.fill = fill

	-- Our border on the top bar so it draws above both fills and the trough,
	-- keeping the configured border colour rather than black.
	K.CreateBorder(fill)

	local spark = fill:CreateTexture(nil, "OVERLAY")
	spark:SetTexture(SPARK)
	spark:SetBlendMode("ADD")
	spark:SetAlpha(0.6)
	spark:SetWidth(16)
	spark:SetPoint("CENTER", fill:GetStatusBarTexture(), "RIGHT", 0, 0)
	f.spark = spark

	local text = CreateFS(fill, C.ExpRep.FontSize)
	text:SetPoint("CENTER")
	text:SetWordWrap(false)
	text:SetTextColor(K.Colors.offWhite[1], K.Colors.offWhite[2], K.Colors.offWhite[3])
	text:SetDrawLayer("OVERLAY", 7)
	f.text = text

	f:SetScript("OnEvent", OnBarEvent)
	f:SetScript("OnEnter", OnEnter)
	f:SetScript("OnLeave", OnLeave)
	f:SetScript("OnMouseUp", OnMouseUp)

	bar = f
	return f
end

-- Replace Blizzard's status tracker. The frame is not protected, so unregistering
-- and hiding it avoids a duplicate bar without tainting secure gameplay frames.
local function HideBlizzard()
	local mgr = _G.StatusTrackingBarManager
	if not mgr or mgr.kkuiHidden then
		return
	end
	mgr.kkuiHidden = true
	mgr:UnregisterAllEvents()
	mgr:Hide()
	hooksecurefunc(mgr, "Show", function(self)
		if self.kkuiHidden then
			self:Hide()
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------
local function RegisterBarEvents()
	if not bar or bar.kkuiEventsRegistered then
		return
	end
	for i = 1, #EVENTS do
		pcall(bar.RegisterEvent, bar, EVENTS[i])
	end
	bar.kkuiEventsRegistered = true
end

function Module:Refresh()
	ApplyAppearance()
	UpdateBar()
end

function Module:OnEnable()
	if not C.ExpRep.Enable then
		return
	end
	if self.setupDone then
		return
	end
	self.setupDone = true

	BuildBar()
	HideBlizzard()
	ApplyAppearance()
	K.CreateMover(bar, "ExpRepBar", L["Experience Bar"], { "TOP", UIParent, "TOP", 0, -4 }, C.ExpRep.Width, C.ExpRep.Height)

	RegisterBarEvents()
	UpdateBar()
end
