--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Tooltip/QuestItem.lua
	Purpose:
		Name the quest a bag item starts and say where you stand with it: not
		started, in your quest log, ready to turn in, or already done. The game
		only says "This Item Begins a Quest", which leaves you guessing whether
		the item is still worth keeping.

		Only bag items are read, since the quest link comes from the bag slot.
		A quest the client has not loaded yet shows its status without a name
		and is asked for, so the next hover has the name.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Tooltip")

local format = string.format

-- Quests already asked for, so a tooltip that refreshes several times a second
-- asks once. A quest ID is small and the set only grows with quest items seen.
local requested = {}

local C_Container = C_Container
local C_QuestLog = C_QuestLog
local IsSecret = K.IsSecret

local function StatusFor(questID, isActive)
	if isActive then
		if C_QuestLog.ReadyForTurnIn(questID) then
			return L["Ready to turn in"], K.Colors.positive
		end
		return L["In your quest log"], K.Colors.positive
	end
	if C_QuestLog.IsQuestFlaggedCompleted(questID) then
		return L["Already completed"], K.Colors.muted
	end
	return L["Not started"], K.Colors.highlight
end

local function OnItemTooltip(tt, data)
	if tt:IsForbidden() or not data then
		return
	end
	local info = tt.processingInfo
	if not info or info.getterName ~= "GetBagItem" or not info.getterArgs then
		return
	end
	local bag, slot = info.getterArgs[1], info.getterArgs[2]
	if not bag or not slot or IsSecret(bag) or IsSecret(slot) then
		return
	end

	local quest = C_Container.GetContainerItemQuestInfo(bag, slot)
	local questID = quest and quest.questID
	if not questID then
		return
	end

	local status, color = StatusFor(questID, quest.isActive)
	local title = C_QuestLog.GetTitleForQuestID(questID)
	if not title and not requested[questID] then
		requested[questID] = true
		C_QuestLog.RequestLoadQuestByID(questID)
	end

	local name = K.Colors.highlight
	tt:AddLine(" ")
	if title then
		local level = C_QuestLog.GetQuestDifficultyLevel(questID)
		if level and level > 0 then
			title = format("[%d] %s", level, title)
		end
		tt:AddLine(title, name[1], name[2], name[3], true)
	end
	tt:AddLine(status, color[1], color[2], color[3])
	tt:Show()
end

function Module:SetupQuestItem()
	if C.Tooltip.QuestItemInfo == false then
		return
	end
	if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item) then
		return
	end
	if not (C_Container and C_Container.GetContainerItemQuestInfo and C_QuestLog and C_QuestLog.GetTitleForQuestID) then
		return
	end

	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, OnItemTooltip)
end
