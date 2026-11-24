--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/TrainAll.lua
	Purpose:
		A Train All button beside Train on class and profession trainers. It
		learns everything the trainer lists as available that you can afford,
		one at a time, waiting for the trainer to update between each so a new
		rank that opens up is picked up too.

		Left alone: pet trainers (they spend training points, not gold), the step
		that raises a profession to its next tier, and anything that would learn
		a new profession, since those use up a profession slot and the game asks
		about them first. Hovering the button lists what it will learn and the
		total cost.
-----------------------------------------------------------------------------]]

local K, L = KkthnxUI[1], KkthnxUI[3]

local Module = K:GetModule("QoL")

local _G = _G
local format = string.format

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GetMoney = GetMoney
local GetNumTrainerServices = GetNumTrainerServices
local GetTrainerServiceCost = GetTrainerServiceCost
local GetTrainerServiceInfo = GetTrainerServiceInfo
local GetTrainerServiceStepIndex = GetTrainerServiceStepIndex
local BuyTrainerService = BuyTrainerService
local C_Timer_After = C_Timer.After
local C_Trainer = C_Trainer
local GetMoneyString = GetMoneyString

-- A pause between purchases so the trainer list has updated before the next.
local STEP_DELAY = 0.15
-- Never more than this many in one press, as a guard against a list that
-- never empties.
local MAX_PER_PRESS = 60
-- A purchase the trainer never answers ends the run instead of leaving the
-- button stuck.
local REPLY_TIMEOUT = 3

local button
local training = false
local learned = 0
local spent = 0
local stepQueued = false
local purchase = 0

local function IsPetTrainer()
	return C_Trainer and C_Trainer.GetTrainerType and Enum.TrainerType and C_Trainer.GetTrainerType() == Enum.TrainerType.Pet
end

-- Walks the available services in list order and calls fn(index, name, cost)
-- for each one this button would learn, while the gold lasts.
local function EachTrainable(fn)
	if IsPetTrainer() then
		return
	end
	local money = GetMoney()
	local step = GetTrainerServiceStepIndex and GetTrainerServiceStepIndex()
	for index = 1, GetNumTrainerServices() do
		if index ~= step then
			local name, serviceType, _, _, subText = GetTrainerServiceInfo(index)
			if serviceType == "available" then
				local cost, isProfession = GetTrainerServiceCost(index)
				cost = cost or 0
				if not isProfession and cost <= money then
					money = money - cost
					if fn(index, name, cost, subText) then
						return
					end
				end
			end
		end
	end
end

local function UpdateButton()
	if not button then
		return
	end
	local count = 0
	EachTrainable(function()
		count = count + 1
	end)
	-- A fixed 120 wide button ran over the money box at the bottom left, so it
	-- fills the gap between that box and Train. Measured here because the
	-- window has a layout by the time the trainer list updates.
	local train, money = _G.ClassTrainerTrainButton, _G.ClassTrainerFrameMoneyBg
	local left, right = money and money:GetRight(), train and train:GetLeft()
	if left and right and right - left > 40 then
		button:SetWidth(right - left)
	end
	button:SetEnabled(count > 0 and not training)
	button:SetText(count > 0 and format("%s (%d)", L["Train All"], count) or L["Train All"])
end

local function Finish()
	training = false
	if learned > 0 then
		K.Print(L["Learned %d for %s."], learned, GetMoneyString(spent, true))
	end
	UpdateButton()
end

local function Step()
	if not training then
		return
	end
	if learned >= MAX_PER_PRESS or not (_G.ClassTrainerFrame and _G.ClassTrainerFrame:IsShown()) then
		Finish()
		return
	end
	local bought = false
	EachTrainable(function(index, _, cost)
		BuyTrainerService(index)
		learned = learned + 1
		spent = spent + cost
		bought = true
		return true
	end)
	if not bought then
		Finish()
		return
	end
	-- The next step runs from TRAINER_UPDATE once the list has caught up.
	purchase = purchase + 1
	local this = purchase
	C_Timer_After(REPLY_TIMEOUT, function()
		if training and this == purchase and not stepQueued then
			Finish()
		end
	end)
end

local function OnTrainerUpdate()
	if training then
		-- One update can arrive as several events. Only one step follows them.
		if stepQueued then
			return
		end
		stepQueued = true
		C_Timer_After(STEP_DELAY, function()
			stepQueued = false
			Step()
		end)
	else
		UpdateButton()
	end
end

local function OnClick()
	if training then
		return
	end
	training = true
	learned, spent = 0, 0
	button:Disable()
	Step()
end

local function OnEnter(self)
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	GameTooltip:AddLine(L["Train All"], 1, 1, 1)
	local total = 0
	EachTrainable(function(_, name, cost, subText)
		total = total + cost
		local label = (subText and subText ~= "") and format("%s (%s)", name, subText) or name
		local soft = K.Colors.secondary
		GameTooltip:AddDoubleLine(label, cost > 0 and GetMoneyString(cost, true) or "", soft[1], soft[2], soft[3], 1, 1, 1)
	end)
	if total > 0 then
		GameTooltip:AddLine(" ")
		local gold = K.Colors.highlight
		GameTooltip:AddDoubleLine(L["Total"], GetMoneyString(total, true), gold[1], gold[2], gold[3], 1, 1, 1)
	end
	GameTooltip:Show()
end

local function Build()
	local train = _G.ClassTrainerTrainButton
	if button or not train then
		return
	end
	button = CreateFrame("Button", "KKUI_TrainAllButton", train:GetParent(), "MagicButtonTemplate")
	button:SetHeight(train:GetHeight())
	button:SetWidth(train:GetWidth())
	button:SetPoint("RIGHT", train, "LEFT", 0, 0)
	button:SetMotionScriptsWhileDisabled(true)
	button:SetScript("OnClick", OnClick)
	button:SetScript("OnEnter", OnEnter)
	button:SetScript("OnLeave", GameTooltip_Hide)
	-- Blizzard hides the Train button in gamepad mode, so this one follows it.
	hooksecurefunc(train, "Hide", function()
		button:Hide()
	end)
	hooksecurefunc(train, "Show", function()
		button:Show()
	end)
	button:SetShown(train:IsShown())
	UpdateButton()
end

local function OnAddOnLoaded(_, _, addon)
	if addon == "Blizzard_TrainerUI" then
		Build()
	end
end

function Module:SetupTrainAll()
	Build()
	if not button then
		self:RegisterEvent("ADDON_LOADED", OnAddOnLoaded)
	end
	self:RegisterEvent("TRAINER_SHOW", function()
		Build()
		UpdateButton()
	end)
	self:RegisterEvent("TRAINER_UPDATE", OnTrainerUpdate)
	self:RegisterEvent("PLAYER_MONEY", UpdateButton)
	self:RegisterEvent("TRAINER_CLOSED", function()
		if training then
			Finish()
		end
	end)
end
