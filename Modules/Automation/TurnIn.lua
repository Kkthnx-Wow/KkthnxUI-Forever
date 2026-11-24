--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/TurnIn.lua
	Purpose:
		Handing quests in: continuing through the progress page and completing the
		quest. On a choice of rewards the reward mode decides: leave it, mark the
		one that sells for the most, or take that one. Quests that cost gold to
		hand in can be left to you.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Automation")

local select = select
local IsSecret = K.IsSecret
local CreateFrame = CreateFrame
local C_Item = C_Item

local GetQuestID = GetQuestID
local IsQuestCompletable = IsQuestCompletable
local CompleteQuest = CompleteQuest
local GetNumQuestChoices = GetNumQuestChoices
local GetQuestItemInfo = GetQuestItemInfo
local GetQuestReward = GetQuestReward
local GetQuestMoneyToGet = GetQuestMoneyToGet
local GetNumQuestRewards = GetNumQuestRewards

local COIN_ICON = "Interface\\Icons\\INV_Misc_Coin_01"

-- True when handing this quest in would take gold and that is switched off.
local function CostsGold()
	if not C.AutoQuest.SkipGoldCost then
		return false
	end
	local money = GetQuestMoneyToGet()
	return money and not IsSecret(money) and money > 0 or false
end

-- Continue past the progress page when the quest can be turned in.
function Module:OnQuestProgress()
	if not self:CanAutomate() or not self:ShouldTurnIn(GetQuestID()) then
		return
	end
	local questID = GetQuestID()
	if IsQuestCompletable() and not CostsGold() and self:TryAction("progress", questID) then
		CompleteQuest()
	end
end

-- ---------------------------------------------------------------------------
-- Reward choice
-- ---------------------------------------------------------------------------

-- The reward button the quest window drew for choice number index.
local function GetChoiceButton(index)
	local rewards = _G.QuestInfoRewardsFrame
	local buttons = rewards and rewards.RewardButtons
	if buttons then
		for i = 1, #buttons do
			local button = buttons[i]
			if button.type == "choice" and button:GetID() == index and button:IsShown() then
				return button
			end
		end
	end
	return nil
end

-- One coin badge, moved to whichever reward is worth the most.
local marker
local function ShowMarker(index)
	local button = GetChoiceButton(index)
	if not button then
		return
	end
	if not marker then
		marker = CreateFrame("Frame")
		marker:SetSize(18, 18)
		local icon = marker:CreateTexture(nil, "OVERLAY")
		icon:SetAllPoints()
		icon:SetTexture(COIN_ICON)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		local ring = marker:CreateTexture(nil, "ARTWORK")
		ring:SetPoint("TOPLEFT", -1, 1)
		ring:SetPoint("BOTTOMRIGHT", 1, -1)
		local c = K.Colors.highlight
		ring:SetColorTexture(c[1], c[2], c[3], 1)
	end
	marker:SetParent(button)
	marker:SetFrameLevel(button:GetFrameLevel() + 5)
	marker:ClearAllPoints()
	marker:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
	marker:Show()
end

local function HideMarker()
	if marker then
		marker:Hide()
		marker:SetParent(nil)
	end
end

-- The choice that sells for the most. Returns nil and the first uncached item
-- when a value is still loading, and nil when nothing has any value at all.
local function FindBestChoice(numChoices)
	local bestIndex, bestValue = nil, 0
	for index = 1, numChoices do
		local itemID = select(6, GetQuestItemInfo("choice", index))
		if itemID and not IsSecret(itemID) then
			local value = select(11, C_Item.GetItemInfo(itemID))
			if value == nil then
				return nil, itemID
			end
			if value > bestValue then
				bestValue = value
				bestIndex = index
			end
		end
	end
	return bestIndex
end

-- Items the reward page will hand over: every fixed reward plus the one choice.
local function RewardItemCount(numChoices)
	return (GetNumQuestRewards() or 0) + (numChoices > 0 and 1 or 0)
end

-- Take the reward, unless the bags cannot hold it. With no free slot at all the
-- game would refuse, so the quest is held and the window left to you rather than
-- trying. Fewer free slots than items is still tried, since rewards can stack
-- onto what you carry, and a refusal then holds the quest just the same.
function Module:TakeReward(questID, choice, numChoices)
	if RewardItemCount(numChoices) > 0 and self.FreeBagSlots() == 0 then
		self:HoldQuest(questID, "bags")
		return
	end
	if self:TryAction("reward", questID) then
		GetQuestReward(choice)
	end
end

-- Complete the quest, dealing with a choice of rewards as the mode says.
local pendingQuestID
function Module:OnQuestComplete()
	HideMarker()
	if not self:CanAutomate() then
		return
	end

	local questID = GetQuestID()
	local turnIn = self:ShouldTurnIn(questID) and not CostsGold()
	local mode = C.AutoQuest.RewardMode
	local numChoices = GetNumQuestChoices() or 0

	if numChoices <= 1 then
		if turnIn then
			-- The same value the game's own button passes.
			self:TakeReward(questID, numChoices == 1 and 1 or 0, numChoices)
		end
		return
	end

	if mode ~= "TAKE" and mode ~= "HIGHLIGHT" then
		return
	end

	local bestIndex, waitingItem = FindBestChoice(numChoices)
	if waitingItem then
		-- Run again once, when the item arrives, and only if the same quest is
		-- still on screen by then.
		if pendingQuestID ~= questID then
			pendingQuestID = questID
			self:WaitForItemData(waitingItem, function()
				local frame = _G.QuestFrame
				if pendingQuestID == questID and frame and frame:IsShown() and GetQuestID() == questID then
					-- Clear first, so a second cold item can wait in turn.
					pendingQuestID = nil
					self:OnQuestComplete()
				end
			end)
		end
		return
	end
	pendingQuestID = nil

	-- Nothing sells for anything, so there is no best to pick. Leave it to you.
	if not bestIndex then
		return
	end

	if mode == "TAKE" and turnIn then
		self:TakeReward(questID, bestIndex, numChoices)
	else
		ShowMarker(bestIndex)
	end
end

function Module:OnQuestFinished()
	pendingQuestID = nil
	HideMarker()
end

function Module:SetupTurnIn()
	self:RegisterEvent("QUEST_PROGRESS", "OnQuestProgress")
	self:RegisterEvent("QUEST_COMPLETE", "OnQuestComplete")
	self:RegisterEvent("QUEST_FINISHED", "OnQuestFinished")
end
