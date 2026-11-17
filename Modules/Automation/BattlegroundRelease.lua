--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/BattlegroundRelease.lua
	Purpose:
		Release your spirit as soon as you die in a battleground, so you join the
		next spirit healer wave instead of missing it while you reach for the
		button.

		Only in battlegrounds, never arenas, dungeons or the open world. Never
		when the client offers a way to come back where you fell (a soulstone,
		a reincarnation and the like), so one is never thrown away. Holding Shift
		as you die keeps you on the ground for that death.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Automation")

local C_DeathInfo = C_DeathInfo
local C_PvP = C_PvP
local C_Timer = C_Timer
local IsShiftKeyDown = IsShiftKeyDown
local RepopMe = RepopMe
local UnitIsDead = UnitIsDead
local UnitIsGhost = UnitIsGhost

-- A beat after death, so the self resurrect choices are known before we look.
local DELAY = 0.5

local function CanComeBack()
	local options = C_DeathInfo.GetSelfResurrectOptions()
	return options and #options > 0
end

local function Release()
	if not UnitIsDead("player") or UnitIsGhost("player") then
		return
	end
	if not C_PvP.IsBattleground() or CanComeBack() then
		return
	end
	RepopMe()
end

local function OnDead()
	if not C.Automation.BattlegroundRelease or IsShiftKeyDown() then
		return
	end
	if not C_PvP.IsBattleground() then
		return
	end
	C_Timer.After(DELAY, Release)
end

function Module:SetupBattlegroundRelease()
	self:RegisterEvent("PLAYER_DEAD", OnDead)
end
