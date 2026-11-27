--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/WorldMap/Navigation.lua
	Purpose:
		Arrival time under the game's own on-screen navigation marker. The game
		shows how far away a tracked waypoint, quest or corpse is, this adds how
		long it will take at the speed you are closing in on it.

		The speed comes from how fast the distance drops, not from your run
		speed, so walking at an angle, flying or riding a boat all give a fair
		estimate. Nothing shows while you stand still or move away.

		Our own text sits on SuperTrackedFrame, which is a plain unprotected
		frame, and its timer only runs while the game has a navigation target.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("WorldMap")

local _G = _G
local floor = math.floor
local format = string.format
local CreateFrame = CreateFrame
local C_Navigation = C_Navigation

-- Seconds between estimates. Short enough to feel live, long enough that one
-- jittery distance reading does not swing the number.
local TICK = 0.5
-- Weight of the newest speed sample in the running average.
local SMOOTHING = 0.3
-- Slower than this (yards per second) reads as standing still.
local MIN_SPEED = 1
-- Closer than this the game is about to say you arrived, so stay quiet.
local MIN_DISTANCE = 5
-- A distance jump bigger than this in one tick is a new target or a teleport,
-- not movement, so the average starts over.
local MAX_JUMP = 300

local driver, label
local lastDistance, speed
local elapsedTotal = 0

local function FormatTime(seconds)
	seconds = floor(seconds + 0.5)
	local hours = floor(seconds / 3600)
	local minutes = floor(seconds / 60) % 60
	local secs = seconds % 60
	if hours > 0 then
		return format("%d:%02d:%02d", hours, minutes, secs)
	end
	return format("%d:%02d", minutes, secs)
end

local function Reset()
	lastDistance, speed = nil, nil
	if label then
		label:Hide()
	end
end

local function Tick()
	local frame = _G.SuperTrackedFrame
	local distanceText = frame and frame.DistanceText
	-- The game hides its distance while the marker is pinned to the screen
	-- edge, so ours follows it. The distance is not read meanwhile, so the
	-- average starts over when it comes back.
	if not (distanceText and distanceText:IsShown()) then
		Reset()
		return
	end

	local distance = C_Navigation.GetDistance()
	if not distance then
		Reset()
		return
	end

	if lastDistance then
		local change = lastDistance - distance
		if change > MAX_JUMP or change < -MAX_JUMP then
			speed = nil
		else
			local sample = change / elapsedTotal
			speed = speed and (speed + (sample - speed) * SMOOTHING) or sample
		end
	end
	lastDistance = distance

	if speed and speed >= MIN_SPEED and distance > MIN_DISTANCE then
		label:SetFormattedText(L["Arrive in %s"], FormatTime(distance / speed))
		label:Show()
	else
		label:Hide()
	end
end

local function OnUpdate(_, elapsed)
	elapsedTotal = elapsedTotal + elapsed
	if elapsedTotal < TICK then
		return
	end
	Tick()
	elapsedTotal = 0
end

local function Start()
	Reset()
	elapsedTotal = 0
	driver:SetScript("OnUpdate", OnUpdate)
end

local function Stop()
	driver:SetScript("OnUpdate", nil)
	Reset()
end

local function OnEvent(_, event)
	if event == "NAVIGATION_FRAME_CREATED" then
		Start()
	elseif event == "NAVIGATION_FRAME_DESTROYED" then
		Stop()
	elseif event == "SUPER_TRACKING_CHANGED" then
		-- A new target makes the old speed meaningless.
		Reset()
	end
end

local function Attach(frame)
	local distanceText = frame.DistanceText
	if not distanceText then
		return
	end

	label = frame:CreateFontString(nil, "BACKGROUND")
	label:SetFontObject(distanceText:GetFontObject() or "GameFontNormal")
	label:SetTextColor(0.85, 0.85, 0.85)
	label:SetPoint("TOP", distanceText, "BOTTOM", 0, 2)
	label:Hide()

	driver = CreateFrame("Frame")
	driver:RegisterEvent("NAVIGATION_FRAME_CREATED")
	driver:RegisterEvent("NAVIGATION_FRAME_DESTROYED")
	driver:RegisterEvent("SUPER_TRACKING_CHANGED")
	driver:SetScript("OnEvent", OnEvent)

	-- Already tracking something when we load, as after a /reload.
	if C_Navigation.GetFrame() then
		Start()
	end
end

function Module:SetupNavigation()
	if not C.WorldMap.ArrivalTime then
		return
	end
	if not (C_Navigation and C_Navigation.GetDistance and C_Navigation.GetFrame) then
		return
	end

	local frame = _G.SuperTrackedFrame
	if frame then
		Attach(frame)
		return
	end

	-- Blizzard_QuestNavigation is not on demand, so this is only a fallback in
	-- case it ever loads after us.
	local waiter = CreateFrame("Frame")
	waiter:RegisterEvent("ADDON_LOADED")
	waiter:SetScript("OnEvent", function(self, _, name)
		if name == "Blizzard_QuestNavigation" and _G.SuperTrackedFrame then
			self:UnregisterEvent("ADDON_LOADED")
			Attach(_G.SuperTrackedFrame)
		end
	end)
end
