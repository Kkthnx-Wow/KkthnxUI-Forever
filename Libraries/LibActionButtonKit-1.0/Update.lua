--[[-----------------------------------------------------------------------------
	LibActionButtonKit-1.0
	File: Update.lua

	Everything the buttons draw. One function per concern, each taking a button
	and reading its slot from the library's own data. Refresh runs them all.

	Secret values (12.x): cooldown and usable results can be secret while the
	game restricts them. They are never compared or used in arithmetic here.
	Cooldowns go through duration objects when the client has them, and a secret
	usable flag is handed to SetVertexColorFromBoolean, which accepts secrets.
-----------------------------------------------------------------------------]]

local Kit = LibStub("LibActionButtonKit-1.0")
if Kit.Update then
	return
end

local pairs, type, next, setmetatable = pairs, type, next, setmetatable
local GetBindingKey, GetBindingText = GetBindingKey, GetBindingText
local CreateColor = CreateColor
local C_Timer = C_Timer

local Update = {}
Kit.Update = Update

local api = Kit.api
local features = Kit.features
local data = Kit.data

local issecretvalue = _G.issecretvalue or function()
	return false
end

local RANGE_INDICATOR = _G.RANGE_INDICATOR or "●"
local FLASH_TIME = _G.ATTACK_BUTTON_FLASH_TIME or 0.4
local MAX_COUNT = 9999

local function SlotOf(button)
	local buttonData = data[button]
	return buttonData and buttonData.slot, buttonData
end

local function HasActionAt(slot)
	return slot and api.HasAction(slot)
end

-- Consumables and stackables show a count and never a macro name.
local function IsStackAction(slot)
	return (api.IsConsumableAction and api.IsConsumableAction(slot))
		or (api.IsStackableAction and api.IsStackableAction(slot))
end

-- ---------------------------------------------------------------------------
-- Icon and visibility
-- ---------------------------------------------------------------------------

-- Empty slots show while dragging, or always with showGrid.
local dragging = false

function Update.Visibility(button)
	local slot, buttonData = SlotOf(button)
	if not buttonData then
		return
	end
	local shown = HasActionAt(slot) or buttonData.options.showGrid or dragging
	button:SetAlpha(shown and 1 or 0)
end

function Update.SetDragging(state)
	dragging = state
	for button in pairs(data) do
		Update.Visibility(button)
	end
end

function Update.Icon(button)
	local slot = SlotOf(button)
	local texture = HasActionAt(slot) and api.GetActionTexture(slot)
	if texture then
		button.icon:SetTexture(texture)
		button.icon:Show()
	else
		button.icon:Hide()
	end
end

-- ---------------------------------------------------------------------------
-- Cooldowns
-- ---------------------------------------------------------------------------

-- Classic style values, from a function that returns either a table (12.x
-- C_ActionBar) or the four loose values (older globals).
local function CooldownValues(slot)
	local start, duration, enabled, modRate = api.GetActionCooldown(slot)
	if type(start) == "table" then
		local info = start
		return info.startTime, info.duration, info.isEnabled, info.modRate
	end
	return start, duration, enabled, modRate
end

local function ClearAll(button)
	button.cooldown:Clear()
	button.chargeCooldown:Clear()
	button.lossOfControlCooldown:Clear()
end

local function CooldownFromDurations(button, slot)
	local duration = api.GetActionCooldownDuration(slot)
	if duration then
		button.cooldown:SetCooldownFromDurationObject(duration)
	else
		button.cooldown:Clear()
	end
	local charge = api.GetActionChargeDuration and api.GetActionChargeDuration(slot)
	if charge then
		button.chargeCooldown:SetCooldownFromDurationObject(charge)
	else
		button.chargeCooldown:Clear()
	end
end

local function CooldownFromValues(button, slot)
	local start, duration, enabled, modRate = CooldownValues(slot)
	if start and duration and enabled ~= false and enabled ~= 0 and duration > 0 then
		button.cooldown:SetCooldown(start, duration, modRate)
	else
		button.cooldown:Clear()
	end

	if api.GetActionCharges then
		local charges, maxCharges, chargeStart, chargeDuration, chargeRate = api.GetActionCharges(slot)
		if type(charges) == "table" then
			local info = charges
			charges, maxCharges = info.currentCharges, info.maxCharges
			chargeStart, chargeDuration, chargeRate = info.cooldownStartTime, info.cooldownDuration, info.chargeModRate
		end
		if charges and maxCharges and maxCharges > 1 and charges < maxCharges and chargeDuration and chargeDuration > 0 then
			button.chargeCooldown:SetCooldown(chargeStart, chargeDuration, chargeRate)
		else
			button.chargeCooldown:Clear()
		end
	end
end

-- 12.x: a duration object, which may hold secret values. Older clients: plain
-- start and duration.
local function LossOfControl(button, slot)
	local loc = button.lossOfControlCooldown
	if api.GetActionLossOfControlCooldownDuration and loc.SetCooldownFromDurationObject then
		local duration = api.GetActionLossOfControlCooldownDuration(slot)
		if duration then
			loc:SetCooldownFromDurationObject(duration)
		else
			loc:Clear()
		end
		return
	end
	if not api.GetActionLossOfControlCooldownInfo then
		return
	end
	local start, duration = api.GetActionLossOfControlCooldownInfo(slot)
	if start and duration and duration > 0 then
		loc:SetCooldown(start, duration)
	else
		loc:Clear()
	end
end

-- While a stun or silence outlasts the action's own cooldown, the game shows only
-- the loss of control swipe in its place. shouldReplaceNormalCooldown is never
-- secret, so this test is safe in combat. Loose-value clients have no such flag.
local function LossOfControlReplaces(slot)
	local info = api.GetActionLossOfControlCooldownInfo and api.GetActionLossOfControlCooldownInfo(slot)
	return type(info) == "table" and info.shouldReplaceNormalCooldown == true
end

function Update.Cooldown(button)
	local slot = SlotOf(button)
	if not HasActionAt(slot) then
		ClearAll(button)
		return
	end
	if LossOfControlReplaces(slot) then
		button.cooldown:Clear()
		button.chargeCooldown:Clear()
	elseif features.durationObjects and button.cooldown.SetCooldownFromDurationObject then
		CooldownFromDurations(button, slot)
	else
		CooldownFromValues(button, slot)
	end
	LossOfControl(button, slot)
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

function Update.Count(button)
	local slot, buttonData = SlotOf(button)
	local count = button.Count
	if not buttonData.options.showCount or not HasActionAt(slot) then
		count:SetText("")
		return
	end
	if api.GetActionDisplayCount then
		-- Already formatted by the game, and may be secret. SetText takes both.
		count:SetText(api.GetActionDisplayCount(slot, MAX_COUNT))
		return
	end
	local reagentCount = api.IsItemAction and not api.IsItemAction(slot) and (api.GetActionCount(slot) or 0) > 0
	if IsStackAction(slot) or reagentCount then
		local value = api.GetActionCount(slot)
		count:SetText(value > MAX_COUNT and "*" or value)
		return
	end
	local charges, maxCharges = api.GetActionCharges and api.GetActionCharges(slot)
	if type(charges) == "table" then
		charges, maxCharges = charges.currentCharges, charges.maxCharges
	end
	count:SetText((maxCharges and maxCharges > 1) and charges or "")
end

function Update.Text(button)
	local slot, buttonData = SlotOf(button)
	local text = ""
	if buttonData.options.showMacroName and HasActionAt(slot) then
		if not IsStackAction(slot) then
			text = api.GetActionText(slot) or ""
		end
	end
	button.Name:SetText(text)
end

function Update.HotKey(button)
	local _, buttonData = SlotOf(button)
	local options = buttonData.options
	local hotkey = button.HotKey
	local key = options.bindingName and GetBindingKey(options.bindingName)
	if key and options.showHotKey then
		hotkey:SetText(GetBindingText(key, true))
		hotkey:Show()
	elseif options.rangeTint == "hotkey" then
		-- No key, so the range dot stands in, shown only when out of range.
		hotkey:SetText(RANGE_INDICATOR)
		hotkey:SetShown(buttonData.inRange == false)
	else
		hotkey:SetText("")
		hotkey:Hide()
	end
end

-- ---------------------------------------------------------------------------
-- Tint: usable, power and range
-- ---------------------------------------------------------------------------

-- Color objects by the host's rgb table. Weak keys, because a host may build new
-- option tables on every settings change and the old ones must be free to go.
local colorCache = setmetatable({}, { __mode = "k" })
local function AsColor(rgb)
	local color = colorCache[rgb]
	if not color then
		color = CreateColor(rgb[1], rgb[2], rgb[3])
		colorCache[rgb] = color
	end
	return color
end
local WHITE = CreateColor(1, 1, 1)

-- One place decides the icon colour, so range and usable never fight. Out of
-- range wins over everything when rangeTint is "icon".
function Update.Tint(button)
	local slot, buttonData = SlotOf(button)
	if not HasActionAt(slot) then
		return
	end
	local options = buttonData.options
	local colors = options.colors
	local icon = button.icon

	local hotkey = button.HotKey
	if options.rangeTint == "hotkey" then
		local rgb = buttonData.inRange == false and colors.range or nil
		if rgb then
			hotkey:SetVertexColor(rgb[1], rgb[2], rgb[3])
		else
			hotkey:SetVertexColor(1, 1, 1)
		end
	end

	if options.rangeTint == "icon" and buttonData.inRange == false then
		local rgb = colors.range
		icon:SetVertexColor(rgb[1], rgb[2], rgb[3])
		return
	end

	local usable, noMana = buttonData.usable, buttonData.noMana
	if usable == nil then
		usable, noMana = api.IsUsableAction(slot)
	end

	if issecretvalue(usable) or issecretvalue(noMana) then
		if icon.SetVertexColorFromBoolean then
			icon:SetVertexColorFromBoolean(usable, WHITE, AsColor(colors.unusable))
		end
		return
	end

	if usable then
		icon:SetVertexColor(1, 1, 1)
	elseif noMana then
		local rgb = colors.mana
		icon:SetVertexColor(rgb[1], rgb[2], rgb[3])
	else
		local rgb = colors.unusable
		icon:SetVertexColor(rgb[1], rgb[2], rgb[3])
	end
end

-- From ACTION_USABLE_CHANGED (values given) or a full refresh (values nil, so
-- the game is asked).
function Update.Usable(button, usable, noMana)
	local _, buttonData = SlotOf(button)
	buttonData.usable, buttonData.noMana = usable, noMana
	Update.Tint(button)
end

-- inRange: true, false, or nil for an action without a range.
function Update.Range(button, inRange)
	local _, buttonData = SlotOf(button)
	if buttonData.inRange == inRange then
		return
	end
	buttonData.inRange = inRange
	if buttonData.options.rangeTint == "hotkey" then
		-- The range dot shows or hides with the answer.
		Update.HotKey(button)
	end
	Update.Tint(button)
end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

function Update.Checked(button)
	local slot = SlotOf(button)
	if HasActionAt(slot) then
		button:SetChecked(api.IsCurrentAction(slot) or api.IsAutoRepeatAction(slot))
	else
		button:SetChecked(false)
	end
end

function Update.Equipped(button)
	local slot = SlotOf(button)
	button.Border:SetShown(HasActionAt(slot) and api.IsEquippedAction(slot) and true or false)
end

-- Attack and auto repeat flash. One shared ticker runs only while something is
-- flashing.
local flashing = {}
local flashTicker
local flashOn = false

local function FlashTick()
	flashOn = not flashOn
	for button in pairs(flashing) do
		button.Flash:SetShown(flashOn)
	end
end

function Update.Flash(button)
	local slot = SlotOf(button)
	local should = HasActionAt(slot)
		and ((api.IsAttackAction(slot) and api.IsCurrentAction(slot)) or api.IsAutoRepeatAction(slot))
	if should then
		flashing[button] = true
		if not flashTicker then
			flashTicker = C_Timer.NewTicker(FLASH_TIME, FlashTick)
		end
	else
		flashing[button] = nil
		button.Flash:Hide()
		if flashTicker and not next(flashing) then
			flashTicker:Cancel()
			flashTicker = nil
		end
	end
end

-- ---------------------------------------------------------------------------
-- Proc glow
-- ---------------------------------------------------------------------------

local IsSpellOverlayed = (C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed) or _G.IsSpellOverlayed

local FlyoutHasSpell = (C_Flyout and C_Flyout.FlyoutHasSpell) or _G.FlyoutHasSpell

-- The spell an action casts, for matching proc events. For a macro that casts a
-- spell, GetActionInfo already returns that spell's id with subType "spell", the
-- same value the game's own buttons compare against.
local function SpellOf(slot)
	local actionType, id, subType = api.GetActionInfo(slot)
	if actionType == "spell" then
		return id
	elseif actionType == "macro" and subType == "spell" then
		return id
	end
end

-- A flyout glows when any spell inside it procs, as the game's own buttons do.
local function FlyoutProcs(slot, spellID)
	local actionType, id = api.GetActionInfo(slot)
	return actionType == "flyout" and FlyoutHasSpell and FlyoutHasSpell(id, spellID) and true or false
end

-- The library does not draw a glow. It tracks the state and fires GlowShown and
-- GlowHidden so the host draws it in its own style. Called with spellID and
-- shown from the proc events, or with nothing on refresh to sync the state.
function Update.Glow(button, spellID, shown)
	local slot, buttonData = SlotOf(button)
	local actionSpell = HasActionAt(slot) and SpellOf(slot)
	local glowing
	if spellID then
		if actionSpell ~= spellID and not (HasActionAt(slot) and FlyoutProcs(slot, spellID)) then
			return
		end
		glowing = shown
	else
		glowing = actionSpell and IsSpellOverlayed and IsSpellOverlayed(actionSpell) or false
	end
	glowing = glowing and true or false
	if buttonData.glowing ~= glowing then
		buttonData.glowing = glowing
		Kit:Fire(glowing and "GlowShown" or "GlowHidden", button)
	end
end

-- ---------------------------------------------------------------------------
-- Flyout arrow
-- ---------------------------------------------------------------------------

-- Edge, offset and turn for each direction the bar's flyouts open. The turn is
-- from pointing up, and the art's own baseTurn (set in Button.lua) is added on.
-- The arrow is centred on the edge so it sits half over the border.
local ARROW = {
	UP = { "TOP", 0, 0, 0 },
	DOWN = { "BOTTOM", 0, 0, math.pi },
	LEFT = { "LEFT", 0, 0, math.pi / 2 },
	RIGHT = { "RIGHT", 0, 0, -math.pi / 2 },
}

function Update.FlyoutArrow(button)
	local slot, buttonData = SlotOf(button)
	local arrow = button.FlyoutArrow
	local isFlyout = HasActionAt(slot) and api.GetActionInfo(slot) == "flyout"
	if not isFlyout then
		arrow:Hide()
		return
	end
	local place = ARROW[buttonData.bar:GetAttribute("kit-flyoutdir") or "UP"] or ARROW.UP
	arrow:ClearAllPoints()
	arrow:SetPoint("CENTER", button, place[1], place[2], place[3])
	arrow:SetRotation(place[4] + (arrow.baseTurn or 0))
	arrow:Show()
end

-- ---------------------------------------------------------------------------
-- Everything
-- ---------------------------------------------------------------------------

function Update.Refresh(button)
	if not data[button] then
		return
	end
	Update.Icon(button)
	Update.Visibility(button)
	Update.Cooldown(button)
	Update.Count(button)
	Update.Text(button)
	Update.HotKey(button)
	Update.Usable(button)
	Update.Checked(button)
	Update.Flash(button)
	Update.Equipped(button)
	Update.Glow(button)
	Update.FlyoutArrow(button)
	Kit:Fire("ButtonUpdated", button)
end

-- Redraw every button, for hosts after a settings change.
function Kit:RefreshAll()
	for button in pairs(data) do
		Update.Refresh(button)
	end
end
