--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/SwingTimer.lua
	Purpose:
		Main hand, off hand and ranged swing bars, each with its own mover and
		its own settings. Built on the same game API as the Blizzard swing timer
		(PLAYER_SWING, C_SwingTimer) and the same rules for when a bar applies:
		a bar only exists while its weapon does, a weapon swap restarts the
		swing, and an out of range bar dims once its swing has finished.

		What it adds over the stock bars:
		  The fill and the countdown are handed to the engine through a duration
		  object, so nothing runs per frame. The stock bars poll on OnUpdate.
		  A haste change partway through a swing stretches or shrinks the rest
		  of it, where the stock bars keep the old length until the next swing.
		  Visibility has a "while swinging" mode, and "in combat" keeps a swing
		  that is still running when combat drops.
		  Per bar colour, fill or drain, and a range dim that can be tuned.

		The Blizzard swing timer setting is left alone. It is off by default.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("SwingTimer")

local _G = _G
local ipairs = ipairs
local CreateFrame = CreateFrame
local GetInventoryItemTexture = GetInventoryItemTexture
local GetTime = GetTime
local UIParent = UIParent
local UnitAffectingCombat = UnitAffectingCombat
local UnitAttackSpeed = UnitAttackSpeed
local C_DurationUtil = C_DurationUtil
local C_StringUtil = C_StringUtil
local C_SwingTimer = C_SwingTimer
local C_Timer = C_Timer
local Enum = Enum
local IsSecret = K.IsSecret

-- Mover keys and slots, top to bottom. The ranged bar keeps the old Auto Shot
-- mover key, so a hunter's saved spot carries over. Default spots are worked out
-- in DefaultSpots.
local BARS = {
	{ key = "MainHand", mover = "SwingMainHand", label = _G.SWING_TIMER_MAIN_HAND or L["Main Hand"], slot = _G.INVSLOT_MAINHAND or 16 },
	{ key = "OffHand", mover = "SwingOffHand", label = _G.SWING_TIMER_OFF_HAND or L["Off Hand"], slot = _G.INVSLOT_OFFHAND or 17 },
	{ key = "Ranged", mover = "AutoShot", label = _G.SWING_TIMER_RANGED or L["Ranged"], slot = _G.INVSLOT_RANGED or 18 },
}

-- The UI's one spacing step, the same 6px the unit frames and the cast bar use
-- between pieces. It separates the bars and each bar from its icon.
local GAP = 6
-- The player castbar's default bottom edge (Units/Player.lua). The bars stack
-- from one gap above its top.
local CASTBAR_Y = 190

-- Default mover spots. The bars stack up from the player castbar, ranged lowest,
-- one gap apart at whatever heights are set, centred on the screen.
local function DefaultSpots()
	local swing = C.Unitframe.Swing
	local cast = C.Unitframe.Castbar
	local y = CASTBAR_Y + (cast and cast.PlayerHeight or 28) + GAP
	for i = #BARS, 1, -1 do
		local info = BARS[i]
		info.y = y
		y = y + swing[info.key].Height + GAP
	end
end

local bars = {} -- swing type -> bar
local inCombat = false
local formatter

-- /kk swingtest state. While on, every bar shows and swings on a loop at its
-- weapon's speed (or a stand-in speed with no weapon), and real swings are
-- ignored so the two never fight over a bar. The generation number retires the
-- restart callbacks of an earlier test run.
local testing = false
local testGeneration = 0
local TEST_SPEED = { MainHand = 2.6, OffHand = 1.8, Ranged = 3.0 }
local TEST_PAUSE = 0.6
local TEST_ICON = 134400 -- the question mark, for a slot with nothing in it

-- ---------------------------------------------------------------------------
-- Weapon state
-- ---------------------------------------------------------------------------

-- Attack speed of the bar's weapon, or nil when it has none. The main hand always
-- swings, a fist counts. A secret speed is treated as unknown.
local function EquippedSpeed(bar)
	local main, off, ranged = UnitAttackSpeed("player")
	local speed
	if bar.swingType == Enum.PlayerSwingType.OffHand then
		speed = off
	elseif bar.swingType == Enum.PlayerSwingType.Ranged then
		speed = ranged
	else
		speed = main
	end
	if speed == nil or IsSecret(speed) or speed <= 0 then
		return nil
	end
	return speed
end

local function HasWeapon(bar)
	if bar.swingType == Enum.PlayerSwingType.MainHand then
		return true
	end
	return EquippedSpeed(bar) ~= nil
end

-- ---------------------------------------------------------------------------
-- Presentation
-- ---------------------------------------------------------------------------

local function ShouldShow(bar)
	if testing then
		return true
	end
	local mode = bar.db.Visibility
	if mode == "hidden" or not HasWeapon(bar) then
		return false
	elseif mode == "always" then
		return true
	elseif mode == "combat" then
		-- A swing still running as combat drops is seen to its end.
		return inCombat or bar.swinging
	end
	return bar.swinging
end

-- Dim and redden a bar whose target is out of reach. Like the stock bars this
-- waits for a running swing to finish, so a swing that already left is not
-- shown as failing.
local function ApplyRange(bar)
	local out = bar.outOfRange and not bar.swinging
	local alpha = out and Module.rangeAlpha or 1
	bar.status:SetAlpha(alpha)
	bar.bg:SetAlpha(alpha)
	bar.iconHolder:SetAlpha(alpha)
	local color = out and K.Colors.negative or K.Colors.text
	bar.title:SetTextColor(color[1], color[2], color[3])
	bar.time:SetTextColor(color[1], color[2], color[3])
end

-- The icon of whatever sits in the bar's slot. An empty main hand (unarmed) has
-- no item and so no icon, and the slot is hidden rather than left blank.
local function UpdateIcon(bar)
	local texture = Module.showIcon and GetInventoryItemTexture("player", bar.slot) or nil
	if testing and Module.showIcon and not texture then
		texture = TEST_ICON
	end
	bar.icon:SetTexture(texture)
	bar.iconHolder:SetShown(texture ~= nil)
end

local function Refresh(bar)
	bar.holder:SetShown(ShouldShow(bar))
	ApplyRange(bar)
end

-- ---------------------------------------------------------------------------
-- Swing lifecycle
-- ---------------------------------------------------------------------------

local function Idle(bar)
	bar.swinging = false
	bar.status:SetMinMaxValues(0, 1)
	bar.status:SetValue(Module.direction == Enum.StatusBarTimerDirection.RemainingTime and 1 or 0)
	bar.time:SetText("")
	if bar.spark then
		bar.spark:Hide()
	end
end

-- Hand the duration to the bar, the countdown text and the one shot that ends
-- the swing. The end timer is cancelled and replaced, so a swing that restarts
-- early is never ended by the old one.
local function Arm(bar, remaining)
	bar.status:SetTimerDuration(bar.duration, Enum.StatusBarInterpolation.Immediate, Module.direction)
	bar.binding:SetDuration(bar.duration)
	if bar.endTimer then
		bar.endTimer:Cancel()
	end
	bar.endTimer = C_Timer.NewTimer(remaining, bar.OnSwingEnd)
end

local function StartSwing(bar, swingDuration)
	if swingDuration == nil or IsSecret(swingDuration) or swingDuration <= 0 then
		return
	end
	bar.duration:SetTimeFromStart(GetTime(), swingDuration)
	bar.swinging = true
	Arm(bar, swingDuration)
	if bar.spark then
		bar.spark:Show()
	end
	Refresh(bar)
end

-- Attack speed changed partway through a swing. The part already done stays
-- done and the rest is stretched or shrunk to the new speed, so a haste proc
-- moves the end of the current swing instead of waiting for the next one.
local function Rescale(bar)
	if not bar.swinging then
		return
	end
	local speed = EquippedSpeed(bar)
	local total = bar.duration:GetTotalDuration()
	if not speed or IsSecret(total) or total <= 0 then
		return
	end
	local delta = speed - total
	if delta < 0.001 and delta > -0.001 then
		return
	end
	local done = bar.duration:GetElapsedDuration() / total
	if done >= 1 then
		return
	end
	local now = GetTime()
	bar.duration:SetTimeFromStart(now - done * speed, speed)
	Arm(bar, (1 - done) * speed)
end

-- ---------------------------------------------------------------------------
-- Range checks
-- ---------------------------------------------------------------------------

-- The game only sends range updates for swing types that asked for them, so a
-- bar asks only while it can show something.
local function UpdateRangeCheck(bar)
	local want = Module.rangeCheck and bar.db.Visibility ~= "hidden" and HasWeapon(bar) or false
	if want ~= bar.rangeOn then
		bar.rangeOn = want
		C_SwingTimer.EnableRangeCheck(bar.swingType, want)
	end
	if not want then
		bar.outOfRange = false
	end
end

local function ReadRange(bar)
	if not bar.rangeOn then
		bar.outOfRange = false
		return
	end
	-- nil means no check could be made (no target, nothing to hit), and the game
	-- says that must not be read as out of range.
	local inRange = C_SwingTimer.IsTargetWithinSwingRange(bar.swingType)
	bar.outOfRange = inRange ~= nil and not IsSecret(inRange) and inRange == false
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function Module:PLAYER_SWING(_, swingDuration, swingType)
	local bar = bars[swingType]
	if bar and not testing and bar.db.Visibility ~= "hidden" then
		StartSwing(bar, swingDuration)
	end
end

function Module:PLAYER_SWING_RANGE_UPDATE(_, swingType, isInRange, checksRange)
	local bar = bars[swingType]
	if not bar then
		return
	end
	if IsSecret(isInRange) or IsSecret(checksRange) then
		bar.outOfRange = false
	else
		bar.outOfRange = checksRange and not isInRange or false
	end
	ApplyRange(bar)
end

function Module:PLAYER_TARGET_CHANGED()
	for _, bar in ipairs(self.list) do
		ReadRange(bar)
		ApplyRange(bar)
	end
end

function Module:PLAYER_IN_COMBAT_CHANGED(_, combat)
	if IsSecret(combat) then
		combat = UnitAffectingCombat("player")
	end
	inCombat = combat and true or false
	for _, bar in ipairs(self.list) do
		Refresh(bar)
	end
end

-- A swapped weapon starts its swing over at its own speed, the same as the stock
-- bars, and a bar whose weapon is gone is cleared.
function Module:WEAPON_SLOT_CHANGED()
	for _, bar in ipairs(self.list) do
		UpdateRangeCheck(bar)
		UpdateIcon(bar)
		if bar.swinging and not testing then
			local speed = EquippedSpeed(bar)
			if speed then
				StartSwing(bar, speed)
			else
				if bar.endTimer then
					bar.endTimer:Cancel()
					bar.endTimer = nil
				end
				Idle(bar)
			end
		end
		Refresh(bar)
	end
end

-- Covers the weapon list on login and haste changes in a fight. The stock code
-- notes WEAPON_SLOT_CHANGED is not reliable on entering the world.
function Module:UNIT_ATTACK_SPEED()
	for _, bar in ipairs(self.list) do
		UpdateRangeCheck(bar)
		if self.hasteAdjust then
			Rescale(bar)
		end
		Refresh(bar)
	end
end

-- Weapons can arrive after the world loads, and the stock code leans on this
-- event for that reason. Only the weapon list is read again, no swing changes.
function Module:UNIT_INVENTORY_CHANGED()
	for _, bar in ipairs(self.list) do
		UpdateRangeCheck(bar)
		UpdateIcon(bar)
		Refresh(bar)
	end
end

function Module:PLAYER_ENTERING_WORLD()
	inCombat = UnitAffectingCombat("player") and true or false
	for _, bar in ipairs(self.list) do
		UpdateRangeCheck(bar)
		ReadRange(bar)
		UpdateIcon(bar)
		Refresh(bar)
	end
end

-- ---------------------------------------------------------------------------
-- Test mode
-- ---------------------------------------------------------------------------

-- A test swing ended. Pause, then swing again. Every other pause shows the out
-- of range dim, so the dim can be checked without a target.
local function TestNext(bar)
	local generation = testGeneration
	bar.testCycle = (bar.testCycle or 0) + 1
	bar.outOfRange = bar.testCycle % 2 == 0
	ApplyRange(bar)
	C_Timer.After(TEST_PAUSE, function()
		if testing and generation == testGeneration then
			bar.outOfRange = false
			StartSwing(bar, EquippedSpeed(bar) or TEST_SPEED[bar.key])
		end
	end)
end

-- /kk swingtest. Shows all three bars swinging on a loop, with their icons,
-- spark, colours, text and range dim, so a change can be watched without a
-- fight. Run it again to stop. Works with any bar's visibility setting.
function Module:ToggleTest()
	if not self.list then
		K.Print(L["Swing bars are turned off."])
		return
	end
	testing = not testing
	testGeneration = testGeneration + 1
	for _, bar in ipairs(self.list) do
		if bar.endTimer then
			bar.endTimer:Cancel()
			bar.endTimer = nil
		end
		bar.testCycle = 0
		Idle(bar)
		UpdateIcon(bar)
		if testing then
			bar.outOfRange = false
			StartSwing(bar, EquippedSpeed(bar) or TEST_SPEED[bar.key])
		else
			ReadRange(bar)
			Refresh(bar)
		end
	end
	K.Print(testing and L["Swing bar test on. Type /kk swingtest again to stop."] or L["Swing bar test off."])
end

-- ---------------------------------------------------------------------------
-- Building and settings
-- ---------------------------------------------------------------------------

local function Build(info, swingType)
	local holder = CreateFrame("Frame", "KKUI_Swing" .. info.key, UIParent)
	holder:SetFrameStrata("LOW")

	-- The bar takes the holder's right side. With the icon on, the holder is wider
	-- by one icon and one gap, so bar and icon stay centred as one piece the way
	-- the castbar is. With it off the bar fills the holder. ApplySettings sizes it.
	local status = CreateFrame("StatusBar", nil, holder)
	status:SetPoint("TOPRIGHT", holder, "TOPRIGHT", 0, 0)
	status:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
	K.CreateBorder(status)

	local bg = status:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	bg:SetColorTexture(K.Colors.voidDark[1], K.Colors.voidDark[2], K.Colors.voidDark[3], 0.8)

	-- A font has to be set before any text. ApplySettings sizes it afterwards.
	local title = status:CreateFontString(nil, "OVERLAY")
	K.SetFont(title, 11, K.FontOutlineStyle())
	title:SetPoint("LEFT", status, "LEFT", 4, 0)
	title:SetJustifyH("LEFT")
	title:SetText(info.label)

	local time = status:CreateFontString(nil, "OVERLAY")
	K.SetFont(time, 11, K.FontOutlineStyle())
	time:SetPoint("RIGHT", status, "RIGHT", -4, 0)
	time:SetJustifyH("RIGHT")

	-- The weapon icon in its own square slot on the holder's left, styled like the
	-- cast bar's spell icon. ApplySettings sizes it.
	local iconHolder = CreateFrame("Frame", nil, holder)
	iconHolder:SetPoint("LEFT", holder, "LEFT", 0, 0)
	K.CreateBackground(iconHolder, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.9)
	K.CreateBorder(iconHolder)
	local icon = iconHolder:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", iconHolder, "TOPLEFT", 1, -1)
	icon:SetPoint("BOTTOMRIGHT", iconHolder, "BOTTOMRIGHT", -1, 1)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local bar = {
		key = info.key,
		slot = info.slot,
		swingType = swingType,
		holder = holder,
		status = status,
		bg = bg,
		title = title,
		time = time,
		iconHolder = iconHolder,
		icon = icon,
		duration = C_DurationUtil.CreateDuration(),
		binding = C_DurationUtil.CreateDurationTextBinding(),
		swinging = false,
		outOfRange = false,
		rangeOn = false,
	}
	bar.binding:SetFormatter(formatter)
	bar.binding:SetFontString(time)
	bar.binding:SetEnabled(true)
	-- Made once per bar, so arming a swing never builds a closure.
	bar.OnSwingEnd = function()
		bar.endTimer = nil
		Idle(bar)
		if testing then
			TestNext(bar)
		end
		ApplyRange(bar)
		bar.holder:SetShown(ShouldShow(bar))
	end

	local db = C.Unitframe.Swing[info.key]
	bar.db = db
	local width = db.Width + (C.Unitframe.Swing.Icon ~= false and db.Height + GAP or 0)
	K.CreateMover(holder, info.mover, info.label .. " " .. L["Swing"], { "BOTTOM", UIParent, "BOTTOM", 0, info.y }, width, db.Height)
	return bar
end

-- Everything that can change without a reload. Called on enable and from the
-- options panel.
function Module:ApplySettings()
	if not self.list then
		return
	end
	local db = C.Unitframe.Swing
	self.direction = db.Drain and Enum.StatusBarTimerDirection.RemainingTime or Enum.StatusBarTimerDirection.ElapsedTime
	self.rangeCheck = db.RangeCheck
	self.rangeAlpha = db.RangeAlpha
	self.hasteAdjust = db.HasteAdjust
	self.showIcon = db.Icon ~= false

	local texture = K.GetTexture(C.Unitframe.Texture)
	for _, bar in ipairs(self.list) do
		local bdb = bar.db
		-- The icon slot is kept while the option is on, even when the slot is empty
		-- (unarmed), so a weapon swap never shifts the bar sideways.
		local width = bdb.Width + (self.showIcon and bdb.Height + GAP or 0)
		bar.holder:SetSize(width, bdb.Height)
		bar.holder:SetScale(bdb.Scale)
		bar.holder:SetAlpha(bdb.Alpha)
		bar.status:SetWidth(bdb.Width)
		local mover = bar.holder.KKUI_Mover
		if mover then
			mover:SetSize(width * bdb.Scale, bdb.Height * bdb.Scale)
		end

		bar.status:SetStatusBarTexture(texture)
		local color = bdb.Color
		bar.status:SetStatusBarColor(color[1], color[2], color[3])

		local fontSize = bdb.Height >= 14 and 11 or 9
		K.SetFont(bar.title, fontSize, K.FontOutlineStyle())
		K.SetFont(bar.time, fontSize, K.FontOutlineStyle())
		bar.title:SetShown(bdb.ShowTitle)
		bar.time:SetShown(bdb.ShowTime)

		bar.iconHolder:SetSize(bdb.Height, bdb.Height)
		UpdateIcon(bar)

		-- Pinned to the fill's top and bottom edges, so the spark is exactly as tall
		-- as the fill at any bar height and never pokes out over the border.
		if db.Spark and not bar.spark then
			local spark = bar.status:CreateTexture(nil, "OVERLAY")
			spark:SetTexture(C.Media.Textures.Spark)
			spark:SetBlendMode("ADD")
			local fill = bar.status:GetStatusBarTexture()
			spark:SetPoint("TOP", fill, "TOPRIGHT", 0, 0)
			spark:SetPoint("BOTTOM", fill, "BOTTOMRIGHT", 0, 0)
			bar.spark = spark
		end
		if bar.spark then
			bar.spark:SetWidth(16)
			bar.spark:SetShown(db.Spark and bar.swinging)
		end

		if not bar.swinging then
			Idle(bar)
		end
		UpdateRangeCheck(bar)
		ReadRange(bar)
		Refresh(bar)
	end
end

function Module:OnEnable()
	local db = C.Unitframe.Swing
	if not (db and db.Enable) then
		return
	end
	-- Only a client with the swing API gets bars.
	if not (C_SwingTimer and C_DurationUtil and Enum.PlayerSwingType) then
		return
	end

	formatter = C_StringUtil.CreateSecondsFormatter()
	formatter:SetDefaultAbbreviation(Enum.SecondsFormatterAbbreviation.None)
	formatter:SetMinInterval(Enum.SecondsFormatterInterval.Seconds)
	-- Under a minute reads as "1.8", the way the stock bars count.
	formatter:SetMillisecondsThreshold(60)

	self.list = {}
	DefaultSpots()
	for _, info in ipairs(BARS) do
		local swingType = Enum.PlayerSwingType[info.key]
		local bar = Build(info, swingType)
		bars[swingType] = bar
		self.list[#self.list + 1] = bar
	end

	self:ApplySettings()

	self:RegisterEvent("PLAYER_SWING")
	self:RegisterEvent("PLAYER_SWING_RANGE_UPDATE")
	self:RegisterEvent("PLAYER_TARGET_CHANGED")
	self:RegisterEvent("PLAYER_IN_COMBAT_CHANGED")
	self:RegisterEvent("WEAPON_SLOT_CHANGED")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterUnitEvent("UNIT_ATTACK_SPEED", nil, "player")
	self:RegisterUnitEvent("UNIT_INVENTORY_CHANGED", nil, "player")
	self:PLAYER_ENTERING_WORLD()
end
