--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Units/Player.lua
	Purpose:
		The player frame. Portrait on the left, health and power stacked, class
		resource above, debuffs above that, and a free floating castbar down by
		the action bars the way the original KkthnxUI had it.

		No name text here on purpose. You know who you are.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")
local Build = Module.Build

Module.Styles.Player = function(self)
	local cfg = C.Unitframe.Player
	local castbar = C.Unitframe.Castbar

	Module.EnableInteraction(self, "player")

	Build.Health(self, cfg.Height)
	Build.Power(self, Module.PowerHeight(cfg))
	if cfg.CostPrediction ~= false then
		Build.CostPrediction(self)
	end
	Build.PowerTick(self)
	Build.HealthText(self, 13)
	Build.PowerText(self, 11)

	Build.Portrait(self, "left")
	Build.PortraitLevel(self)

	if cfg.ShowName then
		Build.Name(self, 12)
	end

	if cfg.AdditionalPower then
		Build.AdditionalPower(self)
	end

	Build.Indicators(self)
	Build.PlayerIndicators(self)
	Build.PvPIndicator(self, "left")

	-- Upward stack, in the order they leave the health bar. The class resource
	-- builder does nothing for a class that has none.
	if cfg.ClassPower then
		Build.ClassPower(self)
	end
	-- Totems hang below the frame. They go first so the buff row, when it is
	-- switched on, starts under them instead of on top of them. The swing bars
	-- live in Modules/Misc/SwingTimer.lua on movers of their own.
	Build.Totems(self)
	Build.Auras(self, cfg)

	-- Sit evenly between the action bars below and the unit frames above.
	Build.DetachedCastbar(self, "PlayerCastbar", "Player Castbar", castbar.PlayerWidth, castbar.PlayerHeight, { "BOTTOM", UIParent, "BOTTOM", 0, 190 }, "left")
end
