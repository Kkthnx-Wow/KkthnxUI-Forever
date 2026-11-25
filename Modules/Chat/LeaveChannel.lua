--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/LeaveChannel.lua
	Purpose:
		Two ways to leave a chat channel without a slash command. Right-clicking
		a channel name in a chat line, such as [2. Trade], gets a Leave entry.
		Right-clicking a chat tab gets a Leave Channel submenu listing every
		channel you are in.

		The menu is built before any hook on Blizzard's menu function would run,
		so the channel is read from the menu's own title. For a numbered channel
		that title carries a channel link with the channel number. Community
		channels and the fixed chat types (Say, Guild and so on) have no such
		link and get no Leave entry.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Chat")

local tonumber = tonumber
local type = type
local format = string.format
local match = string.match
local select = select

local GetChannelName = GetChannelName
local GetChannelList = _G.GetChannelList
local LeaveChannelByLocalID = _G.LeaveChannelByLocalID
local LeaveChannelByName = _G.LeaveChannelByName
local CHAT_LEAVE = _G.CHAT_LEAVE
local IsSecret = K.IsSecret

-- The title is the first entry, anything after it is a button.
local function ChannelFromMenu(rootDescription)
	local iterate, state, start = rootDescription:EnumerateElementDescriptions()
	local _, title = iterate(state, start)
	local text = title and MenuUtil.GetElementText(title)
	if type(text) ~= "string" or IsSecret(text) then
		return nil
	end
	return tonumber(match(text, "|Hchannel:channel:(%d+)|h"))
end

local function Leave(number)
	local id, name = GetChannelName(number)
	if not id or id == 0 then
		return
	end
	if LeaveChannelByLocalID then
		LeaveChannelByLocalID(id)
	elseif name then
		LeaveChannelByName(name)
	end
end

local function OnChannelMenu(_, rootDescription)
	local number = ChannelFromMenu(rootDescription)
	if not number or GetChannelName(number) == 0 then
		return
	end
	rootDescription:CreateDivider()
	rootDescription:CreateButton(CHAT_LEAVE or L["Leave"], function()
		Leave(number)
	end)
end

-- GetChannelList returns id, name, disabled for each channel in turn.
local function OnTabMenu(_, rootDescription)
	local count = select("#", GetChannelList())
	if count == 0 then
		return
	end
	rootDescription:CreateDivider()
	local submenu = rootDescription:CreateButton(L["Leave Channel"])
	for i = 1, count, 3 do
		local id, name = select(i, GetChannelList())
		if id and name and not IsSecret(name) then
			submenu:CreateButton(format("%d. %s", id, name), function()
				Leave(id)
			end)
		end
	end
end

function Module:SetupLeaveChannel()
	if C.Chat.LeaveChannelMenu == false then
		return
	end
	if not (Menu and Menu.ModifyMenu and MenuUtil and MenuUtil.GetElementText) then
		return
	end

	Menu.ModifyMenu("MENU_CHAT_FRAME_CHANNEL", OnChannelMenu)
	if GetChannelList then
		Menu.ModifyMenu("MENU_FCF_TAB", OnTabMenu)
	end
end
