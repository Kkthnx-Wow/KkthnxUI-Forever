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

		Herbs, ore and other objects get the game's own interact icons instead of
		a sparkle. A sparkle there would need a nameplate forced onto whatever the
		interact key picks, which in other addons made spells cast without a target
		land on nearby players, so only the game's own option is switched.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local CreateFrame = CreateFrame
local GetCVar = GetCVar
local SetCVar = SetCVar
local InCombatLockdown = InCombatLockdown
local C_Timer = C_Timer
local pcall = pcall
local pairs = pairs
local tonumber = tonumber
local band = bit.band
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

-- ---------------------------------------------------------------------------
-- Interact icons on herbs, ore and objects
-- ---------------------------------------------------------------------------

-- The game marks the herb, ore node, chest or NPC the interact key would use
-- with its own icon (a leaf, a pickaxe, a gear). By default it skips game
-- objects. This switches the game's own Interact Key Icons option to Show All,
-- the same four settings its Accessibility page writes, and puts back what you
-- had when turned off. The interact key itself and how targeting works are left
-- alone: those are yours to set in the game's Controls page.
local ICON_CVARS = {
	SoftTargetIconEnemy = "1",
	SoftTargetIconInteract = "1",
	SoftTargetIconGameObject = "1",
	SoftTargetLowPriorityIcons = "1",
}
local INTERACT_CVAR = "softTargetInteract"
local KBM_FLAG = Enum.SoftTargetEnableFlags and Enum.SoftTargetEnableFlags.Kbm or 2
local hintShown = false

local function ApplyInteractIcons()
	if InCombatLockdown() then
		K.DeferCombat("InteractIcons", ApplyInteractIcons)
		return
	end
	local db = K.DB
	if not db then
		return
	end
	if C.QoL.InteractIcons then
		if not db.interactIconsRestore then
			local saved = {}
			for cvar in pairs(ICON_CVARS) do
				saved[cvar] = GetCVar(cvar)
			end
			db.interactIconsRestore = saved
		end
		for cvar, value in pairs(ICON_CVARS) do
			if GetCVar(cvar) ~= value then
				pcall(SetCVar, cvar, value)
			end
		end
		-- Mouse and keyboard only get the icons once the interact key is on for them.
		local mode = tonumber(GetCVar(INTERACT_CVAR)) or 0
		if not hintShown and band(mode, KBM_FLAG) == 0 then
			hintShown = true
			K.Print(L["Interact icons show once Enable Interact Key is on in the game's Controls settings."])
		end
	elseif db.interactIconsRestore then
		for cvar, value in pairs(db.interactIconsRestore) do
			if value ~= nil and GetCVar(cvar) ~= value then
				pcall(SetCVar, cvar, value)
			end
		end
		db.interactIconsRestore = nil
	end
end

-- Runs at enable and whenever the option is toggled in the config.
function Module:UpdateInteractIcons()
	ApplyInteractIcons()
end
