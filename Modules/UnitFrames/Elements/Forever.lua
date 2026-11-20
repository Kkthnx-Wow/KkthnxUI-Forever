--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Elements/Forever.lua
	Purpose:
		The pieces of the unit frames that only exist on WoW Forever: the swing
		timer, the shaman totem row, the PvP flag icon and the hunter pet mood.

		Each one is a thin skin over an oUF element. oUF owns the events and the
		game queries, so these builders only create the widgets, give them our
		bar texture, background and border, and park them on the frame's stacks.

		The swing timer is shown only while a swing is running, the totems fade to
		nothing while a slot is empty, so none of them takes room from the frame
		when it has nothing to say.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")
local Build = Module.Build

local CreateFrame = CreateFrame
local Enum = Enum
local GetTime = GetTime
local UIParent = UIParent
local UnitAffectingCombat = UnitAffectingCombat

-- Which classes swing which weapon. Dual wielders get the off hand bar, and every
-- class with a wand, bow, gun or thrown weapon gets the ranged bar, which sits on
-- top of the main hand bar since the two never run together.
local OFF_HAND = { WARRIOR = true, ROGUE = true, SHAMAN = true, HUNTER = true }

local SWING_HEIGHT = 8
local SWING_OFF_HEIGHT = 6

-- ---------------------------------------------------------------------------
-- Swing timer
-- ---------------------------------------------------------------------------

local function StyleSwingBar(bar, color)
	bar:SetStatusBarTexture(Module.Texture())
	bar:SetStatusBarColor(color[1], color[2], color[3])
	K.CreateBackground(bar, 0.08, 0.08, 0.08, 0.9)
	K.CreateBorder(bar)

	-- Only drawn while a swing is running, so the bar starts hidden and oUF shows
	-- it. Combat alone does not open it, an idle bar would just be clutter.
	bar.showCombat = false
	bar.showAlways = false
	bar.checkRange = false

	local time = bar:CreateFontString(nil, "OVERLAY")
	K.SetFont(time, 10, K.FontOutlineStyle())
	time:SetPoint("RIGHT", bar, "RIGHT", -3, 0)
	bar.Time = time
end

-- The hunter's Auto Shot bar. It stands on its own above the player castbar,
-- stays up for the whole fight, and turns red instead of vanishing while the
-- target is out of range, too close or too far, so you can see why a shot is
-- not coming. oUF hides an out of range bar on its own, so this runs after it
-- and puts the bar back. The swing end and combat state are tracked here
-- because oUF keeps its own copy private.
local function AutoShotPostUpdate(bar, event, _, ...)
	if event == "PLAYER_SWING_RANGE_UPDATE" then
		local isInRange, checksRange = ...
		bar.__inRange = not checksRange or isInRange
	elseif event == "PLAYER_SWING" then
		local duration = ...
		if duration and duration > 0 then
			bar.__swingEnd = GetTime() + duration
		end
	elseif event == "PLAYER_IN_COMBAT_CHANGED" then
		bar.__inCombat = (...) and true or false
	else
		bar.__inCombat = UnitAffectingCombat("player") and true or false
	end

	local inRange = bar.__inRange ~= false
	local color = inRange and bar.__color or K.Colors.negative
	bar:SetStatusBarColor(color[1], color[2], color[3])

	if not inRange then
		local swinging = bar.__swingEnd and GetTime() < bar.__swingEnd
		if swinging or (bar.showCombat and bar.__inCombat) then
			bar:Show()
		end
	end
end

local function BuildAutoShot(self, color)
	local db = C.Unitframe.Player
	local width, height = db.AutoShotWidth or 242, db.AutoShotHeight or 12

	local holder = CreateFrame("Frame", nil, UIParent)
	holder:SetSize(width, height)

	-- Off the unit frame and onto its own holder, so it keeps its own alpha and
	-- the mover can place it anywhere.
	local bar = self:CreateSwingElement(Enum.PlayerSwingType.Ranged)
	bar:SetParent(holder)
	bar:SetAllPoints(holder)
	StyleSwingBar(bar, color)
	K.SetFont(bar.Time, 11, K.FontOutlineStyle())
	bar.__color = color
	bar.showCombat = true
	bar.checkRange = true
	bar.PostUpdate = AutoShotPostUpdate

	K.CreateMover(holder, "AutoShot", "Auto Shot", { "BOTTOM", UIParent, "BOTTOM", 0, 226 }, width, height)
	return bar
end

-- Player only. Everything is created through the swing meta element, so a client
-- without the swing API simply gets no bars.
function Build.SwingTimer(self)
	if not (C.Unitframe.Player.SwingTimer and self.CreateSwingElement and Enum.PlayerSwingType) then
		return
	end

	local swing = Enum.PlayerSwingType
	local accent = K.Colors.accent
	local gold = K.Colors.gold or accent

	local main = self:CreateSwingElement(swing.MainHand)
	Module.StackDown(self, main, SWING_HEIGHT)
	StyleSwingBar(main, accent)

	-- Ranged shares the main hand's spot, a swing is one or the other. Hunters
	-- get a bar of their own instead, since Auto Shot is their main attack.
	if K.Class == "HUNTER" and C.Unitframe.Player.AutoShotBar ~= false then
		BuildAutoShot(self, gold)
	else
		local ranged = self:CreateSwingElement(swing.Ranged)
		ranged:SetAllPoints(main)
		StyleSwingBar(ranged, gold)
	end

	if OFF_HAND[K.Class] then
		local off = self:CreateSwingElement(swing.OffHand)
		Module.StackDown(self, off, SWING_OFF_HEIGHT)
		StyleSwingBar(off, accent)
	end
end

-- ---------------------------------------------------------------------------
-- Shaman totems
-- ---------------------------------------------------------------------------

local TOTEM_SIZE = 26
local TOTEM_SLOTS = 4

-- Four icons under the frame, spread across its width. Slots are filled in the
-- element's own priority order, so earth, fire, water and air always land in the
-- same place instead of shuffling as totems are dropped.
function Build.Totems(self)
	if K.Class ~= "SHAMAN" or not C.Unitframe.Player.Totems then
		return
	end

	local holder = CreateFrame("Frame", nil, self)
	Module.StackDown(self, holder, TOTEM_SIZE)

	local totems = {}
	for i = 1, TOTEM_SLOTS do
		local totem = CreateFrame("Button", nil, holder)
		totem:SetSize(TOTEM_SIZE, TOTEM_SIZE)
		totem:SetPoint("LEFT", holder, "LEFT", (i - 1) * (TOTEM_SIZE + Module.GAP), 0)
		K.CreateBackground(totem, 0.06, 0.06, 0.06, 0.9)
		K.CreateBorder(totem)

		local icon = totem:CreateTexture(nil, "ARTWORK")
		icon:SetPoint("TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", -1, 1)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		totem.Icon = icon

		local cooldown = CreateFrame("Cooldown", nil, totem, "CooldownFrameTemplate")
		cooldown:SetAllPoints(icon)
		cooldown:SetHideCountdownNumbers(false)
		K.StyleCooldownSwipe(cooldown)
		totem.Cooldown = cooldown

		totems[i] = totem
	end

	self.TotemHolder = holder
	self.Totems = totems
end

-- ---------------------------------------------------------------------------
-- PvP flag
-- ---------------------------------------------------------------------------

-- The faction or free for all badge beside the portrait, on the outer side so it
-- never covers the frame. oUF picks the art and shows it only while flagged.
function Build.PvPIndicator(self, side)
	local cfg = C.Unitframe[self.mystyle == "player" and "Player" or "Target"]
	if cfg and cfg.PvPIcon == false then
		return
	end

	local anchor = self.Portrait or self.Health
	local icon = self:CreateTexture(nil, "OVERLAY")
	icon:SetSize(26, 26)
	if side == "left" then
		icon:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
	else
		icon:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
	end

	self.PvPIndicator = icon
	return icon
end

-- ---------------------------------------------------------------------------
-- Hunter pet mood
-- ---------------------------------------------------------------------------

-- Happy, content or unhappy, shown on a hunter's pet only. oUF hides it for every
-- other unit and class, so the builder can be called for any pet frame.
function Build.PetHappiness(self)
	if K.Class ~= "HUNTER" or C.Unitframe.Pet.Happiness == false then
		return
	end

	local icon = self.Health:CreateTexture(nil, "OVERLAY")
	icon:SetSize(14, 14)
	icon:SetPoint("RIGHT", self.Health, "RIGHT", -2, 0)

	self.Happiness = icon
	return icon
end
