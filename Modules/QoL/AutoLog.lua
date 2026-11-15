--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/AutoLog.lua
	Purpose:
		Turn combat logging on when you zone into content worth logging and off
		again after you leave, so a raid night is recorded without a macro.

		Chosen by the difficulty of the instance, not by a list of instances, so it
		keeps working as new content ships:
			Raids           Normal (10, 20 and 40 player), Heroic, and Looking For Raid
			Dungeons        Heroic
		Timewalking, follower and scenario content is left alone.

		Logging stops half a minute after leaving, so a quick trip out and back in
		keeps one unbroken log. A log you started yourself outside logged content is
		never stopped.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local GetInstanceInfo = GetInstanceInfo
local LoggingCombat = LoggingCombat

local STOP_DELAY = 30

-- Raid difficulty IDs by the setting that controls them. WoW Forever's raids are
-- the 10, 20 and 40 player sizes (the client's own difficulty tooltip lists those
-- three), so the legacy IDs lead and the flexible 14, 15 and 17 stay as a
-- fallback. There is no Mythic raid.
local RAID_SETTING = {
	[3] = "AutoLogRaidNormal", -- 10 player
	[4] = "AutoLogRaidNormal", -- 25 player
	[9] = "AutoLogRaidNormal", -- 40 player
	[242] = "AutoLogRaidNormal", -- 20 player
	[243] = "AutoLogRaidNormal", -- 10 player
	[14] = "AutoLogRaidNormal",
	[5] = "AutoLogRaidHeroic",
	[6] = "AutoLogRaidHeroic",
	[15] = "AutoLogRaidHeroic",
	[7] = "AutoLogRaidFinder",
	[17] = "AutoLogRaidFinder",
}

-- Heroic dungeons. There is no Mythic or Mythic Plus.
local DUNGEON_DIFFICULTY = { [2] = true }

local weStarted = false
local stopTimer

local function ShouldLog()
	local _, instanceType, difficultyID = GetInstanceInfo()
	if instanceType == "raid" then
		local setting = RAID_SETTING[difficultyID]
		return setting ~= nil and C.QoL[setting] == true
	elseif instanceType == "party" then
		return C.QoL.AutoLogDungeon == true and DUNGEON_DIFFICULTY[difficultyID] == true
	end
	return false
end

local function CancelStop()
	if stopTimer then
		stopTimer:Cancel()
		stopTimer = nil
	end
end

local function Apply()
	if ShouldLog() then
		CancelStop()
		if not LoggingCombat() then
			-- The detailed log is what log sites expect. Set once, never undone.
			if GetCVar("advancedCombatLogging") ~= "1" then
				SetCVar("advancedCombatLogging", "1")
			end
			LoggingCombat(true)
			weStarted = true
			K.Print(L["Combat logging started."])
		end
	elseif weStarted and not stopTimer then
		stopTimer = C_Timer.NewTimer(STOP_DELAY, function()
			stopTimer = nil
			if weStarted and not ShouldLog() then
				weStarted = false
				if LoggingCombat() then
					LoggingCombat(false)
					K.Print(L["Combat logging stopped."])
				end
			end
		end)
	end
end

-- The instance info settles a moment after the zone event.
local function OnZone()
	C_Timer.After(2, Apply)
end

function Module:SetupAutoLog()
	self:RegisterEvent("PLAYER_ENTERING_WORLD", OnZone)
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA", OnZone)
end
