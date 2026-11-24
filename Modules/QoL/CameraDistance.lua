--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/CameraDistance.lua
	Purpose:
		Let the camera pull back as far as the game's own Max Camera Distance
		slider goes. That slider writes cameraDistanceMaxZoomFactor, and on this
		client Blizzard's settings cap it at 2.0, so that is the value used.

		The value the game had before is kept, account wide like the setting
		itself, and put back when the option is turned off. A higher value set
		by hand or by the installer is never lowered.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("QoL")

local GetCVar = GetCVar
local SetCVar = SetCVar
local InCombatLockdown = InCombatLockdown
local tonumber = tonumber
local pcall = pcall

local CVAR = "cameraDistanceMaxZoomFactor"
-- The top of Blizzard's own slider for this setting on this client.
local MAX_FACTOR = 2.0

local function Current()
	return tonumber(GetCVar(CVAR))
end

local function Apply()
	local current = Current()
	if not current or current >= MAX_FACTOR then
		return
	end
	local db = K.DB
	if db and db.cameraDistanceRestore == nil then
		db.cameraDistanceRestore = GetCVar(CVAR)
	end
	pcall(SetCVar, CVAR, MAX_FACTOR)
end

local function Restore()
	local db = K.DB
	local restore = db and db.cameraDistanceRestore
	if restore == nil then
		return
	end
	db.cameraDistanceRestore = nil
	-- Only undo our own write. A value changed since then is the player's.
	if Current() == MAX_FACTOR then
		pcall(SetCVar, CVAR, restore)
	end
end

-- Runs at enable and whenever the option is toggled in the config.
-- Combat is left alone, the queued run reads the toggle as it is by then.
function Module:UpdateCameraDistance()
	if InCombatLockdown() then
		K.DeferCombat("CameraDistance", function()
			Module:UpdateCameraDistance()
		end)
		return
	end
	if C.QoL.MaxCameraDistance then
		Apply()
	else
		Restore()
	end
end
