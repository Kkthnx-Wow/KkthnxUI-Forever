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
local ipairs = ipairs
local next = next
local _G = _G
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

-- ---------------------------------------------------------------------------
-- Failure guard
-- ---------------------------------------------------------------------------
-- The game refuses a turn-in with full bags, then shows the NPC's window again.
-- Without memory of that, the window picked the same quest and tried again,
-- forever. Now every action we take is recorded, a refusal that follows it puts
-- that quest on hold, and the hold lifts when the thing that blocked it changes:
-- bag space for a full inventory, gold for a gold cost, or a short wait for the
-- rest. On top of that no quest gets the same action more than twice in a short
-- window, so a refusal we do not recognise cannot loop either.

local GetTime = GetTime
local GetTitleText = GetTitleText
local C_Container = C_Container
local strfind = string.find
local gsub = string.gsub

local ATTEMPT_WINDOW = 15 -- seconds in which repeated tries count together
local ATTEMPT_LIMIT = 2 -- tries of one action on one quest inside that window
local ERROR_WINDOW = 3 -- seconds after an action that a refusal is pinned on it
local HOLD_TIMEOUT = 60 -- a hold with no clearing event lifts after this long

-- Why a quest is on hold, each with the change that lifts it.
local BAGS, MONEY, ITEMS, OTHER = "bags", "money", "items", "other"

local attempts = {} -- "kind:questID" -> { count, first }
local holds = {} -- questID -> { reason, at, free }
local lastAction -- { kind, questID, at }

-- A format string from the client turned into a plain Lua pattern.
local function ToPattern(text)
	if not text then
		return nil
	end
	text = gsub(text, "([%(%)%.%+%-%*%?%[%]%^%$])", "%%%1")
	-- A single %s or %d in the client string stands for the quest name or a count.
	text = gsub(text, "%%[sd]", ".+")
	return "^" .. text .. "$"
end

-- Refusal messages and the hold each one means.
local REFUSALS = {
	{ _G.ERR_INV_FULL, BAGS },
	{ _G.ERR_BAG_FULL, BAGS },
	{ _G.ERR_ITEM_MAX_COUNT, BAGS },
	{ _G.ERR_QUEST_FAILED_BAG_FULL_S, BAGS },
	{ _G.ERR_QUEST_FAILED_MAX_COUNT_S, BAGS },
	{ _G.ERR_QUEST_FAILED_NOT_ENOUGH_MONEY, MONEY },
	{ _G.ERR_QUEST_FAILED_MISSING_ITEMS, ITEMS },
	{ _G.ERR_QUEST_LOG_FULL, OTHER },
	{ _G.ERR_QUEST_FAILED_S, OTHER },
	{ _G.ERR_QUEST_FAILED_LOW_LEVEL, OTHER },
	{ _G.ERR_QUEST_FAILED_TOO_MANY_DAILY_QUESTS_I, OTHER },
}
for _, entry in ipairs(REFUSALS) do
	entry[3] = ToPattern(entry[1])
end

local HOLD_TEXT = {
	[BAGS] = L["your bags are full"],
	[MONEY] = L["it costs more gold than you have"],
	[ITEMS] = L["the required items are not in your bags"],
	[OTHER] = L["the game refused it"],
}

-- Free slots in the ordinary bags, the ones a quest reward can land in.
local function FreeBagSlots()
	local free = 0
	for bag = 0, 4 do
		local slots, family = C_Container.GetContainerNumFreeSlots(bag)
		if slots and family == 0 then
			free = free + slots
		end
	end
	return free
end
Module.FreeBagSlots = FreeBagSlots

local function QuestName(questID)
	local title = C_QuestLog.GetTitleForQuestID and C_QuestLog.GetTitleForQuestID(questID)
	if not title or IsSecret(title) then
		title = GetTitleText and GetTitleText()
	end
	if not title or IsSecret(title) or title == "" then
		title = tostring(questID)
	end
	return title
end

-- Put a quest on hold and say so once.
function Module:HoldQuest(questID, reason)
	if not self:ValidQuest(questID) then
		return
	end
	local current = holds[questID]
	holds[questID] = { reason = reason, at = GetTime(), free = FreeBagSlots() }
	if not current or current.reason ~= reason then
		K.Print(L["Auto quest paused %s because %s. It picks up again once that changes."], K.ColorText("highlight", QuestName(questID)), HOLD_TEXT[reason] or HOLD_TEXT[OTHER])
	end
end

-- Is this quest on hold? A hold past its timeout lifts here.
function Module:IsHeld(questID)
	local hold = questID and holds[questID]
	if not hold then
		return false
	end
	if GetTime() - hold.at > HOLD_TIMEOUT then
		holds[questID] = nil
		return false
	end
	return true
end

-- Ask before taking an action on a quest. Records it, and says no when the quest
-- is on hold or has had this action twice already in the window.
function Module:TryAction(kind, questID)
	if not self:ValidQuest(questID) or self:IsHeld(questID) then
		return false
	end
	local now = GetTime()
	local key = kind .. ":" .. questID
	local record = attempts[key]
	if record and now - record.first > ATTEMPT_WINDOW then
		record = nil
	end
	if not record then
		record = { count = 0, first = now }
		attempts[key] = record
	end
	if record.count >= ATTEMPT_LIMIT then
		-- Something keeps refusing this without a message we know.
		self:HoldQuest(questID, OTHER)
		return false
	end
	record.count = record.count + 1
	lastAction = { kind = kind, questID = questID, at = now }
	return true
end

-- A quest that went through clears everything we held about it.
function Module:ForgetQuest(questID)
	if not questID then
		return
	end
	holds[questID] = nil
	for _, kind in ipairs({ "accept", "select", "progress", "reward" }) do
		attempts[kind .. ":" .. questID] = nil
	end
	if lastAction and lastAction.questID == questID then
		lastAction = nil
	end
end

-- A refusal right after one of our actions is pinned on that quest.
function Module:OnQuestError(_, _, message)
	if not lastAction or not message or IsSecret(message) then
		return
	end
	if GetTime() - lastAction.at > ERROR_WINDOW then
		return
	end
	for _, entry in ipairs(REFUSALS) do
		if entry[3] and strfind(message, entry[3]) then
			local questID = lastAction.questID
			lastAction = nil
			self:HoldQuest(questID, entry[2])
			return
		end
	end
end

-- Lift holds once what blocked them has changed. Bag holds lift when a slot
-- opens up compared to when the hold began, gold holds on any money change.
function Module:OnBagsChanged()
	if not next(holds) then
		return
	end
	local free = FreeBagSlots()
	for questID, hold in pairs(holds) do
		if (hold.reason == BAGS and free > hold.free) or hold.reason == ITEMS then
			holds[questID] = nil
		end
	end
end

function Module:OnMoneyChanged()
	for questID, hold in pairs(holds) do
		if hold.reason == MONEY then
			holds[questID] = nil
		end
	end
end

function Module:OnQuestDone(_, questID)
	self:ForgetQuest(questID)
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
		-- The failure guard: refusals, and the changes that lift a hold.
		self:RegisterEvent("UI_ERROR_MESSAGE", "OnQuestError")
		self:RegisterEvent("BAG_UPDATE_DELAYED", "OnBagsChanged")
		self:RegisterEvent("PLAYER_MONEY", "OnMoneyChanged")
		self:RegisterEvent("QUEST_TURNED_IN", "OnQuestDone")
		self:RegisterEvent("QUEST_ACCEPTED", "OnQuestDone")
	end)
end
