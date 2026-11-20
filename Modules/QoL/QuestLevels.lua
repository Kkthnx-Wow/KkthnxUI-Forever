--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/QuestLevels.lua
	Purpose:
		Put the quest level in front of quest titles where the game leaves it out.
		Forever already writes "[12] Title" in the quest log, the objective
		tracker and the map tooltips. The NPC windows do not, so this adds the
		same prefix to:
			the quest list in a gossip window
			the quest list in a quest giver's greeting
			the title at the top of a quest's text

		It uses the game's own format, with a + for elite quests, and colours the
		number by how hard the quest is for you. Every change is a post hook on
		text the game has just set, so nothing it does or reads is altered.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("QoL")

local _G = _G
local format = string.format
local hooksecurefunc = hooksecurefunc

local C_QuestLog = C_QuestLog

-- "[12] " or "[12+] ", with the number in the difficulty colour.
local function Prefix(questID, level)
	if not level or level <= 0 then
		level = questID and C_QuestLog.GetQuestDifficultyLevel(questID)
	end
	if not level or level <= 0 then
		return nil
	end
	local elite = questID and C_QuestLog.IsEliteQuest and C_QuestLog.IsEliteQuest(questID) and "+" or ""
	local text = format("[%d%s]", level, elite)
	local difficulty = questID and C_PlayerInfo and C_PlayerInfo.GetContentDifficultyQuestForPlayer
	if difficulty and GetDifficultyColor then
		local color = GetDifficultyColor(difficulty(questID))
		if color and color.r then
			text = K.RGBToHex(color) .. text .. "|r"
		end
	end
	return text .. " "
end

-- ---------------------------------------------------------------------------
-- Gossip
-- ---------------------------------------------------------------------------

local function OnGossipButton(_, button, elementData)
	local info = elementData and elementData.info
	if not info or not info.questID or not (elementData.availableQuestButton or elementData.activeQuestButton) then
		return
	end
	if not button.UpdateTitleForQuest then
		return
	end
	local prefix = Prefix(info.questID, info.questLevel)
	if prefix then
		button:UpdateTitleForQuest(info.questID, prefix .. info.title, info.isIgnored, info.isTrivial)
	end
end

local function HookGossip()
	local gossip = _G.GossipFrame
	local scrollBox = gossip and gossip.GreetingPanel and gossip.GreetingPanel.ScrollBox
	if not scrollBox or not scrollBox.RegisterCallback or not ScrollBoxListMixin then
		return
	end
	scrollBox:RegisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, OnGossipButton, Module)
end

-- ---------------------------------------------------------------------------
-- Quest greeting
-- ---------------------------------------------------------------------------

local function OnGreetingShow()
	local panel = _G.QuestFrameGreetingPanel
	local pool = panel and panel.titleButtonPool
	if not pool then
		return
	end
	for button in pool:EnumerateActive() do
		local id = button:GetID()
		local questID
		if button.isActive == 1 then
			questID = GetActiveQuestID(id)
		else
			questID = select(5, GetAvailableQuestInfo(id))
		end
		local prefix = questID and Prefix(questID)
		local text = button:GetText()
		-- The panel can be refreshed in place, so a title already carrying the
		-- prefix is left as it is.
		if prefix and text and text ~= button.__kkuiLevelText then
			button:SetText(prefix .. text)
			button.__kkuiLevelText = button:GetText()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Quest text title
-- ---------------------------------------------------------------------------

local function OnShowTitle()
	local header = _G.QuestInfoTitleHeader
	local frame = _G.QuestInfoFrame
	if not header or not header:IsShown() then
		return
	end
	local questID
	if frame and frame.questLog then
		questID = C_QuestLog.GetSelectedQuest()
	else
		questID = GetQuestID()
	end
	local prefix = questID and questID > 0 and Prefix(questID)
	local text = header:GetText()
	if prefix and text and text ~= header.__kkuiLevelText then
		header:SetText(prefix .. text)
		header.__kkuiLevelText = header:GetText()
	end
end

function Module:SetupQuestLevels()
	if self.questLevelsHooked or not C.QoL.QuestLevels then
		return
	end
	self.questLevelsHooked = true
	HookGossip()
	-- The panel's XML OnShow holds the function itself, so the script is hooked
	-- for that path and the global for the refresh the quest frame calls by name.
	local greeting = _G.QuestFrameGreetingPanel
	if greeting then
		greeting:HookScript("OnShow", OnGreetingShow)
	end
	if _G.QuestFrameGreetingPanel_OnShow then
		hooksecurefunc("QuestFrameGreetingPanel_OnShow", OnGreetingShow)
	end
	-- The title is drawn from a layout table that holds QuestInfo_ShowTitle
	-- itself, so the hook goes on the call that runs the whole layout.
	if _G.QuestInfo_Display then
		hooksecurefunc("QuestInfo_Display", OnShowTitle)
	end
end
