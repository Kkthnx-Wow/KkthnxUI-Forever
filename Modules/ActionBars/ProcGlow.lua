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

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("ActionBars")

local ipairs = ipairs
local next = next
local pairs = pairs

local LCG = LibStub and LibStub("LibCustomGlow-1.0-KkthnxUI", true)
local GLOW_KEY = "KKUI_Proc"
-- How far the Pixel ring's frame sits outside the button edge. Our border art
-- draws its solid line from about 1.6px outside the button edge to 0.6px inside
-- it, and the 2px ring runs from this offset inward, so 1 lays it on the line.
local PIXEL_OFFSET = 1
-- Size of the Default style's ant ring against the button. Measured in game on a
-- 38px button: the library's 1.19 put the ring 2.5px inside our border line
-- (17px from the centre instead of 19.5), so it is grown by 19.5 / 17.
local ANTS_SCALE = 1.365
-- The glow frame is 1.4 times the button, so the ring's size against the frame.
local ANTS_OF_FRAME = ANTS_SCALE / 1.4

-- Glow frames come from a shared pool, so the hook is per frame, not per button.
local antsHooked = setmetatable({}, { __mode = "k" })

-- Size the Default style's ant ring so it runs on our border line. Takes the
-- intro animation (or the glow frame itself) and works from the glow frame's
-- own size, so it is right for whichever button the pooled frame is on.
local function FitAnts(source)
	local glow = source.ants and source or source:GetParent()
	if not (glow and glow.ants) then
		return
	end
	local width, height = glow:GetSize()
	glow.ants:SetSize(width * ANTS_OF_FRAME, height * ANTS_OF_FRAME)
end
-- Frame levels above the button for the Pixel ring. The border is drawn on the
-- button itself and the hover highlight sits 3 above it, so at the library's
-- default of 0 the ring fell behind the border it sits on.
local PIXEL_LEVEL = 4

local function Styles(color)
	return {
		Default = {
			start = function(button)
				LCG.ButtonGlow_Start(button)
				local glow = button._ButtonGlow
				if glow and glow.ants then
					-- The library puts its own size back whenever the glow's
					-- intro plays, so each pooled glow frame is hooked once to
					-- size the ring again after it.
					if glow.animIn and not antsHooked[glow] then
						antsHooked[glow] = true
						glow.animIn:HookScript("OnPlay", FitAnts)
					end
					FitAnts(glow.animIn or glow)
				end
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
				-- Pushed PIXEL_OFFSET out from the button edge so the ring runs on our
				-- border band rather than just inside it, over the icon.
				LCG.PixelGlow_Start(button, color, 8, 0.25, nil, 2, PIXEL_OFFSET, PIXEL_OFFSET, false, GLOW_KEY, PIXEL_LEVEL)
			end,
			stop = function(button)
				LCG.PixelGlow_Stop(button, GLOW_KEY)
			end,
		},
	}
end

-- Buttons a real proc is lighting right now, so the test never switches one off.
local procLit = {}
-- Buttons the test lit, to undo exactly those.
local testLit = {}
-- How many bar 1 buttons the test lights.
local TEST_BUTTONS = 3

function Module:SetupProcGlow()
	if not LCG then
		return
	end
	local color = { K.Colors.gold[1], K.Colors.gold[2], K.Colors.gold[3], 1 }
	local styles = Styles(color)
	local style = styles[C.ActionBar.ProcGlow or "Pixel"] or styles.Pixel
	self.procStyle = style

	self.Kit.RegisterCallback(self, "GlowShown", function(_, button)
		procLit[button] = true
		style.start(button)
	end)
	self.Kit.RegisterCallback(self, "GlowHidden", function(_, button)
		procLit[button] = nil
		-- A button the test is lighting keeps its glow until the test ends.
		if not testLit[button] then
			style.stop(button)
		end
	end)
end

-- /kk proctest. Lights the first few shown bar 1 buttons with the chosen glow
-- style, so it can be checked without waiting for a proc. Run it again to stop.
-- The glow is drawn on its own frames, so this is safe in combat.
function Module:ToggleProcTest()
	local style = self.procStyle
	local bar = self.bars and self.bars.Bar1
	if not (style and bar) then
		K.Print(L["The proc glow needs the KkthnxUI action bars."])
		return
	end

	if next(testLit) then
		for button in pairs(testLit) do
			testLit[button] = nil
			if not procLit[button] then
				style.stop(button)
			end
		end
		K.Print(L["Proc glow test off."])
		return
	end

	local lit = 0
	for _, button in ipairs(bar.buttons) do
		if lit >= TEST_BUTTONS then
			break
		end
		if button:IsShown() then
			testLit[button] = true
			style.start(button)
			lit = lit + 1
		end
	end
	if lit == 0 then
		K.Print(L["Bar 1 has no shown buttons to light."])
		return
	end
	K.Print(L["Proc glow test on. Type /kk proctest again to stop."])
end
