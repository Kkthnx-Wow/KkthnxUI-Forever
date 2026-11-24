--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/CursorTrail.lua
	Purpose:
		A trail behind the mouse pointer, so the cursor stays findable in a busy
		fight. Three looks share one engine:
		  Ribbon     one continuous stroke that tapers and fades
		  Particles  glows dropped along the path that drift and twinkle
		  Comet      a ribbon with a glow on the pointer and sparks shed along it
		A glow can sit on the pointer itself in any look.

		Points are dropped along the path and left where they land, then aged
		out. Spacing is measured from the last point rather than the last frame,
		so a slow drag still places points, and a fast flick is filled in so the
		line has no gaps.

		The ribbon is made of Line regions, one per pair of neighbouring points,
		anchored once when the point is placed. Only the newest piece, from the
		last point to the pointer, moves each frame. Everything else per frame is
		alpha, thickness and colour. All widgets come from fixed pools made on
		enable, no table or closure is built per frame, and the whole loop stops
		once the pointer is still and the last of the trail has faded. Off by
		default.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("CursorTrail")

local CreateFrame = CreateFrame
local GetCursorPosition = GetCursorPosition
local GetTime = GetTime
local UnitAffectingCombat = UnitAffectingCombat
local UIParent = UIParent
local floor, sqrt, min, max, sin, cos = math.floor, math.sqrt, math.min, math.max, math.sin, math.cos
local random = math.random
local PI2 = math.pi * 2

-- A frame longer than this means a loading screen or an alt-tab, so the samples
-- either side of it are not part of one stroke.
local HITCH = 0.25
-- Pixels of movement that count as the pointer having moved at all.
local NUDGE = 0.5
-- How often the idle watcher looks for that movement.
local WATCH = 0.05
-- Ceiling on gap filling, so one enormous jump cannot place hundreds of points.
local MAX_FILL = 12
-- How long the pointer glow takes to fade once the pointer stops.
local HEAD_FADE = 0.35
-- A comet sheds a spark on every this many points.
local SPARK_EVERY = 3

local holder, watcher, ticker

-- Point ring. Plain arrays rather than a table per point.
local px, py, born = {}, {}, {}
local capacity, live, head = 0, 0, 0
-- Ribbon pieces: lines[i] joins point i to the point before it in the same stroke.
local lines, joined = {}, {}
local headLine
-- Particles, one per point, with a drift velocity and a twinkle phase.
local dots, vx, vy, phase = {}, {}, {}, {}
-- Comet sparks, their own ring.
local sparks, sx, sy, svx, svy, sborn = {}, {}, {}, {}, {}, {}
local sparkCap, sparkLive, sparkHead, sinceSpark = 0, 0, 0, 0
local headGlow

local lastX, lastY, emitX, emitY, lastTick, lastMove, strokeLast
local turning, inCinematic, asleep = 0, false, true

-- Settings, read on enable and on a live change, so the per frame pass never
-- walks the config.
local useRibbon, useDots, useSparks, useHead
local size, spacing, lifetime, opacity, shrink, drift, twinkle
local headSize, combatOnly, hideTurning
local r1, g1, b1, r2, g2, b2, fade

local function Suppressed()
	if inCinematic then
		return true
	end
	if hideTurning and turning > 0 then
		return true
	end
	if combatOnly and not UnitAffectingCombat("player") then
		return true
	end
	return false
end

local function Clear()
	live, head, sparkLive, sparkHead, sinceSpark = 0, 0, 0, 0, 0
	lastX, lastY, emitX, emitY, strokeLast, lastMove = nil, nil, nil, nil, nil, nil
	for i = 1, capacity do
		lines[i]:Hide()
		dots[i]:Hide()
		joined[i] = false
	end
	for i = 1, sparkCap do
		sparks[i]:Hide()
	end
	headLine:Hide()
	headGlow:Hide()
	holder:Hide()
end

-- Colour at a point in the trail's life, head colour to tail colour.
local function Tint(region, t)
	if fade then
		region:SetVertexColor(r1 + (r2 - r1) * t, g1 + (g2 - g1) * t, b1 + (b2 - b1) * t)
	end
end

local function EmitSpark(x, y, now)
	sparkHead = sparkHead % sparkCap + 1
	if sparkLive < sparkCap then
		sparkLive = sparkLive + 1
	end
	local angle = random() * PI2
	local speed = 20 + random() * 40
	sx[sparkHead], sy[sparkHead] = x, y
	svx[sparkHead], svy[sparkHead] = cos(angle) * speed, sin(angle) * speed
	sborn[sparkHead] = now
end

-- Drop one point. The ribbon piece back to the previous point is anchored here
-- and never moved again, it only fades.
local function Emit(x, y, now)
	head = head % capacity + 1
	px[head], py[head], born[head] = x, y, now
	if live < capacity then
		live = live + 1
	end

	if useRibbon then
		local line = lines[head]
		if strokeLast then
			line:SetStartPoint("BOTTOMLEFT", UIParent, px[strokeLast], py[strokeLast])
			line:SetEndPoint("BOTTOMLEFT", UIParent, x, y)
			joined[head] = true
		else
			joined[head] = false
			line:Hide()
		end
	end
	strokeLast = head

	if useDots then
		local dot = dots[head]
		if drift then
			local angle = random() * PI2
			local speed = 6 + random() * 14
			vx[head], vy[head] = cos(angle) * speed, sin(angle) * speed
		else
			dot:ClearAllPoints()
			dot:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
		end
		phase[head] = random() * PI2
	end

	if useSparks then
		sinceSpark = sinceSpark + 1
		if sinceSpark >= SPARK_EVERY then
			sinceSpark = 0
			EmitSpark(x, y, now)
		end
	end
end

-- Age every live point. Returns whether anything is still worth drawing.
local function Paint(now)
	local visible = false
	for k = 0, live - 1 do
		local i = (head - k - 1) % capacity + 1
		local age = now - born[i]
		if age >= lifetime then
			if useRibbon then
				lines[i]:Hide()
			end
			if useDots then
				dots[i]:Hide()
			end
		else
			local t = age / lifetime
			local left = 1 - t
			visible = true
			if useRibbon and joined[i] then
				local line = lines[i]
				line:SetAlpha(opacity * left)
				line:SetThickness(shrink and max(1, size * (1 - t * 0.85)) or size)
				Tint(line, t)
				line:Show()
			end
			if useDots then
				local dot = dots[i]
				local alpha = opacity * left
				if twinkle then
					alpha = alpha * (0.6 + 0.4 * sin(age * 18 + phase[i]))
				end
				dot:SetAlpha(alpha)
				local scaled = shrink and size * (1 - t * 0.7) or size
				dot:SetSize(scaled, scaled)
				if drift then
					dot:ClearAllPoints()
					dot:SetPoint("CENTER", UIParent, "BOTTOMLEFT", px[i] + vx[i] * age, py[i] + vy[i] * age)
				end
				Tint(dot, t)
				dot:Show()
			end
		end
	end

	-- Retire dead points off the tail end so live stays honest.
	while live > 0 do
		local oldest = (head - live) % capacity + 1
		if now - born[oldest] < lifetime then
			break
		end
		live = live - 1
	end

	if useSparks then
		local sparkLife = lifetime * 0.8
		local sparkSize = size * 0.55
		for k = 0, sparkLive - 1 do
			local i = (sparkHead - k - 1) % sparkCap + 1
			local age = now - sborn[i]
			local spark = sparks[i]
			if age >= sparkLife then
				spark:Hide()
			else
				local t = age / sparkLife
				visible = true
				spark:SetAlpha(opacity * (1 - t))
				local scaled = sparkSize * (1 - t * 0.5)
				spark:SetSize(scaled, scaled)
				spark:ClearAllPoints()
				spark:SetPoint("CENTER", UIParent, "BOTTOMLEFT", sx[i] + svx[i] * age, sy[i] + svy[i] * age)
				Tint(spark, t)
				spark:Show()
			end
		end
		while sparkLive > 0 do
			local oldest = (sparkHead - sparkLive) % sparkCap + 1
			if now - sborn[oldest] < sparkLife then
				break
			end
			sparkLive = sparkLive - 1
		end
	end

	return visible
end

-- The pieces that follow the pointer: the last ribbon piece up to the pointer,
-- and the glow on it. Both fade out shortly after the pointer stops.
local function PaintHead(now, x, y, blocked)
	local strength = 0
	if lastMove and not blocked then
		strength = max(0, 1 - (now - lastMove) / HEAD_FADE)
	end

	if useRibbon then
		if strength > 0 and strokeLast and now - born[strokeLast] < lifetime then
			headLine:SetStartPoint("BOTTOMLEFT", UIParent, px[strokeLast], py[strokeLast])
			headLine:SetEndPoint("BOTTOMLEFT", UIParent, x, y)
			headLine:SetThickness(size)
			headLine:SetAlpha(opacity * strength)
			headLine:Show()
		else
			headLine:Hide()
		end
	end

	if useHead then
		if strength > 0 then
			headGlow:ClearAllPoints()
			headGlow:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
			headGlow:SetAlpha(opacity * strength)
			headGlow:Show()
		else
			headGlow:Hide()
		end
	end

	return strength > 0
end

local Wake

local function Sleep()
	ticker:SetScript("OnUpdate", nil)
	asleep = true
	watcher:SetScript("OnUpdate", watcher.Check)
end

local function OnTick()
	local now = GetTime()
	if lastTick and now - lastTick > HITCH then
		Clear()
	end
	lastTick = now

	local scale = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	x, y = x / scale, y / scale

	local moved = true
	if lastX then
		local dx, dy = x - lastX, y - lastY
		moved = (dx * dx + dy * dy) >= (NUDGE * NUDGE)
	end
	lastX, lastY = x, y

	local blocked = Suppressed()
	if blocked then
		-- Do not bridge a stroke across a mouselook or a cinematic.
		emitX, emitY, strokeLast, lastMove = nil, nil, nil, nil
	else
		if moved then
			lastMove = now
		end
		if not emitX then
			-- Seed the origin without dropping a point, or waking up parks a blob
			-- under a stationary pointer.
			emitX, emitY = x, y
		else
			local dx, dy = x - emitX, y - emitY
			local travelled = sqrt(dx * dx + dy * dy)
			if travelled >= spacing then
				-- Fill the gap a fast flick leaves, so the line stays continuous.
				local steps = min(MAX_FILL, max(1, floor(travelled / spacing)))
				for step = 1, steps do
					local along = step / steps
					Emit(emitX + dx * along, emitY + dy * along, now)
				end
				emitX, emitY = x, y
			end
		end
	end

	local trail = Paint(now)
	local pointer = PaintHead(now, x, y, blocked)
	holder:SetShown(trail or pointer)

	-- Nothing moving and nothing left on screen, so there is nothing to draw.
	-- Motion while suppressed must not hold the loop open either, or combat only
	-- would tick forever on an idle character wiggling the mouse.
	if (not moved or blocked) and not trail and not pointer then
		Sleep()
	end
end

function Wake()
	if not asleep then
		return
	end
	asleep = false
	watcher:SetScript("OnUpdate", nil)
	lastTick = GetTime()
	ticker:SetScript("OnUpdate", OnTick)
end

-- Cheap poll while asleep. Pointer movement raises no event, so this is the one
-- part that cannot be event driven. It runs at 20Hz and only compares numbers.
local function OnWatch(self, elapsed)
	self.wait = (self.wait or 0) + elapsed
	if self.wait < WATCH then
		return
	end
	self.wait = 0
	if Suppressed() then
		return
	end
	local scale = UIParent:GetEffectiveScale()
	local x, y = GetCursorPosition()
	x, y = x / scale, y / scale
	if not lastX then
		lastX, lastY = x, y
		Wake()
		return
	end
	local dx, dy = x - lastX, y - lastY
	if (dx * dx + dy * dy) >= (NUDGE * NUDGE) then
		Wake()
	end
end

function Module:PLAYER_STARTED_LOOKING()
	turning = turning + 1
end

function Module:PLAYER_STOPPED_LOOKING()
	turning = max(0, turning - 1)
end

function Module:PLAYER_STARTED_TURNING()
	turning = turning + 1
end

function Module:PLAYER_STOPPED_TURNING()
	turning = max(0, turning - 1)
end

function Module:CINEMATIC_START()
	inCinematic = true
	Clear()
end

function Module:CINEMATIC_STOP()
	inCinematic = false
end

-- Points are anchored in screen units, so a scale change leaves every one of
-- them in the wrong place.
function Module:UI_SCALE_CHANGED()
	Clear()
end

function Module:PLAYER_ENTERING_WORLD()
	Clear()
	turning, inCinematic = 0, false
end

-- Combat only: come back up so the first swing of the mouse in combat draws.
function Module:PLAYER_REGEN_DISABLED()
	if combatOnly then
		Wake()
	end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

-- Everything except the pool size applies live: the look, the art, the colours
-- and the timings. The trail is cleared so a change never leaves half a stroke
-- drawn the old way.
function Module:ApplySettings()
	if not holder then
		return
	end
	local db = C.Misc
	local style = db.CursorTrailStyle
	useRibbon = style == "Ribbon" or style == "Comet"
	useDots = style == "Particles"
	useSparks = style == "Comet"
	useHead = db.CursorTrailHead or style == "Comet"

	size = db.CursorTrailSize
	spacing = db.CursorTrailSpacing
	lifetime = db.CursorTrailLifetime
	opacity = db.CursorTrailAlpha
	shrink = db.CursorTrailShrink
	drift = db.CursorTrailDrift
	twinkle = db.CursorTrailTwinkle
	headSize = db.CursorTrailHeadSize
	combatOnly = db.CursorTrailCombat
	hideTurning = db.CursorTrailHideTurning
	fade = db.CursorTrailFade

	if db.CursorTrailClassColor then
		r1, g1, b1 = K.ClassColor.r, K.ClassColor.g, K.ClassColor.b
	else
		local c = db.CursorTrailColor
		r1, g1, b1 = c[1], c[2], c[3]
	end
	local tail = db.CursorTrailTailColor
	r2, g2, b2 = tail[1], tail[2], tail[3]

	local glow = K.FindTrailArt(C.Media.TrailGlows, db.CursorTrailShape)
	local ribbon = K.FindTrailArt(C.Media.TrailRibbons, db.CursorTrailRibbon)
	local headArt = K.FindTrailArt(C.Media.TrailGlows, db.CursorTrailHeadShape)

	for i = 1, capacity do
		K.SetTrailArt(lines[i], ribbon)
		lines[i]:SetBlendMode("ADD")
		lines[i]:SetVertexColor(r1, g1, b1)
		K.SetTrailArt(dots[i], glow)
		dots[i]:SetBlendMode("ADD")
		dots[i]:SetSize(size, size)
		dots[i]:SetVertexColor(r1, g1, b1)
	end
	for i = 1, sparkCap do
		K.SetTrailArt(sparks[i], glow)
		sparks[i]:SetBlendMode("ADD")
		sparks[i]:SetVertexColor(r1, g1, b1)
	end
	K.SetTrailArt(headLine, ribbon)
	headLine:SetBlendMode("ADD")
	headLine:SetVertexColor(r1, g1, b1)
	K.SetTrailArt(headGlow, headArt)
	headGlow:SetBlendMode("ADD")
	headGlow:SetSize(headSize, headSize)
	headGlow:SetVertexColor(r1, g1, b1)

	if combatOnly then
		self:RegisterEvent("PLAYER_REGEN_DISABLED")
	else
		self:UnregisterEvent("PLAYER_REGEN_DISABLED")
	end

	Clear()
	Wake()
end

function Module:OnEnable()
	local db = C.Misc
	if not db.CursorTrail then
		return
	end

	capacity = db.CursorTrailLength
	sparkCap = max(8, floor(capacity / SPARK_EVERY) + 4)

	holder = CreateFrame("Frame", "KKUI_CursorTrail", UIParent)
	holder:SetAllPoints(UIParent)
	holder:SetFrameStrata("TOOLTIP")
	holder:EnableMouse(false)
	holder:Hide()

	-- Every widget the trail can use is made here, once. The art and colour are
	-- set by ApplySettings, so a live change re-skins the same pools.
	for i = 1, capacity do
		local line = holder:CreateLine(nil, "ARTWORK")
		line:Hide()
		lines[i] = line
		joined[i] = false
		local dot = holder:CreateTexture(nil, "ARTWORK")
		dot:Hide()
		dots[i] = dot
	end
	for i = 1, sparkCap do
		local spark = holder:CreateTexture(nil, "ARTWORK", nil, 1)
		spark:Hide()
		sparks[i] = spark
	end
	headLine = holder:CreateLine(nil, "ARTWORK")
	headLine:Hide()
	headGlow = holder:CreateTexture(nil, "OVERLAY")
	headGlow:Hide()

	ticker = CreateFrame("Frame")
	watcher = CreateFrame("Frame")
	watcher.Check = OnWatch

	self:RegisterEvent("PLAYER_STARTED_LOOKING")
	self:RegisterEvent("PLAYER_STOPPED_LOOKING")
	self:RegisterEvent("PLAYER_STARTED_TURNING")
	self:RegisterEvent("PLAYER_STOPPED_TURNING")
	self:RegisterEvent("CINEMATIC_START")
	self:RegisterEvent("CINEMATIC_STOP")
	self:RegisterEvent("UI_SCALE_CHANGED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")

	self:ApplySettings()
end
