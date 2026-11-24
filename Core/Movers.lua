--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/Movers.lua
	Purpose:
		Placement system. Anything the user can drag gets a mover: an invisible
		frame of the same size that the real widget anchors to. Moving the mover
		moves the widget, and only the mover position is saved.

		Dragging is hand rolled rather than StartMoving so we can snap to the
		screen, to other movers and to the grid, with live guides and live
		coordinates. Positions are stored per profile as an offset from a chosen
		anchor point on UIParent, so a frame pinned by the corner it lives near
		stays put across resolution and scale changes. The anchor point is
		editable from the nudge popup.

		Snapping only looks at movers near the one being dragged. Every mover on
		the screen used to offer its edges, which put a snap line every few pixels
		and made a drag jump from line to line. A snap also holds until the cursor
		has clearly left it, so a box does not flicker on a boundary. Every edge
		lands on a whole physical pixel, so a box never shimmers or shifts when it
		is let go.
-----------------------------------------------------------------------------]]

local K, L = KkthnxUI[1], KkthnxUI[3]

local _G = _G
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local floor = math.floor
local abs = math.abs
local max = math.max
local min = math.min
local sort = table.sort
local tremove = table.remove
local format = string.format
local strfind = string.find
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetCursorPosition = GetCursorPosition
local IsShiftKeyDown = IsShiftKeyDown
local IsControlKeyDown = IsControlKeyDown
local UIParent = UIParent

local movers = {}      -- key -> mover frame
local moverOrder = {}  -- creation order, for deterministic reset
local editing = false
local panel

local SNAP = 8          -- distance that catches a snap, in UIParent units
local RELEASE = 12      -- distance that lets a held snap go
local NEAR = 48         -- a mover offers snap lines only within this gap
local GAP = 6           -- spacing snap between neighbours, the unit frame gap
local GRID_STEPS = { 8, 16, 32, 64 }
local UNDO_LIMIT = 50

-- Frame levels while editing. Boxes are stacked by size, the smallest on top, so
-- a small box inside a large one can always be reached. The hovered box goes
-- above all of them.
local BASE_LEVEL = 10
local HOVER_LEVEL = 2000

-- Assigned by the popup section further down, so a drag or a nudge can push live
-- numbers into an open popup instead of leaving it showing stale ones.
local NotifyPopup = function() end
local RefreshPanel = function() end

local P = K.Colors
local THEME = {
	coords = P.highlight, -- coordinate text and titles
	grid = { P.accent[1], P.accent[2], P.accent[3], 0.12 }, -- grid lines
	center = { P.accent[1], P.accent[2], P.accent[3], 0.45 }, -- centre cross
	backdrop = { P.panel[1], P.panel[2], P.panel[3], 0.88 }, -- mover fill
	flash = { P.highlight[1], P.highlight[2], P.highlight[3], 1 }, -- hover / locate flash
	guide = { P.positive[1], P.positive[2], P.positive[3], 1 }, -- snap guides and snapped target
	rest = { 1, 1, 1, 1 }, -- resting border colour
}

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local function Store()
	KkthnxUIDB.movers = KkthnxUIDB.movers or {}
	local profile = K:GetActiveProfileName() or "Default"
	local store = KkthnxUIDB.movers[profile]
	if not store then
		store = {}
		KkthnxUIDB.movers[profile] = store
	end
	return store
end

-- Account wide placement preferences: snapping on or off, the grid and its step.
local function Options()
	local db = KkthnxUIDB.moverOptions
	if not db then
		db = { snap = true, grid = false, gridStep = 32 }
		KkthnxUIDB.moverOptions = db
	end
	return db
end

-- One physical pixel in UIParent units. Read live, since the UI scale can change.
local function PixelSize()
	local mult = K.Pixel and K.Pixel.mult
	if not mult or mult <= 0 then
		return 1
	end
	return mult
end

local function PixelRound(value)
	local px = PixelSize()
	return floor(value / px + 0.5) * px
end

-- Offsets are kept exact. Rounding them to whole numbers put the centre of an
-- odd sized box on a half pixel, which is why a box shifted when it was let go.
-- Only float noise is trimmed.
local function Trim(value)
	return floor(value * 10000 + 0.5) / 10000
end

-- Whole numbers read as whole numbers, a half pixel keeps its one decimal.
local function FormatOffset(value)
	if abs(value - floor(value + 0.5)) < 0.05 then
		return format("%d", floor(value + 0.5))
	end
	return format("%.1f", value)
end

-- The anchor points a mover can be pinned by, in the order the popup cycles them.
local ANCHOR_POINTS = { "CENTER", "TOP", "BOTTOM", "LEFT", "RIGHT", "TOPLEFT", "TOPRIGHT", "BOTTOMLEFT", "BOTTOMRIGHT" }
K.MoverAnchorPoints = ANCHOR_POINTS

-- Screen coordinates of one named point on a frame.
local function PointCoords(frame, point)
	local left, bottom = frame:GetLeft(), frame:GetBottom()
	local width, height = frame:GetWidth(), frame:GetHeight()
	if not (left and bottom and width and height) then
		return
	end
	local x, y = left + width / 2, bottom + height / 2
	if strfind(point, "LEFT") then
		x = left
	elseif strfind(point, "RIGHT") then
		x = left + width
	end
	if strfind(point, "TOP") then
		y = bottom + height
	elseif strfind(point, "BOTTOM") then
		y = bottom
	end
	return x, y
end

-- Where a mover sits right now, measured from one of UIParent's points. Anchoring
-- a frame by the corner it lives near keeps it put when the resolution or the UI
-- scale changes, which a centre-relative offset does not.
local function OffsetFor(mover, point)
	local mx, my = PointCoords(mover, point)
	local ux, uy = PointCoords(UIParent, point)
	if not (mx and ux) then
		return 0, 0
	end
	return Trim(mx - ux), Trim(my - uy)
end

-- Read a saved position. Older profiles stored a bare { x, y } pair, which always
-- meant a centre anchor, so those are read back as CENTER.
local function SavedFor(mover)
	local saved = Store()[mover.moverKey]
	if not saved then
		return
	end
	if saved[1] then
		return "CENTER", saved[1], saved[2]
	end
	return saved.point or "CENTER", saved.x or 0, saved.y or 0
end

-- The screen point a mover sits closest to, by which third of the screen its
-- centre is in.
local function NearestPoint(mover)
	local cx, cy = mover:GetCenter()
	local width, height = UIParent:GetWidth(), UIParent:GetHeight()
	if not (cx and width and height) then
		return "CENTER"
	end
	local vertical = (cy > height * 2 / 3 and "TOP") or (cy < height / 3 and "BOTTOM") or ""
	local horizontal = (cx < width / 3 and "LEFT") or (cx > width * 2 / 3 and "RIGHT") or ""
	local point = vertical .. horizontal
	return point ~= "" and point or "CENTER"
end

-- The point a mover is currently pinned by: its saved one, else the one its
-- default position declared. A default that hangs off another frame (focus sits
-- relative to the player frame) names a point on that frame, not on the screen,
-- and reading it as a screen point gave offsets like -1710 from the far corner.
-- Those are pinned by the screen point they sit nearest instead.
local function CurrentPoint(mover)
	local point = SavedFor(mover)
	if point then
		return point
	end
	local default = mover.moverDefault
	if default and default[2] and default[2] ~= UIParent then
		return NearestPoint(mover)
	end
	return (default and default[1]) or "CENTER"
end
K.GetMoverPoint = CurrentPoint

-- A frame can ask to hear when its mover has been put somewhere new, by setting
-- mover.OnMoved. It is called a frame later, once the frame has followed the
-- mover and its own position can be read.
local function NotifyMoved(mover)
	local callback = mover.OnMoved
	if callback then
		C_Timer.After(0, function()
			callback(mover)
		end)
	end
end

-- Current position as an offset from the point this mover is pinned by.
local function CurrentOffset(mover)
	return OffsetFor(mover, CurrentPoint(mover))
end

-- One shared name tag for whichever mover is under the mouse or being dragged:
-- its full name and its live offset. A box too small for its own label still gets
-- named this way, and the numbers are read fresh on every change so they cannot
-- disagree with the nudge popup.
local tag, tagOwner
local function ShowTag(mover)
	if not tag then
		tag = CreateFrame("Frame", nil, UIParent)
		tag:SetFrameStrata("TOOLTIP")
		tag:SetHeight(18)
		K.CreateBackdrop(tag, { 0.05, 0.04, 0.03, 0.95 })
		tag.Text = tag:CreateFontString(nil, "OVERLAY")
		K.SetFont(tag.Text, 11, K.FontOutlineStyle())
		tag.Text:SetPoint("CENTER")
		tag.Text:SetWordWrap(false)
	end
	local x, y = CurrentOffset(mover)
	local c = THEME.coords
	tag.Text:SetFormattedText("%s  %s%s  %s, %s|r", mover.moverLabel, K.RGBToHex(c), CurrentPoint(mover), FormatOffset(x), FormatOffset(y))
	tag:SetWidth(tag.Text:GetStringWidth() + 14)
	-- Above the box, or below it when the box is against the top of the screen.
	-- Only re-anchored when that choice or the owner changes.
	local top = mover:GetTop()
	local below = top and top > UIParent:GetHeight() - 26 or false
	if tagOwner ~= mover or tag.__below ~= below then
		tag:ClearAllPoints()
		if below then
			tag:SetPoint("TOP", mover, "BOTTOM", 0, -4)
		else
			tag:SetPoint("BOTTOM", mover, "TOP", 0, 4)
		end
		tag.__below = below
	end
	tagOwner = mover
	tag:Show()
end

local function HideTag(mover)
	if tag and (not mover or tagOwner == mover) then
		tagOwner = nil
		tag:Hide()
	end
end

-- Refresh the tag only if it is this mover's.
local function UpdateTag(mover)
	if tag and tagOwner == mover and tag:IsShown() then
		ShowTag(mover)
	end
end

-- Put a mover at an offset, then pull its bottom left corner onto a whole
-- physical pixel. A typed number, a centre anchor on an odd sized box, or a UI
-- scale that is not pixel perfect would otherwise leave the edges between pixels.
local function Place(mover, point, offsetX, offsetY)
	mover:ClearAllPoints()
	mover:SetPoint(point, UIParent, point, offsetX, offsetY)
	local left, bottom = mover:GetLeft(), mover:GetBottom()
	if left and bottom then
		local dx, dy = PixelRound(left) - left, PixelRound(bottom) - bottom
		if abs(dx) > 0.001 or abs(dy) > 0.001 then
			offsetX, offsetY = Trim(offsetX + dx), Trim(offsetY + dy)
			mover:ClearAllPoints()
			mover:SetPoint(point, UIParent, point, offsetX, offsetY)
		end
	end
	return offsetX, offsetY
end

-- ---------------------------------------------------------------------------
-- Undo
-- ---------------------------------------------------------------------------

-- Each change remembers the saved position it replaced, so Undo can put it back.
-- false stands for "had no saved position", which restores the default.
local undo = {}
local sessionStart -- every saved position as move mode opened, for Revert

local function CopyEntry(entry)
	if not entry then
		return false
	end
	local copy = {}
	for k, v in pairs(entry) do
		copy[k] = v
	end
	return copy
end

local function Remember(mover)
	undo[#undo + 1] = { key = mover.moverKey, entry = CopyEntry(Store()[mover.moverKey]) }
	if #undo > UNDO_LIMIT then
		tremove(undo, 1)
	end
	RefreshPanel()
end

local function ApplyOffset(mover, offsetX, offsetY, point)
	point = point or CurrentPoint(mover)
	offsetX, offsetY = Place(mover, point, offsetX, offsetY)
	Store()[mover.moverKey] = { point = point, x = offsetX, y = offsetY }
	UpdateTag(mover)
	NotifyMoved(mover)
end

local function RestorePosition(mover)
	local point, x, y = SavedFor(mover)
	if point then
		Place(mover, point, x, y)
	else
		local default = mover.moverDefault
		mover:ClearAllPoints()
		mover:SetPoint(default[1], default[2] or UIParent, default[3] or default[1], default[4] or 0, default[5] or 0)
	end
	UpdateTag(mover)
	NotifyMoved(mover)
end

-- Re-pin a mover by a different point without letting it move on screen: the new
-- offsets are measured from where it already sits.
local function SetAnchorPoint(mover, point)
	Remember(mover)
	local x, y = OffsetFor(mover, point)
	ApplyOffset(mover, x, y, point)
end

local function Undo()
	if InCombatLockdown() then
		return
	end
	local last = tremove(undo)
	if not last then
		return
	end
	local mover = movers[last.key]
	Store()[last.key] = last.entry or nil
	if mover then
		RestorePosition(mover)
		NotifyPopup(mover)
	end
	RefreshPanel()
end

-- Put every mover back where it was when move mode opened.
local function Revert()
	if InCombatLockdown() or not sessionStart then
		return
	end
	local store = Store()
	for key in pairs(store) do
		store[key] = nil
	end
	for key, entry in pairs(sessionStart) do
		store[key] = CopyEntry(entry)
	end
	for _, mover in ipairs(moverOrder) do
		RestorePosition(mover)
	end
	undo = {}
	RefreshPanel()
end

-- ---------------------------------------------------------------------------
-- Guides and grid
-- ---------------------------------------------------------------------------

local guideV, guideH
local function Guides()
	if not guideV then
		-- A dedicated top strata frame so the guide lines float above everything.
		local holder = CreateFrame("Frame", nil, UIParent)
		holder:SetAllPoints(UIParent)
		holder:SetFrameStrata("TOOLTIP")

		local g = THEME.guide
		guideV = holder:CreateTexture(nil, "OVERLAY")
		guideV:SetColorTexture(g[1], g[2], g[3], 0.9)
		guideV:SetPoint("TOP", UIParent, "TOP")
		guideV:SetPoint("BOTTOM", UIParent, "BOTTOM")
		guideV:Hide()
		guideH = holder:CreateTexture(nil, "OVERLAY")
		guideH:SetColorTexture(g[1], g[2], g[3], 0.9)
		guideH:SetPoint("LEFT", UIParent, "LEFT")
		guideH:SetPoint("RIGHT", UIParent, "RIGHT")
		guideH:Hide()
	end
	return guideV, guideH
end

local function ShowGuide(texture, vertical, pos)
	local px = PixelSize()
	texture:ClearAllPoints()
	if vertical then
		texture:SetPoint("TOP", UIParent, "TOPLEFT", pos, 0)
		texture:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", pos, 0)
		texture:SetWidth(px)
	else
		texture:SetPoint("LEFT", UIParent, "BOTTOMLEFT", 0, pos)
		texture:SetPoint("RIGHT", UIParent, "BOTTOMRIGHT", 0, pos)
		texture:SetHeight(px)
	end
	texture:Show()
end

-- The grid is drawn out from the screen centre, so its lines meet the centre
-- cross and the centre is always a grid line. Rebuilt when the step or the
-- screen size changes, from a pool of line textures.
local grid
local gridLines = {}
local gridBuiltFor

local function GridStep()
	return Options().gridStep or 32
end

local function BuildGrid()
	if not grid then
		grid = CreateFrame("Frame", "KKUI_MoverGrid", UIParent)
		grid:SetAllPoints(UIParent)
		grid:SetFrameStrata("BACKGROUND")
		grid:Hide()
	end

	local w, h = UIParent:GetWidth(), UIParent:GetHeight()
	local step = GridStep()
	local signature = format("%d:%.1f:%.1f", step, w, h)
	if gridBuiltFor == signature then
		return grid
	end
	gridBuiltFor = signature

	local px = PixelSize()
	local used = 0
	local function Line(vertical, pos, color)
		used = used + 1
		local tex = gridLines[used]
		if not tex then
			tex = grid:CreateTexture(nil, "BACKGROUND")
			gridLines[used] = tex
		end
		tex:SetColorTexture(color[1], color[2], color[3], color[4])
		tex:ClearAllPoints()
		pos = PixelRound(pos)
		if vertical then
			tex:SetPoint("TOP", UIParent, "TOPLEFT", pos, 0)
			tex:SetPoint("BOTTOM", UIParent, "BOTTOMLEFT", pos, 0)
			tex:SetWidth(px)
		else
			tex:SetPoint("LEFT", UIParent, "BOTTOMLEFT", 0, pos)
			tex:SetPoint("RIGHT", UIParent, "BOTTOMRIGHT", 0, pos)
			tex:SetHeight(px)
		end
		tex:Show()
	end

	local cx, cy = w / 2, h / 2
	for offset = step, cx, step do
		Line(true, cx - offset, THEME.grid)
		Line(true, cx + offset, THEME.grid)
	end
	for offset = step, cy, step do
		Line(false, cy - offset, THEME.grid)
		Line(false, cy + offset, THEME.grid)
	end
	Line(true, cx, THEME.center)
	Line(false, cy, THEME.center)
	for i = used + 1, #gridLines do
		gridLines[i]:Hide()
	end
	return grid
end

local function GridShown()
	return Options().grid and true or false
end

function K.ToggleMoverGrid(show)
	if show == nil then
		show = not GridShown()
	end
	Options().grid = show
	BuildGrid():SetShown(show and editing)
	RefreshPanel()
end

local function SetGridStep(step)
	Options().gridStep = step
	if grid and grid:IsShown() then
		BuildGrid()
	end
	RefreshPanel()
end

-- ---------------------------------------------------------------------------
-- Snapping
-- ---------------------------------------------------------------------------
-- Snap lines are gathered once when a drag starts, into reused arrays, since the
-- other movers cannot move during it. Each line carries the span of the mover
-- that offered it on the other axis, so it only counts while the dragged box is
-- near that mover. Kinds: 0 lines up any edge or the centre, 1 is a spacing line
-- for the dragged box's low edge (left or bottom), 2 for its high edge.

local lineX = { pos = {}, lo = {}, hi = {}, kind = {}, owner = {}, n = 0 }
local lineY = { pos = {}, lo = {}, hi = {}, kind = {}, owner = {}, n = 0 }

local function AddLine(set, pos, lo, hi, kind, owner)
	local n = set.n + 1
	set.n = n
	set.pos[n], set.lo[n], set.hi[n], set.kind[n], set.owner[n] = pos, lo, hi, kind, owner
end

local INF = 1e9

local function GatherLines(self)
	lineX.n, lineY.n = 0, 0
	local w, h = UIParent:GetWidth(), UIParent:GetHeight()
	-- The screen edges and centre, always in reach.
	AddLine(lineX, 0, -INF, INF, 0, false)
	AddLine(lineX, w / 2, -INF, INF, 0, false)
	AddLine(lineX, w, -INF, INF, 0, false)
	AddLine(lineY, 0, -INF, INF, 0, false)
	AddLine(lineY, h / 2, -INF, INF, 0, false)
	AddLine(lineY, h, -INF, INF, 0, false)

	for _, mover in ipairs(moverOrder) do
		if mover ~= self and mover:IsShown() then
			local left, right = mover:GetLeft(), mover:GetRight()
			local bottom, top = mover:GetBottom(), mover:GetTop()
			if left and bottom then
				AddLine(lineX, left, bottom, top, 0, mover)
				AddLine(lineX, (left + right) / 2, bottom, top, 0, mover)
				AddLine(lineX, right, bottom, top, 0, mover)
				AddLine(lineX, right + GAP, bottom, top, 1, mover)
				AddLine(lineX, left - GAP, bottom, top, 2, mover)
				AddLine(lineY, bottom, left, right, 0, mover)
				AddLine(lineY, (bottom + top) / 2, left, right, 0, mover)
				AddLine(lineY, top, left, right, 0, mover)
				AddLine(lineY, top + GAP, left, right, 1, mover)
				AddLine(lineY, bottom - GAP, left, right, 2, mover)
			end
		end
	end
end

-- How far the dragged box's span (a, b) sits from a line owner's span (lo, hi).
local function SpanGap(a, b, lo, hi)
	return max(0, lo - b, a - hi)
end

-- The distance from the edge a line wants to that line, or nil if the line does
-- not apply to this box. edgeLow is the box's low edge, size its width or height.
local function LineDelta(set, i, edgeLow, size, crossA, crossB)
	if SpanGap(crossA, crossB, set.lo[i], set.hi[i]) > NEAR then
		return
	end
	local pos, kind = set.pos[i], set.kind[i]
	if kind == 1 then
		return pos - edgeLow
	elseif kind == 2 then
		return pos - (edgeLow + size)
	end
	-- Whichever of the three edges is closest to an alignment line.
	local d1, d2, d3 = pos - edgeLow, pos - (edgeLow + size / 2), pos - (edgeLow + size)
	local best = d1
	if abs(d2) < abs(best) then
		best = d2
	end
	if abs(d3) < abs(best) then
		best = d3
	end
	return best
end

-- Snap one axis. Returns the adjusted low edge, the line position for the guide
-- and the mover that offered it. state holds the snap from the last frame, which
-- is kept until the cursor is RELEASE away from it, so a box sitting between two
-- lines does not hop between them.
local function SnapAxis(set, state, edgeLow, size, crossA, crossB, gridCenter)
	local held = state.index
	if held and held <= set.n then
		local d = LineDelta(set, held, edgeLow, size, crossA, crossB)
		if d and abs(d) <= RELEASE then
			return edgeLow + d, set.pos[held], set.owner[held]
		end
	end
	state.index = nil

	local bestIndex, bestDelta
	for i = 1, set.n do
		local d = LineDelta(set, i, edgeLow, size, crossA, crossB)
		if d and abs(d) <= SNAP and (not bestDelta or abs(d) < abs(bestDelta)) then
			bestIndex, bestDelta = i, d
		end
	end
	if bestIndex then
		state.index = bestIndex
		return edgeLow + bestDelta, set.pos[bestIndex], set.owner[bestIndex]
	end

	-- No screen or mover line in reach: fall back to the grid while it is shown.
	-- Whichever edge is nearer a grid line goes to it. Lines count out from the
	-- centre, the way the grid is drawn.
	if gridCenter then
		local step = GridStep()
		local lowLine = gridCenter + floor((edgeLow - gridCenter) / step + 0.5) * step
		local highEdge = edgeLow + size
		local highLine = gridCenter + floor((highEdge - gridCenter) / step + 0.5) * step
		local dLow, dHigh = lowLine - edgeLow, highLine - highEdge
		if abs(dLow) <= abs(dHigh) and abs(dLow) <= SNAP then
			return lowLine, lowLine, false
		elseif abs(dHigh) <= SNAP then
			return edgeLow + dHigh, highLine, false
		end
	end
	return edgeLow
end

-- ---------------------------------------------------------------------------
-- Dragging
-- ---------------------------------------------------------------------------

local snapX, snapY = {}, {}
local litX, litY -- movers whose border is lit as the current snap target

local function Rest(mover)
	if mover and mover.KKUI_Border then
		K.SetBorderColor(mover.KKUI_Border, THEME.rest[1], THEME.rest[2], THEME.rest[3], THEME.rest[4])
	end
end

-- Light the boxes the drag is snapped to and put back any that no longer are.
-- Both axes are handled together, so a box that is the target for one axis is
-- never switched off by the other.
local function SetLit(newX, newY)
	if litX and litX ~= newX and litX ~= newY then
		Rest(litX)
	end
	if litY and litY ~= newX and litY ~= newY then
		Rest(litY)
	end
	local g = THEME.guide
	if newX and newX ~= litX and newX ~= litY and newX.KKUI_Border then
		K.SetBorderColor(newX.KKUI_Border, g[1], g[2], g[3], 1)
	end
	if newY and newY ~= newX and newY ~= litX and newY ~= litY and newY.KKUI_Border then
		K.SetBorderColor(newY.KKUI_Border, g[1], g[2], g[3], 1)
	end
	litX, litY = newX, newY
end

local function ClearSnapDisplay()
	local vg, hg = Guides()
	vg:Hide()
	hg:Hide()
	SetLit(nil, nil)
end

local function OnMoveUpdate(self)
	local mx, my = GetCursorPosition()
	local free = IsShiftKeyDown() or not Options().snap
	-- Nothing to do while the cursor and the Shift key stay as they were.
	if mx == self.__lastX and my == self.__lastY and free == self.__lastFree then
		return
	end
	self.__lastX, self.__lastY, self.__lastFree = mx, my, free

	-- GetCursorPosition is unscaled. Dividing by this frame's effective scale puts
	-- it in UIParent units, the same space as GetLeft and SetPoint offsets.
	local scale = self:GetEffectiveScale()
	local w, h = self:GetWidth(), self:GetHeight()
	local left = mx / scale - self.__grabX
	local bottom = my / scale - self.__grabY

	local guideX, guideY, ownerX, ownerY
	if free then
		snapX.index, snapY.index = nil, nil
	else
		local gw, gh
		if GridShown() then
			gw, gh = UIParent:GetWidth() / 2, UIParent:GetHeight() / 2
		end
		-- Each axis checks the other axis's span from the raw position, so the
		-- two snaps cannot feed each other.
		local rawLeft, rawBottom = left, bottom
		left, guideX, ownerX = SnapAxis(lineX, snapX, rawLeft, w, rawBottom, rawBottom + h, gw)
		bottom, guideY, ownerY = SnapAxis(lineY, snapY, rawBottom, h, rawLeft, rawLeft + w, gh)
	end

	-- Keep the whole box on screen, then onto whole pixels.
	local sw, sh = UIParent:GetWidth(), UIParent:GetHeight()
	left = PixelRound(min(max(left, 0), sw - w))
	bottom = PixelRound(min(max(bottom, 0), sh - h))

	if left ~= self.__placedLeft or bottom ~= self.__placedBottom then
		self.__placedLeft, self.__placedBottom = left, bottom
		self:ClearAllPoints()
		self:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
		ShowTag(self)
		NotifyPopup(self)
	end

	local vg, hg = Guides()
	if guideX then
		ShowGuide(vg, true, PixelRound(guideX))
	else
		vg:Hide()
	end
	if guideY then
		ShowGuide(hg, false, PixelRound(guideY))
	else
		hg:Hide()
	end
	SetLit(ownerX or nil, ownerY or nil)
end

local function OnDragStart(self)
	if InCombatLockdown() or not editing then
		return
	end
	local scale = self:GetEffectiveScale()
	local mx, my = GetCursorPosition()
	self.__grabX = mx / scale - self:GetLeft()
	self.__grabY = my / scale - self:GetBottom()
	self.__lastX, self.__lastY, self.__placedLeft, self.__placedBottom = nil, nil, nil, nil
	snapX.index, snapY.index = nil, nil
	GatherLines(self)
	Remember(self)
	self.__dragging = true
	self.__wasDragged = true
	self:SetScript("OnUpdate", OnMoveUpdate)
end

-- Ends a drag and saves where it landed. Also called when move mode closes in
-- the middle of a drag, so a box is never left somewhere it was not saved.
local function FinishDrag(self)
	if not self.__dragging then
		return
	end
	self:SetScript("OnUpdate", nil)
	self.__dragging = nil
	-- Read the point before saving, so a first move keeps the point it was shown with.
	local point = CurrentPoint(self)
	local ox, oy = OffsetFor(self, point)
	ApplyOffset(self, ox, oy, point)
	ClearSnapDisplay()
	if self:IsMouseOver() and editing then
		ShowTag(self)
	else
		HideTag(self)
	end
	NotifyPopup(self)
end

-- Arrow keys nudge the hovered mover by one pixel, ten with Shift. Ctrl+Z undoes.
local nudge = {
	UP = { 0, 1 },
	DOWN = { 0, -1 },
	LEFT = { -1, 0 },
	RIGHT = { 1, 0 },
}

local function NudgeMover(mover, dx, dy)
	if InCombatLockdown() then
		return
	end
	local px = PixelSize()
	local point = CurrentPoint(mover)
	local ox, oy = OffsetFor(mover, point)
	Remember(mover)
	ApplyOffset(mover, ox + dx * px, oy + dy * px, point)
	NotifyPopup(mover)
end

local function OnKeyDown(self, key)
	if key == "Z" and IsControlKeyDown() then
		self:SetPropagateKeyboardInput(false)
		Undo()
		return
	end
	local step = nudge[key]
	if not step then
		self:SetPropagateKeyboardInput(true)
		return
	end
	self:SetPropagateKeyboardInput(false)
	local amount = IsShiftKeyDown() and 10 or 1
	NudgeMover(self, step[1] * amount, step[2] * amount)
end

-- ---------------------------------------------------------------------------
-- Factory
-- ---------------------------------------------------------------------------

function K.CreateMover(frame, key, label, defaultPoint, width, height, attachPoint)
	if movers[key] then
		return movers[key]
	end

	local mover = CreateFrame("Frame", "KKUI_Mover_" .. key, UIParent)
	mover:SetSize(width or frame:GetWidth(), height or frame:GetHeight())
	mover:SetFrameStrata("HIGH")
	mover:SetClampedToScreen(true)
	mover:EnableMouse(false)
	mover:RegisterForDrag("LeftButton")
	mover:SetScript("OnDragStart", OnDragStart)
	mover:SetScript("OnDragStop", FinishDrag)
	mover:Hide()

	mover.moverKey = key
	mover.moverDefault = defaultPoint
	mover.moverLabel = label or key

	K.CreateBackdrop(mover, THEME.backdrop)

	-- Pinned to both edges so a name can never run past its own box and over a
	-- neighbour. A name that does not fit is cut with an ellipsis, and the tag
	-- shown on hover carries it in full.
	local text = mover:CreateFontString(nil, "OVERLAY")
	K.SetFont(text, 11, K.FontOutlineStyle())
	text:SetPoint("LEFT", mover, "LEFT", 3, 0)
	text:SetPoint("RIGHT", mover, "RIGHT", -3, 0)
	text:SetJustifyH("CENTER")
	text:SetText(mover.moverLabel)
	text:SetWordWrap(false)
	mover.Label = text

	-- A click opens the nudge popup for exact numbers. The mouse up that ends a
	-- drag is not a click, so letting go of a box no longer pops the window open.
	mover:SetScript("OnMouseUp", function(self, button)
		if not editing then
			return
		end
		if self.__wasDragged then
			self.__wasDragged = nil
			return
		end
		if button == "LeftButton" then
			K.OpenMoverPopup(self)
		end
	end)

	mover:SetScript("OnEnter", function(self)
		if not editing then
			return
		end
		self:EnableKeyboard(true)
		self:SetScript("OnKeyDown", OnKeyDown)
		K.SetBorderColor(self.KKUI_Border, THEME.flash[1], THEME.flash[2], THEME.flash[3], THEME.flash[4])
		-- Lift the box under the mouse over whatever it overlaps, so its label and
		-- border are whole while you work on it.
		self:SetFrameLevel(HOVER_LEVEL)
		ShowTag(self)
	end)
	mover:SetScript("OnLeave", function(self)
		self:EnableKeyboard(false)
		self:SetScript("OnKeyDown", nil)
		if self ~= litX and self ~= litY then
			K.SetBorderColor(self.KKUI_Border, THEME.rest[1], THEME.rest[2], THEME.rest[3], THEME.rest[4])
		end
		self:SetFrameLevel(self.__restLevel or 1)
		if not self.__dragging then
			HideTag(self)
		end
	end)

	RestorePosition(mover)

	frame:ClearAllPoints()
	frame:SetPoint(attachPoint or "TOPLEFT", mover, attachPoint or "TOPLEFT", 0, 0)

	movers[key] = mover
	moverOrder[#moverOrder + 1] = mover
	frame.KKUI_Mover = mover

	return mover
end

-- Let a frame be dragged directly with the left mouse button, the way a bag or
-- loot window moves. The drag moves the frame, then on release its mover is
-- slid underneath and the position saved through the normal mover storage, so it
-- survives a reload and still resets from the Move UI panel.
function K.EnableFrameDrag(frame)
	local mover = frame.KKUI_Mover
	if not mover then
		return
	end
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetClampedToScreen(true)
	frame:SetScript("OnDragStart", function(self)
		if InCombatLockdown() or editing then
			return
		end
		self:StartMoving()
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local left, top = self:GetLeft(), self:GetTop()
		if not left then
			return
		end
		-- Match the mover to the frame's new corner, then persist by its own point
		-- and re-anchor the frame to the mover as usual.
		mover:ClearAllPoints()
		mover:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
		local point = CurrentPoint(mover)
		local ox, oy = OffsetFor(mover, point)
		ApplyOffset(mover, ox, oy, point)
		self:ClearAllPoints()
		self:SetPoint("TOPLEFT", mover, "TOPLEFT", 0, 0)
	end)
end

-- Ordered list of { key, label } for the config GUI mover list.
function K.GetMoverList()
	local list = {}
	for _, mover in ipairs(moverOrder) do
		list[#list + 1] = { key = mover.moverKey, label = mover.moverLabel }
	end
	return list
end

-- Reset a single mover to its default.
function K.ResetMover(key)
	local mover = movers[key]
	if not mover then
		return
	end
	-- Action bars and other secure frames hang off their movers, so moving one in
	-- combat is a blocked action.
	if InCombatLockdown() then
		K.Print(L["Cannot move frames during combat."])
		return
	end
	Remember(mover)
	Store()[key] = nil
	RestorePosition(mover)
	NotifyPopup(mover)
end

function K.FlashMover(key)
	local mover = movers[key]
	if not mover or not editing then
		return
	end
	K.SetBorderColor(mover.KKUI_Border, THEME.flash[1], THEME.flash[2], THEME.flash[3], THEME.flash[4])
	C_Timer.After(0.6, function()
		if mover.KKUI_Border then
			K.SetBorderColor(mover.KKUI_Border, THEME.rest[1], THEME.rest[2], THEME.rest[3], THEME.rest[4])
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Per-mover popup: name, X/Y inputs, and directional nudge pad
-- ---------------------------------------------------------------------------

local popup, popupTarget

local function RefreshPopup()
	if not popup or not popupTarget then
		return
	end
	local ox, oy = CurrentOffset(popupTarget)
	popup.Title:SetText(popupTarget.moverLabel)
	-- Leave a field alone while it is being typed in.
	if not popup.X:HasFocus() then
		popup.X:SetText(FormatOffset(ox))
		popup.X:SetCursorPosition(0)
	end
	if not popup.Y:HasFocus() then
		popup.Y:SetText(FormatOffset(oy))
		popup.Y:SetCursorPosition(0)
	end

	-- Spell out what the offsets are actually measured from, since the same pair of
	-- numbers means somewhere quite different depending on the point.
	local point = CurrentPoint(popupTarget)
	popup.Anchor:SetText(point)
	popup.AnchorNote:SetFormattedText(L["Measured from screen %s"], point)
end

-- Let a drag or an arrow-key nudge feed the open popup, so the coordinates and the
-- anchor line track the frame in real time rather than only on the next open.
NotifyPopup = function(mover)
	if popup and popup:IsShown() and popupTarget == mover then
		RefreshPopup()
	end
end

local function ApplyInputs()
	if not popupTarget or InCombatLockdown() then
		return
	end
	local x = tonumber(popup.X:GetText())
	local y = tonumber(popup.Y:GetText())
	if x and y then
		Remember(popupTarget)
		ApplyOffset(popupTarget, x, y)
	end
	RefreshPopup()
end

local function BuildPopup()
	if popup then
		return popup
	end

	popup = CreateFrame("Frame", "KKUI_MoverPopup", UIParent)
	popup:SetSize(232, 250)
	popup:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 260)
	popup:SetFrameStrata("DIALOG")
	popup:SetMovable(true)
	popup:SetClampedToScreen(true)
	popup:EnableMouse(true)
	popup:RegisterForDrag("LeftButton")
	popup:SetScript("OnDragStart", popup.StartMoving)
	popup:SetScript("OnDragStop", popup.StopMovingOrSizing)
	K.CreateGradientBackground(popup)
	K.CreateBorder(popup)

	local title = popup:CreateFontString(nil, "OVERLAY")
	K.SetFont(title, 12, K.FontOutlineStyle())
	title:SetPoint("TOP", 0, -8)
	title:SetTextColor(THEME.coords[1], THEME.coords[2], THEME.coords[3])
	popup.Title = title

	local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	K.SkinCloseButton(close)

	-- A subtle secondary box that groups the nudge pad and the X/Y inputs so they
	-- read as one linked control cluster.
	local group = CreateFrame("Frame", nil, popup)
	group:SetPoint("TOPLEFT", popup, "TOPLEFT", 12, -30)
	group:SetSize(208, 100)
	K.CreateBackground(group, 0.1, 0.08, 0.05, 0.55)
	K.CreateBorder(group)

	-- Directional nudge pad on the left. Shift steps ten pixels, the same as the
	-- arrow keys. Each button carries a real arrow texture rather than a typed
	-- character, so it renders crisply regardless of the active font.
	local ARROW = {
		up = { 0.45312500, 0.64062500, 0.01562500, 0.20312500 },
		down = { 0.45312500, 0.64062500, 0.20312500, 0.01562500 },
		left = { 0.23437500, 0.42187500, 0.01562500, 0.20312500 },
		right = { 0.42187500, 0.23437500, 0.01562500, 0.20312500 },
	}
	local function MakeArrow(dir, x, y, dx, dy)
		local b = CreateFrame("Button", nil, group, "UIPanelButtonTemplate")
		b:SetSize(28, 26)
		b:SetPoint("TOPLEFT", group, "TOPLEFT", x, y)
		K.SkinButton(b)

		local arrow = b:CreateTexture(nil, "OVERLAY")
		arrow:SetTexture("Interface\\BUTTONS\\SquareButtonTextures")
		arrow:SetTexCoord(ARROW[dir][1], ARROW[dir][2], ARROW[dir][3], ARROW[dir][4])
		arrow:SetVertexColor(THEME.coords[1], THEME.coords[2], THEME.coords[3])
		arrow:SetSize(12, 12)
		arrow:SetPoint("CENTER")

		b:SetScript("OnClick", function()
			if popupTarget then
				local amount = IsShiftKeyDown() and 10 or 1
				NudgeMover(popupTarget, dx * amount, dy * amount)
			end
		end)
		return b
	end

	MakeArrow("up", 40, -8, 0, 1)
	MakeArrow("left", 10, -37, -1, 0)
	MakeArrow("right", 70, -37, 1, 0)
	MakeArrow("down", 40, -66, 0, -1)

	-- X and Y inputs stacked on the right, inside the same group. Enter or Tab
	-- applies, and Tab moves to the other field.
	local function MakeInput(label, yOff)
		local text = group:CreateFontString(nil, "OVERLAY")
		K.SetFont(text, 11, K.FontOutlineStyle())
		text:SetPoint("TOPLEFT", group, "TOPLEFT", 112, yOff)
		text:SetText(label)

		local edit = CreateFrame("EditBox", nil, group, "InputBoxTemplate")
		edit:SetSize(74, 22)
		edit:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 4, -3)
		edit:SetAutoFocus(false)
		edit:SetNumeric(false)
		edit:SetScript("OnEnterPressed", function(self)
			self:ClearFocus()
			ApplyInputs()
		end)
		edit:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
			RefreshPopup()
		end)
		K.SkinEditBox(edit)
		return edit
	end

	popup.X = MakeInput("X", -8)
	popup.Y = MakeInput("Y", -52)
	popup.X:SetScript("OnTabPressed", function(self)
		ApplyInputs()
		popup.Y:SetFocus()
	end)
	popup.Y:SetScript("OnTabPressed", function(self)
		ApplyInputs()
		popup.X:SetFocus()
	end)

	-- Anchor point picker. Clicking steps through the points, and the frame keeps
	-- its place on screen because the new offsets are measured from where it
	-- already sits. Pinning a frame by the corner it lives near is what keeps it
	-- there when the resolution or the UI scale changes.
	local anchorLabel = popup:CreateFontString(nil, "OVERLAY")
	K.SetFont(anchorLabel, 11, K.FontOutlineStyle())
	anchorLabel:SetPoint("TOPLEFT", group, "BOTTOMLEFT", 4, -8)
	anchorLabel:SetText(L["Anchor"])

	local anchor = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
	anchor:SetSize(140, 22)
	anchor:SetPoint("TOPRIGHT", group, "BOTTOMRIGHT", 0, -6)
	K.SkinButton(anchor)
	anchor:SetScript("OnClick", function()
		if not popupTarget or InCombatLockdown() then
			return
		end
		local current = CurrentPoint(popupTarget)
		local index = 1
		for i, point in ipairs(ANCHOR_POINTS) do
			if point == current then
				index = i
				break
			end
		end
		SetAnchorPoint(popupTarget, ANCHOR_POINTS[(index % #ANCHOR_POINTS) + 1])
		RefreshPopup()
	end)
	popup.Anchor = anchor

	local anchorNote = popup:CreateFontString(nil, "OVERLAY")
	K.SetFont(anchorNote, 10, K.FontOutlineStyle())
	anchorNote:SetPoint("TOPLEFT", anchorLabel, "BOTTOMLEFT", 0, -12)
	-- A fixed two line box inside the panel. The sentence ran out past the right
	-- edge as a single line, and a fixed height keeps the button below it still.
	anchorNote:SetSize(200, 26)
	anchorNote:SetJustifyH("LEFT")
	anchorNote:SetJustifyV("TOP")
	anchorNote:SetWordWrap(true)
	anchorNote:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	popup.AnchorNote = anchorNote

	local reset = CreateFrame("Button", nil, popup, "UIPanelButtonTemplate")
	reset:SetSize(208, 24)
	reset:SetPoint("TOPLEFT", anchorNote, "BOTTOMLEFT", -4, -8)
	reset:SetText(L["Reset"])
	K.SkinButton(reset)
	reset:SetScript("OnClick", function()
		if popupTarget then
			K.ResetMover(popupTarget.moverKey)
			RefreshPopup()
		end
	end)

	return popup
end

-- Open the popup targeting a specific mover.
local function OpenPopup(mover)
	popupTarget = mover
	BuildPopup()
	RefreshPopup()
	popup:Show()
end
K.OpenMoverPopup = OpenPopup

-- ---------------------------------------------------------------------------
-- Edit mode
-- ---------------------------------------------------------------------------

local function MakeButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width, 22)
	button:SetText(text)
	K.SkinButton(button)
	return button
end

local function MakeCheck(parent, text, onClick)
	local check = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
	K.SkinCheckBox(check)
	check.Text:SetText(text)
	check.Text:ClearAllPoints()
	check.Text:SetPoint("LEFT", check, "RIGHT", 4, 0)
	K.SetFont(check.Text, 12)
	check:SetScript("OnClick", onClick)
	return check
end

local function BuildPanel()
	if panel then
		return panel
	end

	panel = CreateFrame("Frame", "KKUI_MoverPanel", UIParent)
	panel:SetSize(264, 196)
	panel:SetPoint("TOP", UIParent, "TOP", 0, -120)
	panel:SetFrameStrata("DIALOG")
	panel:SetMovable(true)
	panel:SetClampedToScreen(true)
	panel:EnableMouse(true)
	panel:RegisterForDrag("LeftButton")
	panel:SetScript("OnDragStart", panel.StartMoving)
	panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
	K.CreateGradientBackground(panel)
	K.CreateBorder(panel)
	-- Escape closes move mode like any other window.
	_G.tinsert(_G.UISpecialFrames, "KKUI_MoverPanel")
	panel:SetScript("OnHide", function()
		if editing then
			K.ToggleMovers(false)
		end
	end)

	local title = panel:CreateFontString(nil, "OVERLAY")
	K.SetFont(title, 13, K.FontOutlineStyle())
	title:SetPoint("TOP", panel, "TOP", 0, -8)
	title:SetTextColor(THEME.coords[1], THEME.coords[2], THEME.coords[3])
	title:SetText(L["Move UI"])

	local hint = panel:CreateFontString(nil, "OVERLAY")
	K.SetFont(hint, 10, K.FontOutlineStyle())
	hint:SetPoint("TOP", title, "BOTTOM", 0, -6)
	hint:SetWidth(240)
	hint:SetJustifyH("CENTER")
	hint:SetSpacing(3)
	hint:SetTextColor(K.Colors.secondary[1], K.Colors.secondary[2], K.Colors.secondary[3])
	hint:SetText(L["Drag a box to move it. Hold Shift to place it freely. Hover and use the arrow keys to nudge, with Shift for ten. Click a box for exact numbers."])

	-- Placement options: snapping, the grid and its step. The grid also becomes a
	-- snap target while it is shown.
	local snap = MakeCheck(panel, L["Snap"], function(self)
		Options().snap = self:GetChecked() and true or false
	end)
	snap:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 8, 66)
	panel.Snap = snap

	local gridCheck = MakeCheck(panel, L["Grid"], function(self)
		K.ToggleMoverGrid(self:GetChecked() and true or false)
	end)
	gridCheck:SetPoint("LEFT", snap.Text, "RIGHT", 14, 0)
	panel.Grid = gridCheck

	local stepButton = MakeButton(panel, "", 84)
	stepButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 68)
	stepButton:SetScript("OnClick", function()
		local current = GridStep()
		local nextStep = GRID_STEPS[1]
		for i, step in ipairs(GRID_STEPS) do
			if step == current then
				nextStep = GRID_STEPS[(i % #GRID_STEPS) + 1]
				break
			end
		end
		SetGridStep(nextStep)
	end)
	panel.Step = stepButton

	local undoButton = MakeButton(panel, L["Undo"], 118)
	undoButton:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 38)
	undoButton:SetScript("OnClick", Undo)
	panel.Undo = undoButton

	local revert = MakeButton(panel, L["Revert"], 118)
	revert:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 38)
	revert:SetScript("OnClick", Revert)
	panel.Revert = revert

	local done = MakeButton(panel, L["Done"], 118)
	done:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 10, 10)
	done:SetScript("OnClick", function()
		K.ToggleMovers(false)
	end)

	local reset = MakeButton(panel, L["Reset All"], 118)
	reset:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -10, 10)
	reset:SetScript("OnClick", function()
		if K.Confirm then
			K.Confirm(L["Put every frame back in its default place?"], K.ResetMovers)
		else
			K.ResetMovers()
		end
	end)

	return panel
end

-- Keep the panel's controls in step with the options and the undo list.
RefreshPanel = function()
	if not panel then
		return
	end
	panel.Snap:SetChecked(Options().snap)
	panel.Grid:SetChecked(GridShown())
	panel.Step:SetText(format(L["Grid %d"], GridStep()))
	panel.Step:SetEnabled(GridShown())
	panel.Undo:SetText(#undo > 0 and format("%s (%d)", L["Undo"], #undo) or L["Undo"])
	panel.Undo:SetEnabled(#undo > 0)
end

local function SnapshotStore()
	local copy = {}
	for key, entry in pairs(Store()) do
		copy[key] = CopyEntry(entry)
	end
	return copy
end

function K.ToggleMovers(show)
	if show == nil then
		show = not editing
	end
	if show and InCombatLockdown() then
		K.Print(L["Cannot move frames during combat."])
		return
	end
	if show == editing then
		return
	end

	if not show then
		-- A drag still running is finished and saved before anything closes.
		for _, mover in ipairs(moverOrder) do
			FinishDrag(mover)
		end
	end

	editing = show

	for _, mover in ipairs(moverOrder) do
		mover:EnableMouse(show)
		mover:SetShown(show)
		if not show then
			mover:EnableKeyboard(false)
			mover:SetScript("OnKeyDown", nil)
			mover:SetScript("OnUpdate", nil)
			mover.__dragging = nil
			mover.__wasDragged = nil
		end
	end

	if show then
		undo = {}
		sessionStart = SnapshotStore()
		-- Largest first, so each smaller box lands on a higher level.
		local bySize = {}
		for i, mover in ipairs(moverOrder) do
			bySize[i] = mover
		end
		sort(bySize, function(a, b)
			return a:GetWidth() * a:GetHeight() > b:GetWidth() * b:GetHeight()
		end)
		for i, mover in ipairs(bySize) do
			mover.__restLevel = BASE_LEVEL + i * 2
			mover:SetFrameLevel(mover.__restLevel)
		end
	else
		HideTag()
		ClearSnapDisplay()
		sessionStart = nil
		undo = {}
	end

	if GridShown() then
		BuildGrid():SetShown(show)
	elseif grid then
		grid:Hide()
	end

	BuildPanel()
	RefreshPanel()
	panel:SetShown(show)
	if not show and popup then
		popup:Hide()
	end
end

function K.MoversEnabled()
	return editing
end

function K.ResetMovers()
	if InCombatLockdown() then
		K.Print(L["Cannot move frames during combat."])
		return
	end
	local store = Store()
	for key in pairs(store) do
		store[key] = nil
	end
	for _, mover in ipairs(moverOrder) do
		RestorePosition(mover)
	end
	undo = {}
	RefreshPanel()
	if popupTarget then
		NotifyPopup(popupTarget)
	end
	K.Print(L["Frame positions reset."])
end

-- Placing frames is blocked in combat, so move mode closes when a fight starts.
-- This event fires just before the lockdown, so a drag in progress still saves.
local combat = CreateFrame("Frame")
combat:RegisterEvent("PLAYER_REGEN_DISABLED")
combat:RegisterEvent("UI_SCALE_CHANGED")
combat:RegisterEvent("DISPLAY_SIZE_CHANGED")
combat:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		if editing then
			K.ToggleMovers(false)
		end
	elseif grid and grid:IsShown() then
		-- The screen changed size, so the grid is drawn again for it.
		BuildGrid()
	end
end)
