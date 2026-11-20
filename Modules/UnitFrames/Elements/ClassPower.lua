--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Elements/ClassPower.lua
	Purpose:
		Class resources above the player frame: combo points, holy power, soul
		shards and arcane charges.

		Only the widget the player's class can actually use is built, so a warrior
		never reserves empty space above their health bar.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")
local Build = Module.Build

local CreateFrame = CreateFrame

-- Classes with a segmented resource oUF drives through the ClassPower element.
-- Forever only has combo points. Holy power, soul shards and arcane charges are
-- later resources oUF never enables on this client.
local CLASS_POWER = {
	DRUID = true,
	ROGUE = true,
}

local MAX_SEGMENTS = 10

-- Per-point colours for combo points, a red to green ramp with the accent for any
-- extra (anima charged) points.
local COMBO_COLORS = {
	{ 0.85, 0.27, 0.27 },
	{ 0.90, 0.45, 0.25 },
	{ 0.90, 0.68, 0.28 },
	{ 0.62, 0.80, 0.35 },
	{ 0.35, 0.80, 0.45 },
	{ 0.36, 0.55, 0.81 },
	{ 0.55, 0.32, 0.78 },
}
-- Classes whose ClassPower element is combo points.
local COMBO_CLASS = {
	ROGUE = true,
	DRUID = true,
}

-- Spread `count` segments across the holder width. Called from the element's
-- PostUpdate (the maximum changes with spec and talents) and again whenever the
-- holder resizes, since the real width only exists after the spawn pass.
local function LayoutSegments(holder, count)
	local bars = holder.bars
	local width = holder:GetWidth()
	if not width or width <= 1 or count < 1 then
		return
	end

	local spacing = C.Unitframe.ClassPower.Spacing
	local barWidth = (width - spacing * (count - 1)) / count

	for i = 1, #bars do
		local bar = bars[i]
		bar:ClearAllPoints()
		bar:SetWidth(barWidth)
		if i == 1 then
			bar:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
			bar:SetPoint("BOTTOMLEFT", holder, "BOTTOMLEFT", 0, 0)
		else
			bar:SetPoint("TOPLEFT", bars[i - 1], "TOPRIGHT", spacing, 0)
			bar:SetPoint("BOTTOMLEFT", bars[i - 1], "BOTTOMRIGHT", spacing, 0)
		end
	end

	holder.count = count
end

local function OnHolderResize(holder)
	LayoutSegments(holder, holder.count or 1)
end

-- Build the holder plus its segments and return the array oUF wants.
local function CreateSegmented(self, total)
	local db = C.Unitframe.ClassPower
	local holder = CreateFrame("Frame", nil, self)
	Module.StackUp(self, holder, db.Height)

	local bars = {}
	for i = 1, total do
		local bar = CreateFrame("StatusBar", nil, holder)
		bar:SetStatusBarTexture(Module.Texture())
		K.CreateBackground(bar, 0.08, 0.08, 0.08, 0.9)
		K.CreateBorder(bar)
		bar:Hide()
		bars[i] = bar
	end

	holder.bars = bars
	holder.count = total
	holder:SetScript("OnSizeChanged", OnHolderResize)

	self.ClassPowerHolder = holder
	return holder, bars
end

function Build.ClassPower(self)
	if not CLASS_POWER[K.Class] then
		return
	end

	local holder, bars = CreateSegmented(self, MAX_SEGMENTS)

	-- The element hands us the live maximum, which is the only reliable moment
	-- to re-divide the row. Combo-point classes also get the per-point ramp so
	-- each point reads distinctly.
	local combo = COMBO_CLASS[K.Class]
	-- Arguments are (element, cur, max, hasCurChanged, hasMaxChanged, ...). Reading
	-- the wrong flag here left the row undivided when only the maximum changed.
	bars.PostUpdate = function(_, _, max, _, hasMaxChanged)
		if hasMaxChanged and max and max > 0 then
			LayoutSegments(holder, max)
		end
		if combo then
			for i = 1, #bars do
				local col = COMBO_COLORS[i] or COMBO_COLORS[#COMBO_COLORS]
				bars[i]:SetStatusBarColor(col[1], col[2], col[3])
			end
		end
	end

	self.ClassPower = bars
	return bars
end

