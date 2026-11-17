--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Tooltip/HealthBar.lua
	Purpose:
		Style the unit tooltip's health bar: our texture and border, anchored just
		outside the tooltip, with a locked colour (so the unit post-call's class or
		reaction colour sticks) and a percent value readout.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Tooltip")

local _G = _G

-- Anchor the health bar just outside the tooltip, above or below, with a small
-- gap. Blizzard re-anchors it on show, so this is called again from the unit
-- post-call to keep our placement.
local function PositionHealthBar(bar)
	local tt = bar:GetParent()
	bar:ClearAllPoints()
	if C.Tooltip.HealthBarPosition == "BOTTOM" then
		bar:SetPoint("TOPLEFT", tt, "BOTTOMLEFT", 0, -6)
		bar:SetPoint("TOPRIGHT", tt, "BOTTOMRIGHT", 0, -6)
	else
		bar:SetPoint("BOTTOMLEFT", tt, "TOPLEFT", 0, 6)
		bar:SetPoint("BOTTOMRIGHT", tt, "TOPRIGHT", 0, 6)
	end
end
Module.PositionHealthBar = PositionHealthBar

-- The colour we want on the bar, kept here and not on the bar. Blizzard's own
-- health handler reads a lockColor key off the bar, so writing that key from our
-- code means Blizzard's code reads a tainted value on every health tick. Instead
-- the stock handler is left alone and our colour is put back right after it.
local barColor = setmetatable({}, { __mode = "k" })
local colorHooked = false

function Module.ColorHealthBar(bar, r, g, b)
	barColor[bar] = { r, g, b }
	bar:SetStatusBarColor(r, g, b)
end

function Module:StyleHealthBar()
	local bar = _G.GameTooltipStatusBar
	if not bar then
		return
	end
	bar:SetStatusBarTexture(K.GetTexture(C.Unitframe and C.Unitframe.Texture or "KkthnxUI"))
	bar:SetHeight(12)
	PositionHealthBar(bar)

	-- Blizzard recolours the bar green on every value change. Put ours back after it.
	if not colorHooked then
		colorHooked = true
		hooksecurefunc(bar, "SetValue", function(self)
			local color = barColor[self]
			if color then
				self:SetStatusBarColor(color[1], color[2], color[3])
			end
		end)
	end

	if not bar.KKUI_Background then
		K.CreateBackground(bar, 0.1, 0.1, 0.1, 0.9)
		K.CreateBorder(bar)
	end

	if not bar.KKUI_Text then
		local text = bar:CreateFontString(nil, "OVERLAY")
		K.SetFont(text, 11, K.FontOutlineStyle())
		text:SetPoint("CENTER", bar, "CENTER", 0, 0)
		bar.KKUI_Text = text

		-- Hooked on SetValue rather than the OnValueChanged script. A script hook on
		-- the tooltip bar runs inside the tooltip's own update, which is the same
		-- execution that goes on to build widget sets.
		hooksecurefunc(bar, "SetValue", Module.UpdateHealthText)
	end
end

-- "7.9m / 7.9m" read from the unit the tooltip shows (set by the unit post
-- call), not from the bar. The numbers are secret on this client, so they go
-- straight into AbbreviateNumbers and SetFormattedText, the two calls that
-- accept them, and are never compared or added.
function Module.UpdateHealthText(bar)
	local fs = bar.KKUI_Text
	if not fs then
		return
	end
	local unit = Module.tooltipUnit
	if not C.Tooltip.HealthValue or not unit or not UnitExists(unit) then
		fs:SetText("")
		return
	end
	if UnitIsDeadOrGhost(unit) then
		fs:SetText(DEAD)
		return
	end
	fs:SetFormattedText("%s / %s", AbbreviateNumbers(UnitHealth(unit)), AbbreviateNumbers(UnitHealthMax(unit)))
end
