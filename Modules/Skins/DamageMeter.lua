--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/DamageMeter.lua
	Purpose:
		Restyle the game's own damage meter (Blizzard_DamageMeter) to match the
		UI as a flat list. Our bar texture on a dark trough with a 1 pixel edge,
		the same edge on the class and spell icons, our font on the text, and
		flat panels with our border for the window header, body and the
		breakdown window.

		Layout, sizes, bar style, opacity and colours stay Blizzard's, set in Edit
		Mode. Only art is swapped, and only from secure hooks, so nothing here
		runs inside Blizzard's own calls. State lives in local tables, never on
		Blizzard's frames.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("DamageMeterSkin")

local _G = _G
local hooksecurefunc = hooksecurefunc
local CreateFrame = CreateFrame

-- Keys are Blizzard frames, so the tables never hold one alive on their own.
local styledEntries = setmetatable({}, { __mode = "k" })
local hookedEntries = setmetatable({}, { __mode = "k" })
local styledWindows = setmetatable({}, { __mode = "k" })

-- The game clips each row to its own rectangle, with the bar 1 pixel inside
-- it top and bottom. So rows get no border of their own (it would be cut off),
-- just a 1 pixel dark edge that fits in that gap, and the window body carries
-- the one real border around the whole list.
local EDGE_ALPHA = 0.9
local TROUGH_ALPHA = 0.6

local function RestyleFont(fontString)
	if not fontString then
		return
	end
	local _, size = fontString:GetFont()
	K.SetFont(fontString, size or 12, K.FontOutlineStyle())
end

-- ---------------------------------------------------------------------------
-- Entries (one bar in the list or in the breakdown)
-- ---------------------------------------------------------------------------

-- A dark rectangle 1 pixel larger than the frame on every side, under it.
local function AddEdge(frame, layer, subLevel)
	local edge = frame:CreateTexture(nil, layer, nil, subLevel)
	local px = K.Mult or 1
	edge:SetPoint("TOPLEFT", -px, px)
	edge:SetPoint("BOTTOMRIGHT", px, -px)
	edge:SetColorTexture(0, 0, 0, EDGE_ALPHA)
	return edge
end

-- The icon gets its edge inside its own square, since the row clips anything
-- outside it and the icon is as tall as the row.
local function StyleIcon(holder)
	local icon = holder and holder.Icon
	if not icon then
		return
	end
	local px = K.Mult or 1
	local edge = holder:CreateTexture(nil, "BACKGROUND", nil, -8)
	edge:SetAllPoints(holder)
	edge:SetColorTexture(0, 0, 0, EDGE_ALPHA)
	icon:ClearAllPoints()
	icon:SetPoint("TOPLEFT", holder, "TOPLEFT", px, -px)
	icon:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", -px, px)
end

-- Runs after every UpdateStyle, which puts back the edge art and the anchors.
local function AfterEntryStyle(entry)
	local bar = entry.StatusBar
	if not bar then
		return
	end

	if not styledEntries[entry] then
		styledEntries[entry] = true

		bar:SetStatusBarTexture(K.GetTexture(C.Unitframe.Texture))
		local trough = bar:CreateTexture(nil, "BACKGROUND", nil, -7)
		trough:SetAllPoints(bar)
		trough:SetColorTexture(K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], TROUGH_ALPHA)
		AddEdge(bar, "BACKGROUND", -8)

		StyleIcon(entry.Icon)
		RestyleFont(bar.Name)
		RestyleFont(bar.Value)

		-- A new texture can drop the tint the entry set before it was skinned.
		local color = entry.statusBarColor
		if color and color.GetRGB then
			bar:GetStatusBarTexture():SetVertexColor(color:GetRGB())
		end
	end

	-- Blizzard's shadow art is re-anchored on every style change, and the edge
	-- shown again, so both are hidden here each time.
	if bar.Background then
		bar.Background:Hide()
	end
	if bar.BackgroundEdge then
		bar.BackgroundEdge:Hide()
	end

	-- With icons on, the bar sits flush against the icon in every bar style.
	-- The bar's edge then lands on the icon's own edge, so the two share one
	-- dark line instead of leaving a gap.
	if entry.GetIconAttachmentAnchor and entry.ShouldShowBarIcons and entry:ShouldShowBarIcons() then
		local point, relativeTo, relativePoint = entry:GetIconAttachmentAnchor()
		if relativeTo == entry.Icon then
			bar:SetPoint(point, relativeTo, relativePoint, 0, 0)
		end
	end
end

-- Entries made after the mixin hook carry it already. Ones made before it are
-- hooked one by one, once.
local function HookEntry(entry)
	if not entry or hookedEntries[entry] then
		return
	end
	hookedEntries[entry] = true
	if entry.UpdateStyle ~= _G.DamageMeterEntryMixin.UpdateStyle then
		hooksecurefunc(entry, "UpdateStyle", AfterEntryStyle)
	end
	if entry.StatusBar then
		AfterEntryStyle(entry)
	end
end

-- ---------------------------------------------------------------------------
-- Windows
-- ---------------------------------------------------------------------------

-- Session window layout. The strip is the header's visible height, the gap is
-- the UI's usual 6 pixels between bordered pieces, and the inset is the room
-- between the body's top edge and the first row. The list starts 2 pixels
-- below the game's header texture (DamageMeterSessionWindow.lua).
local HEADER_STRIP = 28
local HEADER_GAP = 6
local LIST_INSET = 6
local LIST_OFFSET = 2

-- Header buttons: small squares centred in the strip. Our border draws about
-- a pixel outside each button, so these numbers were measured on screen to
-- leave the same 4 visible pixels between buttons as between a button and the
-- strip's own border, and 5 before the title text. The game never re-anchors
-- them after load.
local BUTTON_SIZE = 18
local BUTTON_INSET = (HEADER_STRIP - BUTTON_SIZE) / 2
local BUTTON_GAP = 7
local TITLE_GAP = 4

-- Every glyph in the header is gold and lights up on hover, like the fold and
-- close buttons elsewhere.
local GLYPH_HOVER = { 1, 0.86, 0.4 }
-- A small flat gear from the quest log, tinted to match. A full colour item
-- icon turns to mud at this size.
local SETTINGS_ATLAS = "QuestLog-icon-setting"
local SETTINGS_WIDTH = 12
local SETTINGS_HEIGHT = 13

-- The down chevron on the title's menu button, drawn from two bars like the
-- fold and close glyphs, so it stays crisp at any size.
local CHEVRON_BAR = 8
local CHEVRON_STROKE = 2.75
local CHEVRON_RISE = 0.5
local CHEVRON_HALF = CHEVRON_BAR / 2 * math.cos(math.pi / 4)

-- The settings dropdown swaps its own atlas on every hover and press, at the
-- alpha our strip left it at, so only our gear shows.
local function SkinSettingsButton(button)
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	K.SkinButton(button)
	local info = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(SETTINGS_ATLAS)
	if not info then
		return
	end
	-- The gear art is dark grey, so tinting it came out at under half the gold
	-- of the other glyphs. A flat gold fill cut to the gear's shape by a mask
	-- matches them exactly.
	local gold = K.Colors.highlight
	local icon = button:CreateTexture(nil, "OVERLAY")
	icon:SetSize(SETTINGS_WIDTH, SETTINGS_HEIGHT)
	icon:SetPoint("CENTER")
	icon:SetColorTexture(gold[1], gold[2], gold[3])
	local mask = button:CreateMaskTexture()
	mask:SetAtlas(SETTINGS_ATLAS)
	mask:SetAllPoints(icon)
	icon:AddMaskTexture(mask)
	button:HookScript("OnEnter", function()
		icon:SetColorTexture(GLYPH_HOVER[1], GLYPH_HOVER[2], GLYPH_HOVER[3])
	end)
	button:HookScript("OnLeave", function()
		icon:SetColorTexture(gold[1], gold[2], gold[3])
	end)
end

-- The session picker shows a short name ("O", "C") as text. It keeps the
-- game's width when that is wider, for languages with longer short names.
local function SkinSessionButton(button)
	local width = button:GetWidth()
	button:SetSize(width > BUTTON_SIZE and width or BUTTON_SIZE, BUTTON_SIZE)
	K.SkinButton(button)
	local label = button.SessionName
	if label then
		RestyleFont(label)
		-- Centred in the button, a pixel right, where the digit measured left
		-- of centre.
		label:ClearAllPoints()
		label:SetPoint("CENTER", button, "CENTER", 1, 0)
		local gold = K.Colors.highlight
		label:SetTextColor(gold[1], gold[2], gold[3])
		button:HookScript("OnEnter", function()
			label:SetTextColor(GLYPH_HOVER[1], GLYPH_HOVER[2], GLYPH_HOVER[3])
		end)
		button:HookScript("OnLeave", function()
			label:SetTextColor(gold[1], gold[2], gold[3])
		end)
	end
end

local function AddChevron(button)
	local gold = K.Colors.highlight
	local function Bar(x, rotation)
		local bar = button:CreateTexture(nil, "OVERLAY")
		bar:SetColorTexture(gold[1], gold[2], gold[3])
		bar:SetSize(CHEVRON_BAR, CHEVRON_STROKE)
		K.DisablePixelSnap(bar)
		bar:SetPoint("CENTER", x, CHEVRON_RISE)
		bar:SetRotation(rotation)
		return bar
	end
	-- The two bars meet at the bottom centre, a V.
	local left = Bar(-CHEVRON_HALF, -math.pi / 4)
	local right = Bar(CHEVRON_HALF, math.pi / 4)
	button:HookScript("OnEnter", function()
		left:SetColorTexture(GLYPH_HOVER[1], GLYPH_HOVER[2], GLYPH_HOVER[3])
		right:SetColorTexture(GLYPH_HOVER[1], GLYPH_HOVER[2], GLYPH_HOVER[3])
	end)
	button:HookScript("OnLeave", function()
		left:SetColorTexture(gold[1], gold[2], gold[3])
		right:SetColorTexture(gold[1], gold[2], gold[3])
	end)
end

-- The title's menu button, left in the strip, with the title beside it. The
-- session timer stays in front of it as the game has it, and the button only
-- moves over for the timer while the timer has text.
local function LayoutTitle(window, strip, session)
	local button = window.DamageMeterTypeDropdown
	local timer = window.SessionTimer
	if not (button and timer) then
		return
	end
	button:SetSize(BUTTON_SIZE, BUTTON_SIZE)
	K.SkinButton(button)
	AddChevron(button)

	timer:ClearAllPoints()
	timer:SetPoint("LEFT", strip, "LEFT", BUTTON_INSET, 0)

	local hadText
	local function Place()
		local text = timer:GetText()
		local hasText = text ~= nil and not K.IsSecret(text) and text ~= ""
		if hasText == hadText then
			return
		end
		hadText = hasText
		button:ClearAllPoints()
		-- An empty font string still takes up a pixel, so without a timer the
		-- button goes on the strip itself, level with the right side.
		if hasText then
			button:SetPoint("LEFT", timer, "RIGHT", BUTTON_GAP, 0)
		else
			button:SetPoint("LEFT", strip, "LEFT", BUTTON_INSET, 0)
		end
	end
	Place()
	hooksecurefunc(timer, "SetText", Place)

	-- The game hangs the title off its own arrow art, which is now hidden and
	-- smaller than our button, so the title is moved past the button.
	local title = button.TypeName
	if title then
		title:ClearAllPoints()
		title:SetPoint("LEFT", button, "RIGHT", TITLE_GAP, 0)
		if session then
			title:SetPoint("RIGHT", session, "LEFT", -BUTTON_GAP, 0)
		end
	end
end

local function LayoutHeaderButtons(window, header, strip)
	local fold = window.MinimizeButton
	local settings = window.SettingsDropdown
	local session = window.SessionDropdown

	local previous
	if fold then
		fold:SetSize(BUTTON_SIZE, BUTTON_SIZE)
		fold:ClearAllPoints()
		fold:SetPoint("TOPRIGHT", header, "TOPRIGHT", -BUTTON_INSET, -BUTTON_INSET)
		previous = fold
	end
	if settings then
		SkinSettingsButton(settings)
		settings:ClearAllPoints()
		if previous then
			settings:SetPoint("RIGHT", previous, "LEFT", -BUTTON_GAP, 0)
		else
			settings:SetPoint("TOPRIGHT", header, "TOPRIGHT", -BUTTON_INSET, -BUTTON_INSET)
		end
		previous = settings
	end
	if session then
		SkinSessionButton(session)
		session:ClearAllPoints()
		if previous then
			session:SetPoint("RIGHT", previous, "LEFT", -BUTTON_GAP, 0)
		else
			session:SetPoint("TOPRIGHT", header, "TOPRIGHT", -BUTTON_INSET, -BUTTON_INSET)
		end
	end

	LayoutTitle(window, strip, session)
end

local function SkinPanelTexture(texture)
	if texture then
		texture:SetColorTexture(K.Colors.panel[1], K.Colors.panel[2], K.Colors.panel[3], 0.9)
	end
end

-- The breakdown window that opens from a bar.
local function SkinSourceWindow(window)
	if not window or styledWindows[window] then
		return
	end
	styledWindows[window] = true

	SkinPanelTexture(window.Background)
	K.CreateBorder(window)
	if window.CloseButton then
		K.SkinCloseButton(window.CloseButton)
	end
	if window.ForEachEntryFrame then
		window:ForEachEntryFrame(HookEntry)
	end
end

local function SkinSessionWindow(window)
	if not window or styledWindows[window] then
		return
	end
	styledWindows[window] = true

	-- Header: a flat strip with its own border, always shown, even folded. The
	-- game's header texture only serves as the anchor the list hangs from, so
	-- its art is cleared and it is made taller. That moves the list down far
	-- enough to fit the gap and the body's own border below our strip.
	local header = window.Header
	local strip
	if header then
		header:SetColorTexture(0, 0, 0, 0)
		header:SetHeight(HEADER_STRIP + HEADER_GAP + LIST_INSET - LIST_OFFSET)
		strip = CreateFrame("Frame", nil, window)
		strip:SetPoint("TOPLEFT", header, "TOPLEFT")
		strip:SetPoint("TOPRIGHT", header, "TOPRIGHT")
		strip:SetHeight(HEADER_STRIP)
		strip:SetFrameLevel(window:GetFrameLevel())
		local fill = strip:CreateTexture(nil, "BACKGROUND")
		fill:SetAllPoints(strip)
		fill:SetColorTexture(K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.9)
		K.CreateBorder(strip)
	end

	-- Body: its own panel starting one gap below the header strip, so the two
	-- borders stand apart. The game's background is moved onto it, and keeps
	-- the opacity setting, which only sets that texture's alpha. The panel
	-- lives in the fold container, so folding hides it with the list.
	local container = window.MinimizeContainer
	if container then
		local body = container
		if header then
			body = CreateFrame("Frame", nil, container)
			body:SetPoint("TOPLEFT", header, "TOPLEFT", 0, -(HEADER_STRIP + HEADER_GAP))
			body:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT")
			body:SetFrameLevel(container:GetFrameLevel())
			if container.Background then
				container.Background:ClearAllPoints()
				container.Background:SetAllPoints(body)
			end
		end
		SkinPanelTexture(container.Background)
		K.CreateBorder(body)
		RestyleFont(container.NotActive)
	end

	RestyleFont(window.SessionTimer)
	if window.DamageMeterTypeDropdown then
		RestyleFont(window.DamageMeterTypeDropdown.TypeName)
	end
	if window.SessionDropdown then
		RestyleFont(window.SessionDropdown.SessionName)
	end

	-- Our fold button. Blizzard puts its atlas back on every fold, so the art is
	-- cleared again after each one and our glyph follows the state.
	local fold = window.MinimizeButton
	if fold then
		local setOpen = K.SkinFoldButton(fold)
		local function AfterMinimize(self)
			local normal, pushed = fold:GetNormalTexture(), fold:GetPushedTexture()
			if normal then
				normal:SetAlpha(0)
			end
			if pushed then
				pushed:SetAlpha(0)
			end
			if setOpen then
				setOpen(not self:IsMinimized())
			end
		end
		hooksecurefunc(window, "SetMinimized", AfterMinimize)
		AfterMinimize(window)
	end

	if strip then
		LayoutHeaderButtons(window, header, strip)
	end

	if window.ForEachEntryFrame then
		window:ForEachEntryFrame(HookEntry)
	end
	if window.GetLocalPlayerEntry then
		HookEntry(window:GetLocalPlayerEntry())
	end
	if window.GetSourceWindow then
		SkinSourceWindow(window:GetSourceWindow())
	end
end

local function Setup()
	local meter = _G.DamageMeter
	local entryMixin = _G.DamageMeterEntryMixin
	if not meter or not entryMixin or not entryMixin.UpdateStyle then
		return
	end

	-- Every entry made from here on runs our pass after its style is applied.
	hooksecurefunc(entryMixin, "UpdateStyle", AfterEntryStyle)

	hooksecurefunc(meter, "SetupSessionWindow", function(_, _, windowData)
		SkinSessionWindow(windowData and windowData.sessionWindow)
	end)
	if meter.ForEachSessionWindow then
		meter:ForEachSessionWindow(SkinSessionWindow)
	end
end

function Module:OnEnable()
	if not (C.Skins and C.Skins.DamageMeter) then
		return
	end
	if _G.EventUtil and _G.EventUtil.ContinueOnAddOnLoaded then
		_G.EventUtil.ContinueOnAddOnLoaded("Blizzard_DamageMeter", Setup)
	end
end
