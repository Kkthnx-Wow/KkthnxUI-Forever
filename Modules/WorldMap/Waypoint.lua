--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/WorldMap/Waypoint.lua
	Purpose:
		Waypoints on the game's own map pin. Both ways set the user waypoint and
		super-track it, so the game draws its own pin and on-screen arrow.

			/way 45 60            the zone you are in
			/way 45.2 60.8        tenths work too, a comma between the two is fine
			/way Westfall 45 60   a zone by name, whole or the start of it
			/way 1436 45 60       a map ID, with or without a leading #
			/way clear            remove the waypoint

			Alt+click on the world map sets it where you clicked.

		The map click goes through the canvas click handler registry, which the map
		runs through securecallfunction, so our handler never taints the map.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("WorldMap")

local _G = _G
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local tinsert = table.insert
local tconcat = table.concat
local strlower = string.lower
local strmatch = string.match
local gmatch = string.gmatch
local IsAltKeyDown = IsAltKeyDown
local PlaySound = PlaySound
local C_Map = C_Map
local C_SuperTrack = C_SuperTrack

-- Above Blizzard's own Ctrl+click pin handler (90), so Alt is checked first.
local CLICK_PRIORITY = 100

-- Map types a player would type by name. Dungeons are in so naming one says it
-- takes no waypoint, rather than that it does not exist.
local NAMED_TYPES = {
	[Enum.UIMapType.Continent] = true,
	[Enum.UIMapType.Zone] = true,
	[Enum.UIMapType.Dungeon] = true,
}

-- lower case name -> list of map IDs, built the first time a name is typed.
local nameIndex

local function MapName(mapID)
	local info = C_Map.GetMapInfo(mapID)
	return info and info.name or tostring(mapID)
end

local function CurrentMapID()
	local mapID = C_Map.GetBestMapForUnit("player")
	if not mapID and _G.WorldMapFrame then
		mapID = _G.WorldMapFrame:GetMapID()
	end
	return mapID
end

-- Every zone and continent under the top of the map tree the player is in.
-- Walking up from the player's own map avoids hard coding a world map ID.
local function BuildNameIndex()
	nameIndex = {}
	local root = CurrentMapID()
	local info = root and C_Map.GetMapInfo(root)
	while info and info.parentMapID and info.parentMapID > 0 do
		root = info.parentMapID
		info = C_Map.GetMapInfo(root)
	end
	if not root then
		return
	end

	local children = C_Map.GetMapChildrenInfo(root, nil, true)
	if not children then
		return
	end
	for _, child in ipairs(children) do
		if NAMED_TYPES[child.mapType] and child.name and child.name ~= "" then
			local key = strlower(child.name)
			local list = nameIndex[key]
			if not list then
				list = {}
				nameIndex[key] = list
			end
			tinsert(list, child.mapID)
		end
	end
end

-- A name can repeat (a zone and its phased copy), so take the first copy that
-- takes a waypoint.
local function FirstUsable(list)
	for _, mapID in ipairs(list) do
		if C_Map.CanSetUserWaypointOnMap(mapID) then
			return mapID
		end
	end
	return list[1]
end

-- An exact name wins. Otherwise the start of a name, if only one zone has it.
local function FindMapByName(text)
	if not nameIndex then
		BuildNameIndex()
	end
	if not nameIndex then
		return
	end

	local key = strlower(text)
	if nameIndex[key] then
		return FirstUsable(nameIndex[key])
	end

	local found
	for name, list in pairs(nameIndex) do
		if name:sub(1, #key) == key then
			if found then
				return nil, true
			end
			found = list
		end
	end
	return found and FirstUsable(found)
end

-- x and y are 0 to 1, as the map and UiMapPoint use them.
local function SetWaypoint(mapID, x, y)
	if not C_Map.CanSetUserWaypointOnMap(mapID) then
		K.Print(L["You can't place a waypoint on %s."], MapName(mapID))
		return false
	end
	local point = UiMapPoint.CreateFromCoordinates(mapID, x, y)
	if not C_Map.SetUserWaypoint(point) then
		K.Print(L["The waypoint could not be set."])
		return false
	end
	C_SuperTrack.SetSuperTrackedUserWaypoint(true)
	K.Print(L["Waypoint set in %s at %s."], MapName(mapID), K.FormatCoords(x * 100, y * 100))
	return true
end

local function ClearWaypoint()
	if C_Map.HasUserWaypoint() then
		C_Map.ClearUserWaypoint()
		C_SuperTrack.SetSuperTrackedUserWaypoint(false)
		K.Print(L["Waypoint cleared."])
	else
		K.Print(L["There is no waypoint to clear."])
	end
end

local function Coord(text)
	local value = tonumber(text)
	if value and value >= 0 and value <= 100 then
		return value / 100
	end
end

local function Usage()
	K.Print(L["Usage: /way [zone or map ID] x y, or /way clear"])
end

-- The last two words are the coordinates, anything before them names the map.
local function HandleSlash(msg)
	local words = {}
	for word in gmatch(msg or "", "[^%s,]+") do
		tinsert(words, word)
	end

	local first = words[1] and strlower(words[1])
	if first == "clear" or first == "reset" then
		ClearWaypoint()
		return
	end

	local count = #words
	if count < 2 then
		Usage()
		return
	end
	local x, y = Coord(words[count - 1]), Coord(words[count])
	if not x or not y then
		Usage()
		return
	end

	local mapID
	if count == 2 then
		mapID = CurrentMapID()
		if not mapID then
			K.Print(L["Your current zone is not known here. Name the zone first."])
			return
		end
	else
		local name = tconcat(words, " ", 1, count - 2)
		local id = tonumber(strmatch(name, "^#?(%d+)$"))
		if id then
			if not C_Map.GetMapInfo(id) then
				K.Print(L["There is no map with ID %d."], id)
				return
			end
			mapID = id
		else
			local ambiguous
			mapID, ambiguous = FindMapByName(name)
			if not mapID then
				if ambiguous then
					K.Print(L["More than one zone starts with \"%s\". Type more of the name."], name)
				else
					K.Print(L["No zone called \"%s\" was found."], name)
				end
				return
			end
		end
	end

	SetWaypoint(mapID, x, y)
end

-- Alt+click on the map canvas. Returning true stops the click there, so the
-- map does not also zoom into the zone under the cursor.
local function OnCanvasClick(map, button, cursorX, cursorY)
	if button ~= "LeftButton" or not IsAltKeyDown() then
		return false
	end
	local mapID = map:GetMapID()
	if mapID and cursorX and cursorY and SetWaypoint(mapID, cursorX, cursorY) then
		local sound = SOUNDKIT and SOUNDKIT.UI_MAP_WAYPOINT_SUPER_TRACK_ON
		if sound then
			PlaySound(sound)
		end
	end
	return true
end

function Module:SetupWaypoints()
	if not C.WorldMap.Waypoints then
		return
	end
	-- UiMapPoint is Blizzard Lua, loaded for this client family. Without it there
	-- is nothing to hand SetUserWaypoint, so stay off rather than half work.
	if not (UiMapPoint and UiMapPoint.CreateFromCoordinates and C_Map.SetUserWaypoint and C_SuperTrack) then
		return
	end

	-- Leave /way to a dedicated waypoint addon when one is loaded.
	local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
	_G.SLASH_KKUI_WAY1 = "/kkway"
	if not (isLoaded and isLoaded("TomTom")) then
		_G.SLASH_KKUI_WAY2 = "/way"
	end
	_G.SlashCmdList.KKUI_WAY = HandleSlash

	local map = _G.WorldMapFrame
	if map and map.AddCanvasClickHandler then
		map:AddCanvasClickHandler(OnCanvasClick, CLICK_PRIORITY)
	end
end
