--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/Bars.lua
	Purpose:
		Bar creation, grid layout, paging, and mouseover fade. Each bar always
		spawns 12 library buttons once. UpdateBar then lays out and shows only the
		configured count, applies size/spacing/opacity, and refreshes button
		config live. This keeps count and size changes working out of combat
		without recreating secure frames.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("ActionBars")

local ceil = math.ceil
local floor = math.floor
local format = string.format
local select = select
local InCombatLockdown = InCombatLockdown
local ClearOverrideBindings = ClearOverrideBindings
local SetOverrideBindingClick = SetOverrideBindingClick
local GetBindingKey = GetBindingKey

-- Mirrors Blizzard's own paging. Its order of precedence is a vehicle or
-- override bar, a temporary shapeshift bar, the page chosen by hand, and only
-- then the bonus bar of a form or stance, which applies on page 1 alone. The
-- override, vehicle and shapeshift page numbers are read from the client the
-- way Blizzard's own controller reads them, not hardcoded.
--
-- A form only gets a page here if the game really gives it one. Many forms and
-- stances have no bonus bar at all, and paging to a page nothing lives on would
-- leave the bar looking empty. The starting table is for the classes known to
-- have them, and anything else the game reports is learned and kept (see
-- LearnBonusBars), so no form is guessed at.
local STARTING_BONUS_PAGES = {
	DRUID = { [1] = 7, [3] = 9, [4] = 10 },
	ROGUE = { [1] = 7 },
	-- Battle, Defensive, Berserker. Battle Stance read live as offset 1, page 7.
	-- Learning only runs out of combat, so without these a first stance dance
	-- in a fight stayed on page 1.
	WARRIOR = { [1] = 7, [2] = 8, [3] = 9 },
}

local function BonusPages()
	local pages = {}
	for offset, page in pairs(STARTING_BONUS_PAGES[K.Class] or {}) do
		pages[offset] = page
	end
	-- What the game has reported for this class, on top of the starting table.
	local learned = K.DB and K.DB.bonusBarPages and K.DB.bonusBarPages[K.Class]
	if learned then
		for offset, page in pairs(learned) do
			pages[offset] = page
		end
	end
	return pages
end

local function GetPageDriver()
	local override = C_ActionBar.GetOverrideBarIndex()
	local vehicle = C_ActionBar.GetVehicleBarIndex()
	local shapeshift = C_ActionBar.GetTempShapeshiftBarIndex()

	local parts = {
		format("[overridebar] %d", override),
		format("[vehicleui][possessbar] %d", vehicle),
		format("[shapeshift] %d", shapeshift),
	}
	for page = 2, 6 do
		parts[#parts + 1] = format("[bar:%d] %d", page, page)
	end

	local pages = BonusPages()
	local offsets = {}
	for offset in pairs(pages) do
		offsets[#offsets + 1] = offset
	end
	table.sort(offsets)
	for _, offset in ipairs(offsets) do
		-- Prowl and plain cat form share a page, so one clause covers both.
		parts[#parts + 1] = format("[bonusbar:%d] %d", offset, pages[offset])
	end

	parts[#parts + 1] = "1"
	return table.concat(parts, "; ")
end

local MAX_BUTTONS = 12

-- ---------------------------------------------------------------------------
-- Creation
-- ---------------------------------------------------------------------------

-- Create a bar with all 12 buttons. Layout and visibility come from UpdateBar.
function Module:CreateBar(def)
	local cfg = C.ActionBar[def.key]
	if not cfg or not cfg.Enable then
		return
	end

	local barName = "KKUI_ActionBar_" .. def.key
	local bar = CreateFrame("Frame", barName, UIParent, "SecureHandlerStateTemplate")
	bar.key = def.key
	bar.bindName = def.bindName
	bar.buttons = {}

	for i = 1, MAX_BUTTONS do
		local options = self:GetButtonOptions(def.key, def.bindName and (def.bindName .. i))
		local button = self.Kit:CreateButton(bar, i, format("%sButton%d", barName, i), options)
		self:StyleButton(button)
		bar.buttons[i] = button
		self.buttons[#self.buttons + 1] = button
	end

	self.bars[def.key] = bar
	return bar
end

-- ---------------------------------------------------------------------------
-- Layout / live update
-- ---------------------------------------------------------------------------

-- The "cast on key press" choice for our buttons. "Default" hands it back to the
-- game's own setting. An older boolean in a saved profile still counts.
function Module:GetKeyDownSetting()
	local value = C.ActionBar.KeyDown
	if value == "Press" or value == true then
		return true
	elseif value == "Release" or value == false then
		return false
	end
	return nil
end

-- The pet, stance and possess bars reuse Blizzard's own buttons instead of
-- library ones, so each lays itself out through its own function.
local AUX_LAYOUT = { PetBar = "LayoutPetBar", StanceBar = "LayoutStanceBar", PossessBar = "LayoutPossessBar" }

-- Grid layout shared by those three. `shown` is how many buttons are in use, which
-- decides the footprint, while every button keeps its own grid slot. The mover
-- follows the footprint. Moves protected buttons, so out of combat only.
function Module:LayoutAuxGrid(bar, cfg, shown)
	local size, space, perRow = cfg.Size, cfg.Space, cfg.PerRow
	shown = shown or #bar.buttons
	local rows = shown > 0 and ceil(shown / perRow) or 1
	local cols = shown > 0 and (shown < perRow and shown or perRow) or 1
	bar:SetSize(cols * size + (cols - 1) * space, rows * size + (rows - 1) * space)

	for i, button in ipairs(bar.buttons) do
		button:SetSize(size, size)
		local col = (i - 1) % perRow
		local row = floor((i - 1) / perRow)
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", bar, "TOPLEFT", col * (size + space), -row * (size + space))
	end

	local mover = bar.KKUI_Mover
	if mover then
		mover:SetSize(bar:GetWidth(), bar:GetHeight())
	end
end

-- Hotkey text on the stock buttons, shown or hidden from the bar's own setting.
-- Alpha rather than Hide, since the stock code shows and hides these itself.
function Module:ApplyAuxHotKeys(bar, cfg)
	local alpha = cfg.HotKey and 1 or 0
	for _, button in ipairs(bar.buttons) do
		local name = button:GetName()
		local hotkey = button.HotKey or (name and _G[name .. "HotKey"])
		if hotkey then
			hotkey:SetAlpha(alpha)
		end
	end
end

-- Re-lay a bar from its current config. Safe to call any time out of combat.
function Module:UpdateBar(key)
	local bar = self.bars[key]
	local cfg = C.ActionBar[key]
	if not bar or not cfg then
		return
	end
	if InCombatLockdown() then
		self:QueueCombatUpdate(key)
		return
	end

	local aux = AUX_LAYOUT[key]
	if aux then
		self[aux](self)
		self:ApplyAuxHotKeys(bar, cfg)
		self:SetupFade(bar, cfg)
		return
	end

	local size = cfg.Size
	local space = cfg.Space
	local perRow = cfg.PerRow
	local count = cfg.Buttons
	local rows = ceil(count / perRow)
	-- A bar with fewer buttons than one row is only as wide as its buttons, so a
	-- centred bar stays centred on what is actually shown.
	local cols = count < perRow and count or perRow

	bar:SetSize(cols * size + (cols - 1) * space, rows * size + (rows - 1) * space)
	-- The bar hangs off its mover's top left corner, so the mover has to follow
	-- a live size change. Left at its old size, a bar given a second row grew
	-- down past its anchor and off the bottom of the screen until a reload.
	local mover = bar.KKUI_Mover
	if mover then
		mover:SetSize(bar:GetWidth(), bar:GetHeight())
	end

	local keyDown = self:GetKeyDownSetting()
	for i, button in ipairs(bar.buttons) do
		if i <= count then
			button:SetSize(size, size)
			local col = (i - 1) % perRow
			local row = floor((i - 1) / perRow)
			button:ClearAllPoints()
			button:SetPoint("TOPLEFT", bar, "TOPLEFT", col * (size + space), -row * (size + space))
			-- The matching Blizzard binding gives the hotkey text.
			self.Kit:SetOptions(button, self:GetButtonOptions(key, bar.bindName and (bar.bindName .. i)))
			self:ApplyButtonFonts(button)
			-- For key presses only. nil leaves it to the game's own "cast on key
			-- press" setting. Mouse clicks always cast on release, so picking a
			-- spell up never casts it.
			self.Kit:SetKeyDown(button, keyDown)
			button:Show()
		else
			button:Hide()
		end
	end

	self.Kit:SetFlyoutDirection(bar, self:GetFlyoutDirection(bar, cfg))
	self:SetupFade(bar, cfg)
end

-- Which way a flyout opens from this bar, chosen the way the stock bars do it:
-- a wide bar opens up or down toward the middle of the screen, a tall bar opens
-- sideways toward the middle, so a flyout never lands on top of its own bar.
-- Before the bar has a position there is nothing to go on, so it opens upward.
function Module:GetFlyoutDirection(bar, cfg)
	local x, y = bar:GetCenter()
	if not (x and y) then
		return "UP"
	end
	local rows = ceil(cfg.Buttons / cfg.PerRow)
	if cfg.PerRow >= rows then
		return y < GetScreenHeight() / 2 and "UP" or "DOWN"
	end
	return x > GetScreenWidth() / 2 and "LEFT" or "RIGHT"
end

-- Update every bar (used after a global change like font or texture).
function Module:UpdateAllBars()
	for _, def in ipairs(self.BarDefs) do
		self:UpdateBar(def.key)
	end
end

-- Route each Blizzard action binding to our button via an override binding, so
-- the key clicks our (visible) button rather than Blizzard's hidden one. Out of
-- combat only, re-run whenever bindings change.
function Module:ReassignBindings()
	if InCombatLockdown() then
		K.DeferCombat("ActionBarBindings", function()
			Module:ReassignBindings()
		end)
		return
	end
	for _, def in ipairs(self.BarDefs) do
		local bar = self.bars[def.key]
		if bar and def.bindName then
			ClearOverrideBindings(bar)
			for i, button in ipairs(bar.buttons) do
				local binding = def.bindName .. i
				for k = 1, select("#", GetBindingKey(binding)) do
					local key = select(k, GetBindingKey(binding))
					if key and key ~= "" then
						-- "Keybind" tells the library this click is a key press.
						SetOverrideBindingClick(bar, false, key, button:GetName(), "Keybind")
					end
				end
			end
		end
	end
end

-- Defer a layout change until combat ends.
function Module:QueueCombatUpdate(key)
	K.DeferCombat("ActionBar:" .. key, function()
		Module:UpdateBar(key)
	end)
end

-- ---------------------------------------------------------------------------
-- Mouseover fade
-- ---------------------------------------------------------------------------

-- How fast the bar glides between hidden and shown, in alpha per second.
local FADE_SPEED = 5

-- While a bar is thought to be hovered, how often that is double checked. Hover
-- comes from OnEnter and OnLeave, but hiding the button under the cursor (dragging
-- a spell off its slot, say) never sends OnLeave, so a hovered bar re-verifies on
-- this throttle until the pointer is really gone.
local HOVER_RECHECK = 0.1

-- Per bar fade state, kept in weak tables so a bar that goes away takes its entry
-- with it. Nothing is written onto the bars themselves.
local faders = setmetatable({}, { __mode = "k" })
local hooked = setmetatable({}, { __mode = "k" })
local fadeEvents

local FadeTick

-- Work out where a bar should be resting and start the glide if it is not there.
-- Called when something that decides that changes, a hover, or combat starting or
-- ending. Between those the bar has no per frame cost at all.
-- True while the pointer is on the bar, or on the flyout one of its buttons
-- opened. The flyout sits outside the bar's own rectangle, so the bar alone
-- reads as "left" the moment the pointer steps onto it.
local function IsOverBar(bar)
	if bar:IsMouseOver() then
		return true
	end
	local kit = Module.Kit
	local opener = kit:GetFlyoutOpener()
	return opener ~= nil and opener:GetParent() == bar and kit:IsMouseOverFlyout()
end

-- Set while the cursor carries a spell or item, so a faded bar shows its empty slots
-- as drop targets for the drag.
local gridShown = false

-- Combat as the fade sees it. PLAYER_REGEN_DISABLED fires before the lockdown
-- starts, so InCombatLockdown() still reads false inside it and a combat fade bar
-- would stay hidden into the fight. The events set this flag directly instead.
local inCombat = InCombatLockdown()

local function Retarget(bar)
	local state = faders[bar]
	if not state then
		return
	end

	-- Full while fighting, and (for mouseover bars) while hovered or while something
	-- is being dragged. Otherwise the bar rests at the faded alpha. A combat fade bar
	-- therefore hides out of combat and comes up the moment a fight starts.
	local reveal = state.mouseover and (state.hovered or gridShown)
	local want = (inCombat or reveal) and state.target or state.faded
	state.want = want

	if state.current ~= want or state.hovered then
		bar:SetScript("OnUpdate", FadeTick)
	end
end

-- Runs only while the bar is gliding or hovered, and removes itself the moment it
-- is neither.
FadeTick = function(bar, delta)
	local state = faders[bar]
	if not state then
		bar:SetScript("OnUpdate", nil)
		return
	end

	if state.hovered then
		state.recheck = (state.recheck or 0) + delta
		if state.recheck >= HOVER_RECHECK then
			state.recheck = 0
			if not IsOverBar(bar) then
				state.hovered = false
				Retarget(bar)
			end
		end
	end

	local current, want = state.current, state.want
	if current ~= want then
		local step = FADE_SPEED * delta
		if want > current then
			current = current + step
			if current > want then
				current = want
			end
		else
			current = current - step
			if current < want then
				current = want
			end
		end
		state.current = current
		bar:SetAlpha(current)
	end

	if state.current == state.want and not state.hovered then
		bar:SetScript("OnUpdate", nil)
	end
end

local function OnFadeEvent(_, event)
	if event == "PLAYER_REGEN_DISABLED" then
		inCombat = true
	elseif event == "PLAYER_REGEN_ENABLED" then
		inCombat = false
	elseif event == "ACTIONBAR_SHOWGRID" then
		gridShown = true
	elseif event == "ACTIONBAR_HIDEGRID" then
		gridShown = false
	end
	for bar in pairs(faders) do
		Retarget(bar)
	end
end

-- One shared frame for the combat events. It is its own frame rather than the
-- module's event registry on purpose, a split module can lose a handler when
-- another file unregisters the same event by name.
local function EnsureFadeEvents()
	if fadeEvents then
		return
	end
	fadeEvents = CreateFrame("Frame")
	fadeEvents:RegisterEvent("PLAYER_REGEN_DISABLED")
	fadeEvents:RegisterEvent("PLAYER_REGEN_ENABLED")
	fadeEvents:RegisterEvent("ACTIONBAR_SHOWGRID")
	fadeEvents:RegisterEvent("ACTIONBAR_HIDEGRID")
	fadeEvents:SetScript("OnEvent", OnFadeEvent)
end

-- Apply a static alpha, or a fader that shows the bar on hover and in combat.
function Module:SetupFade(bar, cfg)
	-- No fader. A plain static alpha.
	if not (cfg.Mouseover or cfg.FadeCombat) then
		faders[bar] = nil
		bar:SetScript("OnUpdate", nil)
		bar:SetAlpha(cfg.Alpha)
		return
	end

	local state = {
		target = cfg.Alpha,
		-- Alpha the bar rests at while faded. Zero for a pure mouseover bar, or the
		-- configured value for a combat fade that leaves the bar dimly visible.
		faded = cfg.FadeAlpha or 0,
		mouseover = cfg.Mouseover and true or false,
		hovered = false,
	}
	-- A re-run (any re-layout, a mover drop, a font change) carries on from where
	-- the bar is, so a faded bar does not flash to full and fade out again.
	local prev = faders[bar]
	if prev then
		state.current = prev.current
		state.hovered = prev.hovered
	else
		state.current = state.target
	end
	faders[bar] = state
	bar:SetAlpha(state.current)

	-- The hooks read the live state through the weak table, so they are added once
	-- and a later SetupFade with new settings just swaps the state under them.
	if state.mouseover and not hooked[bar] then
		hooked[bar] = true

		local function Enter()
			local s = faders[bar]
			if s then
				s.hovered = true
				Retarget(bar)
			end
		end
		local function Leave()
			local s = faders[bar]
			if s then
				-- Moving between buttons fires a leave then an enter, and the pointer
				-- is still over the bar for the first of those.
				s.hovered = IsOverBar(bar)
				Retarget(bar)
			end
		end

		bar:HookScript("OnEnter", Enter)
		bar:HookScript("OnLeave", Leave)
		for _, button in ipairs(bar.buttons or {}) do
			button:HookScript("OnEnter", Enter)
			button:HookScript("OnLeave", Leave)
		end

		-- A bar that hides while hovered (a vehicle taking over) must not come back
		-- believing the pointer is still on it.
		bar:HookScript("OnHide", function()
			local s = faders[bar]
			if s then
				s.hovered = false
				Retarget(bar)
			end
		end)
	end

	EnsureFadeEvents()
	Retarget(bar)
end

-- Flyout buttons belong to no bar, so entering or leaving one rechecks the bar
-- whose button opened the flyout. Hooked once per flyout button.
local function RecheckFlyoutBar()
	local opener = Module.Kit:GetFlyoutOpener()
	local bar = opener and opener:GetParent()
	local s = bar and faders[bar]
	if s then
		s.hovered = IsOverBar(bar)
		Retarget(bar)
	end
end

function Module:HookFlyoutFade(button)
	button:HookScript("OnEnter", RecheckFlyoutBar)
	button:HookScript("OnLeave", RecheckFlyoutBar)
end

-- ---------------------------------------------------------------------------
-- Paging
-- ---------------------------------------------------------------------------

-- Main bar paging. The page driver picks a page and the library sets it on the
-- bar, where the buttons' secure clicks read it.
-- Ask the game which page a form or stance really pages to, once, and remember
-- it. This is how a form that is not in the starting table gets its page without
-- anyone guessing. It only learns while nothing else is overriding the bar, with
-- the first page selected, out of combat, since those are the same conditions the
-- game itself pages the bonus bar under.
local function LearnBonusBars()
	if InCombatLockdown() or not K.DB then
		return
	end
	local api = C_ActionBar
	if api.HasOverrideActionBar() or api.HasVehicleActionBar() or api.HasTempShapeshiftActionBar() or api.IsPossessBarVisible() then
		return
	end
	if api.GetActionBarPage() ~= 1 then
		return
	end
	local offset = api.GetBonusBarOffset()
	if not offset or offset == 0 then
		return
	end

	-- Only a bar the game confirms is recorded. A form with no bar simply never
	-- gets a clause, and one reading of "no bar" during a form change is not
	-- trusted enough to take a page away.
	if not api.HasBonusActionBar() then
		return
	end
	local page = api.GetBonusBarIndex()
	if not page or page == 0 then
		return
	end
	local store = K.DB.bonusBarPages
	if not store then
		store = {}
		K.DB.bonusBarPages = store
	end
	local byClass = store[K.Class]
	if not byClass then
		byClass = {}
		store[K.Class] = byClass
	end

	local known = BonusPages()[offset]
	if known == page then
		return
	end
	byClass[offset] = page

	local stream = K.Debug and K.Debug.Register("actionbars", "Action bar paging decisions")
	if stream then
		stream:Log("bonus bar %d on %s: page %d (was %s)", offset, K.Class, page, tostring(known))
	end

	local main = Module.bars.Bar1
	if main then
		Module.Kit:SetPaging(main, GetPageDriver())
	end
end

-- Forever puts the vehicle, temp shapeshift and override pages at 31, 32 and 33
-- (read live on 1.60.1). The library works out any page's slots from the page
-- number, so no page range has to be prepared.
function Module:SetupMainBar(bar)
	self.Kit:SetPaging(bar, GetPageDriver())

	self:RegisterEvent("UPDATE_BONUS_ACTIONBAR", LearnBonusBars)
	self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
		C_Timer.After(1, LearnBonusBars)
	end)
end

-- Point every button on a bar at a fixed page of the action table.
function Module:AssignPage(bar, page)
	self.Kit:SetFixedPage(bar, page)
end
