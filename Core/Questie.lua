--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/Questie.lua
	Purpose:
		A thin bridge to the quest helper addon, read through its public API only.

		The quest helper draws its own objective icon on every nameplate and puts
		another on Blizzard's target frame. Our nameplates already carry a quest
		marker, so its plates icon doubled ours, and our unit frames replace the
		Blizzard target frame, so its target icon was drawn on a hidden frame.

		This hands both of our markers the icon it would have drawn (loot, slay,
		talk and so on). When our nameplate marker takes its icon, its own plate
		icons are switched off through its nameplate option, and switched back on
		if ours is turned off, so the player never ends up with neither.

		Nothing here runs unless the addon is loaded. It is read at runtime by the
		nameplate and unit frame code, so load order between the two does not
		matter.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local _G = _G
local IsInInstance = IsInInstance
local UnitGUID = UnitGUID
local strsplit = strsplit
local tinsert = table.insert
local ipairs = ipairs
local CreateFrame = CreateFrame
local C_Timer_After = C_Timer.After

local IsSecret = K.IsSecret

local Bridge = {}
K.Questie = Bridge

local ready = false
local listeners = {}
local notifyQueued = false

-- The public API table, only once the addon says its data is valid.
local function API()
	local questie = _G.Questie
	local api = questie and questie.API
	if api and api.isReady then
		return api
	end
end

function Bridge.IsReady()
	return ready
end

-- The icon texture the quest helper would show for this unit, or nil.
-- Instances are skipped, as the helper does itself there, since unit identity
-- can be hidden from addons inside them.
function Bridge.UnitIcon(unit)
	if not ready or not unit then
		return nil
	end
	local api = API()
	if not (api and api.GetQuestObjectiveIconForUnit) then
		return nil
	end
	if IsInInstance() then
		return nil
	end
	local guid = UnitGUID(unit)
	if not guid or IsSecret(guid) then
		return nil
	end
	-- Only creatures carry objectives. A player GUID would come back empty anyway,
	-- but this keeps the lookup off every friendly player plate.
	local kind = strsplit("-", guid)
	if kind ~= "Creature" and kind ~= "Vehicle" then
		return nil
	end
	return api.GetQuestObjectiveIconForUnit(guid)
end

-- Called with no arguments after the helper's quest data moves. Its updates come
-- in bursts (one per objective), so listeners run once after the burst.
function Bridge.OnUpdate(callback)
	tinsert(listeners, callback)
end

local function Notify()
	notifyQueued = false
	for _, callback in ipairs(listeners) do
		callback()
	end
end

local function QueueNotify()
	if not notifyQueued then
		notifyQueued = true
		C_Timer_After(0.2, Notify)
	end
end

-- Our nameplate marker uses the helper's icons only when our plates and our
-- marker are both on. Otherwise its own plate icons are the only ones there are.
function Bridge.OwnsNameplateIcons()
	local db = C.Nameplate
	return db and db.Enable and db.ShowQuestIcon and db.QuestieIcons and true or false
end

-- Switch the helper's own plate icons off while ours show its icon, and back on
-- if ours stop. KkthnxUIDB remembers that we were the one who switched it off,
-- so a player who turned it off by hand keeps it off.
local function SyncNameplateOption()
	local questie = _G.Questie
	local profile = questie and questie.db and questie.db.profile
	if not profile then
		return
	end

	if Bridge.OwnsNameplateIcons() then
		if profile.nameplateEnabled then
			profile.nameplateEnabled = false
			KkthnxUIDB.questieNameplatesOff = true
			-- Plates already on screen keep the icons drawn before this point.
			local loader = _G.QuestieLoader
			local plates = loader and loader.ImportModule and loader:ImportModule("QuestieNameplate")
			if plates and plates.HideCurrentFrames then
				plates:HideCurrentFrames()
			end
			K.Print(L["Questie nameplate icons are now shown on KkthnxUI nameplates. Turn off Questie Icons in the KkthnxUI nameplate options to get them back."])
		end
	elseif KkthnxUIDB.questieNameplatesOff then
		KkthnxUIDB.questieNameplatesOff = nil
		profile.nameplateEnabled = true
	end
end

local function OnReady()
	ready = true
	SyncNameplateOption()

	local api = API()
	if api and api.RegisterForQuestUpdates then
		api.RegisterForQuestUpdates(QueueNotify)
	end
	Notify()
end

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", function(self)
	self:UnregisterEvent("PLAYER_LOGIN")
	local questie = _G.Questie
	local api = questie and questie.API
	if api and api.RegisterOnReady then
		api.RegisterOnReady(OnReady)
	end
end)
