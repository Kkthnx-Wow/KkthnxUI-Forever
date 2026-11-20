--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/LinkInfo.lua
	Purpose:
		Two small additions to item links in chat. Loot messages get the item icon
		in front of the link, and weapon or armor links in any public channel show
		their item level inside the brackets. Both are message filters, so they only
		change what is displayed. Items the client has not cached yet are left
		alone rather than waited on, and secret messages are never touched.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Chat")

local C_Item = C_Item
local ipairs = ipairs
local format = string.format
local gsub = string.gsub
local IsSecret = K.IsSecret

local ITEM_LINK = "(|c%x+|Hitem:.-|h|r)"
local LEVEL_EVENTS = {
	"CHAT_MSG_LOOT",
	"CHAT_MSG_CHANNEL",
	"CHAT_MSG_SAY",
	"CHAT_MSG_YELL",
	"CHAT_MSG_GUILD",
	"CHAT_MSG_OFFICER",
	"CHAT_MSG_PARTY",
	"CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID",
	"CHAT_MSG_RAID_LEADER",
	"CHAT_MSG_WHISPER",
	"CHAT_MSG_WHISPER_INFORM",
}

local function WithIcon(link)
	local icon = C_Item.GetItemIconByID(link)
	if not icon then
		return link
	end
	return format("|T%s:12:12:0:0:64:64:5:59:5:59|t%s", icon, link)
end

local function LootIconFilter(_, _, msg, ...)
	if type(msg) ~= "string" or IsSecret(msg) then
		return false
	end
	return false, gsub(msg, ITEM_LINK, WithIcon), ...
end

local function WithLevel(head, name, tail)
	local link = head .. "[" .. name .. "]" .. tail
	local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(link)
	if classID ~= Enum.ItemClass.Weapon and classID ~= Enum.ItemClass.Armor then
		return link
	end
	local level = C_Item.GetDetailedItemLevelInfo(link)
	if not level or level < 2 then
		return link
	end
	return format("%s[%s %d]%s", head, name, level, tail)
end

local function ItemLevelFilter(_, _, msg, ...)
	if type(msg) ~= "string" or IsSecret(msg) then
		return false
	end
	-- Rewrite only the text inside the brackets, the link data stays untouched so
	-- hover tooltips and clicks behave as before.
	return false, gsub(msg, "(|Hitem:[^|]+|h)%[([^%]]+)%](|h)", WithLevel), ...
end

function Module:SetupLinkInfo()
	if C.Chat.LootIcons then
		ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_LOOT", LootIconFilter)
	end
	if C.Chat.LinkItemLevel then
		for _, event in ipairs(LEVEL_EVENTS) do
			ChatFrameUtil.AddMessageEventFilter(event, ItemLevelFilter)
		end
	end
end
