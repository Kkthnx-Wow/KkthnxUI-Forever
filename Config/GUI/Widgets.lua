--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Config/GUI/Widgets.lua
	Purpose:
		The GUI widget toolkit. Every control (check, slider, dropdown, colour,
		button, header) is built from a declarative control table and wired to a
		config path through K:SetConfig. Shared on K.GUI so the window and schema
		files can build panels without touching frame internals.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local format = string.format
local type = type
local pairs = pairs
local ipairs = ipairs

-- Shared theme accent, pulled from the palette so a palette change flows through
-- every widget instead of leaving stray hardcoded colours behind.
local ACCENT = K.Colors.accent

local GUI = {}
K.GUI = GUI

-- control -> function that redraws its widget from a value, so a reset can update
-- what is on screen instead of leaving stale widgets behind.
GUI.refreshers = {}

-- Settings that only take effect after a reload. The window gives each one a small
-- "needs reload" tag, shown once the setting is changed.
GUI.reloadMarks = {}
GUI.pendingReload = {}
GUI.pendingCount = 0

function GUI.FlagReload(control)
	if not control.reload then
		return
	end
	if not GUI.pendingReload[control] then
		GUI.pendingReload[control] = true
		GUI.pendingCount = GUI.pendingCount + 1
	end
	local mark = GUI.reloadMarks[control]
	if mark then
		mark:Show()
	end
	if GUI.MarkReload then
		GUI.MarkReload()
	end
end

-- ---------------------------------------------------------------------------
-- Config path access
-- ---------------------------------------------------------------------------

function GUI.GetValue(path)
	local node = C
	for i = 1, #path do
		node = node[path[i]]
		if node == nil then
			return nil
		end
	end
	return node
end

-- The value a setting ships with, read from the defaults table the live config was
-- built from. Used by the right-click reset and shown in the tooltip.
function GUI.GetDefault(path)
	local node = K.ConfigDefaults
	if not node then
		return nil
	end
	for i = 1, #path do
		node = node[path[i]]
		if node == nil then
			return nil
		end
	end
	return node
end

-- Copy a default before it reaches the live config, so the two never share a
-- table and editing a colour cannot rewrite what "default" means.
local function CopyDefault(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for k, v in pairs(value) do
		copy[k] = CopyDefault(v)
	end
	return copy
end

-- Render a value the way it reads in a tooltip. Colours are a table of three
-- numbers, everything else is a plain scalar.
local function DescribeValue(control, value)
	if value == nil then
		return nil
	end
	if type(value) == "boolean" then
		return value and (L["On"]) or (L["Off"])
	end
	if type(value) == "table" then
		if control.kind == "color" and value[1] then
			return format("|cff%02x%02x%02x%s|r", (value[1] or 0) * 255, (value[2] or 0) * 255, (value[3] or 0) * 255, L["this colour"])
		end
		return nil
	end
	-- Show the readable label for a dropdown rather than the stored value.
	if control.options then
		for _, opt in ipairs(control.options) do
			if opt.value == value then
				return tostring(opt.text)
			end
		end
	end
	if type(value) == "number" then
		return tostring(K.Round(value * 100) / 100)
	end
	return tostring(value)
end

-- Attach the shared hover tooltip, and wire right-click to put the setting back
-- to its default. refresh redraws the widget after a reset, since the control
-- holds its own display state.
-- The label of the setting a control depends on, so a greyed row can say what to
-- switch on. Built once from the schema, keyed by config path.
local labelByPath
local function DependencyLabel(path)
	if not labelByPath then
		labelByPath = {}
		local function Walk(node, depth)
			if type(node) ~= "table" or depth > 8 then
				return
			end
			if type(node.path) == "table" and type(node.label) == "string" then
				local key = table.concat(node.path, ".")
				labelByPath[key] = labelByPath[key] or node.label
			end
			for _, child in pairs(node) do
				if type(child) == "table" and child ~= node.path then
					Walk(child, depth + 1)
				end
			end
		end
		Walk(GUI.schema, 0)
	end
	return labelByPath[table.concat(path, ".")]
end

function GUI.AttachTooltip(frame, control, refresh)
	local resettable = control.path ~= nil
	if not (control.tooltip or resettable) then
		return
	end

	if refresh and control.path then
		GUI.refreshers[control] = refresh
	end

	frame:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(control.label or "", 1, 1, 1)
		if control.tooltip then
			GameTooltip:AddLine(control.tooltip, K.Colors.silver[1], K.Colors.silver[2], K.Colors.silver[3], true)
		end
		if GUI.IsNew(control) then
			GameTooltip:AddLine(format(L["New in %s"], control.since), 1, 0.82, 0)
		end
		if GUI.IsModified(control) then
			GameTooltip:AddLine(L["Changed from the default."], 1, 0.6, 0.2)
		end
		-- Say why a greyed row is greyed.
		if control.dependsOn and not GUI.GetValue(control.dependsOn) then
			local dependency = DependencyLabel(control.dependsOn)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(dependency and format(L["Turn on %s first to use this."], dependency) or L["Another setting has to be on first."], 1, 0.5, 0.25, true)
		end
		if control.disabledWhen and GUI.GetValue(control.disabledWhen) then
			local managing = DependencyLabel(control.disabledWhen)
			GameTooltip:AddLine(" ")
			GameTooltip:AddLine(managing and format(L["Turn off %s to change this."], managing) or L["Another setting is managing this one."], 1, 0.5, 0.25, true)
		end
		if resettable then
			local shown = DescribeValue(control, GUI.GetDefault(control.path))
			GameTooltip:AddLine(" ")
			if shown then
				GameTooltip:AddLine(format(L["Right click to reset to default (%s)"], shown), 0.6, 0.8, 1, true)
			else
				GameTooltip:AddLine(L["Right click to reset to default"], 0.6, 0.8, 1, true)
			end
		end
		GameTooltip:Show()
	end)
	frame:HookScript("OnLeave", GameTooltip_Hide)

	if not resettable then
		return
	end

	local function Reset(_, button)
		if button ~= "RightButton" then
			return
		end
		local default = GUI.GetDefault(control.path)
		if default == nil then
			return
		end
		GUI.ApplyChange(control, CopyDefault(default))
		if refresh then
			refresh(default)
		end
	end

	frame:EnableMouse(true)
	-- Only a Button has OnClick. Plain frames (the slider and dropdown holders)
	-- take the right-click through OnMouseUp instead.
	if frame.RegisterForClicks then
		frame:RegisterForClicks("AnyUp")
		frame:HookScript("OnClick", Reset)
	else
		frame:HookScript("OnMouseUp", Reset)
	end
end

-- Put every setting in one category back to what it ships with. Right-click
-- already resets a single control, but a page like Unitframes holds dozens and
-- clicking through them one at a time is not a fix, it is a chore.
--
-- Flyout pages are reached through searchControls, the same list the category
-- search reads, so a reset covers the per-bar and per-unit settings that live
-- one level down rather than stopping at the button that opens them.
local function ResetControls(controls, count)
	for _, control in ipairs(controls or {}) do
		if control.path then
			local default = GUI.GetDefault(control.path)
			if default ~= nil then
				K:SetConfig(control.path, CopyDefault(default))
				local refresh = GUI.refreshers[control]
				if refresh then
					refresh(default)
				end
				GUI.FlagReload(control)
				count = count + 1
			end
		end
		count = ResetControls(control.searchControls, count)
	end
	return count
end

function GUI.ResetCategory(category)
	if not category then
		return 0
	end
	local count = ResetControls(category.controls, 0)
	if count > 0 then
		-- Widgets that can redraw themselves already did. Settings that apply
		-- through a reload still need one to land, so say so.
		GUI.RefreshDependencies()
		GUI.RefreshModified()
	end
	return count
end

-- Apply a changed value: persist it, run any live callback, flag reload need,
-- then refresh any controls whose enabled state depends on other settings.
function GUI.ApplyChange(control, value)
	K:SetConfig(control.path, value)
	if control.apply then
		control.apply(value)
	end
	GUI.FlagReload(control)
	GUI.RefreshDependencies()
	GUI.RefreshModified()
end

-- ---------------------------------------------------------------------------
-- Dependency (grey-out) system
-- ---------------------------------------------------------------------------
-- A control may declare `dependsOn = { path... }`. When that config value is
-- falsy the widget greys out and stops responding. Each builder attaches a
-- widget.KKUI_SetEnabled(enabled) so one refresh pass can update them all.

GUI.dependents = {}

-- `dependsOn` greys a control while that setting is off. `disabledWhen` is the
-- reverse, it greys the control while that setting is on, for a value another
-- setting manages (the UI scale slider while Auto UI Scale is on).
function GUI.RegisterDependent(widget, control)
	if control.dependsOn or control.disabledWhen then
		GUI.dependents[#GUI.dependents + 1] = { widget = widget, path = control.dependsOn, off = control.disabledWhen }
	end
end

function GUI.RefreshDependencies()
	for _, entry in ipairs(GUI.dependents) do
		if entry.widget.KKUI_SetEnabled then
			local enabled = true
			if entry.path then
				enabled = GUI.GetValue(entry.path) and true or false
			end
			if enabled and entry.off and GUI.GetValue(entry.off) then
				enabled = false
			end
			entry.widget.KKUI_SetEnabled(enabled)
		end
	end
end

-- A small dot beside every setting that differs from its default. The window
-- registers one per control as it builds the page.
GUI.modifiedDots = {}

function GUI.RefreshModified()
	for control, dot in pairs(GUI.modifiedDots) do
		dot:SetShown(GUI.IsModified(control))
	end
end

-- ---------------------------------------------------------------------------
-- Shared look helpers
-- ---------------------------------------------------------------------------

local function SkinButton(button)
	K.CreateBackground(button, 0.2, 0.2, 0.2, 0.7)
	K.CreateBorder(button)
	local fs = button:GetFontString()
	if fs then
		fs:SetTextColor(K.Colors.offWhite[1], K.Colors.offWhite[2], K.Colors.offWhite[3])
	end
end

-- ---------------------------------------------------------------------------
-- Header / description (non-interactive)
-- ---------------------------------------------------------------------------

function GUI.CreateHeader(parent, control)
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetSize(440, 24)

	local fs = frame:CreateFontString(nil, "OVERLAY")
	K.SetFont(fs, 14, "OUTLINE")
	fs:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	fs:SetPoint("LEFT", frame, "LEFT", 0, 0)
	fs:SetText(control.label)

	-- A soft rule trailing the label so each section reads as its own block.
	local rule = frame:CreateTexture(nil, "ARTWORK")
	rule:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.22)
	rule:SetHeight(1)
	rule:SetPoint("LEFT", fs, "RIGHT", 8, 0)
	rule:SetPoint("RIGHT", frame, "RIGHT", -6, 0)

	frame.height = 28
	return frame
end

function GUI.CreateDescription(parent, control)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(fs, 11)
	fs:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	fs:SetWidth(440)
	fs:SetJustifyH("LEFT")
	fs:SetSpacing(3)
	fs:SetText(control.label)
	fs.height = (fs:GetStringHeight() or 12) + 8
	return fs
end

-- ---------------------------------------------------------------------------
-- Checkbox
-- ---------------------------------------------------------------------------

function GUI.CreateCheck(parent, control)
	local check = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
	K.SkinCheckBox(check)

	check.Text:ClearAllPoints()
	check.Text:SetPoint("LEFT", check, "RIGHT", 8, 0)
	check.Text:SetText(control.label)
	K.SetFont(check.Text, 12)
	check.Text:SetTextColor(K.Colors.offWhite[1], K.Colors.offWhite[2], K.Colors.offWhite[3])

	check:SetChecked(GUI.GetValue(control.path) and true or false)
	check:SetScript("OnClick", function(self, button)
		-- Right-click is the reset gesture, and the template flips the box on any
		-- button, so put it back and let the shared handler do the reset.
		if button == "RightButton" then
			self:SetChecked(GUI.GetValue(control.path) and true or false)
			return
		end
		GUI.ApplyChange(control, self:GetChecked() and true or false)
	end)
	GUI.AttachTooltip(check, control, function(value)
		check:SetChecked(value and true or false)
	end)

	check.KKUI_SetEnabled = function(enabled)
		check:SetEnabled(enabled)
		check.Text:SetTextColor(enabled and 1 or 0.4, enabled and 1 or 0.4, enabled and 1 or 0.4)
	end
	GUI.RegisterDependent(check, control)

	check.height = 30
	return check
end

-- ---------------------------------------------------------------------------
-- Slider
-- ---------------------------------------------------------------------------

function GUI.CreateSlider(parent, control)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(260, 50)

	local label = holder:CreateFontString(nil, "OVERLAY")
	K.SetFont(label, 12)
	label:SetPoint("TOPLEFT")
	label:SetText(control.label)

	-- A bare slider, built from scratch, so no Blizzard template art can leak
	-- through. Track is a sibling frame one level below the slider so the thumb
	-- (a texture on the slider) still draws above it.
	local slider = CreateFrame("Slider", nil, holder)
	slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -12)
	slider:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
	slider:SetHeight(16)
	slider:SetOrientation("HORIZONTAL")
	slider:SetMinMaxValues(control.min, control.max)
	slider:SetValueStep(control.step)
	slider:SetObeyStepOnDrag(true)
	slider:SetHitRectInsets(0, 0, -8, -8)

	local track = CreateFrame("Frame", nil, holder)
	track:SetFrameLevel(math.max(0, slider:GetFrameLevel() - 1))
	track:SetPoint("LEFT", slider, "LEFT", 0, 0)
	track:SetPoint("RIGHT", slider, "RIGHT", 0, 0)
	track:SetHeight(6)
	K.CreateBackground(track, 0.08, 0.08, 0.08, 0.95)
	K.CreateBorder(track)

	-- A crisp square handle to match our square, bordered UI rather than a soft dot:
	-- a bright fill sitting on a dark backing square that reads as a thin border, and
	-- an accent line down its middle so it looks like a grabbable knob. The backing
	-- is anchored to the thumb so it slides along with it.
	local THUMB = { 0.6, 0.78, 1.0 }
	local THUMB_HOVER = { 0.82, 0.9, 1.0 }

	local thumb = slider:CreateTexture(nil, "OVERLAY")
	thumb:SetColorTexture(THUMB[1], THUMB[2], THUMB[3], 1)
	thumb:SetSize(10, 18)
	slider:SetThumbTexture(thumb)

	local border = slider:CreateTexture(nil, "ARTWORK")
	border:SetColorTexture(0.04, 0.04, 0.04, 1)
	border:SetSize(14, 22)
	border:SetPoint("CENTER", thumb, "CENTER", 0, 0)

	slider:HookScript("OnEnter", function()
		thumb:SetColorTexture(THUMB_HOVER[1], THUMB_HOVER[2], THUMB_HOVER[3], 1)
	end)
	slider:HookScript("OnLeave", function()
		thumb:SetColorTexture(THUMB[1], THUMB[2], THUMB[3], 1)
	end)

	local low = holder:CreateFontString(nil, "OVERLAY")
	K.SetFont(low, 10)
	low:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	low:SetPoint("TOPLEFT", slider, "BOTTOMLEFT", 0, -2)
	low:SetText(control.min)

	local high = holder:CreateFontString(nil, "OVERLAY")
	K.SetFont(high, 10)
	high:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	high:SetPoint("TOPRIGHT", slider, "BOTTOMRIGHT", 0, -2)
	high:SetText(control.max)

	local step = control.step
	local function Round(v)
		return step >= 1 and K.Round(v) or K.Round(v, 2)
	end

	-- Editable value box, top-right. Type a number and press enter to set it.
	local valueBox = CreateFrame("EditBox", nil, holder, "InputBoxTemplate")
	valueBox:SetSize(52, 18)
	valueBox:SetPoint("TOPRIGHT", holder, "TOPRIGHT", -2, 0)
	valueBox:SetAutoFocus(false)
	valueBox:SetJustifyH("CENTER")
	K.SkinEditBox(valueBox)
	valueBox:SetScript("OnEnterPressed", function(self)
		local v = tonumber(self:GetText())
		if v then
			slider:SetValue(K.Clamp(Round(v), control.min, control.max))
		end
		self:ClearFocus()
	end)
	valueBox:SetScript("OnEscapePressed", valueBox.ClearFocus)

	local value = GUI.GetValue(control.path) or control.min
	slider:SetValue(value)
	valueBox:SetText(Round(value))

	slider:SetScript("OnValueChanged", function(_, v)
		v = Round(v)
		if not valueBox:HasFocus() then
			valueBox:SetText(v)
		end
		GUI.ApplyChange(control, v)
	end)

	holder.KKUI_SetEnabled = function(enabled)
		slider:SetEnabled(enabled)
		valueBox:SetEnabled(enabled)
		holder:SetAlpha(enabled and 1 or 0.4)
		label:SetTextColor(enabled and 1 or 0.5, enabled and 1 or 0.5, enabled and 1 or 0.5)
	end
	GUI.AttachTooltip(holder, control, function(reset)
		slider:SetValue(K.Clamp(Round(reset), control.min, control.max))
		valueBox:SetText(Round(reset))
	end)
	GUI.RegisterDependent(holder, control)

	holder.KKUI_SetWidth = function(w)
		holder:SetWidth(w)
	end

	holder.height = 66
	return holder
end

-- ---------------------------------------------------------------------------
-- Dropdown (lightweight, no UIDropDownMenu taint)
-- ---------------------------------------------------------------------------

function GUI.CreateDropdown(parent, control)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(260, 46)

	local label = holder:CreateFontString(nil, "OVERLAY")
	K.SetFont(label, 12)
	label:SetPoint("TOPLEFT")
	label:SetText(control.label)

	local button = CreateFrame("Button", nil, holder)
	button:SetHeight(22)
	button:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -6)
	button:SetPoint("RIGHT", holder, "RIGHT", 0, 0)
	SkinButton(button)

	-- A real chevron from SquareButtonTextures (greyscale, so it tints), instead
	-- of a typed "v". The down-arrow is the up-arrow with its V coords flipped.
	local arrow = button:CreateTexture(nil, "OVERLAY")
	arrow:SetTexture("Interface\\BUTTONS\\SquareButtonTextures")
	arrow:SetTexCoord(0.45312500, 0.64062500, 0.20312500, 0.01562500)
	arrow:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3])
	arrow:SetSize(14, 14)
	arrow:SetPoint("RIGHT", -6, 0)

	local text = button:CreateFontString(nil, "OVERLAY")
	K.SetFont(text, 12)
	text:SetPoint("LEFT", 6, 0)
	text:SetPoint("RIGHT", arrow, "LEFT", -4, 0)
	text:SetJustifyH("LEFT")

	local function CurrentText()
		local value = GUI.GetValue(control.path)
		for _, opt in ipairs(control.options) do
			if opt.value == value then
				return opt.text
			end
		end
		return tostring(value)
	end
	text:SetText(CurrentText())

	local menu = CreateFrame("Frame", nil, button)
	menu:SetPoint("TOPLEFT", button, "BOTTOMLEFT", 0, -2)
	menu:SetPoint("TOPRIGHT", button, "BOTTOMRIGHT", 0, -2)
	menu:SetFrameStrata("FULLSCREEN_DIALOG")
	K.CreateBackground(menu, 0.05, 0.05, 0.05, 0.95)
	K.CreateBorder(menu)
	menu:Hide()

	local rowY = -4
	for _, opt in ipairs(control.options) do
		local row = CreateFrame("Button", nil, menu)
		row:SetHeight(20)
		row:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, rowY)
		row:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, rowY)
		rowY = rowY - 20
		local rowText = row:CreateFontString(nil, "OVERLAY")
		K.SetFont(rowText, 12)
		rowText:SetPoint("LEFT", 6, 0)
		rowText:SetText(opt.text)
		row:SetHighlightTexture(C.Media.Textures.White8x8)
		row:GetHighlightTexture():SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.3)
		row:SetScript("OnClick", function()
			GUI.ApplyChange(control, opt.value)
			text:SetText(CurrentText())
			menu:Hide()
		end)
	end
	menu:SetHeight(-rowY + 4)

	button:SetScript("OnClick", function()
		menu:SetShown(not menu:IsShown())
	end)

	GUI.AttachTooltip(holder, control, function()
		text:SetText(CurrentText())
	end)

	holder.KKUI_SetEnabled = function(enabled)
		button:SetEnabled(enabled)
		holder:SetAlpha(enabled and 1 or 0.4)
		label:SetTextColor(enabled and 1 or 0.5, enabled and 1 or 0.5, enabled and 1 or 0.5)
		if not enabled then
			menu:Hide()
		end
	end
	GUI.RegisterDependent(holder, control)

	holder.KKUI_SetWidth = function(w)
		holder:SetWidth(w)
	end

	holder.height = 50
	return holder
end

-- ---------------------------------------------------------------------------
-- Colour picker
-- ---------------------------------------------------------------------------

function GUI.CreateColor(parent, control)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(260, 26)

	local swatch = CreateFrame("Button", nil, holder)
	swatch:SetSize(18, 18)
	swatch:SetPoint("LEFT")
	K.CreateBorder(swatch)
	local tex = swatch:CreateTexture(nil, "ARTWORK")
	tex:SetAllPoints()
	tex:SetColorTexture(1, 1, 1)

	local label = holder:CreateFontString(nil, "OVERLAY")
	K.SetFont(label, 12)
	label:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
	label:SetText(control.label)

	local function Refresh()
		local c = GUI.GetValue(control.path) or { 1, 1, 1, 1 }
		tex:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
	end
	Refresh()

	swatch:SetScript("OnClick", function()
		local c = GUI.GetValue(control.path) or { 1, 1, 1, 1 }
		-- Modern ColorPickerFrame: alpha comes from GetColorAlpha (1 = opaque),
		-- and info.opacity is that same alpha. The old OpacitySliderFrame is gone.
		local function apply()
			local r, g, b = ColorPickerFrame:GetColorRGB()
			local a = ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha() or (c[4] or 1)
			GUI.ApplyChange(control, { r, g, b, a })
			Refresh()
		end
		local info = {
			r = c[1], g = c[2], b = c[3], opacity = c[4] or 1, hasOpacity = true,
			swatchFunc = apply, opacityFunc = apply,
			cancelFunc = function()
				GUI.ApplyChange(control, c)
				Refresh()
			end,
		}
		if ColorPickerFrame.SetupColorPickerAndShow then
			ColorPickerFrame:SetupColorPickerAndShow(info)
		else
			ColorPickerFrame:Show()
		end
	end)

	holder.height = 30
	return holder
end

-- ---------------------------------------------------------------------------
-- Action button (runs a callback)
-- ---------------------------------------------------------------------------

-- A fixed width clipped longer labels, so grow the button to fit its text and
-- keep the requested width as the minimum. Call after the label is set.
function GUI.FitButtonWidth(button, minWidth)
	local fs = button:GetFontString()
	local width = minWidth
	if fs then
		width = math.max(minWidth, math.ceil(fs:GetStringWidth()) + 24)
	end
	button:SetWidth(width)
end

function GUI.CreateButton(parent, control)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(control.width or 150, 24)
	button:SetText(control.label)
	K.SkinButton(button)
	GUI.FitButtonWidth(button, control.width or 150)
	button:SetScript("OnClick", function()
		if control.onClick then
			control.onClick()
		end
	end)
	GUI.AttachTooltip(button, control)
	button.height = 30
	return button
end

-- ---------------------------------------------------------------------------
-- Text entry (free-form string, e.g. a comma separated keyword list)
-- ---------------------------------------------------------------------------

function GUI.CreateEditBox(parent, control)
	local holder = CreateFrame("Frame", nil, parent)
	holder:SetSize(260, 44)

	local label = holder:CreateFontString(nil, "OVERLAY")
	K.SetFont(label, 12)
	label:SetPoint("TOPLEFT")
	label:SetText(control.label)

	local edit = CreateFrame("EditBox", nil, holder)
	edit:SetSize(control.width or 220, 22)
	edit:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -4)
	edit:SetAutoFocus(false)
	edit:SetFontObject("ChatFontNormal")
	edit:SetTextInsets(6, 6, 0, 0)
	K.SkinEditBox(edit)
	edit:SetText(GUI.GetValue(control.path) or "")

	local function Commit()
		GUI.ApplyChange(control, edit:GetText() or "")
		edit:ClearFocus()
	end
	edit:SetScript("OnEnterPressed", Commit)
	edit:SetScript("OnEditFocusLost", Commit)
	edit:SetScript("OnEscapePressed", function()
		edit:SetText(GUI.GetValue(control.path) or "")
		edit:ClearFocus()
	end)

	holder.KKUI_SetEnabled = function(enabled)
		edit:EnableMouse(enabled)
		edit:SetAlpha(enabled and 1 or 0.4)
		label:SetAlpha(enabled and 1 or 0.4)
	end
	GUI.AttachTooltip(holder, control, function(value)
		edit:SetText(value or "")
	end)
	GUI.RegisterDependent(holder, control)

	holder.height = 48
	return holder
end

-- Dispatch table used by the window when laying out a panel.
GUI.Builders = {
	header = GUI.CreateHeader,
	description = GUI.CreateDescription,
	check = GUI.CreateCheck,
	slider = GUI.CreateSlider,
	dropdown = GUI.CreateDropdown,
	color = GUI.CreateColor,
	button = GUI.CreateButton,
	editbox = GUI.CreateEditBox,
}

-- Placeholder so ApplyChange can call it before the window defines it.
GUI.MarkReload = GUI.MarkReload or function() end
