--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/WorldMap/Extras.lua
	Purpose:
		Fade while moving: the world map and the zone map (Shift+M) fade to a
		chosen opacity while you move and come back when you stop or point at
		them. The game has its own map fade, but it is fixed at half opacity and
		only covers the world map, so it is switched off while this one is on and
		put back when this one is turned off.

		Zone map: our border, panel and close button on the small zone map, and a
		scale. Its own opacity setting, from right-clicking its tab, still works.

		Only frame setters are used on Blizzard's maps (SetAlpha, SetScale), never
		their methods, so nothing here runs Blizzard's map code under our taint.
		The fade timer lives on a holder parented to each map, so it stops the
		moment that map hides.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("WorldMap")

local _G = _G
local type = type
local ipairs = ipairs
local CreateFrame = CreateFrame
local GetCVar = GetCVar
local SetCVar = SetCVar
local IsPlayerMoving = IsPlayerMoving

local FADE_CVAR = "mapFade"
-- Alpha change per second, so a full fade takes about a third of a second.
local FADE_SPEED = 3
local CHECK_GAP = 0.05

-- ---------------------------------------------------------------------------
-- Fade while moving
-- ---------------------------------------------------------------------------

local function Approach(current, target, step)
	if current < target then
		return current + step >= target and target or current + step
	end
	return current - step <= target and target or current - step
end

local function AttachFade(map)
	local holder = CreateFrame("Frame", nil, map)
	local elapsedTotal = 0
	holder:SetScript("OnUpdate", function(_, elapsed)
		elapsedTotal = elapsedTotal + elapsed
		if elapsedTotal < CHECK_GAP then
			return
		end
		local target = 1
		if IsPlayerMoving() and not map:IsMouseOver() then
			target = C.WorldMap.FadeAlpha or 0.4
		end
		local current = map:GetAlpha()
		if current ~= target then
			map:SetAlpha(Approach(current, target, FADE_SPEED * elapsedTotal))
		end
		elapsedTotal = 0
	end)
	-- A map closed mid fade opens at full opacity next time.
	map:HookScript("OnHide", function(self)
		self:SetAlpha(1)
	end)
end

-- The game's own fade would pull the world map to half opacity at the same
-- time, so it is switched off while ours runs. Its value is kept once, account
-- wide like the setting, and given back when ours is turned off.
local function TakeOverGameFade(useOurs)
	local db = _G.KkthnxUIDB
	if type(db) ~= "table" then
		return
	end
	if useOurs then
		local current = GetCVar(FADE_CVAR)
		if current and current ~= "0" then
			if db.mapFadeRestore == nil then
				db.mapFadeRestore = current
			end
			SetCVar(FADE_CVAR, "0")
		end
	elseif db.mapFadeRestore ~= nil then
		SetCVar(FADE_CVAR, db.mapFadeRestore)
		db.mapFadeRestore = nil
	end
end

-- ---------------------------------------------------------------------------
-- Zone map
-- ---------------------------------------------------------------------------

local function SkinZoneMap()
	local map = _G.BattlefieldMapFrame
	if not map then
		return
	end

	if C.WorldMap.ZoneMapSkin then
		local border = map.BorderFrame
		if border then
			-- The art, not the frame. The frame carries the opacity setting and
			-- the close button, so it stays.
			for _, key in ipairs({ "TopLeft", "TopRight", "BottomLeft", "BottomRight", "Top", "Bottom", "Left", "Right" }) do
				local texture = border[key]
				if texture then
					texture:SetAlpha(0)
				end
			end
			-- Ours sits on the border frame so the map's opacity setting fades it too.
			local panel = CreateFrame("Frame", nil, border)
			panel:SetPoint("TOPLEFT", map.ScrollContainer or map, "TOPLEFT", -1, 1)
			panel:SetPoint("BOTTOMRIGHT", map.ScrollContainer or map, "BOTTOMRIGHT", 1, -1)
			panel:SetFrameLevel(border:GetFrameLevel())
			K.CreateBorder(panel)
			if border.CloseButton then
				K.SkinCloseButton(border.CloseButton)
				border.CloseButton:ClearAllPoints()
				border.CloseButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -2)
			end
		end
	end

	local scale = C.WorldMap.ZoneMapScale or 1
	if scale ~= 1 then
		map:SetScale(scale)
	end

	if C.WorldMap.FadeWhileMoving then
		AttachFade(map)
	end
end

-- ---------------------------------------------------------------------------

-- With the map tweaks off as a whole, only the game's own fade is given back.
function Module:SetupMapExtras(enabled)
	TakeOverGameFade(enabled and C.WorldMap.FadeWhileMoving)
	if not enabled then
		return
	end
	if C.WorldMap.FadeWhileMoving and _G.WorldMapFrame then
		local map = _G.WorldMapFrame
		AttachFade(map)
		-- The world map signs itself up with the game's movement fader on every
		-- show. With mapFade off that fader still pulls the alpha back to full each
		-- frame, so it would fight ours. Taking the map off its list right after
		-- the show stops that, the same call the map makes itself when it hides.
		-- The fader is plain FrameXML and the map is not a protected frame.
		local fader = _G.PlayerMovementFrameFader
		if fader and fader.RemoveFrame then
			map:HookScript("OnShow", function(self)
				fader.RemoveFrame(self)
			end)
		end
	end

	-- The zone map loads the first time it is opened.
	local wantsZoneMap = C.WorldMap.ZoneMapSkin or C.WorldMap.FadeWhileMoving or (C.WorldMap.ZoneMapScale or 1) ~= 1
	if wantsZoneMap and _G.EventUtil and _G.EventUtil.ContinueOnAddOnLoaded then
		_G.EventUtil.ContinueOnAddOnLoaded("Blizzard_BattlefieldMap", SkinZoneMap)
	end
end
