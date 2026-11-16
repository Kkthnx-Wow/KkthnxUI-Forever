--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/AutoAccept.lua
	Purpose:
		Three small accept-for-me automations, each off until switched on.

		Summons are accepted after a delay, so a summon into somewhere dangerous can
		still be cancelled by hand, and only once you are out of combat. Resurrection
		requests are accepted out of combat only, so a wipe is never undone mid
		encounter by accident. Group invites are accepted only from friends,
		Battle.net friends and guild members, going by the sender's GUID, and never
		while you are already grouped or queued.

		Each handler checks its toggle when it fires, so a change applies without a
		reload.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Automation")

local C_BattleNet = C_BattleNet
local C_FriendList = C_FriendList
local C_SummonInfo = C_SummonInfo
local C_Timer = C_Timer
local AcceptGroup = AcceptGroup
local AcceptResurrect = AcceptResurrect
local InCombatLockdown = InCombatLockdown
local IsGuildMember = IsGuildMember
local IsInGroup = IsInGroup
local StaticPopup_Hide = StaticPopup_Hide
local format = string.format
local IsSecret = K.IsSecret

-- Seconds a summon waits before it is taken, long enough to cancel it by hand.
local SUMMON_DELAY = 10

-- ---------------------------------------------------------------------------
-- Summons
-- ---------------------------------------------------------------------------
local function TakeSummon(summoner, area)
	-- The popup may have been answered or replaced during the wait, so only take
	-- the same summon that was announced.
	if C_SummonInfo.GetSummonConfirmSummoner() == summoner and C_SummonInfo.GetSummonConfirmAreaName() == area then
		C_SummonInfo.ConfirmSummon()
		StaticPopup_Hide("CONFIRM_SUMMON")
	end
end

local function OnSummon()
	if not C.Automation.AutoSummon or InCombatLockdown() then
		return
	end
	local summoner = C_SummonInfo.GetSummonConfirmSummoner()
	local area = C_SummonInfo.GetSummonConfirmAreaName()
	if not summoner or not area or IsSecret(summoner) or IsSecret(area) then
		return
	end
	K.Print(format(L["Accepting a summon from %s to %s in %d seconds."], summoner, area, SUMMON_DELAY))
	C_Timer.After(SUMMON_DELAY, function()
		if not InCombatLockdown() then
			TakeSummon(summoner, area)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Resurrections
-- ---------------------------------------------------------------------------
local function OnResurrect()
	if not C.Automation.AutoResurrect or InCombatLockdown() then
		return
	end
	AcceptResurrect()
	StaticPopup_Hide("RESURRECT_NO_TIMER")
	StaticPopup_Hide("RESURRECT")
end

-- ---------------------------------------------------------------------------
-- Group invites
-- ---------------------------------------------------------------------------
local lastInviter

local function KnowsPlayer(guid)
	return C_FriendList.IsFriend(guid) or C_BattleNet.GetAccountInfoByGUID(guid) ~= nil or IsGuildMember(guid)
end

local function OnInvite(_, _, _, _, _, _, _, _, guid)
	if not C.Automation.AutoInvite or not guid or IsSecret(guid) then
		return
	end
	-- Already grouped, queued, or the same person asking again after a decline.
	local queue = _G.QueueStatusButton
	if IsInGroup() or (queue and queue:IsShown()) or guid == lastInviter then
		return
	end
	if KnowsPlayer(guid) then
		lastInviter = guid
		AcceptGroup()
		StaticPopup_Hide("PARTY_INVITE")
	end
end

local function OnRosterUpdate()
	lastInviter = nil
end

function Module:SetupAutoAccept()
	self:RegisterEvent("CONFIRM_SUMMON", OnSummon)
	self:RegisterEvent("RESURRECT_REQUEST", OnResurrect)
	self:RegisterEvent("PARTY_INVITE_REQUEST", OnInvite)
	self:RegisterEvent("GROUP_ROSTER_UPDATE", OnRosterUpdate)
end
