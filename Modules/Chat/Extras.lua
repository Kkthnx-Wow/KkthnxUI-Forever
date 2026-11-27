--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/Extras.lua
	Purpose:
		Small chat helpers that each stand alone.

		Sent lines are remembered across logins, so the up and down arrows in the
		edit box reach back into the last session. Secure commands are never kept.

		Every chat window keeps a chosen number of lines instead of the game's 128.

		/cls and /clearchat empty the chat window you are looking at, /clsall and
		/clearallchat empty every window.

		Loot, money, currency and experience lines can be shortened, for example
		"Loot: [Linen Cloth] x2" in place of the full sentence. The patterns are
		built from the game's own text, so they follow the client language, and a
		line that does not match is left as it was.

		Channel colours are remembered by channel name. The game keeps colours by
		channel number, and numbers move between sessions, so the colour you gave
		Trade can land on another channel. When a channel turns up under a new
		number its colour is put back.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Chat")

local _G = _G
local ipairs = ipairs
local select = select
local type = type
local format = string.format
local gsub = string.gsub
local match = string.match
local strupper = string.upper
local tremove = table.remove
local tonumber = tonumber
local CreateFrame = CreateFrame
local C_Timer = C_Timer
local hooksecurefunc = hooksecurefunc
local UnitName = UnitName
local UnitGUID = UnitGUID
local UnitLevel = UnitLevel
local UnitIsPlayer = UnitIsPlayer
local IsInRaid = IsInRaid
local IsInGuild = IsInGuild
local GetNumGroupMembers = GetNumGroupMembers
local GetNumGuildMembers = GetNumGuildMembers
local GetGuildRosterInfo = GetGuildRosterInfo
local C_FriendList = C_FriendList
local C_GuildInfo = C_GuildInfo
local C_ChatInfo = C_ChatInfo
local pcall = pcall
local tostring = tostring
local wipe = wipe
local GetRealmName = GetRealmName
local IsSecret = K.IsSecret

local NUM_FRAMES = Constants.ChatFrameConstants.MaxChatWindows
local SENT_LIMIT = 100

local function CharKey()
	local name, realm = UnitName("player"), GetRealmName()
	if not name or not realm then
		return nil
	end
	return name .. " - " .. realm
end

-- ---------------------------------------------------------------------------
-- Sent line memory
-- ---------------------------------------------------------------------------

local sentLines
local restoringSent = false

local function IsSecureLine(text)
	local command = match(text, "^(/%S+)")
	return command and _G.IsSecureCmd and _G.IsSecureCmd(command) and true or false
end

local function RememberSent(_, text)
	if restoringSent or type(text) ~= "string" or IsSecret(text) or text == "" then
		return
	end
	if IsSecureLine(text) then
		return
	end
	if sentLines[#sentLines] == text then
		return
	end
	sentLines[#sentLines + 1] = text
	while #sentLines > SENT_LIMIT do
		tremove(sentLines, 1)
	end
end

local function SetupSentMemory()
	local db = _G.KkthnxUIDB
	local key = CharKey()
	if type(db) ~= "table" or not key then
		return
	end
	db.chatSent = db.chatSent or {}
	db.chatSent[key] = db.chatSent[key] or {}
	sentLines = db.chatSent[key]

	-- Each window has its own edit box and its own history, so every one gets the
	-- saved lines, oldest first so the newest is one arrow press away.
	restoringSent = true
	for i = 1, NUM_FRAMES do
		local editBox = _G["ChatFrame" .. i .. "EditBox"]
		if editBox and editBox.AddHistoryLine then
			for _, line in ipairs(sentLines) do
				if type(line) == "string" then
					editBox:AddHistoryLine(line)
				end
			end
			hooksecurefunc(editBox, "AddHistoryLine", RememberSent)
		end
	end
	restoringSent = false
end

-- ---------------------------------------------------------------------------
-- Scrollback and clearing
-- ---------------------------------------------------------------------------

local function SetupScrollback()
	local lines = C.Chat.MaxLines
	if type(lines) ~= "number" or lines < 128 then
		return
	end
	for i = 1, NUM_FRAMES do
		local frame = _G["ChatFrame" .. i]
		if frame and frame.SetMaxLines and frame:GetMaxLines() ~= lines then
			frame:SetMaxLines(lines)
		end
	end
end

local function ClearChat(all)
	if all then
		for i = 1, NUM_FRAMES do
			local frame = _G["ChatFrame" .. i]
			if frame and frame.Clear then
				frame:Clear()
			end
		end
		return
	end
	local frame = _G.SELECTED_CHAT_FRAME or _G.DEFAULT_CHAT_FRAME
	if frame and frame.Clear then
		frame:Clear()
	end
end

local function SetupClearCommands()
	_G.SLASH_KKUI_CLEARCHAT1 = "/cls"
	_G.SLASH_KKUI_CLEARCHAT2 = "/clearchat"
	_G.SlashCmdList.KKUI_CLEARCHAT = function()
		ClearChat(false)
	end
	-- /find words: the lines in the window you are looking at that contain them,
	-- in the copy window, where they can be read, scrolled and copied.
	_G.SLASH_KKUI_FINDCHAT1 = "/find"
	_G.SlashCmdList.KKUI_FINDCHAT = function(msg)
		msg = msg and msg:match("^%s*(.-)%s*$") or ""
		if msg == "" then
			K.Print(L["Type /find and a word to search the chat window you are looking at."])
			return
		end
		Module:CopyChat(nil, msg)
	end

	_G.SLASH_KKUI_CLEARALLCHAT1 = "/clsall"
	_G.SLASH_KKUI_CLEARALLCHAT2 = "/clearallchat"
	_G.SlashCmdList.KKUI_CLEARALLCHAT = function()
		ClearChat(true)
	end
end

-- ---------------------------------------------------------------------------
-- Short system lines
-- ---------------------------------------------------------------------------

-- A string with numbered arguments gives no pattern, and its lines stay long.
local function Compile(global)
	return K.FormatToPattern(_G[global])
end

-- Tried in order, the longer forms first, since "You receive loot: %s" would
-- also take a line meant for "You receive loot: %sx%d".
local RULES = {
	{ "LOOT_ITEM_SELF_MULTIPLE", "Loot: %s x%s" },
	{ "LOOT_ITEM_PUSHED_SELF_MULTIPLE", "Loot: %s x%s" },
	{ "LOOT_ITEM_CREATED_SELF_MULTIPLE", "Created: %s x%s" },
	{ "LOOT_ITEM_SELF", "Loot: %s" },
	{ "LOOT_ITEM_PUSHED_SELF", "Loot: %s" },
	{ "LOOT_ITEM_CREATED_SELF", "Created: %s" },
	{ "LOOT_ITEM_MULTIPLE", "%s looted %s x%s" },
	{ "LOOT_ITEM", "%s looted %s" },
	{ "CURRENCY_GAINED_MULTIPLE", "Currency: %s x%s" },
	{ "CURRENCY_GAINED", "Currency: %s" },
	{ "YOU_LOOT_MONEY", "Money: %s" },
	{ "LOOT_MONEY_SPLIT", "Money: %s" },
	{ "ERR_QUEST_REWARD_MONEY_S", "Money: %s" },
	{ "ERR_QUEST_REWARD_EXP_I", "XP: +%s" },
	{ "COMBATLOG_XPGAIN_EXHAUSTION1_GROUP", "XP: +%2$s (%1$s, %3$s %4$s, +%5$s group)" },
	{ "COMBATLOG_XPGAIN_EXHAUSTION1", "XP: +%2$s (%1$s, %3$s %4$s)" },
	{ "COMBATLOG_XPGAIN_FIRSTPERSON_GROUP", "XP: +%2$s (%1$s, +%3$s group)" },
	{ "COMBATLOG_XPGAIN_FIRSTPERSON", "XP: +%2$s (%1$s)" },
	{ "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED_GROUP", "XP: +%s (+%s group)" },
	{ "COMBATLOG_XPGAIN_FIRSTPERSON_UNNAMED", "XP: +%s" },
}

local compiled

-- Lua 5.1 format has no numbered arguments, so the reordered templates are
-- filled by hand.
local function Fill(template, ...)
	if not template:find("%$") then
		return format(template, ...)
	end
	local args = { ... }
	return (gsub(template, "%%(%d)%$s", function(n)
		return args[n + 0] or ""
	end))
end

local function Shorten(_, _, msg, ...)
	if type(msg) ~= "string" or IsSecret(msg) then
		return false
	end
	-- Captures go straight into locals, so a line that matches no rule, which
	-- is most of them, makes no table. Five is the most any rule captures.
	for _, rule in ipairs(compiled) do
		local a, b, c, d, e = match(msg, rule[1])
		if a then
			return false, Fill(rule[2], a, b, c, d, e), ...
		end
	end
	return false
end

local SHORT_EVENTS = {
	"CHAT_MSG_LOOT",
	"CHAT_MSG_CURRENCY",
	"CHAT_MSG_MONEY",
	"CHAT_MSG_COMBAT_XP_GAIN",
	"CHAT_MSG_SYSTEM",
}

local function SetupShortLines()
	compiled = {}
	for _, rule in ipairs(RULES) do
		local pattern = Compile(rule[1])
		if pattern then
			compiled[#compiled + 1] = { pattern, L[rule[2]] }
		end
	end
	for _, event in ipairs(SHORT_EVENTS) do
		_G.ChatFrameUtil.AddMessageEventFilter(event, Shorten)
	end
end

-- ---------------------------------------------------------------------------
-- Channel colours by name
-- ---------------------------------------------------------------------------

local channelColors

-- "General - Elwynn Forest" and "General - Westfall" are the same channel to
-- the player, so the zone part is left off the key.
local function ChannelKey(name)
	if type(name) ~= "string" or IsSecret(name) or name == "" then
		return nil
	end
	return (match(name, "^(.-) %- ") or name)
end

local function ForEachChannel(callback)
	local list = { _G.GetChannelList() }
	for i = 1, #list, 3 do
		local id, name = list[i], list[i + 1]
		local key = ChannelKey(name)
		if type(id) == "number" and key then
			callback(id, key)
		end
	end
end

-- The colour comes from the event itself. ChatTypeInfo is only updated by the
-- chat frame's own handler, which may run after ours.
local function SaveColor(key, r, g, b)
	if type(r) == "number" and type(g) == "number" and type(b) == "number" then
		channelColors[key] = { r, g, b }
	end
end

-- Put each known channel's colour back on whatever number it has now. A channel
-- seen for the first time keeps the colour the game gave it, and that becomes
-- its remembered colour.
local function ApplyColors()
	ForEachChannel(function(id, key)
		local saved = channelColors[key]
		local info = _G.ChatTypeInfo and _G.ChatTypeInfo["CHANNEL" .. id]
		if saved and info and info.r then
			if info.r ~= saved[1] or info.g ~= saved[2] or info.b ~= saved[3] then
				_G.ChangeChatColor("CHANNEL" .. id, saved[1], saved[2], saved[3])
			end
		elseif not saved and info then
			SaveColor(key, info.r, info.g, info.b)
		end
	end)
end

local applyQueued = false
local function QueueApply()
	if applyQueued then
		return
	end
	applyQueued = true
	C_Timer.After(1, function()
		applyQueued = false
		ApplyColors()
	end)
end

local function OnColorEvent(_, event, chatType, r, g, b)
	if event == "UPDATE_CHAT_COLOR" then
		-- A colour picked in the chat settings, remembered under the channel's
		-- name so it follows the channel to its next number. The game also sends
		-- this while loading its colours by number at login, which is exactly the
		-- mix-up being undone, so only a change made with the colour picker open
		-- counts as the player's choice.
		local picker = _G.ColorPickerFrame
		if not (picker and picker:IsShown()) then
			return
		end
		-- Blizzard upper-cases the type before using it, so the match does too.
		local id = type(chatType) == "string" and not IsSecret(chatType) and tonumber(match(strupper(chatType), "^CHANNEL(%d+)$"))
		if id then
			local name = select(2, _G.GetChannelName(id))
			local key = ChannelKey(name)
			if key then
				SaveColor(key, r, g, b)
			end
		end
		return
	end
	QueueApply()
end

local function SetupChannelColors()
	local db = _G.KkthnxUIDB
	if type(db) ~= "table" or not _G.GetChannelList or not _G.ChangeChatColor then
		return
	end
	db.chatChannelColors = db.chatChannelColors or {}
	channelColors = db.chatChannelColors

	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("CHANNEL_UI_UPDATE")
	watcher:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
	watcher:RegisterEvent("UPDATE_CHAT_COLOR")
	watcher:SetScript("OnEvent", OnColorEvent)
	QueueApply()
end

-- ---------------------------------------------------------------------------
-- Levels beside names
-- ---------------------------------------------------------------------------

-- A player's level in the brackets of their name, [Bob:42], coloured by how it
-- compares to yours. The game does not say a sender's level, so it is only
-- known for players it tells us about: your group, your guild, your friends,
-- and anyone you target or point at. Others are left as they are.
--
-- Everything is keyed by GUID, read from the chat line itself, so two players
-- with the same first name never swap levels.
local MAX_KNOWN = 2000
local levels, knownCount = {}, 0

local function Remember(guid, level)
	if not guid or IsSecret(guid) or type(level) ~= "number" or IsSecret(level) or level <= 0 then
		return
	end
	if levels[guid] == nil then
		knownCount = knownCount + 1
		if knownCount > MAX_KNOWN then
			wipe(levels)
			knownCount = 1
		end
	end
	levels[guid] = level
end

local function RememberUnit(unit)
	local isPlayer = UnitIsPlayer(unit)
	if not IsSecret(isPlayer) and isPlayer then
		Remember(UnitGUID(unit), UnitLevel(unit))
	end
end

local function ReadGroup()
	RememberUnit("player")
	local prefix = IsInRaid() and "raid" or "party"
	for i = 1, GetNumGroupMembers() do
		RememberUnit(prefix .. i)
	end
end

local function ReadGuild()
	for i = 1, GetNumGuildMembers() do
		local _, _, _, level, _, _, _, _, _, _, _, _, _, _, _, _, guid = GetGuildRosterInfo(i)
		Remember(guid, level)
	end
end

local function ReadFriends()
	for i = 1, C_FriendList.GetNumFriends() do
		local info = C_FriendList.GetFriendInfoByIndex(i)
		if info and info.connected then
			Remember(info.guid, info.level)
		end
	end
end

local function OnLevelEvent(_, event, unit)
	if event == "GUILD_ROSTER_UPDATE" then
		ReadGuild()
	elseif event == "FRIENDLIST_UPDATE" then
		ReadFriends()
	elseif event == "PLAYER_TARGET_CHANGED" then
		RememberUnit("target")
	elseif event == "UPDATE_MOUSEOVER_UNIT" then
		RememberUnit("mouseover")
	elseif event == "UNIT_LEVEL" and type(unit) == "string" then
		RememberUnit(unit)
	else
		ReadGroup()
	end
end

local function LevelText(level)
	local color = _G.GetCreatureDifficultyColor and _G.GetCreatureDifficultyColor(level)
	if color and color.r then
		return format("|cff%02x%02x%02x%d|r", color.r * 255, color.g * 255, color.b * 255, level)
	end
	return tostring(level)
end

local function WithLevel(data, display)
	local lineID = tonumber(match(data, "^[^:]*:(%d+)"))
	if not lineID then
		return nil
	end
	local ok, guid = pcall(C_ChatInfo.GetChatLineSenderGUID, lineID)
	if not ok or not guid or IsSecret(guid) then
		return nil
	end
	local level = levels[guid]
	if not level then
		return nil
	end
	local inner = match(display, "^%[(.*)%]$")
	if not inner then
		return nil
	end
	return "|Hplayer:" .. data .. "|h[" .. inner .. ":" .. LevelText(level) .. "]|h"
end

-- Rewrites the player names in one stored chat line. Used by the chat window's
-- line rewrite in Core.lua, after the line is stored, so nothing runs inside
-- Blizzard's own chat handling.
function Module.AddNameLevels(text)
	if not text:find("|Hplayer:", 1, true) then
		return text
	end
	-- A nil from WithLevel keeps the original match.
	return (gsub(text, "|Hplayer:([^|]+)|h(.-)|h", WithLevel))
end

local function SetupNameLevels()
	local watcher = CreateFrame("Frame")
	for _, event in ipairs({ "GROUP_ROSTER_UPDATE", "UNIT_LEVEL", "PLAYER_LEVEL_UP", "GUILD_ROSTER_UPDATE", "FRIENDLIST_UPDATE", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT" }) do
		watcher:RegisterEvent(event)
	end
	watcher:SetScript("OnEvent", OnLevelEvent)
	ReadGroup()
	ReadFriends()
	if IsInGuild() and C_GuildInfo and C_GuildInfo.GuildRoster then
		C_GuildInfo.GuildRoster()
	end
end

-- ---------------------------------------------------------------------------

function Module:SetupExtras()
	SetupClearCommands()
	if C.Chat.MaxLines then
		SetupScrollback()
	end
	if C.Chat.RememberSent then
		SetupSentMemory()
	end
	if C.Chat.ShortLines then
		SetupShortLines()
	end
	if C.Chat.ChannelColorMemory then
		SetupChannelColors()
	end
	if C.Chat.NameLevels then
		SetupNameLevels()
	end
end
