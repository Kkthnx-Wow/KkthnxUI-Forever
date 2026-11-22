--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/ObjectiveTracker.lua
	Purpose:
		Strip the Blizzard quest / objective tracker down to text so it reads as
		part of this UI: no header bars, our font, our chevron for collapse, our
		border on quest item buttons, and quest progress and timer bars in one
		calm colour (class colour, or our accent).

		The tracker lives in the load-on-demand Blizzard_ObjectiveTracker, so we
		style on enable if it is already loaded, otherwise wait for its ADDON_LOADED.

		Taint rules this file keeps, from the Blizzard source and earlier bugs:
		- Never hook or call into the container's update. ObjectiveTrackerContainer
		  :Update runs every module in one pass, and taint picked up there broke the
		  scenario module's Maw buff read until a reload.
		- Never touch ScenarioObjectiveTracker or UIWidgetObjectiveTracker. Both
		  draw through the shared UI widget pool that tooltips also use.
		- Never write a field Blizzard reads. Header art is hidden with Hide() and
		  SetAlpha on textures, which are widget calls, not Lua writes. Our own
		  regions are created as children and tracked in weak tables here.
		- No SetCollapsed hooks. Collapse state is read after a click, through a
		  script hook on the button, and our chevron is the only thing changed.
		- Work asked for from inside a Blizzard hook is deferred to the next frame,
		  after Blizzard's own pass is over.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("ObjectiveTracker")

local _G = _G
local pairs = pairs
local hooksecurefunc = hooksecurefunc
local C_AddOns = C_AddOns
local C_Timer_After = C_Timer.After

local CHEVRON = K.MediaFolder .. "Textures\\DropdownArrow.tga"
local CHEVRON_SIZE = 16

-- Fallback tint when the class-colour option is off.
local ACCENT = { 0.36, 0.55, 0.81 }

local function GetBarColor()
	if C.Skins.ObjectiveTrackerClassColor then
		local c = K.ClassColor
		return c.r or c[1], c.g or c[2], c.b or c[3]
	end
	return ACCENT[1], ACCENT[2], ACCENT[3]
end

local function ReskinBar(bar)
	if bar and C.Skins.ObjectiveTracker then
		bar:SetStatusBarColor(GetBarColor())
	end
end

-- Our chevron per minimise button, and the item buttons already styled. Weak, so
-- a pooled frame Blizzard drops is not kept alive by us.
local chevrons = setmetatable({}, { __mode = "k" })
local styledItems = setmetatable({}, { __mode = "k" })

-- ---------------------------------------------------------------------------
-- Deferred work
-- ---------------------------------------------------------------------------

-- Hooks only record what they were handed. One timer applies it after the pass.
local pendingBars = {}
local pendingItems = {}
local flushQueued = false

local StyleItemButton

local function Flush()
	flushQueued = false
	for bar in pairs(pendingBars) do
		pendingBars[bar] = nil
		ReskinBar(bar)
	end
	for button in pairs(pendingItems) do
		pendingItems[button] = nil
		StyleItemButton(button)
	end
end

local function QueueFlush()
	if not flushQueued then
		flushQueued = true
		C_Timer_After(0, Flush)
	end
end

-- ---------------------------------------------------------------------------
-- Fonts
-- ---------------------------------------------------------------------------

-- Every header, quest title and objective line inherits one of these two global
-- font objects, so restyling them reaches all of it without touching a single
-- FontString. The size is the player's tracker text size setting, kept as is.
local function ApplyFonts()
	local font = K.GetFont(C.General and C.General.Font)
	local outline = K.FontOutlineStyle()
	for _, object in pairs({ _G.ObjectiveTrackerLineFont, _G.ObjectiveTrackerHeaderFont }) do
		local _, size = object:GetFont()
		if size then
			object:SetFont(font, size, outline)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Headers
-- ---------------------------------------------------------------------------

local function PaintChevron(arrow, hover)
	if hover then
		local a = K.Colors.accent
		arrow:SetVertexColor(a[1], a[2], a[3])
	else
		local c = K.GetBorderColor()
		arrow:SetVertexColor(c[1], c[2], c[3])
	end
	arrow.__customColor = hover or nil
end

-- Point the chevron down while open and right while collapsed, the same arrow the
-- options dropdowns use.
local function UpdateChevron(button, collapsed)
	local arrow = chevrons[button]
	if arrow then
		arrow:SetRotation(collapsed and (math.pi / 2) or 0)
	end
end

local function HideRegion(region)
	if region then
		region:Hide()
	end
end

-- Hide the header bar art and put our chevron on the minimise button. Hide() keeps
-- the module header's add animation from fading its bar back in, since an alpha
-- animation does not show a hidden texture. isCollapsedFn reads the owner's state
-- after a click. Nothing here writes to the header or the button.
local function SkinHeader(header, isCollapsedFn)
	if not header then
		return
	end
	HideRegion(header.Background)
	HideRegion(header.Glow)
	HideRegion(header.Shine)

	local button = header.MinimizeButton
	if not button or chevrons[button] then
		return
	end
	for _, texture in pairs({ button:GetNormalTexture(), button:GetPushedTexture(), button:GetHighlightTexture() }) do
		texture:SetAlpha(0)
	end

	local arrow = button:CreateTexture(nil, "OVERLAY")
	arrow:SetTexture(CHEVRON)
	arrow:SetSize(CHEVRON_SIZE, CHEVRON_SIZE)
	arrow:SetPoint("CENTER")
	K.TintWithBorder(arrow)
	chevrons[button] = arrow
	UpdateChevron(button, isCollapsedFn())

	button:HookScript("OnEnter", function()
		PaintChevron(arrow, true)
	end)
	button:HookScript("OnLeave", function()
		PaintChevron(arrow, false)
	end)
	-- Blizzard's OnClick toggles the state first, so it is settled by the time this
	-- runs. Deferred anyway, to stay out of the update the toggle starts.
	button:HookScript("OnClick", function(self)
		C_Timer_After(0, function()
			UpdateChevron(self, isCollapsedFn())
		end)
	end)
end

-- ---------------------------------------------------------------------------
-- Quest item buttons
-- ---------------------------------------------------------------------------

-- Plain Buttons (not secure templates) from a frame pool, given our slot border in
-- place of the round quest item frame. Styled once per pooled frame.
function StyleItemButton(button)
	if not button or styledItems[button] then
		return
	end
	styledItems[button] = true

	if button.NormalTexture then
		button.NormalTexture:SetAlpha(0)
	end
	local pushed = button:GetPushedTexture()
	if pushed then
		pushed:SetAlpha(0)
	end

	local icon = button.icon
	if icon then
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		icon:ClearAllPoints()
		icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
	end
	if button.Cooldown then
		button.Cooldown:ClearAllPoints()
		button.Cooldown:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		button.Cooldown:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
		K.StyleCooldownSwipe(button.Cooldown)
	end

	K.StyleButtonStates(button, 1)
	K.CreateBorder(button)
end

local function OnItemButtonSetUp(button)
	pendingItems[button] = true
	QueueFlush()
end

-- ---------------------------------------------------------------------------
-- Bars
-- ---------------------------------------------------------------------------

-- Blizzard hands back the bar it just built or reused, so we re-read it from the
-- tracker's pools (a secure hook does not get the return value) and tint it.
local function HandleProgressBar(tracker, key)
	local pb = tracker.usedProgressBars and tracker.usedProgressBars[key]
	if pb and pb.Bar then
		pendingBars[pb.Bar] = true
		QueueFlush()
	end
end

local function HandleTimerBar(tracker, key)
	local tb = tracker.usedTimerBars and tracker.usedTimerBars[key]
	if tb and tb.Bar then
		pendingBars[tb.Bar] = true
		QueueFlush()
	end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function Module:Style()
	if self.styled then
		return
	end
	local container = _G.ObjectiveTrackerFrame
	if not container then
		return
	end
	self.styled = true

	ApplyFonts()
	-- The tracker's text size setting points both font objects back at Blizzard's
	-- own font family, so put ours back after it. A post-hook on the manager, not
	-- on any frame, and it only calls SetFont on the two font objects.
	local manager = _G.ObjectiveTrackerManager
	if manager and manager.SetTextSize then
		hooksecurefunc(manager, "SetTextSize", ApplyFonts)
	end

	-- The container header: its bar is hidden like the rest. Only its regions are
	-- touched, never the container or its update.
	SkinHeader(container.Header, function()
		return container.isCollapsed and true or false
	end)

	-- The sub-trackers. ScenarioObjectiveTracker and UIWidgetObjectiveTracker stay
	-- out, see the taint rules at the top.
	local trackers = {
		_G.CampaignQuestObjectiveTracker,
		_G.QuestObjectiveTracker,
		_G.AdventureObjectiveTracker,
		_G.AchievementObjectiveTracker,
		_G.MonthlyActivitiesObjectiveTracker,
		_G.ProfessionsRecipeTracker,
		_G.BonusObjectiveTracker,
		_G.WorldQuestObjectiveTracker,
	}

	for i = 1, #trackers do
		local tracker = trackers[i]
		if tracker then
			SkinHeader(tracker.Header, function()
				local contents = tracker.ContentsFrame
				return contents and not contents:IsShown() or false
			end)

			-- Colour any bars already built, then react to future ones.
			if tracker.usedProgressBars then
				for _, pb in pairs(tracker.usedProgressBars) do
					ReskinBar(pb and pb.Bar)
				end
			end
			if tracker.usedTimerBars then
				for _, tb in pairs(tracker.usedTimerBars) do
					ReskinBar(tb and tb.Bar)
				end
			end
			if tracker.GetProgressBar then
				hooksecurefunc(tracker, "GetProgressBar", HandleProgressBar)
			end
			if tracker.GetTimerBar then
				hooksecurefunc(tracker, "GetTimerBar", HandleTimerBar)
			end
		end
	end

	-- Item buttons come from a pool and are set up through this mixin method. A hook
	-- on the mixin reaches every button the pool builds from now on.
	-- Buttons built before this ran already hold the unhooked method, so they are
	-- found once by that method and hooked one by one.
	local itemMixin = _G.QuestObjectiveItemButtonMixin
	if itemMixin and itemMixin.SetUp then
		local setUp = itemMixin.SetUp
		hooksecurefunc(itemMixin, "SetUp", OnItemButtonSetUp)
		local frame = EnumerateFrames()
		while frame do
			if frame.SetUp == setUp then
				hooksecurefunc(frame, "SetUp", OnItemButtonSetUp)
				pendingItems[frame] = true
			end
			frame = EnumerateFrames(frame)
		end
		QueueFlush()
	end
end

function Module:ADDON_LOADED(_, addon)
	if addon == "Blizzard_ObjectiveTracker" then
		self:Style()
		self:UnregisterEvent("ADDON_LOADED")
	end
end

function Module:OnEnable()
	if not C.Skins.ObjectiveTracker then
		return
	end
	if C_AddOns and C_AddOns.IsAddOnLoaded("Blizzard_ObjectiveTracker") then
		self:Style()
	else
		self:RegisterEvent("ADDON_LOADED")
	end
end
