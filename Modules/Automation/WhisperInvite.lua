--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/WhisperInvite.lua
	Purpose:
		Send a group invite to anyone who whispers you a keyword you choose, such
		as "inv". The whole whisper has to be the keyword, so a sentence that
		happens to contain the word does not trigger it. Case and spaces around
		it are ignored.

		It only invites when you are able to, which is when you are not grouped
		or you lead the group or assist in a raid. It stays quiet while you are
		queued, and the same person whispering again within a few seconds gets
		one invite, not several.

		The invite goes to the name the whisper came from, the same name a reply
		goes to. The handler checks its toggle when it fires, so a change applies
		without a reload.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Automation")

local _G = _G
local lower = string.lower
local match = string.match

local GetTime = GetTime
local IsInGroup = IsInGroup
local IsInRaid = IsInRaid
local UnitIsGroupAssistant = UnitIsGroupAssistant
local UnitIsGroupLeader = UnitIsGroupLeader
local C_PartyInfo = C_PartyInfo
local IsSecret = K.IsSecret

-- Seconds before the same sender can trigger another invite.
local REPEAT_DELAY = 10

local lastSender
local lastTime = 0

local function Trim(text)
	return match(text, "^%s*(.-)%s*$")
end

local function CanInvite()
	if not IsInGroup() then
		return true
	end
	if UnitIsGroupLeader("player") then
		return true
	end
	return IsInRaid() and UnitIsGroupAssistant("player")
end

local function OnWhisper(_, _, message, sender)
	local db = C.Automation
	if not db.WhisperInvite or not message or not sender then
		return
	end
	if IsSecret(message) or IsSecret(sender) then
		return
	end

	local keyword = Trim(db.WhisperInviteWord or "")
	if keyword == "" or lower(Trim(message)) ~= lower(keyword) then
		return
	end

	local queue = _G.QueueStatusButton
	if (queue and queue:IsShown()) or not CanInvite() then
		return
	end

	local now = GetTime()
	if sender == lastSender and now - lastTime < REPEAT_DELAY then
		return
	end
	lastSender, lastTime = sender, now

	C_PartyInfo.InviteUnit(sender)
end

function Module:SetupWhisperInvite()
	if not (C_PartyInfo and C_PartyInfo.InviteUnit) then
		return
	end
	self:RegisterEvent("CHAT_MSG_WHISPER", OnWhisper)
end
