--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Elements/PowerTick.lua
	Purpose:
		A thin spark that sweeps across the player's power bar and lands on the
		moment the next regen tick is due. Only for mana and energy, whatever the
		class, so a druid gets it as a caster and in cat form, a rogue always, and
		a hunter for as long as the game gives it mana.

		The game has no API that says when the next tick comes, so the tick is
		read from the power events instead. A rise in power that lands on the
		2 second beat of the last tick re-syncs the spark. A rise that does not
		(a potion, a proc, a refund) is ignored, and if three in a row miss the
		beat the anchor was probably a stray gain, so the next one becomes the
		new anchor. Between ticks the spark keeps its beat on its own, which is
		what keeps it right through the mana five second rule and at full energy,
		when no event arrives at all.

		Forever keeps the player's mana secret, so there a rise cannot be read
		from the value. Any power update the player's own casts do not explain
		is taken as the candidate instead, and the same beat rules judge it.

		If regen turns out to be continuous rather than a beat (rises that come
		less than a second apart, over and over), there is no tick to show, so
		the spark steps aside instead of lying.

		The five second rule rides on the same bar. Casting a spell that costs
		mana stops spirit regen for five seconds, so while that runs a gold spark
		sweeps the mana bar over the five seconds with the time left beside it,
		and the tick spark steps aside. Only spells whose cost includes mana start
		it, so a mana drain or burn from an enemy does not.

		Record what it decides with /kkdebug powertick.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")
local Build = Module.Build

local CreateFrame = CreateFrame
local C_Timer = C_Timer
local GetTime = GetTime
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitPower = UnitPower
local UnitPowerType = UnitPowerType
local ipairs = ipairs
local abs = math.abs
local floor = math.floor
local format = string.format
local GetSpellPowerCost = C_Spell.GetSpellPowerCost

local IsSecret = K.IsSecret

-- The beat of the game's regen. Ticks that land this close to a multiple of it
-- count, and the spark's travel time is one beat.
local TICK_INTERVAL = 2
local TOLERANCE = 0.4
-- Past this long without a tick the beat is no longer trusted, so the next rise
-- starts a fresh anchor instead of being judged against a stale one.
local STALE_AFTER = 60
-- Rises closer together than this are not a beat. A run of them means regen is
-- continuous.
local CONTINUOUS_GAP = 1
local CONTINUOUS_RUN = 4
-- Misses in a row before the anchor is thrown away.
local MAX_MISSES = 3

-- The shared spark texture is drawn at its own width, so its core stays 2px.
local SPARK_WIDTH = 16

-- How long spending mana stops spirit regen.
local FIVE_SECOND_RULE = 5

-- Forever keeps the player's current mana secret, even out of combat, so a rise
-- cannot be told from a spend by comparing values. Then every power update is a
-- candidate tick, held this long, and dropped if one of the player's casts lands
-- within it either side. The spend and the cast event can arrive in either order.
local SPEND_WINDOW = 0.25

-- Only these two have a tick worth showing.
local TICKING = { MANA = true, ENERGY = true }

local stream

local function Log(fmt, ...)
	if not stream then
		stream = K.Debug and K.Debug.Register("powertick", "Regen ticks the player power spark accepted or ignored")
	end
	if stream and stream.enabled then
		stream:Log(fmt, ...)
	end
end

-- The spark follows the beat while it has an anchor and the bar has something
-- to say, and costs nothing otherwise because the OnUpdate is removed.
local UpdateShown

local function RuleActive(tick, now)
	return tick.ruleEnd and tick.token == "MANA" and now < tick.ruleEnd
end

local function OnUpdate(driver)
	local tick = driver.tick
	local now = GetTime()
	local width = tick.bar:GetWidth()

	if tick.ruleEnd then
		if RuleActive(tick, now) then
			local left = tick.ruleEnd - now
			tick.ruleSpark:SetPoint("CENTER", tick.bar, "LEFT", (1 - left / FIVE_SECOND_RULE) * width, 0)
			tick.ruleText:SetText(format("%.1f", left))
			return
		end
		-- Over, so the tick spark takes the bar back.
		tick.ruleEnd = nil
		UpdateShown(tick)
		return
	end

	if tick.lastTick then
		local progress = ((now - tick.lastTick) % TICK_INTERVAL) / TICK_INTERVAL
		tick.spark:SetPoint("CENTER", tick.bar, "LEFT", progress * width, 0)
	end
end

function UpdateShown(tick)
	local alive = not UnitIsDeadOrGhost("player")
	local rule = tick.ruleSpark and alive and RuleActive(tick, GetTime()) and true or false
	local show = tick.showTick and tick.enabled and not tick.continuous and tick.lastTick and alive and not rule
	tick.spark:SetShown(show and true or false)
	if tick.ruleSpark then
		tick.ruleSpark:SetShown(rule)
		tick.ruleText:SetShown(rule)
	end
	tick.driver:SetScript("OnUpdate", (show or rule) and OnUpdate or nil)
end

-- True when casting the spell spent mana. Costs tied to a form or aura the
-- player does not have right now are skipped.
local function CostsMana(spellID)
	local costs = spellID and GetSpellPowerCost and GetSpellPowerCost(spellID)
	if not costs then
		return false
	end
	local mana = Enum.PowerType.Mana
	for _, info in ipairs(costs) do
		if info.type == mana and not IsSecret(info.cost) and (info.cost > 0 or (info.costPerSec or 0) > 0) then
			if not info.requiredAuraID or info.requiredAuraID == 0 or info.hasRequiredAura then
				return true
			end
		end
	end
	return false
end

-- Reads the current power type. The anchor survives a change (a druid shifting
-- form keeps the same beat as far as anyone can tell, and the miss rule puts it
-- right if not), but what was learnt about the rise rate does not.
local function RefreshPowerType(tick)
	local powerType, token = UnitPowerType("player")
	tick.powerType = powerType
	tick.token = token
	tick.enabled = TICKING[token] or false
	tick.continuous = false
	tick.fastRun = 0
	tick.misses = 0
	tick.lastRise = nil

	local value = tick.enabled and UnitPower("player", powerType)
	tick.lastValue = (value and not IsSecret(value)) and value or nil
	UpdateShown(tick)
end

local function OnRise(tick, now)
	local gap = tick.lastRise and (now - tick.lastRise)
	tick.lastRise = now

	if gap and gap < CONTINUOUS_GAP then
		tick.fastRun = tick.fastRun + 1
		if tick.fastRun >= CONTINUOUS_RUN then
			tick.continuous = true
			Log("%s regen looks continuous (%d rises under %.1fs apart), spark off", tick.token, tick.fastRun, CONTINUOUS_GAP)
			UpdateShown(tick)
			return
		end
	else
		tick.fastRun = 0
		-- A normal gap means the fast run is over, so the beat is worth showing
		-- again. This rise is judged against the old anchor like any other.
		if tick.continuous then
			tick.continuous = false
			Log("%s regen back to a beat, spark on", tick.token)
		end
	end

	local last = tick.lastTick
	if last then
		local elapsed = now - last
		if elapsed < STALE_AFTER then
			local beats = floor(elapsed / TICK_INTERVAL + 0.5)
			local off = abs(elapsed - beats * TICK_INTERVAL)
			if beats < 1 or off > TOLERANCE then
				tick.misses = tick.misses + 1
				if tick.misses < MAX_MISSES then
					Log("ignored rise, %.2fs after the last tick, %.2fs off the beat (miss %d)", elapsed, off, tick.misses)
					return
				end
				Log("ignored rise %d times running, re-anchoring on this one", tick.misses)
			else
				Log("tick, %.2fs after the last (%d beat%s, %.2fs off)", elapsed, beats, beats == 1 and "" or "s", off)
			end
		else
			Log("first rise after %.0fs, anchoring", elapsed)
		end
	else
		Log("first rise, anchoring")
	end

	tick.misses = 0
	tick.lastTick = now
	UpdateShown(tick)
end

-- Settles a held power update once the spend window has passed. Anything the
-- player cast or channelled near it was the cost going out, not a tick.
local function SettlePending(tick)
	local at = tick.pendingAt
	tick.pendingAt = nil
	if not at or tick.channeling then
		return
	end
	local spent = tick.lastCast
	if spent and abs(spent - at) <= SPEND_WINDOW then
		Log("power update at %.2f was a spend, skipped", at)
		return
	end
	OnRise(tick, at)
end

local function OnEvent(driver, event, unit, token, spellID)
	local tick = driver.tick

	if event == "UNIT_SPELLCAST_SUCCEEDED" or event == "UNIT_SPELLCAST_CHANNEL_START" then
		-- token is the cast GUID here.
		tick.lastCast = GetTime()
		if event == "UNIT_SPELLCAST_CHANNEL_START" then
			tick.channeling = true
		end
		if tick.ruleSpark and CostsMana(spellID) then
			tick.ruleEnd = GetTime() + FIVE_SECOND_RULE
			Log("mana spent, five second rule until %.1f", tick.ruleEnd)
			UpdateShown(tick)
		end
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		tick.channeling = false
		tick.lastCast = GetTime()
	elseif event == "UNIT_POWER_UPDATE" then
		if not tick.enabled or token ~= tick.token then
			return
		end
		local value = UnitPower("player", tick.powerType)
		if IsSecret(value) then
			-- Nothing to compare, so hold it and let the spend window decide.
			tick.lastValue = nil
			if not tick.channeling and not tick.pendingAt then
				tick.pendingAt = GetTime()
				C_Timer.After(SPEND_WINDOW, tick.settle)
			end
			return
		end
		local last = tick.lastValue
		tick.lastValue = value
		if last and value > last then
			OnRise(tick, GetTime())
		end
	elseif event == "UNIT_DISPLAYPOWER" then
		RefreshPowerType(tick)
	elseif event == "PLAYER_ENTERING_WORLD" then
		-- A new zone or a reload restarts the game's regen timer, so the old beat is
		-- no use. The spark waits for the first tick it can see.
		tick.lastTick = nil
		tick.ruleEnd = nil
		RefreshPowerType(tick)
	else
		-- Death, release and resurrection.
		UpdateShown(tick)
	end
end

-- Player only. Hangs the spark on the power bar, so it is gone with the bar when
-- the power bar is switched off.
function Build.PowerTick(self)
	local bar = self.Power
	local db = C.Unitframe.Player
	local showRule = db.FiveSecondRule ~= false
	if not bar or not (db.PowerTick or showRule) then
		return
	end

	local spark = bar:CreateTexture(nil, "OVERLAY", nil, 7)
	spark:SetTexture(C.Media.Textures.Spark)
	spark:SetBlendMode("ADD")
	spark:SetVertexColor(1, 1, 1, 0.8)
	spark:SetSize(SPARK_WIDTH, bar:GetHeight() > 0 and bar:GetHeight() or 16)
	-- One anchor only, moved every frame. The height follows the bar instead of
	-- coming from extra anchors, which would fight the moving one.
	spark:SetPoint("CENTER", bar, "LEFT", 0, 0)
	spark:Hide()
	bar:HookScript("OnSizeChanged", function(_, _, height)
		if height and height > 0 then
			spark:SetHeight(height)
		end
	end)

	local driver = CreateFrame("Frame", nil, bar)
	local tick = { bar = bar, spark = spark, driver = driver, showTick = db.PowerTick and true or false }
	driver.tick = tick
	-- Made once, so a held power update does not build a closure each time.
	tick.settle = function()
		SettlePending(tick)
	end

	if showRule then
		local gold = K.Colors.gold or K.Colors.accent
		local ruleSpark = bar:CreateTexture(nil, "OVERLAY", nil, 7)
		ruleSpark:SetTexture(C.Media.Textures.Spark)
		ruleSpark:SetBlendMode("ADD")
		ruleSpark:SetVertexColor(gold[1], gold[2], gold[3], 1)
		ruleSpark:SetSize(SPARK_WIDTH, spark:GetHeight())
		ruleSpark:SetPoint("CENTER", bar, "LEFT", 0, 0)
		ruleSpark:Hide()
		bar:HookScript("OnSizeChanged", function(_, _, height)
			if height and height > 0 then
				ruleSpark:SetHeight(height)
			end
		end)
		tick.ruleSpark = ruleSpark

		-- The power value sits in the middle, so the seconds go on the left edge.
		local ruleText = bar:CreateFontString(nil, "OVERLAY")
		K.SetFont(ruleText, 10, K.FontOutlineStyle())
		ruleText:SetPoint("LEFT", bar, "LEFT", 3, 0)
		ruleText:SetTextColor(gold[1], gold[2], gold[3])
		ruleText:Hide()
		tick.ruleText = ruleText
	end
	-- Casts feed the five second rule and, with secret mana, tell a spend from a
	-- tick, so they are watched either way.
	driver:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
	driver:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
	driver:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
	driver:SetScript("OnEvent", OnEvent)
	driver:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
	driver:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
	driver:RegisterEvent("PLAYER_ENTERING_WORLD")
	driver:RegisterEvent("PLAYER_DEAD")
	driver:RegisterEvent("PLAYER_ALIVE")
	driver:RegisterEvent("PLAYER_UNGHOST")

	RefreshPowerType(tick)
	bar.PowerTick = tick
end
