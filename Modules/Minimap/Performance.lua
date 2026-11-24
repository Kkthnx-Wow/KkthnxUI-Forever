--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Minimap/Performance.lua
	Purpose:
		The framerate and latency datatext, reading like "100fps - 10ms". The two
		numbers are graded against our shared palette (jade, gold, ember, crimson)
		so a glance tells you whether things are healthy, while the fps and ms
		labels take a colour of your choosing (white, class, or custom).

		Hovering gives the detail, and it stays live while the pointer is on it:
		  Framerate now, plus the average and the low over the last minute.
		  Home and world latency, each with what it covers, since the game only
		  measures them every 30 seconds and the two are easy to mix up.
		  Download and upload separately.
		  Addon CPU from the game's own profiler: how much of each frame all
		  addons take, then the costliest ones with their share. The share is
		  worked out the way the game's addon list does, so the numbers agree.
		  Holding Shift shows more addons and their memory. Memory is only
		  measured while Shift is held, since reading it walks every addon.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Minimap")

local _G = _G
local format = string.format
local ipairs = ipairs
local sort = table.sort
local min = math.min
local floor = math.floor

local CreateFrame = CreateFrame
local GetTime = GetTime
local IsShiftKeyDown = IsShiftKeyDown
local GetFramerate = _G.GetFramerate
local GetNetStats = _G.GetNetStats
local C_AddOnProfiler = _G.C_AddOnProfiler
local C_AddOns = _G.C_AddOns
local UpdateAddOnMemoryUsage = _G.UpdateAddOnMemoryUsage
local GetAddOnMemoryUsage = _G.GetAddOnMemoryUsage
local collectgarbage = collectgarbage
local GameTooltip = _G.GameTooltip

local Minimap = _G.Minimap

-- How often the readout and an open tooltip refresh.
local UPDATE_INTERVAL = 1
-- Framerate samples kept, one a second, for the average and the low.
local HISTORY = 60
-- Addons listed under CPU, and with Shift held.
local TOP_ADDONS, TOP_ADDONS_SHIFT = 5, 12
-- Memory is read at most this often while Shift is held.
local MEMORY_INTERVAL = 2

-- Grading thresholds. Framerate counts UP (higher is better) and latency counts
-- DOWN (lower is better), so each list is walked in its own direction.
local FPS_STEPS = { { 60, "jade" }, { 40, "gold" }, { 20, "ember" } }
local MS_STEPS = { { 75, "jade" }, { 150, "gold" }, { 300, "ember" } }

-- Colour for a framerate. Jade at 60 and above, then down through gold and ember
-- to crimson.
local function FPSColor(value)
	for _, step in ipairs(FPS_STEPS) do
		if value >= step[1] then
			return K.Colors[step[2]]
		end
	end
	return K.Colors.crimson
end

-- Colour for a latency in milliseconds, the same scale inverted.
local function MSColor(value)
	for _, step in ipairs(MS_STEPS) do
		if value <= step[1] then
			return K.Colors[step[2]]
		end
	end
	return K.Colors.crimson
end

-- Colour for a share of frame time, as a fraction.
local function ShareColor(share)
	if share < 0.05 then
		return K.Colors.jade
	elseif share < 0.15 then
		return K.Colors.gold
	elseif share < 0.3 then
		return K.Colors.ember
	end
	return K.Colors.crimson
end

local function Hex(color)
	return K.RGBToHex(color)
end

-- The colour the fps and ms labels wear, per the config.
local function LabelColor()
	local mode = C.Minimap.PerformanceLabelColor
	if mode == "Class" then
		local c = K.ClassColor
		return { c.r or c[1], c.g or c[2], c.b or c[3] }
	elseif mode == "Custom" then
		return C.Minimap.PerformanceCustomColor or { 1, 1, 1 }
	end
	return { 1, 1, 1 }
end

-- Network stats. The worse latency (the one you feel), both latencies, and the
-- download and upload rates in kilobytes a second.
local function Net()
	if not GetNetStats then
		return 0, 0, 0, 0, 0
	end
	local down, up, home, world = GetNetStats()
	home, world = home or 0, world or 0
	return (home > world and home or world), home, world, down or 0, up or 0
end

local function CurrentFPS()
	return floor((GetFramerate() or 0) + 0.5)
end

-- ---------------------------------------------------------------------------
-- Framerate history
-- ---------------------------------------------------------------------------

local fpsRing, fpsCount, fpsHead = {}, 0, 0

local function RecordFPS(fps)
	fpsHead = fpsHead % HISTORY + 1
	fpsRing[fpsHead] = fps
	if fpsCount < HISTORY then
		fpsCount = fpsCount + 1
	end
end

local function FPSHistory()
	if fpsCount == 0 then
		return
	end
	local total, low = 0, nil
	for i = 1, fpsCount do
		local value = fpsRing[i]
		total = total + value
		if not low or value < low then
			low = value
		end
	end
	return floor(total / fpsCount + 0.5), low
end

-- ---------------------------------------------------------------------------
-- Readout
-- ---------------------------------------------------------------------------

local function BuildText()
	local fps = CurrentFPS()
	local ms = Net()
	local label = Hex(LabelColor())
	local sep = C.Minimap.PerformanceSeparator or "-"
	return format("%s%d|r%sfps|r %s%s %s%d|r%sms|r", Hex(FPSColor(fps)), fps, label, label, sep, Hex(MSColor(ms)), ms, label)
end

-- The data bar shows the same readout.
Module.PerformanceText = BuildText

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

local function Header(tooltip, text, right)
	local info = K.Colors.info
	if right then
		local muted = K.Colors.muted
		tooltip:AddDoubleLine(text, right, info[1], info[2], info[3], muted[1], muted[2], muted[3])
	else
		tooltip:AddLine(text, info[1], info[2], info[3])
	end
end

local function Row(tooltip, label, value, color)
	color = color or K.Colors.silver
	tooltip:AddDoubleLine(label, value, 1, 1, 1, color[1], color[2], color[3])
end

-- A percentage with the same precision the game's addon list uses.
local function Percent(fraction)
	local pct = fraction * 100
	if pct >= 1 then
		return format("%.0f%%", pct)
	elseif pct >= 0.1 then
		return format("%.1f%%", pct)
	elseif pct >= 0.01 then
		return format("%.2f%%", pct)
	end
	return "0%"
end

-- Addon CPU from the game's profiler. Returns false when there is none.
local function AddProfilerLines(tooltip, count)
	if not (C_AddOnProfiler and C_AddOnProfiler.IsEnabled and C_AddOnProfiler.IsEnabled()) then
		return false
	end
	local metric = Enum.AddOnProfilerMetric and Enum.AddOnProfilerMetric.RecentAverageTime
	if not metric or not C_AddOnProfiler.GetTopKAddOnsForMetric then
		return false
	end

	local results = C_AddOnProfiler.GetTopKAddOnsForMetric(metric, count)
	if not results or #results == 0 then
		return false
	end

	-- The whole frame, and the part every addon together takes of it.
	local app = C_AddOnProfiler.GetApplicationMetric and C_AddOnProfiler.GetApplicationMetric(metric) or 0
	local overall = C_AddOnProfiler.GetOverallMetric and C_AddOnProfiler.GetOverallMetric(metric) or 0

	tooltip:AddLine(" ")
	if app > 0 then
		local share = overall / app
		local color = ShareColor(share)
		Header(tooltip, L["Addon CPU"], format(L["%s of each frame"], Hex(color) .. Percent(share) .. "|r"))
	else
		Header(tooltip, L["Addon CPU"])
	end

	for _, entry in ipairs(results) do
		local name = entry.addOnName or "?"
		local value = entry.metricValue or 0
		-- Share against the frame time not spent in other addons, the same way the
		-- game's addon list works it out.
		local relative = app - overall + value
		local share = relative > 0 and value / relative or 0
		local color = ShareColor(share)
		local text = format("%.2f ms", value)
		if app > 0 then
			text = format("%s  %s%s|r", text, Hex(color), Percent(share))
		end
		Row(tooltip, name, text, color)
	end
	return true
end

-- Memory per addon, refreshed at most every MEMORY_INTERVAL. The rows and the
-- sort order are reused, so holding Shift does not churn tables.
local memNames, memValues, memOrder, memCount, memTotal, memReadAt = {}, {}, {}, 0, 0, nil

local function ByMemory(a, b)
	return memValues[a] > memValues[b]
end

local function ReadMemory()
	local now = GetTime()
	if memReadAt and now - memReadAt < MEMORY_INTERVAL then
		return
	end
	memReadAt = now
	UpdateAddOnMemoryUsage()
	memCount, memTotal = 0, 0
	for i = 1, C_AddOns.GetNumAddOns() do
		if C_AddOns.IsAddOnLoaded(i) then
			memCount = memCount + 1
			local kb = GetAddOnMemoryUsage(i) or 0
			memNames[memCount] = C_AddOns.GetAddOnInfo(i) or "?"
			memValues[memCount] = kb
			memOrder[memCount] = memCount
			memTotal = memTotal + kb
		end
	end
	for i = memCount + 1, #memOrder do
		memOrder[i] = nil
	end
	sort(memOrder, ByMemory)
end

local function MemoryText(kb)
	if kb >= 1024 then
		return format("%.2f mb", kb / 1024)
	end
	return format("%d kb", kb)
end

local function AddMemoryLines(tooltip, count)
	if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage and C_AddOns and C_AddOns.GetNumAddOns) then
		return
	end
	ReadMemory()
	if memCount == 0 then
		return
	end
	tooltip:AddLine(" ")
	Header(tooltip, L["Addon Memory"], MemoryText(memTotal))
	for i = 1, min(count, memCount) do
		local index = memOrder[i]
		Row(tooltip, memNames[index], MemoryText(memValues[index]))
	end
end

local tipOwner, tipPoint

local function FillTooltip(anchor, point)
	local fps = CurrentFPS()
	local _, home, world, down, up = Net()
	local shift = IsShiftKeyDown()

	GameTooltip:SetOwner(anchor, point or "ANCHOR_LEFT")
	GameTooltip:ClearLines()
	Header(GameTooltip, L["Performance"])
	GameTooltip:AddLine(" ")

	Row(GameTooltip, L["Framerate"], format("%d fps", fps), FPSColor(fps))
	local average, low = FPSHistory()
	if average then
		Row(GameTooltip, L["Average (last minute)"], format("%d fps", average), FPSColor(average))
		Row(GameTooltip, L["Lowest (last minute)"], format("%d fps", low), FPSColor(low))
	end

	GameTooltip:AddLine(" ")
	Header(GameTooltip, L["Latency"], L["checked every 30 sec"])
	Row(GameTooltip, L["Home (chat, auction house)"], format("%d ms", home), MSColor(home))
	Row(GameTooltip, L["World (combat, movement)"], format("%d ms", world), MSColor(world))
	Row(GameTooltip, L["Download"], format("%.2f kb/s", down))
	Row(GameTooltip, L["Upload"], format("%.2f kb/s", up))

	if collectgarbage then
		GameTooltip:AddLine(" ")
		Row(GameTooltip, L["UI Memory"], MemoryText(collectgarbage("count") or 0))
	end

	local count = shift and TOP_ADDONS_SHIFT or TOP_ADDONS
	local profiled = AddProfilerLines(GameTooltip, count)
	-- Memory always shows with Shift, and on its own when there is no profiler.
	if shift or not profiled then
		AddMemoryLines(GameTooltip, count)
	end

	GameTooltip:AddLine(" ")
	local muted = K.Colors.muted
	GameTooltip:AddLine(K.ColorText("info", L["Left Click"]) .. " " .. L["Collect garbage"], muted[1], muted[2], muted[3])
	if not shift then
		GameTooltip:AddLine(K.ColorText("info", L["Hold Shift"]) .. " " .. L["More addons and their memory"], muted[1], muted[2], muted[3])
	end
	GameTooltip:Show()
end

-- Open the tooltip. It keeps refreshing on the readout's own tick while this
-- anchor still owns it, and redraws at once when Shift is pressed or let go.
function Module:PerformanceTooltip(anchor, point)
	tipOwner, tipPoint = anchor, point
	FillTooltip(anchor, point)
end

local function RefreshTooltip()
	if tipOwner and GameTooltip:IsOwned(tipOwner) then
		FillTooltip(tipOwner, tipPoint)
	else
		tipOwner = nil
	end
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function CollectGarbage()
	if not collectgarbage then
		return
	end
	local before = collectgarbage("count") or 0
	collectgarbage("collect")
	local after = collectgarbage("count") or 0
	K.Print(L["Freed %s, UI memory is now %s."], MemoryText(before - after), MemoryText(after))
	RefreshTooltip()
end

function Module:CreatePerformance()
	if not C.Minimap.ShowPerformance then
		return
	end

	local perf = CreateFrame("Button", "KKUI_Performance", UIParent)
	-- Match the map width so the strip lines up with the other readouts around it,
	-- and keep the height in step with the text size.
	local width = C.Minimap.Size or 200
	local height = (C.Minimap.PerformanceFontSize or 13) + 6
	perf:SetSize(width, height)
	perf:RegisterForClicks("LeftButtonUp")

	local text = perf:CreateFontString(nil, "OVERLAY")
	K.SetFont(text, C.Minimap.PerformanceFontSize or 13, K.FontOutlineStyle())
	-- Centred rather than filling the button, so the strip below hugs the readout
	-- instead of stretching the full click area.
	text:SetPoint("CENTER")
	perf.Text = text
	self.performance = perf

	-- The shared strip, spanning the whole readout like the zone name, the clock
	-- and the coordinates do.
	local shade = K.CreateTextShade(perf, "ARTWORK", 6)
	shade:SetRegion(perf, 0, 0)
	shade:SetColor(K.StripColor[1], K.StripColor[2], K.StripColor[3], K.GradientAlpha.strip)
	shade:Show()
	perf.Shade = shade

	-- Sits under the map by default, below the coordinate readout, and is movable
	-- from there like any other piece of the UI.
	local default = { "TOP", Minimap, "BOTTOM", 0, C.Minimap.ShowCoords and -22 or -6 }
	K.CreateMover(perf, "Performance", L["Performance"], default, width, height)

	perf:SetScript("OnClick", CollectGarbage)
	perf:SetScript("OnEnter", function(self2)
		Module:PerformanceTooltip(self2)
	end)
	perf:SetScript("OnLeave", function()
		tipOwner = nil
		GameTooltip_Hide()
	end)

	-- Shift changes what the tooltip lists, so redraw the moment it changes.
	perf:RegisterEvent("MODIFIER_STATE_CHANGED")
	perf:SetScript("OnEvent", function(_, _, key)
		if tipOwner and (key == "LSHIFT" or key == "RSHIFT") then
			RefreshTooltip()
		end
	end)

	-- One tick a second. Record the framerate, redraw the readout only when its
	-- text changed, and keep an open tooltip live.
	local shown
	local elapsed = UPDATE_INTERVAL
	perf:SetScript("OnUpdate", function(_, delta)
		elapsed = elapsed + delta
		if elapsed < UPDATE_INTERVAL then
			return
		end
		elapsed = 0
		RecordFPS(CurrentFPS())
		local value = BuildText()
		if value ~= shown then
			shown = value
			text:SetText(value)
		end
		if tipOwner then
			RefreshTooltip()
		end
	end)
end
