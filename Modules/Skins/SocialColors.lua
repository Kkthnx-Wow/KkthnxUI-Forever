--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/SocialColors.lua
	Purpose:
		Class-colour player names and difficulty-colour levels across the social
		panels: the Friends list (WoW and Battle.net friends) and the /who results
		window. The guild roster lives in Communities on Forever, which colours
		names by class on its own.

		Colours come from KkthnxUI's own harmonised class palette (K.ClassColors),
		so a name in the Friends list reads the same shade as the same class on the
		unit frames and nameplates, rather than Blizzard's brighter defaults.

		Every hook target is existence-guarded so the module stays quiet on layouts
		where a frame or API is missing.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("SocialColors")

local _G = _G
local select = select
local wipe = wipe
local format = string.format

local RGBToHex = K.RGBToHex
local Colors = K.Colors

local GetAreaText = GetAreaText
local GetGuildInfo = GetGuildInfo
local UnitRace = UnitRace
local GetQuestDifficultyColor = GetQuestDifficultyColor
local C_FriendList = C_FriendList
local C_BattleNet = C_BattleNet

local WHITE = "|cffffffff"
-- Our success green, used to flag a friend or guildmate sharing your zone/guild.
local JADE = RGBToHex(Colors.jade[1], Colors.jade[2], Colors.jade[3])
local ONLINE_JADE = JADE .. "%s|r"

local function ShouldShow()
	return C.Skins and C.Skins.SocialColors
end

-- ---------------------------------------------------------------------------
-- Colour helpers
-- ---------------------------------------------------------------------------

-- A colour escape ("|cffRRGGBB") for a class token or localised class name.
local function ClassColorStr(class)
	return K.ClassColorHex(K.ClassFileFromName(class))
end

-- Class colour as an r, g, b triplet, for SetTextColor. Falls back to white.
local function ClassColorRGB(class)
	return K.ClassColorRGB(K.ClassFileFromName(class))
end

-- Difficulty colour escape for a level.
local function DiffColor(level)
	local color = GetQuestDifficultyColor(level)
	return RGBToHex(color.r, color.g, color.b)
end

-- Friends level line uses %d, swap to %s so a coloured level string fits.
local levelTemplate
local function GetLevelTemplate()
	if not levelTemplate then
		local raw = _G.FRIENDS_LEVEL_TEMPLATE or "Level %d %s"
		levelTemplate = raw:gsub("%%d", "%%s"):gsub("%$d", "%$s")
	end
	return levelTemplate
end

-- ---------------------------------------------------------------------------
-- Row enumeration
--   Modern ScrollBoxes expose GetFrames(), which hands back the active-frame
--   array directly with no allocation. Fall back to the legacy child walk (into
--   a reused scratch table) only when that API is missing.
-- ---------------------------------------------------------------------------
local enumScratch = {}
local function GetRowFrames(scrollBox)
	if scrollBox.GetFrames then
		return scrollBox:GetFrames()
	end
	local target = scrollBox.ScrollTarget
	if not target then
		return nil
	end
	wipe(enumScratch)
	for i = 1, target:GetNumChildren() do
		enumScratch[i] = select(i, target:GetChildren())
	end
	return enumScratch
end

-- ---------------------------------------------------------------------------
-- Friends list (WoW + Battle.net)
-- ---------------------------------------------------------------------------
local function UpdateFriendsList(self)
	if not ShouldShow() then
		return
	end
	local buttons = GetRowFrames(self)
	if not buttons then
		return
	end
	local playerArea = GetAreaText()

	for i = 1, #buttons do
		local button = buttons[i]
		if button and button:IsShown() then
			local nameText, infoText

			if button.buttonType == _G.FRIENDS_BUTTON_TYPE_WOW then
				local info = C_FriendList.GetFriendInfoByIndex(button.id)
				if info and info.connected then
					nameText = ClassColorStr(info.className) .. info.name .. "|r, " .. format(GetLevelTemplate(), DiffColor(info.level) .. info.level .. "|r", info.className)
					if info.area == playerArea then
						infoText = format(ONLINE_JADE, info.area)
					end
				end
			elseif button.buttonType == _G.FRIENDS_BUTTON_TYPE_BNET then
				local accountInfo = C_BattleNet.GetFriendAccountInfo(button.id)
				local gameAccountInfo = accountInfo and accountInfo.gameAccountInfo
				if gameAccountInfo and gameAccountInfo.isOnline and gameAccountInfo.clientProgram == _G.BNET_CLIENT_WOW then
					local charName = gameAccountInfo.characterName
					local class = gameAccountInfo.className or UNKNOWN
					local zoneName = gameAccountInfo.areaName or UNKNOWN
					local accountName = accountInfo.accountName
					if accountName and charName and class then
						local wow = _G.FRIENDS_WOW_NAME_COLOR_CODE or WHITE
						nameText = accountName .. " " .. wow .. "(" .. ClassColorStr(class) .. charName .. wow .. ")"
						if zoneName == playerArea then
							infoText = format(ONLINE_JADE, zoneName)
						end
					end
				end
			end

			if nameText and button.name then
				button.name:SetText(nameText)
			end
			if infoText and button.info then
				button.info:SetText(infoText)
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- /who results
-- ---------------------------------------------------------------------------
local whoColumns = { zone = "", guild = "", race = "" }
local whoSortType = "zone"

local function UpdateWhoList(self)
	if not ShouldShow() then
		return
	end
	local buttons = GetRowFrames(self)
	if not buttons then
		return
	end
	local playerZone = GetAreaText()
	local playerGuild = GetGuildInfo("player")
	local playerRace = UnitRace("player")

	for i = 1, #buttons do
		local button = buttons[i]
		if button and button.index then
			local info = C_FriendList.GetWhoInfo(button.index)
			if info then
				local guild, level, race, zone, class = info.fullGuildName, info.level, info.raceStr, info.area, info.filename
				if zone and zone == playerZone then
					zone = JADE .. zone
				end
				if guild and guild == playerGuild then
					guild = JADE .. guild
				end
				if race and race == playerRace then
					race = JADE .. race
				end

				whoColumns.zone = zone or ""
				whoColumns.guild = guild or ""
				whoColumns.race = race or ""

				if button.Name then
					button.Name:SetTextColor(ClassColorRGB(class))
				end
				if button.Level then
					button.Level:SetText(DiffColor(level) .. level)
				end
				if button.Variable then
					button.Variable:SetText(whoColumns[whoSortType] or "")
				end
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Hook installation
-- ---------------------------------------------------------------------------
local function HookFriends()
	local frame = _G.FriendsListFrame
	if frame and frame.ScrollBox then
		hooksecurefunc(frame.ScrollBox, "Update", UpdateFriendsList)
	end
end

local function HookWho()
	local frame = _G.WhoFrame
	if frame and frame.ScrollBox then
		hooksecurefunc(frame.ScrollBox, "Update", UpdateWhoList)
		if C_FriendList and C_FriendList.SortWho then
			hooksecurefunc(C_FriendList, "SortWho", function(sortType)
				-- The Name, Level and Class headers sort too, but the variable
				-- column keeps showing the zone, guild or race picked for it.
				if whoColumns[sortType] then
					whoSortType = sortType
				end
			end)
		end
	end
end

function Module:OnEnable()
	if not ShouldShow() or self.hooksInstalled then
		return
	end
	self.hooksInstalled = true

	HookFriends()
	HookWho()
end
