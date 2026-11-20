--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/LootSparkle.lua
	Purpose:
		Keep the game's sparkle on lootable quest items switched on. The game has
		a console setting for it, but every graphics preset turns it back off, so
		it is set again at login and after any graphics quality change.

		The value the game had before we first set it is kept, account wide like
		the setting itself, and put back when the option is turned off. Only that
		one setting is ever written. The game also needs a restart before a
		sparkle that was on goes away, which is said in chat.

		Stands aside when another addon that keeps this same setting is loaded,
		so the two never fight over it.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local CreateFrame = CreateFrame
local GetCVar = GetCVar
local SetCVar = SetCVar
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local pcall = pcall
local strlower = string.lower
local type = type

local CVAR = "outlineModeShowLootEffectWhenDisabled"

-- Settings whose change can reset the sparkle, lower case as CVAR_UPDATE may
-- name them in any case.
local WATCHED = {
	[strlower(CVAR)] = true,
	graphicsquality = true,
	raidgraphicsquality = true,
}

-- Other addons that keep the same setting.
local OTHER_KEEPERS = { "ForeverLootSparkles" }

local watcher
local writing = false
local recheckQueued = false
local shownThisSession = false

local function OtherKeeperLoaded()
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
	if not isLoaded then
		return false
	end
	for i = 1, #OTHER_KEEPERS do
		if isLoaded(OTHER_KEEPERS[i]) then
			return true
		end
	end
	return false
end

local function Write(value)
	if GetCVar(CVAR) == value then
		return
	end
	writing = true
	pcall(SetCVar, CVAR, value)
	writing = false
end

-- Turn the sparkle on, remembering the game's own value the first time.
local function Apply()
	if not C.QoL.LootSparkle or OtherKeeperLoaded() then
		return
	end
	if InCombatLockdown() then
		K.DeferCombat("LootSparkle", Apply)
		return
	end
	local current = GetCVar(CVAR)
	if current == nil then
		return
	end
	local db = K.DB
	if db and db.lootSparkleRestore == nil and current ~= "1" then
		db.lootSparkleRestore = current
	end
	shownThisSession = true
	Write("1")
end

-- A preset change writes several settings in a row. Look again once it settles.
local function QueueRecheck()
	if recheckQueued then
		return
	end
	recheckQueued = true
	C_Timer.After(1, function()
		recheckQueued = false
		Apply()
	end)
end

local function OnEvent(_, event, name)
	if event == "CVAR_UPDATE" and not writing and type(name) == "string" and WATCHED[strlower(name)] then
		QueueRecheck()
	end
end

-- Runs at enable and whenever the option is toggled in the config.
function Module:UpdateLootSparkle()
	if C.QoL.LootSparkle and not OtherKeeperLoaded() then
		if not watcher then
			watcher = CreateFrame("Frame")
			watcher:SetScript("OnEvent", OnEvent)
		end
		watcher:RegisterEvent("CVAR_UPDATE")
		Apply()
		return
	end

	if watcher then
		watcher:UnregisterAllEvents()
	end

	-- Put back what the game had, once. Left alone when another addon owns it.
	local db = K.DB
	local restore = db and db.lootSparkleRestore
	if restore == nil or OtherKeeperLoaded() then
		return
	end
	db.lootSparkleRestore = nil
	if GetCVar(CVAR) == "1" then
		Write(restore)
		if shownThisSession then
			K.Print(L["Quest loot sparkles stay until you restart the game. A reload is not enough."])
		end
	end
end
