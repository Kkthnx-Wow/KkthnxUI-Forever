--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/MirrorTimers.lua
	Purpose:
		Restyle the game's breath, fatigue and feign death bars to match the rest
		of the UI: our bar texture, background and border, a colour per timer,
		the label on the left of the bar and the seconds left on the right.

		The bars stay Blizzard's own. The container is an Edit Mode system, so it
		is left where Edit Mode puts it and is never moved from here, and all the
		state this skin keeps lives in local tables, not on Blizzard's frames.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("MirrorTimers")

local _G = _G
local ipairs = ipairs
local format = string.format
local hooksecurefunc = hooksecurefunc

local BAR_HEIGHT = 16

-- The client draws these timers with its castbar art, the standard gold fill for
-- fatigue and release, the channel green for Feign Death and a light blue for
-- breath. Ours follow that, using the shared cast colours.
local COLORS = {
	BREATH = { 0.25, 0.6, 1 },
	EXHAUSTION = K.CastColors.cast,
	FEIGNDEATH = K.CastColors.channel,
	DEATH = K.CastColors.cast,
}
local FALLBACK = K.CastColors.noInterrupt

local styled = {}
local timeTexts = {}

-- Our texture and the timer's colour, after Blizzard's Setup has put its own
-- castbar art back.
local function Restyle(frame)
	local bar = frame.StatusBar
	if not bar then
		return
	end
	bar:SetStatusBarTexture(K.GetTexture(C.Unitframe.Texture))
	local color = COLORS[frame.timer] or FALLBACK
	bar:SetStatusBarColor(color[1], color[2], color[3])
end

local function UpdateTime(frame)
	local text = timeTexts[frame]
	local bar = frame.StatusBar
	if not text or not bar then
		return
	end
	local value = bar:GetValue()
	if value and value > 0 then
		text:SetText(format("%d", value + 0.5))
	else
		text:SetText("")
	end
end

local function Style(frame)
	if styled[frame] or not frame.StatusBar then
		return
	end
	styled[frame] = true
	local bar = frame.StatusBar

	-- The castbar box, frame and the text plate under the bar.
	for _, region in ipairs({ frame:GetRegions() }) do
		if region:IsObjectType("Texture") then
			region:SetAlpha(0)
		end
	end

	-- The label sits inside the bar, so the frame only needs the bar's own height.
	bar:ClearAllPoints()
	bar:SetPoint("TOP", frame, "TOP", 0, -2)
	bar:SetHeight(BAR_HEIGHT)
	frame:SetHeight(BAR_HEIGHT + 6)
	K.CreateBackground(bar, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.9)
	K.CreateBorder(bar)

	local label = frame.Text
	if label then
		label:ClearAllPoints()
		label:SetPoint("LEFT", bar, "LEFT", 4, 0)
		label:SetPoint("RIGHT", bar, "RIGHT", -30, 0)
		label:SetJustifyH("LEFT")
		label:SetParent(bar)
		label:SetDrawLayer("OVERLAY", 7)
		K.SetFont(label, 11, K.FontOutlineStyle())
	end

	local time = bar:CreateFontString(nil, "OVERLAY")
	K.SetFont(time, 11, K.FontOutlineStyle())
	time:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
	time:SetJustifyH("RIGHT")
	timeTexts[frame] = time

	hooksecurefunc(frame, "Setup", Restyle)
	hooksecurefunc(frame, "UpdateStatusBarValue", UpdateTime)
	Restyle(frame)
	UpdateTime(frame)
end

function Module:OnEnable()
	if not (C.Skins and C.Skins.MirrorTimers) then
		return
	end
	local container = _G.MirrorTimerContainer
	if not container or not container.mirrorTimers then
		return
	end
	for _, frame in ipairs(container.mirrorTimers) do
		Style(frame)
	end
end
