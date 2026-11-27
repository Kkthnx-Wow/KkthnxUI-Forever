--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Config/GUI/Window.lua
	Purpose:
		The options window: a movable, resizable panel with a grouped page list on
		the left and a scrollable content area on the right. Standard pages are laid
		out from the schema. A page may instead point to a custom builder (Profiles,
		Move UI, What's New).

		Typing in the search box lists matching settings rather than pages. Picking
		one opens its page, scrolls to it and lights it up. Settings added in a
		recent version carry Blizzard's own NEW label until their page is opened, and
		a dot marks every setting that differs from its default. The window size and
		position are remembered.
-----------------------------------------------------------------------------]]

local K, L = KkthnxUI[1], KkthnxUI[3]

local tinsert = table.insert
local max, min = math.max, math.min
local ipairs, pairs = ipairs, pairs
local C_Timer = C_Timer

-- Theme colours from the palette so the window tracks any palette change.
local ACCENT = K.Colors.accent
local PANEL = K.Colors.panel

local DEFAULT_WIDTH, DEFAULT_HEIGHT = 900, 640
local MIN_WIDTH, MIN_HEIGHT = 700, 440
local NAV_WIDTH = 170
local NEW_COLOR = K.Colors.highlight
local MODIFIED_COLOR = K.Colors.warning

-- Category name to a game icon. These come from the client's own icon library so
-- there is no art of ours to ship or keep current. A category with no entry here
-- simply draws no icon.
local CATEGORY_ICON = {
	WhatsNew = "INV_Misc_Note_05",
	General = "INV_Misc_Gear_01",
	ActionBar = "INV_Misc_EngGizmos_30",
	Unitframe = "Achievement_Character_Human_Male",
	Minimap = "INV_Misc_Map_01",
	WorldMap = "INV_Misc_Map02",
	Auras = "Spell_Holy_PowerWordShield",
	Cooldown = "Spell_Nature_TimeStop",
	Chat = "INV_Letter_15",
	Nameplate = "Ability_Hunter_MarkedForDeath",
	Tooltip = "INV_Misc_Note_01",
	ExperienceBar = "Achievement_Level_10",
	AlertFrames = "INV_Misc_Bell_01",
	GroupTools = "INV_Misc_GroupLooking",
	Loot = "INV_Box_01",
	MicroMenu = "INV_Misc_Book_09",
	Bags = "INV_Misc_Bag_08",
	Misc = "INV_Misc_Gear_02",
	Automation = "Trade_Engineering",
	QoL = "INV_Misc_Gear_08",
	Skins = "Trade_Engraving",
	Movers = "Ability_Hunter_Pathfinding",
	Profiles = "INV_Misc_ScrollUnrolled01",
}

-- How the page list is grouped. Pages not named here land in a final Other group,
-- so a page added to the schema is never lost from the list.
local TOP_PAGES = { "WhatsNew", "General" }
local GROUPS = {
	{ title = L["Combat"], pages = { "Unitframe", "Nameplate", "ActionBar", "Auras", "Cooldown" } },
	{ title = L["Interface"], pages = { "Minimap", "WorldMap", "Chat", "Tooltip", "Bags", "MicroMenu", "ExperienceBar", "AlertFrames", "Loot", "Skins" } },
	{ title = L["Gameplay"], pages = { "Automation", "QoL", "GroupTools", "Misc" } },
	{ title = L["Setup"], pages = { "Movers", "Profiles" } },
}

local GUI = K.GUI
GUI.CustomPanels = GUI.CustomPanels or {}

-- control -> { widget, card, category }, so search can find and light a setting.
GUI.controlWidgets = {}
-- category name -> NEW labels drawn on that page, hidden once the page is seen.
GUI.badges = {}

local window, reloadHint, reloadGlow

-- ---------------------------------------------------------------------------
-- NEW label
-- ---------------------------------------------------------------------------

-- Blizzard's own NewFeatureLabel, the pulsing NEW the stock UI uses. If the
-- template is missing the label falls back to plain text.
local function CreateNewBadge(parent, animate)
	local ok, badge = pcall(CreateFrame, "Frame", nil, parent, animate and "NewFeatureLabelTemplate" or "NewFeatureLabelNoAnimateTemplate")
	if ok and badge then
		badge:SetFrameLevel(parent:GetFrameLevel() + 5)
		badge:Show()
		return badge
	end
	badge = CreateFrame("Frame", nil, parent)
	badge:SetSize(40, 20)
	local fs = badge:CreateFontString(nil, "OVERLAY")
	K.SetFont(fs, 11, "OUTLINE")
	fs:SetTextColor(NEW_COLOR[1], NEW_COLOR[2], NEW_COLOR[3])
	fs:SetPoint("CENTER")
	fs:SetText(L["NEW"])
	return badge
end

local function AddBadge(category, badge)
	GUI.badges[category.name] = GUI.badges[category.name] or {}
	tinsert(GUI.badges[category.name], badge)
end

function GUI.HideBadges(name)
	for key, list in pairs(GUI.badges) do
		if not name or key == name then
			for _, badge in ipairs(list) do
				badge:Hide()
			end
		end
	end
end

-- ---------------------------------------------------------------------------
-- Panel layout
-- ---------------------------------------------------------------------------

-- Split a flat control list into sections. Every "header" starts a new section
-- whose title is the header label, controls before the first header form an
-- untitled section so nothing is ever dropped.
local function SplitSections(controls)
	local sections, current = {}, nil
	for _, control in ipairs(controls) do
		if control.kind == "header" then
			current = { title = control.label, fullWidth = control.fullWidth, controls = {} }
			sections[#sections + 1] = current
		else
			if not current then
				current = { controls = {} }
				sections[#sections + 1] = current
			end
			current.controls[#current.controls + 1] = control
		end
	end
	-- A header with nothing under it would draw an empty card, so drop it.
	local kept = {}
	for _, section in ipairs(sections) do
		if #section.controls > 0 then
			kept[#kept + 1] = section
		end
	end
	return kept
end

-- Build one titled card. A soft box holding a section's controls. The widgets are
-- made once here and positioned by FitCard, which can run again at another width.
local function BuildCard(host, section, category)
	local card = CreateFrame("Frame", nil, host)
	-- A subtle top-lit gradient lifts each card off the flat panel behind it.
	K.GradientBG(card, 0.16, 0.17, 0.19, 0.55, 0.10, 0.10, 0.12, 0.55)

	card.hasTitle = section.title ~= nil
	if section.title then
		local fs = card:CreateFontString(nil, "OVERLAY")
		K.SetFont(fs, 13, "OUTLINE")
		fs:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
		fs:SetPoint("TOPLEFT", card, "TOPLEFT", 12, -10)
		fs:SetText(section.title)
		card.titleText = fs

		local rule = card:CreateTexture(nil, "ARTWORK")
		rule:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.25)
		rule:SetHeight(1)
		rule:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -28)
		rule:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -28)
	end

	card.items = {}
	local sectionHasNew = false
	for _, control in ipairs(section.controls) do
		local builder = GUI.Builders[control.kind]
		if builder then
			local widget = builder(card, control)
			card.items[#card.items + 1] = { widget = widget, control = control }
			-- The width the label needs, kept before FitCard resizes the button so
			-- every later fit can still tell whether two of them share a row.
			if control.kind == "button" or control.kind == "extra" then
				card.items[#card.items].natural = widget:GetWidth()
			end

			if control.path or control.label then
				GUI.controlWidgets[control] = { widget = widget, card = card, category = category }
			end

			-- A small tag at the right of the row, shown once this setting is changed
			-- and still waiting on a reload.
			if control.reload and control.path then
				local mark = card:CreateFontString(nil, "OVERLAY")
				K.SetFont(mark, 10)
				mark:SetTextColor(K.Colors.warning[1], K.Colors.warning[2], K.Colors.warning[3])
				mark:SetText(L["needs reload"])
				mark:SetShown(GUI.pendingReload[control] == true)
				GUI.reloadMarks[control] = mark
				card.items[#card.items].mark = mark
			end

			-- Dot for a setting that differs from its default.
			if control.path then
				local dot = card:CreateTexture(nil, "OVERLAY")
				dot:SetSize(6, 6)
				dot:SetColorTexture(MODIFIED_COLOR[1], MODIFIED_COLOR[2], MODIFIED_COLOR[3], 1)
				dot:SetPoint("RIGHT", widget, "TOPLEFT", -5, control.kind == "check" and -15 or -8)
				dot:SetShown(GUI.IsModified(control))
				GUI.modifiedDots[control] = dot
			end

			-- Blizzard's NEW label on a setting its page has not shown yet.
			if GUI.IsNew(control) then
				sectionHasNew = true
				local badge = CreateNewBadge(card, true)
				if control.kind == "check" and widget.Text then
					badge:SetPoint("LEFT", widget.Text, "RIGHT", 14, 0)
				elseif control.kind == "button" or control.kind == "extra" then
					-- On the button's top corner, since buttons now share rows and a
					-- tag beside one would land on its neighbour.
					badge:SetPoint("CENTER", widget, "TOPRIGHT", -16, 2)
				else
					badge:SetPoint("TOPRIGHT", widget, "TOPRIGHT", -24, 2)
				end
				AddBadge(category, badge)
			end
		end
	end

	-- A quiet NEW beside the card title so a new setting is findable while
	-- scrolling. Next to the words, not the card edge, where it floated loose.
	if sectionHasNew and card.titleText then
		local badge = CreateNewBadge(card, false)
		badge:SetPoint("LEFT", card.titleText, "RIGHT", 16, 0)
		AddBadge(category, badge)
	end
	return card
end

local BUTTON_GAP = 8

-- Every button in a run sized and placed at once. Two to a row at half width
-- when every label fits, otherwise one per row at full width, so a run of
-- buttons reads as a grid with the same edges as the sliders around it.
local function PlaceButtonRun(card, run, contentWidth, y)
	local half = math.floor((contentWidth - BUTTON_GAP) / 2)
	local paired = #run > 1
	for _, item in ipairs(run) do
		if item.natural > half then
			paired = false
			break
		end
	end
	local perRow = paired and 2 or 1
	local width = paired and half or contentWidth
	for i, item in ipairs(run) do
		local col = (i - 1) % perRow
		local widget = item.widget
		widget:SetWidth(width)
		widget:ClearAllPoints()
		widget:SetPoint("TOPLEFT", card, "TOPLEFT", 16 + col * (half + BUTTON_GAP), y)
		if col == perRow - 1 or i == #run then
			y = y - (widget.height or 30)
		end
	end
	return y
end

-- Size a card to a width and stack its widgets. Returns the card's height.
local function FitCard(card, width)
	card:SetWidth(width)
	local contentWidth = width - 30
	local y = card.hasTitle and -36 or -10
	local run = {}
	local items = card.items
	for index, item in ipairs(items) do
		local widget, control = item.widget, item.control
		if item.natural then
			run[#run + 1] = item
			local nextItem = items[index + 1]
			if not (nextItem and nextItem.natural) then
				y = PlaceButtonRun(card, run, contentWidth, y)
				run = {}
			end
		else
			-- Stretch width-aware widgets (sliders, dropdowns) to fill the card so
			-- their left and right edges share one grid line.
			if widget.KKUI_SetWidth then
				widget.KKUI_SetWidth(contentWidth)
			end
			-- Descriptions wrap, refit them to the card so text never spills past the
			-- edge and the stored height matches the wrapped text.
			if control.kind == "description" and widget.SetWidth then
				widget:SetWidth(contentWidth)
				widget.height = (widget:GetStringHeight() or 12) + 8
			end
			widget:ClearAllPoints()
			widget:SetPoint("TOPLEFT", card, "TOPLEFT", control.kind == "description" and 12 or 16, y)
			if item.mark then
				item.mark:ClearAllPoints()
				item.mark:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, y - 3)
			end
			y = y - (widget.height or 28)
		end
	end
	local height = -y + 10
	card:SetHeight(height)
	return height
end

-- Flow built cards down `columns` columns, always dropping the next card into the
-- shortest column so mixed section heights stay balanced. A header may set
-- `fullWidth` to span all columns.
local function PlaceCards(host, hostWidth)
	if hostWidth <= 1 then
		hostWidth = 520
	end
	-- A page that does not fix its column count uses as many as fit, so a wide
	-- window is not one long strip of stretched sliders.
	local columns = host.KKUI_columns
	if host.KKUI_auto then
		columns = (hostWidth >= 1100 and 3) or (hostWidth >= 660 and 2) or 1
	end
	local gutter = 12
	local colWidth = math.floor((hostWidth - gutter * (columns - 1)) / columns)
	local topPad, cardGap = 8, 14
	local used = {}
	for i = 1, columns do
		used[i] = 0
	end

	for _, entry in ipairs(host.KKUI_cards) do
		local card = entry.card
		card:ClearAllPoints()
		if entry.fullWidth or columns == 1 then
			local height = FitCard(card, hostWidth)
			local top = 0
			for i = 1, columns do
				top = max(top, used[i])
			end
			card:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(topPad + top))
			for i = 1, columns do
				used[i] = top + height + cardGap
			end
		else
			local col = 1
			for i = 2, columns do
				if used[i] < used[col] then
					col = i
				end
			end
			local height = FitCard(card, colWidth)
			card:SetPoint("TOPLEFT", host, "TOPLEFT", (col - 1) * (colWidth + gutter), -(topPad + used[col]))
			used[col] = used[col] + height + cardGap
		end
	end

	local total = 0
	for i = 1, columns do
		total = max(total, used[i])
	end
	host:SetHeight(total + topPad)
	host.KKUI_placedWidth = hostWidth
	return total + topPad
end

-- Lay a control list into titled cards. Exposed on GUI so flyouts reuse it (they
-- pass one column). opts.category names the page for NEW labels and search.
function GUI.LayoutControls(host, controls, opts)
	opts = opts or {}
	local category = opts.category or { name = "flyout" }
	host.KKUI_columns = opts.columns or 1
	host.KKUI_auto = opts.columns == nil
	host.KKUI_cards = {}
	for _, section in ipairs(SplitSections(controls)) do
		host.KKUI_cards[#host.KKUI_cards + 1] = { card = BuildCard(host, section, category), fullWidth = section.fullWidth }
	end
	host.KKUI_Place = function(width)
		return PlaceCards(host, width)
	end
	return PlaceCards(host, host:GetWidth())
end

-- ---------------------------------------------------------------------------
-- Pages
-- ---------------------------------------------------------------------------

local pages = {} -- category name -> { scroll, child, category }

local function BuildPanel(parent, category)
	local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
	-- Leave room at the top for the section title and its rule.
	scroll:SetPoint("TOPLEFT", 4, -34)
	scroll:SetPoint("BOTTOMRIGHT", -26, 4)

	K.SkinScrollBar(scroll.ScrollBar)

	local child = CreateFrame("Frame", nil, scroll)
	child:SetSize(1, 1)
	scroll:SetScrollChild(child)
	child:SetWidth(parent:GetWidth() - 34)

	if category.custom and GUI.CustomPanels[category.custom] then
		GUI.CustomPanels[category.custom](child)
	else
		GUI.LayoutControls(child, category.controls, { columns = category.columns, category = category })
	end

	scroll:Hide()
	pages[category.name] = { scroll = scroll, child = child, category = category }
	return scroll
end

-- Fit a page to the content area's current width. Pages that are not showing wait
-- until they are opened, so dragging the corner only reflows what is on screen.
local function FitPage(info)
	local width = info.scroll:GetParent():GetWidth() - 34
	if width < 100 or info.child.KKUI_placedWidth == width then
		return
	end
	info.child:SetWidth(width)
	if info.child.KKUI_Place then
		info.child.KKUI_Place(width)
	end
end

-- ---------------------------------------------------------------------------
-- Jump to a setting
-- ---------------------------------------------------------------------------

local function Flash(widget)
	local anchor = widget:GetParent()
	local glow = widget.KKUI_Flash
	if not glow then
		glow = anchor:CreateTexture(nil, "BACKGROUND", nil, 3)
		glow:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.4)
		glow:SetPoint("TOPLEFT", widget, "TOPLEFT", -6, 3)
		glow:SetPoint("BOTTOMRIGHT", widget, "BOTTOMRIGHT", 6, -3)
		local group = glow:CreateAnimationGroup()
		local out = group:CreateAnimation("Alpha")
		out:SetFromAlpha(1)
		out:SetToAlpha(0)
		out:SetDuration(1.6)
		out:SetStartDelay(0.6)
		group:SetScript("OnFinished", function()
			glow:Hide()
		end)
		glow.group = group
		widget.KKUI_Flash = glow
	end
	glow:Show()
	glow.group:Stop()
	glow.group:Play()
end

local function ScrollTo(info, widget)
	local top, widgetTop = info.child:GetTop(), widget:GetTop()
	if not top or not widgetTop then
		return
	end
	local range = info.scroll:GetVerticalScrollRange()
	info.scroll:SetVerticalScroll(min(max(top - widgetTop - 60, 0), range))
end

function GUI.JumpTo(entry)
	GUI.SelectPage(entry.category.name)
	local info = pages[entry.category.name]
	if entry.extra then
		-- The setting lives on a flyout page, so open it first.
		local holder = GUI.controlWidgets[entry.extra]
		if holder and holder.widget.Click then
			holder.widget:Click()
			if not (GUI.controlWidgets[entry.control] and GUI.controlWidgets[entry.control].widget:IsVisible()) then
				holder.widget:Click()
			end
		end
	end
	C_Timer.After(0.05, function()
		local holder = GUI.controlWidgets[entry.control]
		if holder and holder.widget:IsVisible() then
			if not entry.extra and info then
				ScrollTo(info, holder.widget)
			end
			Flash(holder.widget)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Window
-- ---------------------------------------------------------------------------

local function SaveWindow()
	local state = GUI.State()
	if not state or not window then
		return
	end
	local cx, cy = window:GetCenter()
	local ux, uy = UIParent:GetCenter()
	if not cx or not ux then
		return
	end
	state.window = { width = window:GetWidth(), height = window:GetHeight(), x = cx - ux, y = cy - uy }
end

local function RestoreWindow()
	local state = GUI.State()
	local saved = state and state.window
	local maxW, maxH = UIParent:GetWidth() * 0.95, UIParent:GetHeight() * 0.95
	local width = min(max(saved and saved.width or DEFAULT_WIDTH, MIN_WIDTH), maxW)
	local height = min(max(saved and saved.height or DEFAULT_HEIGHT, MIN_HEIGHT), maxH)
	window:SetSize(width, height)
	window:ClearAllPoints()
	window:SetPoint("CENTER", UIParent, "CENTER", saved and saved.x or 0, saved and saved.y or 0)
end

local function BuildWindow()
	window = CreateFrame("Frame", "KKUI_ConfigWindow", UIParent)
	window:SetFrameStrata("HIGH")
	window:EnableMouse(true)
	window:SetMovable(true)
	window:SetResizable(true)
	window:SetClampedToScreen(true)
	window:SetResizeBounds(MIN_WIDTH, MIN_HEIGHT, UIParent:GetWidth() * 0.95, UIParent:GetHeight() * 0.95)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", window.StartMoving)
	window:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		SaveWindow()
	end)
	RestoreWindow()
	K.CreateGradientBackground(window)
	K.CreateBorder(window)
	tinsert(UISpecialFrames, "KKUI_ConfigWindow")
	GUI.window = window

	local header = window:CreateFontString(nil, "OVERLAY")
	K.SetFont(header, 18, "OUTLINE")
	header:SetPoint("TOP", 0, -14)
	header:SetText(K.ColorText("accent", "KkthnxUI") .. "  " .. K.Version)

	local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)
	K.SkinCloseButton(close)
	K.RegisterGamepadFrame(window, close)

	-- Left page column, scrollable so it never runs into the footer no matter how
	-- many pages exist.
	local nav = CreateFrame("Frame", nil, window)
	nav:SetPoint("TOPLEFT", 12, -46)
	nav:SetPoint("BOTTOMLEFT", 12, 44)
	nav:SetWidth(NAV_WIDTH)
	K.CreateBackground(nav, PANEL[1], PANEL[2], PANEL[3], 0.85)
	K.CreateBorder(nav)

	-- Search box. Typing lists matching settings in place of the page list.
	local search = CreateFrame("EditBox", nil, nav, "InputBoxTemplate")
	search:SetHeight(20)
	search:SetPoint("TOPLEFT", nav, "TOPLEFT", 8, -6)
	search:SetPoint("TOPRIGHT", nav, "TOPRIGHT", -8, -6)
	search:SetAutoFocus(false)
	search:SetTextInsets(4, 4, 0, 0)
	K.SkinEditBox(search)

	local searchHint = search:CreateFontString(nil, "OVERLAY")
	K.SetFont(searchHint, 11)
	searchHint:SetTextColor(K.Colors.disabled[1], K.Colors.disabled[2], K.Colors.disabled[3])
	searchHint:SetPoint("LEFT", search, "LEFT", 4, 0)
	searchHint:SetText(L["Search settings..."])

	local navScroll = CreateFrame("ScrollFrame", nil, nav)
	navScroll:SetPoint("TOPLEFT", 3, -32)
	navScroll:SetPoint("BOTTOMRIGHT", -3, 4)
	navScroll:EnableMouseWheel(true)
	navScroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange()
		self:SetVerticalScroll(min(max(self:GetVerticalScroll() - delta * 34, 0), range))
	end)

	local navChild = CreateFrame("Frame", nil, navScroll)
	navChild:SetSize(NAV_WIDTH - 12, 1)
	navScroll:SetScrollChild(navChild)

	-- Right content area.
	local content = CreateFrame("Frame", nil, window)
	content:SetPoint("TOPLEFT", nav, "TOPRIGHT", 10, 0)
	content:SetPoint("BOTTOMRIGHT", -12, 44)
	K.CreateBackground(content, PANEL[1], PANEL[2], PANEL[3], 0.85)
	K.CreateBorder(content)

	-- Section title so it is always clear which page is open.
	local contentTitle = content:CreateFontString(nil, "OVERLAY")
	K.SetFont(contentTitle, 15, "OUTLINE")
	contentTitle:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	contentTitle:SetPoint("TOPLEFT", content, "TOPLEFT", 12, -8)
	local titleRule = content:CreateTexture(nil, "ARTWORK")
	titleRule:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.35)
	titleRule:SetHeight(1)
	titleRule:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -28)
	titleRule:SetPoint("TOPRIGHT", content, "TOPRIGHT", -8, -28)

	-- Reset the whole page. It sits on the title rule so it reads as belonging to
	-- the page it acts on.
	local resetSection = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
	resetSection:SetSize(112, 20)
	resetSection:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, -5)
	resetSection:SetText(L["Reset Section"])
	K.SkinButton(resetSection)
	local resetFont = resetSection:GetFontString()
	if resetFont then
		K.SetFont(resetFont, 11, "")
	end

	local buttons = {}
	local currentName
	local currentCategory

	-- Dots on the page list. A count of new settings on What's New, a small dot on
	-- a page that holds some.
	function GUI.UpdateNav()
		for name, btn in pairs(buttons) do
			local category = GUI.categoryByName[name]
			if name == "WhatsNew" then
				local total = GUI.CountNewTotal()
				btn.Count:SetText(total > 0 and total or "")
				btn.Count:SetShown(total > 0)
			else
				btn.Dot:SetShown(GUI.CountNew(category) > 0 and name ~= currentName)
			end
		end
	end

	-- Leaving a page counts as having seen what was new on it.
	local function CommitSeen(name)
		local category = name and GUI.categoryByName[name]
		if category and category.controls and GUI.MarkPageSeen(category) then
			GUI.HideBadges(name)
		end
	end

	function GUI.SelectPage(name)
		if name ~= currentName then
			CommitSeen(currentName)
			-- A flyout belongs to the page it was opened from, so it closes
			-- when another page takes over.
			if currentName and GUI.HideExtras then
				GUI.HideExtras()
			end
		end
		currentName = name
		for key, info in pairs(pages) do
			local active = key == name
			info.scroll:SetShown(active)
			if active then
				FitPage(info)
				if info.child.KKUI_Refresh then
					info.child.KKUI_Refresh()
				end
			end
			local btn = buttons[key]
			if btn then
				-- The open page sits on a darkened accent with info coloured text,
				-- the rest on the raised colour with secondary text.
				local P = K.Colors
				if active then
					btn.KKUI_Background:SetVertexColor(P.accent[1] * 0.55, P.accent[2] * 0.6, P.accent[3] * 0.75, 0.9)
					btn.Text:SetTextColor(P.info[1], P.info[2], P.info[3])
				else
					btn.KKUI_Background:SetVertexColor(P.raised[1], P.raised[2], P.raised[3], 0.5)
					btn.Text:SetTextColor(P.secondary[1], P.secondary[2], P.secondary[3])
				end
				btn.Accent:SetShown(active)
			end
		end
		contentTitle:SetText(GUI.categoryTitles[name] or "")
		currentCategory = GUI.categoryByName[name]
		-- A custom page owns its own state and has no control list to walk, so
		-- there is nothing to reset there.
		resetSection:SetShown(currentCategory ~= nil and currentCategory.controls ~= nil)
		GUI.UpdateNav()
	end

	window:HookScript("OnHide", function()
		CommitSeen(currentName)
		GUI.UpdateNav()
		if GUI.HideExtras then
			GUI.HideExtras()
		end
	end)

	local function ConfirmReset()
		local count = GUI.ResetCategory(currentCategory)
		if count > 0 then
			K.Print(L["Reset %d settings on this page."], count)
		end
	end

	resetSection:SetScript("OnClick", function()
		if currentCategory then
			K.Confirm(L["Put every setting on this page back to its default?"], ConfirmReset)
		end
	end)

	GUI.categoryTitles = {}
	GUI.categoryByName = {}

	-- Build every page and its button.
	for _, category in ipairs(GUI.schema) do
		GUI.categoryTitles[category.name] = category.title
		GUI.categoryByName[category.name] = category
	end

	for _, category in ipairs(GUI.schema) do
		BuildPanel(content, category)

		local btn = CreateFrame("Button", nil, navChild)
		btn:SetSize(NAV_WIDTH - 18, 30)
		-- No per-button border. A clean rail where only the accent bar and a soft
		-- background mark the active page.
		K.CreateBackground(btn, 0.16, 0.16, 0.16, 0.5)

		-- Accent bar on the left marks the active page.
		local acc = btn:CreateTexture(nil, "OVERLAY")
		acc:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
		acc:SetPoint("TOPLEFT", btn.KKUI_Background, "TOPLEFT", 0, 0)
		acc:SetPoint("BOTTOMLEFT", btn.KKUI_Background, "BOTTOMLEFT", 0, 0)
		acc:SetWidth(3)
		acc:Hide()
		btn.Accent = acc

		local iconName = CATEGORY_ICON[category.name]
		local hasIcon = iconName ~= nil or category.icon
		if hasIcon then
			-- Each icon sits in its own small chip, the same framed treatment the
			-- close button uses, so the row reads as a set of buttons.
			local chip = CreateFrame("Frame", nil, btn)
			chip:SetSize(24, 24)
			chip:SetPoint("LEFT", 6, 0)
			K.GradientBG(chip, 0.16, 0.17, 0.19, 0.9, 0.10, 0.10, 0.12, 0.9)
			K.CreateBorder(chip)

			local icon = chip:CreateTexture(nil, "ARTWORK")
			icon:SetPoint("TOPLEFT", 1, -1)
			icon:SetPoint("BOTTOMRIGHT", -1, 1)
			if iconName and K.SetGUIIcon then
				K.SetGUIIcon(icon, iconName)
			else
				icon:SetTexture(category.icon)
				icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
			end
		end

		local text = btn:CreateFontString(nil, "OVERLAY")
		K.SetFont(text, 12)
		text:SetPoint("LEFT", hasIcon and 34 or 12, 0)
		text:SetText(category.title)
		btn.Text = text

		-- A dot for "this page holds something new", a count on What's New.
		local dot = btn:CreateTexture(nil, "OVERLAY")
		dot:SetSize(8, 8)
		dot:SetColorTexture(NEW_COLOR[1], NEW_COLOR[2], NEW_COLOR[3], 1)
		dot:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
		dot:Hide()
		btn.Dot = dot

		local count = btn:CreateFontString(nil, "OVERLAY")
		K.SetFont(count, 11, "OUTLINE")
		count:SetTextColor(NEW_COLOR[1], NEW_COLOR[2], NEW_COLOR[3])
		count:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
		count:Hide()
		btn.Count = count

		local hl = btn:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints(btn.KKUI_Background)
		hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.2)

		btn:SetScript("OnClick", function()
			GUI.SelectPage(category.name)
		end)
		buttons[category.name] = btn
	end

	-- Group the page buttons. Top pages sit unlabelled, then each named group under
	-- a small heading, then anything left over under Other.
	local listed = {}
	local layout = {}
	for _, name in ipairs(TOP_PAGES) do
		if buttons[name] then
			listed[name] = true
			layout[#layout + 1] = { button = buttons[name] }
		end
	end
	local function AddGroup(title, names)
		local group = {}
		for _, name in ipairs(names) do
			if buttons[name] and not listed[name] then
				listed[name] = true
				group[#group + 1] = { button = buttons[name] }
			end
		end
		if #group == 0 then
			return
		end
		local heading = navChild:CreateFontString(nil, "OVERLAY")
		K.SetFont(heading, 10, "OUTLINE")
		heading:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
		heading:SetText(title:upper())
		layout[#layout + 1] = { heading = heading }
		for _, item in ipairs(group) do
			layout[#layout + 1] = item
		end
	end
	for _, group in ipairs(GROUPS) do
		AddGroup(group.title, group.pages)
	end
	local rest = {}
	for _, category in ipairs(GUI.schema) do
		if not listed[category.name] then
			rest[#rest + 1] = category.name
		end
	end
	AddGroup(L["Other"], rest)

	-- Where a setting lives, from the page down, page, the flyout it opens from
	-- when there is one, then the section when it adds something.
	local function WhereText(entry, separator, specificFirst)
		local parts = { entry.category.title }
		if entry.extra and entry.extra.label then
			parts[#parts + 1] = entry.extra.label
		end
		if entry.section and entry.section ~= entry.category.title and entry.section ~= (entry.extra and entry.extra.label) then
			parts[#parts + 1] = entry.section
		end
		if specificFirst then
			-- Reverse it, so a narrow row that has to cut the end cuts the page name
			-- and keeps the part that tells two settings called "Width" apart.
			for i = 1, math.floor(#parts / 2) do
				parts[i], parts[#parts - i + 1] = parts[#parts - i + 1], parts[i]
			end
		end
		return table.concat(parts, separator)
	end

	-- Result rows for the search, built as needed.
	local resultRows = {}
	local function ResultRow(i)
		local row = resultRows[i]
		if row then
			return row
		end
		row = CreateFrame("Button", nil, navChild)
		row:SetSize(NAV_WIDTH - 18, 38)
		K.CreateBackground(row, K.Colors.raised[1], K.Colors.raised[2], K.Colors.raised[3], 0.5)
		row.name = row:CreateFontString(nil, "OVERLAY")
		K.SetFont(row.name, 12)
		row.name:SetPoint("TOPLEFT", 8, -5)
		row.name:SetPoint("RIGHT", row, "RIGHT", -6, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)
		row.where = row:CreateFontString(nil, "OVERLAY")
		K.SetFont(row.where, 10)
		row.where:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
		row.where:SetPoint("BOTTOMLEFT", 8, 5)
		row.where:SetPoint("RIGHT", row, "RIGHT", -6, 0)
		row.where:SetJustifyH("LEFT")
		row.where:SetWordWrap(false)
		local hl = row:CreateTexture(nil, "HIGHLIGHT")
		hl:SetAllPoints()
		hl:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.2)
		row:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.entry.label, 1, 1, 1)
			GameTooltip:AddLine(self.fullWhere or "", K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", GameTooltip_Hide)
		row:SetScript("OnClick", function(self)
			local entry = self.entry
			search:SetText("")
			search:ClearFocus()
			-- Clearing an already empty box fires no change, which is the case when
			-- the Changed list is showing, so put the page list back by hand.
			GUI.RelayoutNav("")
			GUI.JumpTo(entry)
		end)
		resultRows[i] = row
		return row
	end

	local noResults = navChild:CreateFontString(nil, "OVERLAY")
	K.SetFont(noResults, 11)
	noResults:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	noResults:SetPoint("TOP", navChild, "TOP", 0, -14)
	noResults:SetText(L["No settings found."])
	noResults:Hide()

	-- The Changed list replaces the page list, so it gets its own way back. The
	-- search box is empty then, and Escape in it does the same.
	local backRow = CreateFrame("Button", nil, navChild)
	backRow:SetSize(NAV_WIDTH - 18, 24)
	K.CreateBackground(backRow, K.Colors.raised[1], K.Colors.raised[2], K.Colors.raised[3], 0.5)
	backRow.text = backRow:CreateFontString(nil, "OVERLAY")
	K.SetFont(backRow.text, 12)
	backRow.text:SetPoint("LEFT", 8, 0)
	backRow.text:SetTextColor(K.Colors.info[1], K.Colors.info[2], K.Colors.info[3])
	backRow.text:SetText(L["Back to pages"])
	local backHighlight = backRow:CreateTexture(nil, "HIGHLIGHT")
	backHighlight:SetAllPoints()
	backHighlight:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.2)
	backRow:SetScript("OnClick", function()
		GUI.RelayoutNav("")
	end)
	backRow:Hide()

	-- Stack the page list, or the search results when there is a query.
	local function Relayout(query, forced)
		query = query and query:match("^%s*(.-)%s*$") or ""
		local y = -8
		local searching = query ~= "" or forced ~= nil
		for _, item in ipairs(layout) do
			local frame = item.button or item.heading
			if searching then
				frame:Hide()
			else
				frame:ClearAllPoints()
				if item.heading then
					frame:SetPoint("TOPLEFT", navChild, "TOPLEFT", 10, y - 6)
					y = y - 22
				else
					frame:SetPoint("TOP", navChild, "TOP", 0, y)
					y = y - 34
				end
				frame:Show()
			end
		end

		for _, row in ipairs(resultRows) do
			row:Hide()
		end
		noResults:Hide()
		backRow:Hide()
		if searching then
			local results = forced or GUI.Search(query, 30)
			-- Rows start below the back row when the Changed list is showing.
			local top = 0
			if forced then
				backRow:ClearAllPoints()
				backRow:SetPoint("TOP", navChild, "TOP", 0, -8)
				backRow:Show()
				top = 30
			end
			noResults:ClearAllPoints()
			noResults:SetPoint("TOP", navChild, "TOP", 0, -14 - top)
			noResults:SetText(forced and L["Nothing has been changed."] or L["No settings found."])
			noResults:SetShown(#results == 0)
			for i, entry in ipairs(results) do
				if i > 60 then
					break
				end
				local row = ResultRow(i)
				row.entry = entry
				row.name:SetText(entry.label)
				row.where:SetText(WhereText(entry, " < ", true))
				row.fullWhere = WhereText(entry, " > ")
				row:ClearAllPoints()
				row:SetPoint("TOP", navChild, "TOP", 0, -8 - top - (i - 1) * 42)
				row:Show()
			end
			y = -8 - top - min(#results, 60) * 42
		end
		navChild:SetHeight(-y + 10)
		navScroll:SetVerticalScroll(0)
	end
	Relayout("")
	GUI.RelayoutNav = Relayout

	search:SetScript("OnTextChanged", function(self)
		local text = self:GetText()
		searchHint:SetShown(text == "")
		Relayout(text)
	end)
	-- Enter opens the best match.
	search:SetScript("OnEnterPressed", function(self)
		local first = resultRows[1]
		if first and first:IsShown() and first.entry then
			first:Click()
		else
			self:ClearFocus()
		end
	end)
	search:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
		-- An already empty box fires no text change, which is the case while the
		-- Changed list shows, so put the page list back here.
		Relayout("")
	end)

	-- Footer. Reload button and hint.
	local reload = CreateFrame("Button", nil, window, "UIPanelButtonTemplate")
	reload:SetSize(140, 26)
	reload:SetPoint("BOTTOMRIGHT", -30, 12)
	reload:SetText(L["Reload UI"])
	K.SkinButton(reload, true)
	reload:SetScript("OnClick", ReloadUI)

	-- A glow that pulses on the reload button once a setting needs a reload.
	reloadGlow = reload:CreateTexture(nil, "BACKGROUND")
	reloadGlow:SetColorTexture(K.Colors.warning[1], K.Colors.warning[2], K.Colors.warning[3], 0.35)
	reloadGlow:SetPoint("TOPLEFT", -3, 3)
	reloadGlow:SetPoint("BOTTOMRIGHT", 3, -3)
	reloadGlow:Hide()
	local pulse = reloadGlow:CreateAnimationGroup()
	pulse:SetLooping("BOUNCE")
	local fade = pulse:CreateAnimation("Alpha")
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0.25)
	fade:SetDuration(0.8)
	reloadGlow.pulse = pulse

	reloadHint = window:CreateFontString(nil, "OVERLAY")
	K.SetFont(reloadHint, 11)
	reloadHint:SetPoint("BOTTOMLEFT", 16, 18)
	reloadHint:SetText(L["Changes marked with a reload take effect after /reload."])

	-- Key to the orange dot beside a changed setting.
	local legendDot = window:CreateTexture(nil, "OVERLAY")
	legendDot:SetSize(6, 6)
	legendDot:SetColorTexture(MODIFIED_COLOR[1], MODIFIED_COLOR[2], MODIFIED_COLOR[3], 1)
	-- The key sits left of the reload button so it never crowds the hint on the left.
	legendDot:SetPoint("RIGHT", reload, "LEFT", -150, 0)
	local legend = window:CreateFontString(nil, "OVERLAY")
	K.SetFont(legend, 10)
	legend:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	legend:SetPoint("RIGHT", reload, "LEFT", -14, 0)
	legend:SetJustifyH("RIGHT")
	legendDot:ClearAllPoints()
	legendDot:SetPoint("RIGHT", legend, "LEFT", -5, 0)
	legend:SetText(L["Changed from the default"])

	-- Click to list every setting that differs from its default in the page list.
	local legendButton = CreateFrame("Button", nil, window)
	legendButton:SetPoint("TOPLEFT", legendDot, "TOPLEFT", -4, 4)
	legendButton:SetPoint("BOTTOMRIGHT", legend, "BOTTOMRIGHT", 4, -4)
	local legendHover = legendButton:CreateTexture(nil, "HIGHLIGHT")
	legendHover:SetAllPoints()
	legendHover:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.2)
	legendButton:SetScript("OnClick", function()
		search:SetText("")
		search:ClearFocus()
		Relayout("", GUI.ChangedEntries())
	end)
	legendButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText(L["Changed settings"], 1, 1, 1)
		GameTooltip:AddLine(L["Click to list every setting that is not at its default."], K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3], true)
		GameTooltip:Show()
	end)
	legendButton:SetScript("OnLeave", GameTooltip_Hide)

	local function UpdateLegend()
		local count = #GUI.ChangedEntries()
		legend:SetText(count > 0 and string.format(L["Changed from the default (%d)"], count) or L["Changed from the default"])
	end
	UpdateLegend()
	local baseRefresh = GUI.RefreshModified
	GUI.RefreshModified = function()
		baseRefresh()
		UpdateLegend()
	end

	-- Resize grip in the bottom right corner.
	local grip = CreateFrame("Button", nil, window)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -3, 3)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	local reflowPending = false
	local function Reflow()
		reflowPending = false
		local info = pages[currentName]
		if info then
			FitPage(info)
		end
	end
	grip:SetScript("OnMouseDown", function()
		window:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function()
		window:StopMovingOrSizing()
		SaveWindow()
		Reflow()
	end)
	-- Reflow the open page a moment after the size settles, so a drag stays smooth.
	window:SetScript("OnSizeChanged", function()
		if not reflowPending then
			reflowPending = true
			C_Timer.After(0.1, Reflow)
		end
	end)

	GUI.SelectPage(GUI.schema[1].name)
	GUI.RefreshDependencies()
	window:Hide()
	return window
end

-- Light the reload hint and the reload button when a reload-flagged setting
-- changes.
function GUI.MarkReload()
	if reloadHint then
		reloadHint:SetTextColor(K.Colors.warning[1], K.Colors.warning[2], K.Colors.warning[3])
		local count = GUI.pendingCount
		reloadHint:SetText(count == 1 and L["1 change needs a reload to apply."] or string.format(L["%d changes need a reload to apply."], count))
	end
	if reloadGlow and not reloadGlow:IsShown() then
		reloadGlow:Show()
		reloadGlow.pulse:Play()
	end
end

function K.ToggleConfigGUI()
	if not window then
		BuildWindow()
	end
	window:SetShown(not window:IsShown())
end

-- Used by controls that hand the screen over to something else, like unlocking
-- the movers.
function GUI.Hide()
	if window then
		if GUI.HideExtras then
			GUI.HideExtras()
		end
		window:Hide()
	end
end
