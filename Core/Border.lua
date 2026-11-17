--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/Border.lua
	Purpose:
		The signature KkthnxUI 8 section border. Ported from the original addon
		and wired into the new engine. A border is stored directly on its parent
		frame under a private key so there is no global weak table to manage.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local type = type
local unpack = unpack
local error = error
local IsSecret = K.IsSecret

local BORDER_KEY = "KKUI_Border"

local Border = {}

-- Borders kept off the frame they decorate, for frames Blizzard owns. Writing a key
-- into a Blizzard table marks that key as ours, and Blizzard code that walks or
-- reads the table then runs tainted, so those frames get their border recorded
-- here and are looked up through K.GetBorder.
local offFrame = setmetatable({}, { __mode = "k" })

function K.GetBorder(frame)
	return frame[BORDER_KEY] or offFrame[frame]
end

-- Every border style is a folder holding the same set of files:
--   Border.tga           the eight cell border
--   Highlight.tga        laid out like Border.tga, its band in white with a
--                        soft halo, drawn ADD over the border on hover
--   ButtonHighlight.tga  single squares laid over a square button's icon as
--   ButtonPushed.tga     its own highlight, pushed and checked textures
--   ButtonChecked.tga
--
-- gold is Forever's own window trim (about RGB 130, 96, 52 in game) divided
-- by how bright that style's band reads on average, so the tinted band lands
-- on the trim. A band too dark to reach it gets the same hue at full
-- strength. Blank has no band, so its gold only shows on the hover glow.
local STYLES = {
	KkthnxUI = { gold = { 0.96, 0.709, 0.384, 1 } }, -- band 0.53
	KkthnxUI_Pixel = { gold = { 0.586, 0.433, 0.234, 1 } }, -- band 0.87
	AzeriteUI = { gold = { 1, 0.738, 0.4, 1 } }, -- band 0.45
	KkthnxUI_Blank = { gold = { 0.586, 0.433, 0.234, 1 } },
}

-- The style is read when it is used, not when this file loads, because the
-- profile is only read in on ADDON_LOADED. A style a profile names that we no
-- longer ship falls back to the default instead of drawing nothing.
local function GetStyle()
	local style = C.General and C.General.BorderStyle
	if not STYLES[style] then
		style = "KkthnxUI"
	end
	return style
end

-- Path to one file of the active style's set. A style change asks for a
-- reload, so frames never mix two sets.
function K.GetBorderMedia(name)
	return K.MediaFolder .. "Border\\" .. GetStyle() .. "\\" .. name .. ".tga"
end

-- Every style draws at 12. (Older code meant the others to be 10, but it read
-- the style before the profile loaded, so they always drew at 12, and that is
-- the look they have.)
K.BorderSize = 12
K.BorderRegistry = {}

local FALLBACK = { 1, 1, 1, 1 }

-- The colour every border rests at. Read on each call, never cached, because
-- the options window replaces these tables when a setting changes.
function K.GetBorderColor()
	local general = C.General
	if general and general.ForeverGold then
		return STYLES[GetStyle()].gold
	end
	return (general and general.BorderColor) or FALLBACK
end

-- ---------------------------------------------------------------------------
-- Tiling math
-- ---------------------------------------------------------------------------

local function GetTileCount(border, width)
	local size = border.__size or K.BorderSize
	if size == 0 then
		return 1
	end
	local offset = border.__offset or 0
	return (width + 2 * offset) / size
end

local function UpdateTexCoords(border, tile)
	border.TOP:SetTexCoord(0.25, tile, 0.375, tile, 0.25, 0, 0.375, 0)
	border.BOTTOM:SetTexCoord(0.375, tile, 0.5, tile, 0.375, 0, 0.5, 0)
	border.LEFT:SetTexCoord(0, 0.125, 0, tile)
	border.RIGHT:SetTexCoord(0.125, 0.25, 0, tile)
end

local function OnResize(frame)
	local border = frame and K.GetBorder(frame)
	if not border then
		return
	end
	-- A widget tooltip can become a forbidden object we may not read from tainted
	-- code, and GetWidth on it throws, so bail before touching it.
	if frame.IsForbidden and frame:IsForbidden() then
		return
	end
	local width = frame:GetWidth()
	if IsSecret(width) then
		return
	end
	UpdateTexCoords(border, GetTileCount(border, width))
end

-- The tile count depends on the frame width, so something has to see resizes.
-- That is not done with a script on the framed object. Tooltips, trackers and
-- other Blizzard frames get resized from inside Blizzard code, and the engine
-- dispatches OnSizeChanged for that synchronously, so an insecure handler on the
-- frame runs in the middle of the secure call and leaves the rest of it tainted.
-- (A widget tooltip built on a map point then fails on a secret number.) A child
-- frame stretched over the object is resized by the layout pass instead, outside
-- any Blizzard function, and its handler is ours alone.
local function AttachSizeWatcher(frame)
	local watcher = CreateFrame("Frame", nil, frame)
	watcher:SetAllPoints(frame)
	watcher:EnableMouse(false)
	watcher:SetScript("OnSizeChanged", function()
		OnResize(frame)
	end)
end

-- ---------------------------------------------------------------------------
-- Border methods
-- ---------------------------------------------------------------------------

function Border:SetOffset(offset)
	if type(offset) ~= "number" then
		return
	end
	offset = K.Scale(offset)
	self.__offset = offset

	local p = self.__parent
	self.TOPLEFT:SetPoint("BOTTOMRIGHT", p, "TOPLEFT", -offset, offset)
	self.TOPRIGHT:SetPoint("BOTTOMLEFT", p, "TOPRIGHT", offset, offset)
	self.BOTTOMLEFT:SetPoint("TOPRIGHT", p, "BOTTOMLEFT", -offset, -offset)
	self.BOTTOMRIGHT:SetPoint("TOPLEFT", p, "BOTTOMRIGHT", offset, -offset)

	OnResize(p)
end

function Border:SetTexture(texture)
	if type(texture) == "table" then
		self:SetVertexColor(unpack(texture))
		return
	end
	if type(texture) == "string" then
		self.TOPLEFT:SetTexture(texture)
		self.TOPRIGHT:SetTexture(texture)
		self.BOTTOMLEFT:SetTexture(texture)
		self.BOTTOMRIGHT:SetTexture(texture)
		self.TOP:SetTexture(texture, "REPEAT", "REPEAT")
		self.BOTTOM:SetTexture(texture, "REPEAT", "REPEAT")
		self.LEFT:SetTexture(texture, "REPEAT", "REPEAT")
		self.RIGHT:SetTexture(texture, "REPEAT", "REPEAT")
	end
end

function Border:SetSize(size)
	if type(size) ~= "number" then
		error("Border:SetSize() - size must be a number", 2)
	end
	size = K.Scale(size)
	self.__size = size

	self.TOPLEFT:SetSize(size, size)
	self.TOPRIGHT:SetSize(size, size)
	self.BOTTOMLEFT:SetSize(size, size)
	self.BOTTOMRIGHT:SetSize(size, size)
	self.TOP:SetHeight(size)
	self.BOTTOM:SetHeight(size)
	self.LEFT:SetWidth(size)
	self.RIGHT:SetWidth(size)

	OnResize(self.__parent)
end

function Border:SetVertexColor(r, g, b, a)
	self.TOPLEFT:SetVertexColor(r, g, b, a)
	self.TOPRIGHT:SetVertexColor(r, g, b, a)
	self.BOTTOMLEFT:SetVertexColor(r, g, b, a)
	self.BOTTOMRIGHT:SetVertexColor(r, g, b, a)
	self.TOP:SetVertexColor(r, g, b, a)
	self.BOTTOM:SetVertexColor(r, g, b, a)
	self.LEFT:SetVertexColor(r, g, b, a)
	self.RIGHT:SetVertexColor(r, g, b, a)
end

-- Proxy simple frame methods across all eight segments.
local function AddProxy(method)
	Border[method] = function(self, ...)
		self.TOPLEFT[method](self.TOPLEFT, ...)
		self.TOPRIGHT[method](self.TOPRIGHT, ...)
		self.BOTTOMLEFT[method](self.BOTTOMLEFT, ...)
		self.BOTTOMRIGHT[method](self.BOTTOMRIGHT, ...)
		self.TOP[method](self.TOP, ...)
		self.BOTTOM[method](self.BOTTOM, ...)
		self.LEFT[method](self.LEFT, ...)
		self.RIGHT[method](self.RIGHT, ...)
	end
end

AddProxy("Hide")
AddProxy("Show")
AddProxy("SetShown")
AddProxy("SetAlpha")
AddProxy("SetIgnoreParentAlpha")
AddProxy("SetDrawLayer")
AddProxy("SetBlendMode")

function Border:IsObjectType(t)
	return t == "Border"
end

-- ---------------------------------------------------------------------------
-- Factory
-- ---------------------------------------------------------------------------

function K.CreateBorder(frame, drawLayer, subLevel, keepOffFrame)
	local existing = K.GetBorder(frame)
	if existing then
		return existing
	end

	local border = setmetatable({ __parent = frame }, { __index = Border })
	local layer = type(drawLayer) == "string" and drawLayer or "OVERLAY"
	local sub = type(subLevel) == "number" and subLevel or 1

	local function CreateEdge(c1, c2, c3, c4)
		local tex = frame:CreateTexture(nil, layer, nil, sub)
		tex:SetTexCoord(c1, c2, c3, c4)
		K.DisablePixelSnap(tex)
		return tex
	end

	border.TOPLEFT = CreateEdge(0.5, 0.625, 0, 1)
	border.TOPRIGHT = CreateEdge(0.625, 0.75, 0, 1)
	border.BOTTOMLEFT = CreateEdge(0.75, 0.875, 0, 1)
	border.BOTTOMRIGHT = CreateEdge(0.875, 1, 0, 1)
	border.TOP = CreateEdge(0.25, 0.375, 0, 1)
	border.BOTTOM = CreateEdge(0.375, 0.5, 0, 1)
	border.LEFT = CreateEdge(0, 0.125, 0, 1)
	border.RIGHT = CreateEdge(0.125, 0.25, 0, 1)

	border.TOP:SetPoint("TOPLEFT", border.TOPLEFT, "TOPRIGHT", 0, 0)
	border.TOP:SetPoint("TOPRIGHT", border.TOPRIGHT, "TOPLEFT", 0, 0)
	border.BOTTOM:SetPoint("BOTTOMLEFT", border.BOTTOMLEFT, "BOTTOMRIGHT", 0, 0)
	border.BOTTOM:SetPoint("BOTTOMRIGHT", border.BOTTOMRIGHT, "BOTTOMLEFT", 0, 0)
	border.LEFT:SetPoint("TOPLEFT", border.TOPLEFT, "BOTTOMLEFT", 0, 0)
	border.LEFT:SetPoint("BOTTOMLEFT", border.BOTTOMLEFT, "TOPLEFT", 0, 0)
	border.RIGHT:SetPoint("TOPRIGHT", border.TOPRIGHT, "BOTTOMRIGHT", 0, 0)
	border.RIGHT:SetPoint("BOTTOMRIGHT", border.BOTTOMRIGHT, "TOPRIGHT", 0, 0)

	AttachSizeWatcher(frame)

	if keepOffFrame then
		offFrame[frame] = border
	else
		frame[BORDER_KEY] = border
	end

	border:SetOffset(-4)
	border:SetSize(K.BorderSize)
	border:SetTexture(K.GetBorderMedia("Border"))
	-- Every border starts at the configured colour. Without this a border made
	-- after the login refresh (a tooltip, a bag, a skinned window opened later)
	-- showed the bare texture until the next colour change.
	local color = K.GetBorderColor()
	border:SetVertexColor(color[1], color[2], color[3], color[4] or 1)

	K.BorderRegistry[#K.BorderRegistry + 1] = border
	return border
end

-- A highlight that is the border itself lighting up. Highlight.tga is laid out
-- exactly like Border.tga and holds the same band in white with a soft halo.
-- It is drawn ADD as a second border over the real one, so it follows any
-- frame size and any style. It lives on its own child frame because a frame
-- carries one border, and it keeps its own tint when the border colour is
-- refreshed. Returns the frame to Show and Hide.
function K.CreateHighlightBorder(frame, r, g, b, a)
	local host = CreateFrame("Frame", nil, frame)
	host:SetAllPoints(frame)
	host:SetFrameLevel(frame:GetFrameLevel() + 3)

	local glow = K.CreateBorder(host, "OVERLAY", 7)
	glow:SetTexture(K.GetBorderMedia("Highlight"))
	glow:SetBlendMode("ADD")
	K.SetBorderColor(glow, r or 1, g or 1, b or 1, a or 0.5)

	host.Glow = glow
	host:Hide()
	return host
end

-- The square button states from the border set, put on a button as its own
-- highlight, pushed and checked textures. The game shows and hides those
-- itself, so this is safe on secure action buttons in combat. They sit on
-- the icon (inset by the same amount) and the rail draws over their edge, so
-- each glow comes out from under the border. Checked is tinted gold. At a
-- border size of 12 every style's band ends within about a pixel of the
-- frame edge, so one inset fits them all.
local function StateTexture(texture, file, blend, inset, r, g, b, a)
	texture:SetTexture(file)
	texture:SetTexCoord(0, 1, 0, 1)
	texture:SetDesaturated(false)
	texture:SetBlendMode(blend)
	texture:SetVertexColor(r, g, b, a)
	texture:SetAlpha(1)
	texture:ClearAllPoints()
	texture:SetPoint("TOPLEFT", texture:GetParent(), "TOPLEFT", inset, -inset)
	texture:SetPoint("BOTTOMRIGHT", texture:GetParent(), "BOTTOMRIGHT", -inset, inset)
end

-- A button we built ourselves has no state textures yet. Setting a file makes
-- the game create the texture, which is then styled like any other.
local function GetState(button, kind, file)
	local get, set = button["Get" .. kind .. "Texture"], button["Set" .. kind .. "Texture"]
	if not get then
		return
	end
	local texture = get(button)
	if not texture and set then
		set(button, file)
		texture = get(button)
	end
	return texture
end

function K.StyleButtonStates(button, inset)
	inset = inset or 1
	-- The border itself lights on hover too. The inner glow alone is only a
	-- pixel or two wide on a small button and the border covers most of it.
	K.AddBorderHover(button, 1, 1, 1, 0.5)
	local file = K.GetBorderMedia("ButtonHighlight")
	local highlight = GetState(button, "Highlight", file)
	if highlight then
		StateTexture(highlight, file, "ADD", inset, 1, 1, 1, 0.5)
	end
	-- Pushed and checked go just above the icon (icons sit at ARTWORK or below)
	-- and under the border and text on OVERLAY. Highlight has its own layer.
	file = K.GetBorderMedia("ButtonPushed")
	local pushed = GetState(button, "Pushed", file)
	if pushed then
		StateTexture(pushed, file, "BLEND", inset, 1, 1, 1, 1)
		pushed:SetDrawLayer("ARTWORK", 7)
	end
	file = K.GetBorderMedia("ButtonChecked")
	local checked = GetState(button, "Checked", file)
	if checked then
		StateTexture(checked, file, "ADD", inset, 0.965, 0.769, 0.259, 0.9)
		checked:SetDrawLayer("ARTWORK", 7)
	end
end

-- Light a control's border while the mouse is over it, for controls that are
-- not square icon buttons (checkboxes, dropdowns, swatches, sliders, edit
-- boxes). hoverFrame is what the mouse is over when that is not the bordered
-- frame itself, such as a slider over its track. A disabled control does not
-- light. Built once per frame.
function K.AddBorderHover(frame, r, g, b, a, hoverFrame)
	if frame.KKUI_HoverGlow then
		return frame.KKUI_HoverGlow
	end
	hoverFrame = hoverFrame or frame
	local glow = K.CreateHighlightBorder(frame, r, g, b, a)
	frame.KKUI_HoverGlow = glow
	hoverFrame:HookScript("OnEnter", function(self)
		if self.IsEnabled and not self:IsEnabled() then
			return
		end
		glow:Show()
	end)
	hoverFrame:HookScript("OnLeave", function()
		glow:Hide()
	end)
	if hoverFrame.HasScript and hoverFrame:HasScript("OnDisable") then
		hoverFrame:HookScript("OnDisable", function()
			glow:Hide()
		end)
	end
	return glow
end

-- Textures that are drawn in the border colour without being a border (the
-- dropdown arrow). They follow colour changes like the borders do, and a
-- texture can step out of that for a moment by setting __customColor.
K.BorderTinted = setmetatable({}, { __mode = "k" })

function K.TintWithBorder(texture)
	K.BorderTinted[texture] = true
	local color = K.GetBorderColor()
	texture:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
end

-- A soft outer shadow: a backdrop frame sitting a few pixels
-- outside the target whose only art is a fuzzy edge glow. Used where the hard
-- eight-section border is too heavy, such as nameplates. The colour can be
-- changed later with K.SetShadowColor (target highlight, threat).
local SHADOW_TEXTURE = K.MediaFolder .. "Textures\\GlowShadow.blp"

function K.CreateShadow(frame, size, r, g, b, a)
	if frame.KKUI_Shadow then
		return frame.KKUI_Shadow
	end
	local anchor = frame
	if frame:IsObjectType("Texture") then
		anchor = frame:GetParent()
	end
	local offset = size or 4
	local shadow = CreateFrame("Frame", nil, anchor, "BackdropTemplate")
	shadow:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
	shadow:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
	shadow:SetFrameLevel(math.max(0, anchor:GetFrameLevel() - 1))
	shadow:SetBackdrop({ edgeFile = SHADOW_TEXTURE, edgeSize = offset + 1 })
	shadow:SetBackdropBorderColor(r or 0, g or 0, b or 0, a or 1)
	frame.KKUI_Shadow = shadow
	return shadow
end

-- Recolour an existing shadow (no-op if the frame has none).
function K.SetShadowColor(frame, r, g, b, a)
	local shadow = frame and frame.KKUI_Shadow
	if shadow then
		shadow:SetBackdropBorderColor(r, g, b, a or 1)
	end
end

-- Convenience: give a frame a dark background plus the border in one call.
function K.CreateBackdrop(frame, colorTable)
	if frame.KKUI_Background then
		return frame
	end
	local c = colorTable or { 0.06, 0.06, 0.06, 0.9 }
	K.CreateBackground(frame, c[1], c[2], c[3], c[4])
	K.CreateBorder(frame)
	return frame
end

-- Give a border a colour of its own (quality, threat, hover, dispel school).
-- It is marked so a change of the configured colour leaves it alone, until
-- K.ResetBorderColor hands it back. Any colour that is not the configured one
-- goes through here, or the next refresh paints over it.
function K.SetBorderColor(border, r, g, b, a)
	if not border then
		return
	end
	border.__customColor = true
	border:SetVertexColor(r, g, b, a or 1)
end

-- Put one border back to the configured colour. Used when something that
-- temporarily owned the colour (threat, dispel school) lets go of it.
function K.ResetBorderColor(border)
	if not border then
		return
	end
	border.__customColor = nil
	local color = K.GetBorderColor()
	border:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
end

-- Recolor every registered border, used by the config GUI on color changes.
function K.RefreshBorderColors()
	local color = K.GetBorderColor()
	for _, border in ipairs(K.BorderRegistry) do
		if not border.__customColor then
			border:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
		end
	end
	for texture in pairs(K.BorderTinted) do
		if not texture.__customColor then
			texture:SetVertexColor(color[1], color[2], color[3], color[4] or 1)
		end
	end
end
