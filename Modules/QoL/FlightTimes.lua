--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/FlightTimes.lua
	Purpose:
		Time every flight you take and remember it for the whole account. The
		flight master's map then shows how long a flight to each destination
		takes, and a bar counts down the time left while you fly. A route you
		have not flown yet says so, and its bar counts up instead, so the first
		trip records it.

		Nothing ships with the addon. Times come only from your own flights,
		keyed by the start and end flight points. Landing early with the leave
		button does not overwrite a time.

		Forever can open either the old taxi frame or the newer flight map, so
		the tooltip is added to both. TakeTaxiNode is the one call both use to
		start a flight, so the timing starts from a hook on it.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local _G = _G
local ipairs = ipairs
local pairs = pairs
local floor = math.floor
local concat = table.concat
local format = string.format
local match = string.match
local sort = table.sort
local wipe = wipe

local CreateFrame = CreateFrame
local GetCVarBool = GetCVarBool
local GetGameTime = GetGameTime
local GetZoneText = _G.GetZoneText
local date = _G.date
local tonumber = tonumber
local GameTooltip = GameTooltip
local GetTime = GetTime
local UIParent = UIParent
local UnitOnTaxi = UnitOnTaxi
local hooksecurefunc = hooksecurefunc
local C_TaxiMap = _G.C_TaxiMap
local GetTaxiMapID = _G.GetTaxiMapID
local NumTaxiNodes = _G.NumTaxiNodes
local TaxiNodeGetType = _G.TaxiNodeGetType
local TaxiNodeName = _G.TaxiNodeName
local GetNumRoutes = _G.GetNumRoutes
local TaxiGetNodeSlot = _G.TaxiGetNodeSlot

-- Seconds to wait for the flight to start after picking a destination. Not
-- enough money or a click while mounted in combat never leaves the ground.
local TAKEOFF_GRACE = 6
-- A flight this short is a misread, not a route.
local MIN_FLIGHT = 5
local UPDATE_RATE = 0.2

local times -- KkthnxUIDB.flightTimes, route key -> seconds
local nodes = {} -- slot index -> { id, name } at the open flight master
local origin -- the node the flight master stands at

local flight -- the flight being timed
local bar
local elapsedSinceUpdate = 0
local flightMapHooked = false

-- Tall enough that 12 point text sits inside with room to spare.
-- Wide enough for the caption line under it to fit a long start name beside
-- the landing time.
local BAR_WIDTH, BAR_HEIGHT = 280, 20
-- A caption line under the bar with where you started, the stops and when
-- you land.
local CAPTION_GAP, CAPTION_SIZE = 4, 11
-- The icon square matches the bar height, one UI gap to its left.
local ICON_GAP = 6
-- The flight mount of your faction, a full square icon that reads at bar
-- height. The map legend's flight master symbol is the fallback.
local ICON_FILE = K.Faction == "Horde" and "Interface\\Icons\\Ability_Mount_Wyvern_01" or "Interface\\Icons\\Ability_Mount_Gryphon_01"
local ICON_ATLAS = "FlightPath"

local function Clock(seconds)
	seconds = floor(seconds + 0.5)
	if seconds >= 3600 then
		return format("%d:%02d:%02d", floor(seconds / 3600), floor(seconds / 60) % 60, seconds % 60)
	end
	return format("%d:%02d", floor(seconds / 60), seconds % 60)
end

-- "Booty Bay, Stranglethorn" reads as "Booty Bay". The zone half only makes
-- the line run out of room.
local function ShortName(name)
	return name and match(name, "^([^,]+)") or name
end

-- The landing time on the same clock the minimap shows, following the game's
-- local time and 24 hour settings.
local function LandingClock(secondsLeft)
	local hour, minute
	if GetCVarBool("timeMgrUseLocalTime") then
		hour, minute = tonumber(date("%H")), tonumber(date("%M"))
	else
		hour, minute = GetGameTime()
	end
	local total = (((hour or 0) * 60 + (minute or 0)) * 60 + floor(secondsLeft + 0.5)) % 86400
	hour, minute = floor(total / 3600), floor(total / 60) % 60
	if GetCVarBool("timeMgrUseMilitaryTime") then
		return format("%02d:%02d", hour, minute)
	end
	local suffix = hour < 12 and (_G.TIMEMANAGER_AM or "AM") or (_G.TIMEMANAGER_PM or "PM")
	local h = hour % 12
	return format("%d:%02d %s", h == 0 and 12 or h, minute, suffix)
end

local function StopsText(stops)
	if stops == 0 then
		return L["nonstop"]
	elseif stops == 1 then
		return L["1 stop"]
	end
	return format(L["%d stops"], stops)
end

-- A route is every stop from here to the destination, since the same two
-- flight points take a different path, and a different time, depending on which
-- points in between you know. Node IDs survive a locale change and are the only
-- keys that can be shared. Names are the fallback when IDs cannot be read.
local parts = {}

local function RouteKey(slot)
	local destination = nodes[slot]
	if not origin or not destination or destination == origin then
		return nil
	end
	wipe(parts)
	local byID = origin.id ~= nil
	parts[1] = origin
	for hop = 1, GetNumRoutes(slot) do
		local node = nodes[TaxiGetNodeSlot(slot, hop, false)]
		if not node then
			return nil
		end
		if not node.id then
			byID = false
		end
		parts[#parts + 1] = node
	end
	if #parts < 2 then
		return nil
	end
	local field = byID and "id" or "name"
	for i = 1, #parts do
		parts[i] = parts[i][field]
	end
	return concat(parts, ">")
end

-- ---------------------------------------------------------------------------
-- Flight master
-- ---------------------------------------------------------------------------

local function ReadNodes()
	wipe(nodes)
	origin = nil

	for slot = 1, NumTaxiNodes() do
		local node = { name = TaxiNodeName(slot) }
		nodes[slot] = node
		if TaxiNodeGetType(slot) == "CURRENT" then
			origin = node
		end
	end

	local mapID = GetTaxiMapID and GetTaxiMapID()
	local list = mapID and C_TaxiMap and C_TaxiMap.GetAllTaxiNodes(mapID)
	if list then
		for _, info in ipairs(list) do
			local node = nodes[info.slotIndex]
			if node then
				node.id = info.nodeID
			end
		end
	end
end

local function AddTimeLine(slot)
	if TaxiNodeGetType(slot) ~= "REACHABLE" then
		return
	end
	local key = RouteKey(slot)
	if not key then
		return
	end
	local seconds = times[key]
	local label = L["Flight time"]
	if seconds then
		local info = K.Colors.info
		GameTooltip:AddDoubleLine(label, Clock(seconds), 1, 0.82, 0, info[1], info[2], info[3])
	else
		local muted = K.Colors.muted
		GameTooltip:AddDoubleLine(label, L["Not timed yet"], 1, 0.82, 0, muted[1], muted[2], muted[3])
	end
	GameTooltip:Show()
end

local function OnTaxiButtonEnter(button)
	AddTimeLine(button:GetID())
end

local function OnFlightPinEnter(pin)
	local data = pin.taxiNodeData
	if data then
		AddTimeLine(data.slotIndex)
	end
end

local function HookFlightMap()
	local mixin = _G.FlightMap_FlightPointPinMixin
	if mixin and not flightMapHooked then
		flightMapHooked = true
		-- Pins copy the mixin's methods when they are made, which happens the
		-- first time the map opens, after the addon has loaded.
		hooksecurefunc(mixin, "OnMouseEnter", OnFlightPinEnter)
	end
end

-- ---------------------------------------------------------------------------
-- In flight
-- ---------------------------------------------------------------------------

local function StopFlight()
	flight = nil
	if bar then
		bar:Hide()
	end
end

local function Land(now)
	local duration = now - flight.start
	if not flight.aborted and duration >= MIN_FLIGHT then
		times[flight.key] = floor(duration + 0.5)
	end
	StopFlight()
end

local function UpdateBar(now)
	local spent = now - flight.start
	local known = flight.known
	if known then
		local left = known - spent
		if left < 0 then
			left = 0
		end
		bar:SetValue(left / known)
		bar.Time:SetText(Clock(left))
		bar.Lands:SetText(format(L["lands %s"], LandingClock(left)))
	else
		bar:SetValue(1)
		bar.Time:SetText(Clock(spent))
	end
end

local function OnUpdate(_, elapsed)
	elapsedSinceUpdate = elapsedSinceUpdate + elapsed
	if elapsedSinceUpdate < UPDATE_RATE then
		return
	end
	elapsedSinceUpdate = 0

	if not flight then
		bar:Hide()
		return
	end
	local now = GetTime()
	if flight.test then
		if now - flight.start >= flight.known then
			StopFlight()
		else
			UpdateBar(now)
		end
		return
	end
	local onTaxi = UnitOnTaxi("player")

	if not flight.start then
		if onTaxi then
			flight.start = now
		elseif now - flight.picked > TAKEOFF_GRACE then
			StopFlight()
			return
		else
			return
		end
	elseif not onTaxi then
		Land(now)
		return
	end

	UpdateBar(now)
end

local function CreateBar()
	if bar then
		return
	end
	bar = CreateFrame("StatusBar", "KKUI_FlightBar", UIParent)
	bar:SetSize(BAR_WIDTH, BAR_HEIGHT)
	bar:SetPoint("TOP", UIParent, "TOP", 0, -120)
	bar:SetStatusBarTexture(K.GetTexture(C.Unitframe.Texture))
	bar:SetMinMaxValues(0, 1)
	K.CreateBorder(bar)

	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.5)

	local name = bar:CreateFontString(nil, "OVERLAY")
	K.SetFont(name, 12, K.FontOutlineStyle())
	name:SetPoint("LEFT", 6, 0)
	name:SetPoint("RIGHT", bar, "RIGHT", -56, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	bar.Name = name

	local time = bar:CreateFontString(nil, "OVERLAY")
	K.SetFont(time, 12, K.FontOutlineStyle())
	time:SetPoint("RIGHT", -6, 0)
	bar.Time = time

	-- A child of the bar, so it shows and hides with it.
	local holder = CreateFrame("Frame", nil, bar)
	holder:SetSize(BAR_HEIGHT, BAR_HEIGHT)
	holder:SetPoint("RIGHT", bar, "LEFT", -ICON_GAP, 0)
	K.CreateBorder(holder)

	local holderBg = holder:CreateTexture(nil, "BACKGROUND")
	holderBg:SetAllPoints()
	holderBg:SetColorTexture(0, 0, 0, 0.5)

	local icon = holder:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 1, -1)
	icon:SetPoint("BOTTOMRIGHT", -1, 1)
	if icon:SetTexture(ICON_FILE) then
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	else
		icon:SetAtlas(ICON_ATLAS)
	end
	bar.Icon = icon

	-- Two parts under the bar. The landing time sits right, under the timer,
	-- and the start and stops take the rest from under the icon, so the part
	-- that changes never gets cut off.
	local soft = K.Colors.secondary
	local lands = bar:CreateFontString(nil, "OVERLAY")
	K.SetFont(lands, CAPTION_SIZE, K.FontOutlineStyle())
	lands:SetPoint("TOPRIGHT", bar, "BOTTOMRIGHT", 0, -CAPTION_GAP)
	lands:SetJustifyH("RIGHT")
	lands:SetTextColor(soft[1], soft[2], soft[3])
	bar.Lands = lands

	local caption = bar:CreateFontString(nil, "OVERLAY")
	K.SetFont(caption, CAPTION_SIZE, K.FontOutlineStyle())
	caption:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -CAPTION_GAP)
	caption:SetPoint("RIGHT", lands, "LEFT", -ICON_GAP, 0)
	caption:SetJustifyH("LEFT")
	caption:SetWordWrap(false)
	caption:SetTextColor(soft[1], soft[2], soft[3])
	bar.Caption = caption

	bar:Hide()
	bar:SetScript("OnUpdate", OnUpdate)
	-- The mover spans the icon and the caption too, with the bar pinned to its
	-- top right corner.
	K.CreateMover(bar, "FlightBar", L["Flight Bar"], { "TOP", UIParent, "TOP", 0, -120 }, BAR_WIDTH + ICON_GAP + BAR_HEIGHT, BAR_HEIGHT + CAPTION_GAP + CAPTION_SIZE + 2, "TOPRIGHT")
end

-- A timed route drains in the accent colour, an untimed one sits full in the
-- muted colour and counts up.
local function ShowBar(name, from, stops)
	bar.Caption:SetText(format(L["from %s, %s"], ShortName(from) or UNKNOWN, StopsText(stops)))
	bar.Lands:SetText(flight.known and "" or L["timing this route"])

	local accent = flight.known and K.Colors.accent or K.Colors.muted
	bar:SetStatusBarColor(accent[1], accent[2], accent[3])
	-- Greyed while a new route is still being timed.
	bar.Icon:SetDesaturated(not flight.known)
	bar.Name:SetText(ShortName(name))
	bar.Time:SetText("")
	bar:SetValue(1)
	elapsedSinceUpdate = UPDATE_RATE
	bar:Show()
end

local function OnTakeTaxiNode(slot)
	local key = RouteKey(slot)
	if not key then
		return
	end
	flight = {
		key = key,
		known = times[key],
		picked = GetTime(),
	}
	ShowBar(nodes[slot].name, origin.name, GetNumRoutes(slot) - 1)
end

local function OnEarlyLanding()
	if flight then
		flight.aborted = true
	end
end

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

local TEST_SECONDS = 20

-- /kk flighttest. A pretend flight that drains the bar over TEST_SECONDS, to
-- see and place it without a flight master. Works with the option off too.
function Module:ToggleFlightTest()
	CreateBar()
	if flight and not flight.test then
		K.Print(L["You are on a flight, so the bar is already showing."])
		return
	end
	if flight then
		StopFlight()
		return
	end
	flight = { test = true, known = TEST_SECONDS, start = GetTime() }
	ShowBar(L["Test flight"], GetZoneText(), 1)
end

-- /kk flights. Every route keyed by node IDs, one per line, ready to copy.
-- Name keys stay out, since they only match on the same game language.
function Module:ExportFlightTimes()
	local saved = _G.KkthnxUIDB and _G.KkthnxUIDB.flightTimes
	local lines = {}
	for key, seconds in pairs(saved or {}) do
		if match(key, "^%d+[>%d]*$") then
			lines[#lines + 1] = key .. "=" .. seconds
		end
	end
	if #lines == 0 then
		K.Print(L["No flight times to export yet."])
		return
	end
	sort(lines)
	K.ShowCopyText(format(L["Flight Times (%d routes)"], #lines), concat(lines, "\n"))
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function Module:SetupFlightTimes()
	if not (_G.TakeTaxiNode and NumTaxiNodes and TaxiNodeName and TaxiNodeGetType and UnitOnTaxi) then
		return
	end

	_G.KkthnxUIDB.flightTimes = _G.KkthnxUIDB.flightTimes or {}
	times = _G.KkthnxUIDB.flightTimes

	CreateBar()

	self:RegisterEvent("TAXIMAP_OPENED", ReadNodes)
	hooksecurefunc("TakeTaxiNode", OnTakeTaxiNode)
	if _G.TaxiRequestEarlyLanding then
		hooksecurefunc("TaxiRequestEarlyLanding", OnEarlyLanding)
	end
	if _G.TaxiNodeOnButtonEnter then
		hooksecurefunc("TaxiNodeOnButtonEnter", OnTaxiButtonEnter)
	end

	if C_AddOns.IsAddOnLoaded("Blizzard_FlightMap") then
		HookFlightMap()
	else
		self:RegisterEvent("ADDON_LOADED", function(_, _, name)
			if name == "Blizzard_FlightMap" then
				HookFlightMap()
			end
		end)
	end
end
