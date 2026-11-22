--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/ProcGlow.lua
	Purpose:
		Draw the spell activation (proc) glow on our action buttons.
		LibActionButtonKit tracks which buttons should glow and reports it through
		its GlowShown and GlowHidden callbacks. We draw the glow with the embedded
		LibCustomGlow in the chosen style: a pixel ring or an autocast sparkle in
		the palette gold, or the classic button glow for "Default".
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("ActionBars")

local LCG = LibStub and LibStub("LibCustomGlow-1.0-KkthnxUI", true)
local GLOW_KEY = "KKUI_Proc"

local function Styles(color)
	return {
		Default = {
			start = function(button)
				LCG.ButtonGlow_Start(button)
			end,
			stop = function(button)
				LCG.ButtonGlow_Stop(button)
			end,
		},
		Autocast = {
			start = function(button)
				LCG.AutoCastGlow_Start(button, color, nil, nil, nil, nil, nil, GLOW_KEY)
			end,
			stop = function(button)
				LCG.AutoCastGlow_Stop(button, GLOW_KEY)
			end,
		},
		-- A ring of moving segments around the button.
		Pixel = {
			start = function(button)
				LCG.PixelGlow_Start(button, color, 8, 0.25, nil, 2, 0, 0, false, GLOW_KEY)
			end,
			stop = function(button)
				LCG.PixelGlow_Stop(button, GLOW_KEY)
			end,
		},
	}
end

function Module:SetupProcGlow()
	if not LCG then
		return
	end
	local color = { K.Colors.gold[1], K.Colors.gold[2], K.Colors.gold[3], 1 }
	local styles = Styles(color)
	local style = styles[C.ActionBar.ProcGlow or "Pixel"] or styles.Pixel

	self.Kit.RegisterCallback(self, "GlowShown", function(_, button)
		style.start(button)
	end)
	self.Kit.RegisterCallback(self, "GlowHidden", function(_, button)
		style.stop(button)
	end)
end
