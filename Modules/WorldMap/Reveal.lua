--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/WorldMap/Reveal.lua
	Purpose:
		Map Reveal: draw the parts of a zone map the player has not explored yet, so
		the whole map is visible instead of fogged. The overlay tiles come from the
		raw data in RawMapData.lua (Blizzard's own map art, collected from a fully
		explored account), rendered the way the client tiles its exploration
		overlays. A labelled checkbox on the world map's title bar quick-toggles it
		on and off, and the choice is saved.

		The drawing is a post hook on each MapExplorationPin's RefreshOverlays, so
		it runs whenever the map redraws its exploration layer. It draws only into
		textures it created itself on the pin. Blizzard's overlay pool, texture
		load group and pin fields are never touched, and no Blizzard map method is
		called from here, since writing that state from addon code taints the map
		refresh that reads it.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("WorldMap")

local _G = _G
local pairs = pairs
local ipairs = ipairs
local wipe = wipe
local ceil = math.ceil
local tinsert = table.insert
local tonumber = tonumber
local gmatch = string.gmatch
local strmatch = string.match
local format = string.format
local hooksecurefunc = hooksecurefunc
local CreateFrame = CreateFrame
local C_Map = C_Map
local C_MapExplorationInfo = C_MapExplorationInfo
local WorldMapFrame = _G.WorldMapFrame
local GameTooltip = _G.GameTooltip

-- Scratch tables reused across refreshes so a redraw never churns garbage.
local exploredKeys, fileIDs = {}, {}

-- Our own tile textures, per pin, kept here rather than as a field on the pin.
-- A redraw reuses them from the start and hides whatever is left over.
local tilesByPin = {}

-- The overlay data keys a region as "W<w>H<h>X<x>Y<y>". These turn a live explored
-- texture into that key, and a key back into its numbers.
local function KeyFromInfo(info)
	return format("W%dH%dX%dY%d", info.textureWidth, info.textureHeight, info.offsetX, info.offsetY)
end

local function ShapeFromKey(key)
	local w, h, x, y = strmatch(key, "W(%d+)H(%d+)X(%d+)Y(%d+)")
	return tonumber(w), tonumber(h), tonumber(x), tonumber(y)
end

local function FileIDsFromString(str)
	wipe(fileIDs)
	for id in gmatch(str, "%d+") do
		tinsert(fileIDs, tonumber(id))
	end
end

-- Smallest power of two at or above n, for the ragged edge tiles whose file is
-- padded up to a power of two even though the drawn pixels are not.
local function NextPow2(n)
	local size = 16
	while size < n do
		size = size * 2
	end
	return size
end

-- Hide every tile from index first onwards.
local function HideFrom(tiles, first)
	for i = first, #tiles do
		tiles[i]:Hide()
	end
end

local function AcquireTile(pin, tiles, index)
	local texture = tiles[index]
	if not texture then
		-- A region on the pin, drawn just under Blizzard's own explored overlays,
		-- so it scales and fades with the map like they do.
		texture = pin:CreateTexture(nil, "ARTWORK", nil, -1)
		tiles[index] = texture
	end
	texture:ClearAllPoints()
	return texture
end

-- Draws every region of the current map the player has not explored, tiled
-- exactly the way the client tiles its own exploration overlays. Runs after
-- Blizzard's RefreshOverlays, and straight from the checkbox.
local function DrawReveal(pin)
	local tiles = tilesByPin[pin]
	if not tiles then
		tiles = {}
		tilesByPin[pin] = tiles
	end

	if not C.WorldMap.Reveal then
		HideFrom(tiles, 1)
		return
	end

	-- The scroll container builds its zoom levels when a map first loads into it.
	-- Before that, at login, asking for the current layer reads a nil table.
	local scroll = WorldMapFrame.ScrollContainer
	if not (scroll and scroll.zoomLevels) then
		HideFrom(tiles, 1)
		return
	end

	local mapID = WorldMapFrame:GetMapID()
	local artID = mapID and C_Map.GetMapArtID(mapID)
	local data = artID and Module.RawMapData[artID]
	local layers = data and C_Map.GetMapArtLayers(mapID)
	local layer = layers and layers[scroll:GetCurrentLayerIndex()]
	if not layer then
		HideFrom(tiles, 1)
		return
	end
	local tileW, tileH = layer.tileWidth, layer.tileHeight

	-- Regions the player already explored are drawn by the client, so skip ours for
	-- those or they would double up.
	wipe(exploredKeys)
	local explored = C_MapExplorationInfo.GetExploredMapTextures(mapID)
	if explored then
		for _, info in pairs(explored) do
			exploredKeys[KeyFromInfo(info)] = true
		end
	end

	local shade = C.WorldMap.RevealDim and 0.7 or 1
	local used = 0

	for key, idString in pairs(data) do
		if not exploredKeys[key] then
			local width, height, offsetX, offsetY = ShapeFromKey(key)
			FileIDsFromString(idString)
			local wide = ceil(width / tileW)
			local tall = ceil(height / tileH)

			for row = 1, tall do
				local pixelH = (row < tall) and tileH or (height % tileH)
				if pixelH == 0 then
					pixelH = tileH
				end
				local fileH = (row < tall) and tileH or NextPow2(pixelH)

				for col = 1, wide do
					local pixelW = (col < wide) and tileW or (width % tileW)
					if pixelW == 0 then
						pixelW = tileW
					end
					local fileW = (col < wide) and tileW or NextPow2(pixelW)

					used = used + 1
					local texture = AcquireTile(pin, tiles, used)
					texture:SetSize(pixelW, pixelH)
					texture:SetTexCoord(0, pixelW / fileW, 0, pixelH / fileH)
					texture:SetPoint("TOPLEFT", pin, "TOPLEFT", offsetX + tileW * (col - 1), -(offsetY + tileH * (row - 1)))
					texture:SetTexture(fileIDs[(row - 1) * wide + col], nil, nil, "TRILINEAR")
					texture:SetVertexColor(shade, shade, shade)
					texture:Show()
				end
			end
		end
	end

	HideFrom(tiles, used + 1)
end

-- The pins are created when the map first draws, so hooking may need a retry on
-- the first show. Runs once successfully.
--
-- No reset function is assigned onto the pin's texture pool. In 12.1 those pools
-- are secure variants reached through a proxy and their reset hook is a private
-- field called resetFunc, so such an assignment writes a key nothing reads.
local hooked
local function HookPins()
	-- Only take the hook while reveal is on, so an off setting leaves the map
	-- completely alone.
	if not C.WorldMap.Reveal or hooked or not WorldMapFrame.EnumeratePinsByTemplate then
		return
	end
	for pin in WorldMapFrame:EnumeratePinsByTemplate("MapExplorationPinTemplate") do
		hooked = true
		hooksecurefunc(pin, "RefreshOverlays", DrawReveal)
		-- The map's own refresh for this showing has already run, so draw once now
		-- instead of waiting for the next one.
		DrawReveal(pin)
	end
end

function Module:SetupReveal()
	if not Module.RawMapData then
		return
	end

	local border = WorldMapFrame.BorderFrame
	local check = CreateFrame("CheckButton", "KKUI_MapRevealCheck", border or WorldMapFrame, "UICheckButtonTemplate")
	check:SetSize(24, 24)
	check:SetHitRectInsets(-4, -4, -4, -4)
	-- The border frame draws its title bar from child frames that sit hundreds of
	-- levels above it (the nine slice and the title container), so a fixed bump
	-- left the box and its label hidden behind the map header. Go one above the
	-- highest child instead.
	local level = border and border:GetFrameLevel() or 1
	if border then
		for _, child in ipairs({ border:GetChildren() }) do
			if child ~= check and child:GetFrameLevel() > level then
				level = child:GetFrameLevel()
			end
		end
	end
	check:SetFrameLevel(level + 1)

	-- Sit to the left of the map's maximize/minimize button, where the title bar
	-- has open room, with a clear gap so the box does not read as one of the
	-- window buttons. The label reads inward, to the left of the box.
	-- Forever names it MaximizeMinimizeFrame. The other key is the Retail one.
	local maxMin = border and (border.MaximizeMinimizeFrame or border.MaximizeMinimizeButton)
	if maxMin then
		check:SetPoint("RIGHT", maxMin, "LEFT", -12, 0)
	else
		check:SetPoint("TOPRIGHT", WorldMapFrame, "TOPRIGHT", -60, -4)
	end
	if K.SkinCheckBox then
		K.SkinCheckBox(check)
	end
	check:SetChecked(C.WorldMap.Reveal)

	local label = check:CreateFontString(nil, "OVERLAY")
	K.SetFont(label, 13, K.FontOutlineStyle())
	label:SetPoint("RIGHT", check, "LEFT", -2, 0)
	label:SetText(L["Map Reveal"])
	local gold = K.Colors.highlight
	label:SetTextColor(gold[1], gold[2], gold[3])

	-- Quick toggle. Flip the saved setting and show or hide what is already drawn,
	-- so it applies instantly without waiting for the next map redraw.
	check:SetScript("OnClick", function(self)
		local on = self:GetChecked() and true or false
		-- Through SetConfig so the choice lands in the saved profile, not only the
		-- live table, which is rebuilt from the profile on every reload.
		K:SetConfig({ "WorldMap", "Reveal" }, on)
		-- Take the hook the first time it goes on, then draw or clear our own
		-- tiles on the pins already there. Blizzard's refresh is not called.
		if on then
			HookPins()
		end
		for pin in pairs(tilesByPin) do
			DrawReveal(pin)
		end
		if on and WorldMapFrame.EnumeratePinsByTemplate then
			for pin in WorldMapFrame:EnumeratePinsByTemplate("MapExplorationPinTemplate") do
				if not tilesByPin[pin] then
					DrawReveal(pin)
				end
			end
		end
	end)

	check:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine(L["Map Reveal"])
		GameTooltip:AddLine(L["Show the parts of the zone you have not explored yet."], K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3], true)
		GameTooltip:Show()
	end)
	check:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	HookPins()
	WorldMapFrame:HookScript("OnShow", HookPins)
end
