--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/LevelAnnouncer.lua
	Purpose:
		Say how long each level took when you ding, locally or in /say, party or
		guild chat. The clock for the current level is saved per character with
		time(), so it survives a reload, a relog and zone changes. Only a level up
		resets it, and time spent logged out counts. Switched on after a level has
		started, the first ding shows no time because there is nothing to measure.

		Chat routes fall back to a local line when the channel is not available,
		for example the party route while solo.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local _G = _G
local format = string.format
local floor = math.floor
local time = time
local IsInGroup, IsInRaid, IsInGuild, IsPartyLFG = IsInGroup, IsInRaid, IsInGuild, IsPartyLFG
local SendChatMessage = C_ChatInfo.SendChatMessage

local function FormatDuration(seconds)
	seconds = floor(seconds)
	if seconds < 60 then
		return format("%ds", seconds)
	end
	local minutes = floor(seconds / 60)
	if minutes < 60 then
		return format("%dm %ds", minutes, seconds % 60)
	end
	return format("%dh %dm %ds", floor(minutes / 60), minutes % 60, seconds % 60)
end

-- One saved clock per character, kept in the account saved variables.
local function Clock()
	KkthnxUIDB.levelClock = KkthnxUIDB.levelClock or {}
	local key = K.Name .. "-" .. K.Realm
	KkthnxUIDB.levelClock[key] = KkthnxUIDB.levelClock[key] or {}
	return KkthnxUIDB.levelClock[key]
end

local function StartClock(level)
	local clock = Clock()
	clock.level = level
	clock.startTime = time()
end

local function Send(text)
	local channel = C.QoL.LevelChannel
	if channel == "SAY" then
		SendChatMessage(text, "SAY")
	elseif channel == "PARTY" and IsPartyLFG() then
		SendChatMessage(text, "INSTANCE_CHAT")
	elseif channel == "PARTY" and IsInRaid() then
		SendChatMessage(text, "RAID")
	elseif channel == "PARTY" and IsInGroup() then
		SendChatMessage(text, "PARTY")
	elseif channel == "GUILD" and IsInGuild() then
		SendChatMessage(text, "GUILD")
	else
		K.Print(text)
	end
end

local function OnEnterWorld()
	local level = UnitLevel("player")
	local clock = Clock()
	-- A reload or zone change keeps the running clock. Only a first login or a
	-- level that changed while this was off starts a new one.
	if level and (clock.level ~= level or not clock.startTime) then
		StartClock(level)
	end
end

local function OnLevelUp(_, _, newLevel)
	if not newLevel then
		return
	end
	local startTime = Clock().startTime
	local took = startTime and (time() - startTime) or 0
	local text
	if newLevel >= (_G.GetMaxPlayerLevel() or 0) and C.QoL.LevelMaxMessage then
		text = format(L["Ding! Level %d, max level reached!"], newLevel)
	else
		text = format(L["Ding! Level %d!"], newLevel)
	end
	if took > 0 then
		text = format(L["%s (%s for the last level)"], text, FormatDuration(took))
	end
	Send(text)
	StartClock(newLevel)
end

function Module:SetupLevelAnnouncer()
	self:RegisterEvent("PLAYER_ENTERING_WORLD", OnEnterWorld)
	self:RegisterEvent("PLAYER_LEVEL_UP", OnLevelUp)
end
