--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Elements/Bars.lua
	Purpose:
		The bar family: health (with heal prediction and absorb sub-widgets),
		power, the druid style additional power strip, and the boss encounter
		alternative power strip.

		Health and power are separate bordered boxes, so each one owns its own
		background and border rather than sharing one on the parent frame.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")
local Build = Module.Build

local CreateFrame = CreateFrame
local IsSecret = K.IsSecret
local UnitClass = UnitClass
local UnitIsPlayer = UnitIsPlayer
local UnitInPartyIsAI = UnitInPartyIsAI
local UnitReaction = UnitReaction
local UnitCanAttack = UnitCanAttack
local UnitIsTapDenied = UnitIsTapDenied
local UnitPlayerControlled = UnitPlayerControlled
local UnitThreatSituation = UnitThreatSituation
local oUF = K.oUF

-- ExponentialEaseOut is the only interpolation the client offers besides
-- Immediate, so "smooth bars" maps onto it directly.
local function Smoothing()
	if C.Unitframe.Smooth then
		return Enum.StatusBarInterpolation.ExponentialEaseOut
	end
	return Enum.StatusBarInterpolation.Immediate
end

-- A bordered status bar box. Our gradient backdrop, border, and addon texture.
-- The empty part of the bar shows the gradient, matching the rest of the UI.
local function CreateBox(parent, height)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(Module.Texture())
	if height then
		bar:SetHeight(height)
	end
	K.CreateGradientBackground(bar, 0.9)
	K.CreateBorder(bar)
	return bar
end
Module.CreateBox = CreateBox

-- ---------------------------------------------------------------------------
-- Bar shading
-- ---------------------------------------------------------------------------
-- Backdrop tint. The empty part of the bar tinted to a dark version of the fill
-- colour, so an almost dead target still reads as its class. Run from the bar's
-- PostUpdateColor so it always sees the colour oUF just applied.

local BACKDROP_TINT = 0.22
-- Matches the flat backdrop underneath, so turning the tint on does not make a
-- bar suddenly opaque.
local BACKDROP_ALPHA = 0.9

local function AddBackdropTint(bar)
	local tint = bar:CreateTexture(nil, "BACKGROUND", nil, -6)
	K.SetTextureAsset(tint, Module.Texture())
	tint:SetAllPoints()
	tint:SetVertexColor(0.2, 0.2, 0.2, BACKDROP_ALPHA)
	K.DisablePixelSnap(tint)
	bar.KKUI_Tint = tint
	return tint
end

-- Reading the colour back off the widget rather than trusting the argument keeps
-- this working for the power element's atlas and alternative-colour paths, where
-- the ColorMixin argument is nil.
local function ShadeBar(bar)
	if not bar.KKUI_Tint then
		return
	end
	local texture = bar:GetStatusBarTexture()
	-- Blizzard's own power atlases carry their colour in the art. Our atlas bar
	-- texture is grey and coloured like a file, so it is shaded as normal.
	local atlas = texture:GetAtlas()
	if atlas and not K.StatusbarAtlases[atlas] then
		return
	end

	local r, g, b = texture:GetVertexColor()
	-- A smooth health curve hands back a secret colour, which cannot be
	-- multiplied, so leave the tint alone.
	if not r or IsSecret(r) then
		return
	end
	bar.KKUI_Tint:SetVertexColor(r * BACKDROP_TINT, g * BACKDROP_TINT, b * BACKDROP_TINT, BACKDROP_ALPHA)
end

-- Build the backdrop tint if enabled. Returns whether the bar needs shading on
-- every colour update, so the caller can skip the hook entirely when it is off.
local function AddShading(bar)
	if C.Unitframe.BarBackdrop then
		AddBackdropTint(bar)
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Health
-- ---------------------------------------------------------------------------

-- Incoming heals and absorbs ride on top of the health fill, the way the game's
-- own frames show them: your heals, then everyone else's, then shields, all
-- running right from the health edge, and heal absorbs eating back left into
-- the health that is there. oUF sizes each bar to the full health width and
-- sets its value, so only the anchoring, colour and limits live here.
--
-- Colours come from the palette by meaning. Heals are positive, your own
-- stronger than other people's. Shields are info. Heal absorbs are negative.
local PREDICTION_ALPHA = {
	healingPlayer = 0.55,
	healingOther = 0.3,
	damageAbsorb = 0.4,
	healAbsorb = 0.5,
}
-- Width of the edge slivers that mark a shield or heal absorb too big to show.
local OVER_INDICATOR_WIDTH = 3

local function CreatePredictionBar(parent, color, alpha, reverse)
	local bar = CreateFrame("StatusBar", nil, parent)
	bar:SetStatusBarTexture(Module.Texture())
	bar:SetStatusBarColor(color[1], color[2], color[3], alpha)
	bar:SetPoint("TOP")
	bar:SetPoint("BOTTOM")
	bar:SetReverseFill(reverse or false)
	return bar
end

local function CreateOverIndicator(parent, color, side)
	local sliver = parent:CreateTexture(nil, "OVERLAY")
	sliver:SetColorTexture(color[1], color[2], color[3], 1)
	sliver:SetBlendMode("ADD")
	sliver:SetPoint("TOP" .. side)
	sliver:SetPoint("BOTTOM" .. side)
	sliver:SetWidth(OVER_INDICATOR_WIDTH)
	return sliver
end

local function AddPrediction(health)
	local colors = K.Colors

	-- Every value is held inside the bar. Incoming heals stop at full health,
	-- shields only fill what health and heals leave missing, and a heal absorb
	-- never runs past the left edge. Anything past those limits lights the edge
	-- sliver instead. These are the calculator's own limits, so the numbers are
	-- right before anything is drawn.
	local clamp = Enum and Enum.UnitDamageAbsorbClampMode
	if clamp then
		health.damageAbsorbClampMode = clamp.MissingHealth
		health.healAbsorbClampMode = Enum.UnitHealAbsorbClampMode.CurrentHealth
		health.incomingHealClampMode = Enum.UnitIncomingHealClampMode.MissingHealth
		health.healAbsorbMode = Enum.UnitHealAbsorbMode.ReducedByIncomingHeals
	end
	health.incomingHealOverflow = 1

	-- The bars hang off the health edge, and with smooth bars that edge glides to
	-- a new value while the prediction is already sized for it, so for a moment
	-- the pieces could reach past the end. A clipping layer over the bar keeps
	-- every piece inside the health box at all times.
	local clip = CreateFrame("Frame", nil, health)
	clip:SetAllPoints(health)
	clip:SetClipsChildren(true)
	clip:SetFrameLevel(health:GetFrameLevel() + 1)
	health.KKUI_PredictionClip = clip

	local fill = health:GetStatusBarTexture()

	local healingPlayer = CreatePredictionBar(clip, colors.positive, PREDICTION_ALPHA.healingPlayer)
	healingPlayer:SetPoint("LEFT", fill, "RIGHT", 0, 0)
	health.HealingPlayer = healingPlayer

	local healingOther = CreatePredictionBar(clip, colors.positive, PREDICTION_ALPHA.healingOther)
	healingOther:SetPoint("LEFT", healingPlayer:GetStatusBarTexture(), "RIGHT", 0, 0)
	health.HealingOther = healingOther

	local damageAbsorb = CreatePredictionBar(clip, colors.info, PREDICTION_ALPHA.damageAbsorb)
	damageAbsorb:SetPoint("LEFT", healingOther:GetStatusBarTexture(), "RIGHT", 0, 0)
	health.DamageAbsorb = damageAbsorb

	local healAbsorb = CreatePredictionBar(clip, colors.negative, PREDICTION_ALPHA.healAbsorb, true)
	healAbsorb:SetPoint("RIGHT", fill, "RIGHT", 0, 0)
	health.HealAbsorb = healAbsorb

	-- A shield bigger than the missing health lights the right edge, a heal
	-- absorb bigger than current health lights the left. Both sit inside the bar.
	health.OverDamageAbsorbIndicator = CreateOverIndicator(clip, colors.info, "RIGHT")
	health.OverHealAbsorbIndicator = CreateOverIndicator(clip, colors.negative, "LEFT")
end

-- ---------------------------------------------------------------------------
-- Health border colour
-- ---------------------------------------------------------------------------
-- Dispel, threat and the class colour option all want to own the health border,
-- so none touches it directly. They set a field and call through here, and this
-- decides. Dispel first, then threat, then class, then the configured border
-- colour.

local function UnitBorderColor(frame, unit)
	local colors = frame.colors

	-- Either call can hand back a secret boolean, which cannot be tested. Treat that
	-- as an unknown unit and fall through to the plain border colour.
	local isPlayer = UnitIsPlayer(unit)
	local isAI = UnitInPartyIsAI(unit)
	if IsSecret(isPlayer) or IsSecret(isAI) then
		return nil
	end
	if isPlayer or isAI then
		-- Second return only. The class token can be a secret on restricted units
		-- (target of target, some delve mobs), and a secret can never be a table
		-- key. When it is secret, ask the client for the colour instead, which
		-- accepts a secret token and hands back values safe to feed a setter.
		local _, class = UnitClass(unit)
		if IsSecret(class) then
			return C_ClassColor and C_ClassColor.GetClassColor(class)
		elseif class then
			return colors.class[class]
		end
		return nil
	end

	local reaction = K.UnitReactionIndex(unit)
	if reaction then
		return colors.reaction[reaction]
	end
	return nil
end

function Module.RefreshHealthBorder(self)
	local health = self.Health
	local border = health and health.KKUI_Border
	if not border then
		return
	end

	-- Border priority for a healer's eyes. A dispellable debuff wins over threat,
	-- which wins over the optional class-coloured border.
	local color = self.__dispelColor or self.__threatColor
	if not color and C.Unitframe.ClassColorBorder then
		color = self.__unitColor
	end

	-- This runs on every health tick, and the answer rarely changes. The colours
	-- are shared objects, so the same one means nothing to repaint. false marks
	-- the plain border. A theme change repaints plain borders on its own.
	local applied = color or false
	if border.__kkuiHealthColor == applied then
		return
	end
	border.__kkuiHealthColor = applied

	if color then
		K.SetBorderColor(border, color:GetRGB())
	else
		K.ResetBorderColor(border)
	end
end

-- NPC fill override, run after oUF's own colouring. Players and tapped mobs keep
-- the colour oUF gave them. Enemies get a threat colour when that option is on.
-- With reaction colours on, NPCs take the game's selection colour like Blizzard's
-- plates. A mob whose reaction is secret gets a solid hostile colour, so one we
-- are fighting never falls back to the plain green health fill.
local function ColorNPCFill(element, unit)
	local isPlayer = UnitIsPlayer(unit)
	if IsSecret(isPlayer) or isPlayer then
		return
	end

	local controlled = UnitPlayerControlled(unit)
	if not IsSecret(controlled) and not controlled then
		local tapDenied = UnitIsTapDenied(unit)
		if IsSecret(tapDenied) or tapDenied then
			return
		end
	end

	local canAttack = UnitCanAttack("player", unit)
	local attackable = not IsSecret(canAttack) and canAttack

	if attackable and C.Unitframe.ThreatHealthColor then
		local status = UnitThreatSituation("player", unit)
		if status and not IsSecret(status) then
			local color = K.ThreatFillColor(status, K.PlayerIsTank())
			if color then
				element:SetStatusBarColor(color[1], color[2], color[3])
				return
			end
		end
	end

	if C.Unitframe.ClassHealth then
		local index = K.UnitReactionIndex(unit)
		local color = index and oUF.colors.reaction[index]
		if color then
			element:SetStatusBarColor(color:GetRGB())
			return
		end
	end

	if not attackable then
		return
	end

	-- A readable reaction means oUF's colour stands, so only step in when it is
	-- secret, and then use the hostile colour instead of the stock green.
	local reaction = UnitReaction(unit, "player")
	if reaction and not IsSecret(reaction) then
		return
	end
	local hostile = oUF and oUF.colors and oUF.colors.reaction and oUF.colors.reaction[2]
	if hostile then
		element:SetStatusBarColor(hostile:GetRGB())
	end
end

-- Your own pet reads its owner's class colour. oUF's class pet option asks the
-- client for the pet's class instead, and a pet reports a fixed class of its own
-- (the warrior token), which would draw the pet bar in warrior tan.
local function ColorOwnPet(element, unit)
	if unit ~= "pet" or not element.colorOwnerClass then
		return false
	end
	local color = element.__owner.colors.class[K.Class]
	if not color then
		return false
	end
	element:SetStatusBarColor(color:GetRGB())
	return true
end

local function OnHealthColor(element, unit)
	local frame = element.__owner
	local petColored = ColorOwnPet(element, unit)
	frame.__unitColor = petColored and frame.colors.class[K.Class] or UnitBorderColor(frame, unit)
	Module.RefreshHealthBorder(frame)

	if not petColored then
		ColorNPCFill(element, unit)
	end

	-- After the fill override, so the tint reads the colour the bar ends up with.
	if element.__shaded then
		ShadeBar(element)
	end
end

-- Config mode recolours bars by hand, so it needs the same backdrop shading.
Module.ShadeBar = ShadeBar

function Build.Health(self, height)
	local health = CreateBox(self, height)
	health:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
	health:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, 0)
	health.smoothing = Smoothing()
	health.__shaded = AddShading(health)
	health.PostUpdateColor = OnHealthColor

	health.colorDisconnected = true
	health.colorTapping = true
	if C.Unitframe.ClassHealth then
		health.colorClass = true
		health.colorOwnerClass = true
		health.colorReaction = true
	end
	-- Last link in oUF's colour chain either way. Without it a unit that matches
	-- none of the above keeps whatever colour the bar had last, which the shading
	-- below would then read back and reuse.
	health.colorHealth = true

	if C.Unitframe.HealthPrediction then
		AddPrediction(health)
	end

	self.Health = health

	-- Mouseover and target-select highlights framing the health border.
	if Build.Highlight then
		Build.Highlight(self)
	end

	return health
end

-- ---------------------------------------------------------------------------
-- Power
-- ---------------------------------------------------------------------------

-- gap lets compact frames (raid) sit the power bar tight under health instead
-- of using the standard detached gap. pinBottom anchors the bar to the frame's
-- bottom edge instead of below health, so the caller can let health fill the
-- space above (used by raid so hiding power expands health).
function Build.Power(self, height, gap, pinBottom)
	if not height or height <= 0 then
		return
	end

	gap = gap or Module.GAP
	local power = CreateBox(self, height)
	if pinBottom then
		power:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 0, 0)
		power:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, 0)
	else
		power:SetPoint("TOPLEFT", self.Health, "BOTTOMLEFT", 0, -gap)
		power:SetPoint("TOPRIGHT", self.Health, "BOTTOMRIGHT", 0, -gap)
	end
	power.smoothing = Smoothing()
	power.colorPower = true
	power.frequentUpdates = true

	if AddShading(power) then
		power.PostUpdateColor = ShadeBar
	end

	self.Power = power
	return power
end

-- ---------------------------------------------------------------------------
-- Cast cost preview
-- ---------------------------------------------------------------------------
-- While the player casts, the part of the power bar the spell will spend is
-- marked back from the current power edge, the way the game's own player frame
-- shows it. oUF reads the cost and sizes the bar. It is drawn in the body text
-- colour over the power fill, so it reads as "this much goes" on any power
-- colour, and it is clipped to the power box like the heal prediction.
local COST_ALPHA = 0.35

function Build.CostPrediction(self)
	local power = self.Power
	if not power then
		return
	end

	local clip = CreateFrame("Frame", nil, power)
	clip:SetAllPoints(power)
	clip:SetClipsChildren(true)
	clip:SetFrameLevel(power:GetFrameLevel() + 1)

	local text = K.Colors.text
	local cost = CreateFrame("StatusBar", nil, clip)
	cost:SetStatusBarTexture(Module.Texture())
	cost:SetStatusBarColor(text[1], text[2], text[3], COST_ALPHA)
	cost:SetReverseFill(true)
	cost:SetPoint("TOP")
	cost:SetPoint("BOTTOM")
	cost:SetPoint("RIGHT", power:GetStatusBarTexture(), "RIGHT", 0, 0)

	power.CostPrediction = cost
	return cost
end

-- ---------------------------------------------------------------------------
-- Additional power (druid mana while shifted)
-- ---------------------------------------------------------------------------
-- A thin strip along the bottom of the health bar. Overlaying keeps the frame
-- height stable whether or not the player is in a form that shows it.

function Build.AdditionalPower(self)
	local bar = CreateFrame("StatusBar", nil, self.Health)
	bar:SetStatusBarTexture(Module.Texture())
	bar:SetHeight(4)
	bar:SetFrameLevel(self.Health:GetFrameLevel() + 3)
	bar:SetPoint("BOTTOMLEFT", self.Health, "BOTTOMLEFT", 0, 0)
	bar:SetPoint("BOTTOMRIGHT", self.Health, "BOTTOMRIGHT", 0, 0)
	bar.colorPower = true
	bar.smoothing = Smoothing()

	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.6)

	self.AdditionalPower = bar
	return bar
end

-- ---------------------------------------------------------------------------
-- Alternative power (boss encounter bars)
-- ---------------------------------------------------------------------------

function Build.AlternativePower(self)
	local bar = CreateFrame("StatusBar", nil, self.Health)
	bar:SetStatusBarTexture(Module.Texture())
	bar:SetStatusBarColor(0.7, 0.7, 0.6)
	bar:SetHeight(4)
	bar:SetFrameLevel(self.Health:GetFrameLevel() + 3)
	bar:SetPoint("TOPLEFT", self.Health, "TOPLEFT", 0, 0)
	bar:SetPoint("TOPRIGHT", self.Health, "TOPRIGHT", 0, 0)

	local bg = bar:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(0, 0, 0, 0.6)

	self.AlternativePower = bar
	return bar
end
