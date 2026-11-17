--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/Accept.lua
	Purpose:
		Accepting quests across every window the game uses: the gossip list, the
		older quest-greeting list, the single-quest detail page, area-trigger and
		auto-accept popups, and shared-quest confirmations. Optionally pushes newly
		accepted quests to the party.

		A list window is handled one quest at a time. Picking a quest swaps the
		window to that quest, so the rest of the list is stale until the NPC shows
		it again. Turn-ins go first so a finished quest can open the next one.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Automation")

local next = next
local IsSecret = K.IsSecret
local InCombatLockdown = InCombatLockdown
local IsInGroup = IsInGroup
local C_GossipInfo = C_GossipInfo
local C_QuestLog = C_QuestLog

local GetNumActiveQuests = GetNumActiveQuests
local GetActiveTitle = GetActiveTitle
local GetActiveQuestID = GetActiveQuestID
local SelectActiveQuest = SelectActiveQuest
local GetNumAvailableQuests = GetNumAvailableQuests
local GetAvailableQuestInfo = GetAvailableQuestInfo
local SelectAvailableQuest = SelectAvailableQuest
local GetQuestID = GetQuestID
local QuestGetAutoAccept = QuestGetAutoAccept
local AcknowledgeAutoAcceptQuest = AcknowledgeAutoAcceptQuest
local RemoveAutoQuestPopUp = RemoveAutoQuestPopUp
local AcceptQuest = AcceptQuest
local ConfirmAcceptQuest = ConfirmAcceptQuest
local GetNumAutoQuestPopUps = GetNumAutoQuestPopUps
local GetAutoQuestPopUp = GetAutoQuestPopUp
local ShowQuestOffer = ShowQuestOffer
local ShowQuestComplete = ShowQuestComplete
local QuestLogPushQuest = QuestLogPushQuest

-- Quests offered and completed through a gossip window. Returns true when a
-- quest was picked, so the gossip skip leaves the window alone.
function Module:HandleGossipQuests()
	for _, quest in next, C_GossipInfo.GetActiveQuests() do
		if quest.isComplete and not IsSecret(quest.isComplete) and self:ShouldTurnIn(quest.questID, quest.frequency, quest.repeatable or false) then
			C_GossipInfo.SelectActiveQuest(quest.questID)
			return true
		end
	end

	for _, quest in next, C_GossipInfo.GetAvailableQuests() do
		if self:ShouldAccept(quest.questID, quest.isTrivial, quest.frequency, quest.repeatable or false) then
			C_GossipInfo.SelectAvailableQuest(quest.questID)
			return true
		end
	end

	return false
end

-- Fired for both quest gossip and plain gossip. Deal with quests first, then let
-- the gossip file decide whether to click through a lone gossip option.
function Module:OnGossipShow()
	if not self:CanAutomate() then
		return
	end
	if not self:HandleGossipQuests() and self.HandleGossipSkip then
		self:HandleGossipSkip()
	end
end

-- The older quest-greeting list, used by NPCs without full gossip.
function Module:OnQuestGreeting()
	if not self:CanAutomate() then
		return
	end

	for index = 1, GetNumActiveQuests() do
		local _, isComplete = GetActiveTitle(index)
		if isComplete and self:ShouldTurnIn(GetActiveQuestID(index)) then
			SelectActiveQuest(index)
			return
		end
	end

	for index = 1, GetNumAvailableQuests() do
		local isTrivial, frequency, isRepeatable, _, questID = GetAvailableQuestInfo(index)
		if self:ShouldAccept(questID, isTrivial, frequency, isRepeatable or false) then
			SelectAvailableQuest(index)
			return
		end
	end
end

-- The single-quest detail page shown before accepting.
function Module:OnQuestDetail()
	if not C.AutoQuest.Accept or not self:CanAutomate() then
		return
	end

	local questID = GetQuestID()
	if not self:ValidQuest(questID) then
		return
	end

	if QuestGetAutoAccept() then
		-- Already accepted by the game, the page is only a notice.
		AcknowledgeAutoAcceptQuest()
		RemoveAutoQuestPopUp(questID)
		return
	end

	if self:IsSharedQuest() and not C.AutoQuest.SharedQuests then
		return
	end

	if self:ShouldAccept(questID) then
		AcceptQuest()
	end
end

-- Popups in the objective tracker for quests offered or finished away from an
-- NPC. The popup stays until the quest is dealt with, so each one is opened
-- only once rather than on every quest log update.
local handledPopups = {}

function Module:OnQuestLogUpdate()
	if InCombatLockdown() or not self:CanAutomate() then
		return
	end

	for index = 1, GetNumAutoQuestPopUps() do
		local questID, popUpType = GetAutoQuestPopUp(index)
		if self:ValidQuest(questID) and handledPopups[questID] ~= popUpType then
			if popUpType == "OFFER" and self:ShouldAccept(questID) then
				handledPopups[questID] = popUpType
				ShowQuestOffer(questID)
				return
			elseif popUpType == "COMPLETE" and self:ShouldTurnIn(questID) then
				handledPopups[questID] = popUpType
				ShowQuestComplete(questID)
				return
			end
		end
	end
end

-- Forget a quest once it leaves the log, so the table stays as small as the log.
function Module:OnQuestRemoved(_, questID)
	if questID then
		handledPopups[questID] = nil
	end
end

-- A party member starting an escort or similar asks everyone to confirm.
function Module:OnQuestAcceptConfirm()
	if C.AutoQuest.Accept and C.AutoQuest.SharedQuests and not self:IsPaused() then
		ConfirmAcceptQuest()
	end
end

-- Push a freshly accepted quest to the party when sharing is on. Pushing works
-- on the quest log's selection, so select it and then put the old one back.
function Module:OnQuestAccepted(_, questID)
	if not C.AutoQuest.Share or InCombatLockdown() or not IsInGroup() then
		return
	end
	if not self:ValidQuest(questID) or not C_QuestLog.IsPushableQuest(questID) then
		return
	end
	local logIndex = C_QuestLog.GetLogIndexForQuestID(questID)
	if not logIndex then
		return
	end

	local previous = C_QuestLog.GetSelectedQuest()
	C_QuestLog.SetSelectedQuest(questID)
	QuestLogPushQuest(logIndex)
	if previous and previous ~= questID then
		C_QuestLog.SetSelectedQuest(previous)
	end
end

function Module:SetupAccept()
	self:RegisterEvent("GOSSIP_SHOW", "OnGossipShow")
	self:RegisterEvent("QUEST_GREETING", "OnQuestGreeting")
	self:RegisterEvent("QUEST_DETAIL", "OnQuestDetail")
	self:RegisterEvent("QUEST_LOG_UPDATE", "OnQuestLogUpdate")
	self:RegisterEvent("QUEST_REMOVED", "OnQuestRemoved")
	self:RegisterEvent("QUEST_ACCEPT_CONFIRM", "OnQuestAcceptConfirm")
	self:RegisterEvent("QUEST_ACCEPTED", "OnQuestAccepted")
end
