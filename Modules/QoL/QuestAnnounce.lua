--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/QuestAnnounce.lua
	Purpose:
		Tell the group when you accept or finish a quest, with a clickable quest
		link, so a party working through the same story stays in step. Nothing is
		said while solo, and world quests and profession quests are left out.
		Objective progress can be told too, each finished objective or every
		step, from the same look at the log.

		Accepting is told from the accept event. Finishing is told when a quest in
		the log turns complete, found by checking the log when it changes and
		remembering which quests have already been announced. Anything seen while
		the log is still loading after login only records, so quests that were
		already done are not repeated.

		Messages go out through a short queue, one per SAY_GAP seconds. Chat is a
		server packet, and a burst of them gets a client disconnected.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local format = string.format
local ipairs = ipairs
local type = type
local IsSecret = K.IsSecret
local IsInGroup, IsInRaid = IsInGroup, IsInRaid
local C_QuestLog = C_QuestLog
local SendChatMessage = C_ChatInfo.SendChatMessage

local done = {} -- quest id -> true once announced as complete

-- The quest log fills in over several updates after login, so completion states
-- seen inside this window are recorded but never announced.
local SETTLE_TIME = 15
local startTime = GetTime()

-- Seconds between messages, and how many may wait. Past the cap, newest are dropped.
local SAY_GAP = 1.5
local MAX_QUEUED = 4
local outbox, draining = {}, false

local function Channel()
	if IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
end

local function Drain()
	local text = table.remove(outbox, 1)
	local channel = Channel()
	if text and channel then
		SendChatMessage(text, channel)
	end
	if #outbox > 0 then
		C_Timer.After(SAY_GAP, Drain)
	else
		draining = false
	end
end

-- Progress lines are capped so a big pull cannot flood chat. Accepted and
-- Completed lines are the ones that matter, so they always get a place.
local function Say(text, progressLine)
	if not Channel() or (progressLine and #outbox >= MAX_QUEUED) then
		return
	end
	outbox[#outbox + 1] = text
	if not draining then
		draining = true
		C_Timer.After(0, Drain)
	end
end

local function Title(questID)
	return _G.GetQuestLink(questID) or C_QuestLog.GetTitleForQuestID(questID) or ""
end

local function OnAccepted(_, _, questID)
	if not questID or C_QuestLog.IsWorldQuest(questID) then
		return
	end
	Say(format(L["Accepted: %s"], Title(questID)))
end

local queued

-- quest id -> { [objective index] = count fulfilled }, what was last seen.
local progress = {}

-- Objective steps since the last look. With "DONE" only an objective that has
-- just been finished is told, with "EVERY" each step is. Nothing is told for a
-- quest that finished in this same look, its Completed line says it all, and
-- the first look at a quest only records where it stands.
local function CheckObjectives(questID, settled)
	local mode = C.QoL.QuestProgress
	local objectives = C_QuestLog.GetQuestObjectives(questID)
	if not objectives then
		return
	end
	local seen = progress[questID]
	local first = seen == nil
	if first then
		seen = {}
		progress[questID] = seen
	end
	for i, objective in ipairs(objectives) do
		local count = objective.numFulfilled
		if type(count) == "number" and not IsSecret(count) then
			local before = seen[i]
			seen[i] = count
			local text = objective.text
			if settled and not first and before and count > before and type(text) == "string" and not IsSecret(text) and text ~= "" then
				if mode == "EVERY" or (mode == "DONE" and objective.finished) then
					Say(format("%s: %s", Title(questID), text), true)
				end
			end
		end
	end
end

local function Scan()
	queued = nil
	local settled = GetTime() - startTime > SETTLE_TIME
	local wantProgress = C.QoL.QuestProgress and C.QoL.QuestProgress ~= "OFF"
	for index = 1, C_QuestLog.GetNumQuestLogEntries() do
		local info = C_QuestLog.GetInfo(index)
		local questID = info and not info.isHeader and info.questID
		if questID and not C_QuestLog.IsWorldQuest(questID) then
			if not done[questID] and C_QuestLog.IsComplete(questID) then
				done[questID] = true
				if settled then
					Say(format(L["Completed: %s"], Title(questID)))
				end
			elseif wantProgress and not done[questID] then
				CheckObjectives(questID, settled)
			end
		end
	end
end

-- The log event comes in bursts, so one look a moment after it settles is enough.
local function OnLogChanged()
	if not queued then
		queued = true
		C_Timer.After(0.5, Scan)
	end
end

function Module:SetupQuestAnnounce()
	self:RegisterEvent("QUEST_ACCEPTED", OnAccepted)
	self:RegisterEvent("QUEST_LOG_UPDATE", OnLogChanged)
	self:RegisterEvent("QUEST_REMOVED", function(_, _, questID)
		done[questID] = nil
		progress[questID] = nil
	end)
end
