--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/Quest.lua
	Purpose:
		Hands-off questing, part of the Automation module. This file owns the shared
		quest helpers (pause key, NPC blocklist, the accept and turn-in tests) and
		the event wiring. The per-stage handlers live in sibling files so each
		stays readable:
			Accept.lua  gossip quests, quest lists, detail, and auto-popups
			TurnIn.lua  progress, completion, and reward selection
			Gossip.lua  clicking through a single-option gossip
		Each window is handled one quest at a time. Picking a quest swaps the
		window, so the next quest is handled when the NPC shows its list again.
		The whole thing pauses while a modifier is held, so nothing runs away from
		you when you actually want to read a quest.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Automation")

local gmatch = string.gmatch
local match = string.match
local tonumber = tonumber
local tostring = tostring
local tconcat = table.concat
local tsort = table.sort
local pairs = pairs
local IsSecret = K.IsSecret
local IsShiftKeyDown = IsShiftKeyDown
local IsControlKeyDown = IsControlKeyDown
local IsAltKeyDown = IsAltKeyDown
local UnitGUID = UnitGUID
local UnitName = UnitName
local UnitIsPlayer = UnitIsPlayer
local QuestIsDaily = QuestIsDaily
local QuestIsWeekly = QuestIsWeekly
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer
local Item = Item

-- Automation stops while the pause key is held, so you can read or decline a
-- quest by hand. NONE turns the pause off entirely.
function Module:IsPaused()
	local key = C.AutoQuest.PauseKey
	if key == "SHIFT" then
		return IsShiftKeyDown()
	elseif key == "CTRL" then
		return IsControlKeyDown()
	elseif key == "ALT" then
		return IsAltKeyDown()
	end
	return false
end

-- A questID that is nil, zero, or a secret value is never safe to act on.
function Module:ValidQuest(questID)
	return questID and not IsSecret(questID) and questID ~= 0
end

-- ---------------------------------------------------------------------------
-- NPC blocklist
-- ---------------------------------------------------------------------------

-- The NPC the open gossip or quest window belongs to, or nil for a player, an
-- object, or a GUID the client keeps secret.
function Module:GetNPCID()
	local guid = UnitGUID("npc")
	if not guid or IsSecret(guid) then
		return nil
	end
	local unitType, id = match(guid, "^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)")
	if unitType == "Creature" or unitType == "Vehicle" then
		return tonumber(id)
	end
	return nil
end

-- The list is stored as the text the config editbox shows, so parse it again
-- only when that text changes.
local blockedText, blockedSet
local function GetBlockedSet()
	local text = C.AutoQuest.BlockedNPCs or ""
	if text ~= blockedText then
		blockedText = text
		blockedSet = {}
		for id in gmatch(text, "%d+") do
			blockedSet[tonumber(id)] = true
		end
	end
	return blockedSet
end

function Module:IsBlockedNPC()
	local npcID = self:GetNPCID()
	return npcID and GetBlockedSet()[npcID] or false
end

-- Add or remove the NPC you are talking to. Run from /kk questblock.
function Module:ToggleBlockedNPC()
	local npcID = self:GetNPCID()
	if not npcID then
		K.Print(L["Talk to an NPC first, then run this again."])
		return
	end

	local set = GetBlockedSet()
	local nowBlocked = not set[npcID]
	local ids = {}
	for id in pairs(set) do
		if id ~= npcID then
			ids[#ids + 1] = id
		end
	end
	if nowBlocked then
		ids[#ids + 1] = npcID
	end
	tsort(ids)
	for i = 1, #ids do
		ids[i] = tostring(ids[i])
	end
	K:SetConfig({ "AutoQuest", "BlockedNPCs" }, tconcat(ids, ", "))

	local name = UnitName("npc")
	if not name or IsSecret(name) then
		name = tostring(npcID)
	end
	if nowBlocked then
		K.Print(L["Auto quest now ignores %s."], K.ColorText("highlight", name))
	else
		K.Print(L["Auto quest works with %s again."], K.ColorText("highlight", name))
	end
end

-- ---------------------------------------------------------------------------
-- Tests shared by the handlers
-- ---------------------------------------------------------------------------

-- Nothing runs while paused or while talking to a blocked NPC.
function Module:CanAutomate()
	return not self:IsPaused() and not self:IsBlockedNPC()
end

-- A party member offering a quest shows up as a player in the quest window.
function Module:IsSharedQuest()
	local isPlayer = UnitIsPlayer("npc")
	return isPlayer and not IsSecret(isPlayer) or false
end

-- Daily, weekly and other repeatable quests. The flags come from the list entry
-- when there is one, otherwise from the open quest window and the quest log.
function Module:IsRepeatable(questID, frequency, isRepeatable)
	if isRepeatable or (frequency and frequency ~= 0) then
		return true
	end
	-- A list entry that carried its flags has already answered. The open quest
	-- window below belongs to some other quest while a list is showing.
	if frequency ~= nil or isRepeatable ~= nil then
		return false
	end
	if QuestIsDaily() or QuestIsWeekly() then
		return true
	end
	return C_QuestLog.IsRepeatableQuest(questID) or false
end

-- The quest log refuses new quests once it is full, so do not try.
function Module:IsQuestLogFull()
	local _, numQuests = C_QuestLog.GetNumQuestLogEntries()
	local maxQuests = C_QuestLog.GetMaxNumQuestsCanAccept()
	return numQuests and maxQuests and numQuests >= maxQuests or false
end

-- Should this quest be picked up? isTrivial, frequency and isRepeatable are the
-- list entry's own flags when the caller has them.
function Module:ShouldAccept(questID, isTrivial, frequency, isRepeatable)
	if not C.AutoQuest.Accept or not self:ValidQuest(questID) then
		return false
	end
	if C_QuestLog.IsWorldQuest(questID) then
		return false
	end
	if C.AutoQuest.IgnoreTrivial then
		if isTrivial == nil then
			isTrivial = C_QuestLog.IsQuestTrivial(questID)
		end
		if isTrivial then
			return false
		end
	end
	if not C.AutoQuest.Repeatable and self:IsRepeatable(questID, frequency, isRepeatable) then
		return false
	end
	return not self:IsQuestLogFull()
end

-- Should this quest be handed in? Grey quests always are, since you already
-- hold them. Repeatable ones usually eat materials, so they follow their toggle.
function Module:ShouldTurnIn(questID, frequency, isRepeatable)
	if not C.AutoQuest.TurnIn or not self:ValidQuest(questID) then
		return false
	end
	if not C.AutoQuest.Repeatable and self:IsRepeatable(questID, frequency, isRepeatable) then
		return false
	end
	return true
end

-- Item values are needed to pick the best quest reward, and may be cold.
function Module:WaitForItemData(itemID, callback)
	Item:CreateFromItemID(itemID):ContinueOnItemLoad(callback)
end

-- Pick Best Reward used to be a plain on and off. Carry an "off" over to the
-- reward mode so nobody gets a choice made for them they had turned off.
local function MigrateRewardSetting()
	local stored = K.ActiveProfile and K.ActiveProfile.AutoQuest
	if stored and stored.SelectReward ~= nil then
		if stored.SelectReward == false and stored.RewardMode == nil then
			K:SetConfig({ "AutoQuest", "RewardMode" }, "OFF")
		end
		stored.SelectReward = nil
	end
end

-- Wired from the Automation module's OnEnable. Gated on its own toggle so the
-- rest of the module still runs when auto-quest is off.
function Module:SetupQuests()
	if not C.AutoQuest.Enable then
		return
	end

	MigrateRewardSetting()

	-- A short delay after login lets the quest APIs settle before we hook in.
	C_Timer.After(1, function()
		if self.SetupAccept then
			self:SetupAccept()
		end
		if self.SetupTurnIn then
			self:SetupTurnIn()
		end
		if self.SetupGossip then
			self:SetupGossip()
		end
	end)
end
