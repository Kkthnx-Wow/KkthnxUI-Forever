--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/Skins.lua
	Purpose:
		Reusable skinning helpers so every widget in the addon shares one look.
		Each strips the Blizzard art from a standard template and applies our
		background plus border. Written defensively: missing regions are skipped
		so the same call works across game flavors.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local _G = _G

-- The palette lives in Core/Palette.lua, loaded before this file.
local accent = K.Colors.accent
local gold = K.Colors.highlight

-- ---------------------------------------------------------------------------
-- Shared gradient recipes
-- ---------------------------------------------------------------------------
-- Every gradient in the UI is drawn by tinting a plain texture, so there is no
-- gradient art to ship. The recipes live here rather than as loose numbers at
-- each call site, so retuning the theme is one edit and no two surfaces drift
-- apart. Each entry is { orientation, r1, g1, b1, r2, g2, b2, alpha }, with the
-- same alpha on both stops.
K.Gradients = {
	panel = { "VERTICAL", 0.050, 0.062, 0.080, 0.090, 0.114, 0.149, 0.95 },
	buttonRest = { "VERTICAL", 0.090, 0.114, 0.149, 0.050, 0.065, 0.085, 0.9 },
	buttonHover = { "VERTICAL", 0.220, 0.340, 0.520, 0.130, 0.200, 0.320, 1 },
	-- The hover stops turned over, so a held button reads as pushed in.
	buttonPressed = { "VERTICAL", 0.130, 0.200, 0.320, 0.220, 0.340, 0.520, 1 },
	close = { "VERTICAL", 0.420, 0.120, 0.120, 0.680, 0.220, 0.220, 0.95 },
	closeHover = { "VERTICAL", 0.600, 0.200, 0.200, 0.898, 0.325, 0.325, 1 },
}

-- Alpha steps the horizontal fades use, named so the chat washes and hairlines
-- stay in step with each other.
K.GradientAlpha = {
	wash = 0.6, -- the dark wash behind chat and its bars
	washSoft = 0.45, -- the lighter wash on the side buttons
	line = 0.7, -- a hairline at rest
	lineSoft = 0.6, -- a quieter hairline
	lineActive = 1, -- the lit hairline on the selected tab
	strip = 0.7, -- the name strip behind unit frame and group tool labels
	hover = 0.15, -- the cursor is over this frame
	select = 0.22, -- this frame's unit is your target
}

-- The tint those name strips wear. Deliberately dark and only faintly blue, the
-- text sitting on it is class coloured, so a bright strip fights it. Kept here so
-- both the unit frames and the group tools bar read the same value.
K.StripColor = { 0.075, 0.094, 0.129 }

-- Paint a texture with one of the named recipes. Pass an alpha to override the
-- recipe's own.
function K.ApplyGradient(texture, name, alpha)
	local g = K.Gradients[name]
	if not (texture and g) then
		return
	end
	local a = alpha or g[8]
	texture:SetGradient(g[1], CreateColor(g[2], g[3], g[4], a), CreateColor(g[5], g[6], g[7], a))
end

-- A horizontal fade from a colour out to nothing, which is what every chat wash
-- and hairline is. endAlpha lets a fade stop short of fully transparent.
function K.FadeGradient(texture, r, g, b, alpha, endAlpha)
	if not texture then
		return
	end
	texture:SetGradient("HORIZONTAL", CreateColor(r, g, b, alpha or 1), CreateColor(r, g, b, endAlpha or 0))
end

-- The dark wash, the most common fade of all.
function K.ShadeGradient(texture, alpha)
	K.FadeGradient(texture, 0, 0, 0, alpha or K.GradientAlpha.wash)
end

-- A soft shade behind a piece of text, strongest in the middle, fading out to
-- both edges. A texture gradient only runs one way, so this is two mirrored
-- halves that share one switch. Built from our own colours rather than a game
-- atlas, so every one of these matches the rest of the UI and the colour and
-- alpha are ours to set.
function K.CreateTextShade(parent, layer, subLevel)
	local shade = {}

	-- An invisible holder gives the pair one rectangle, the halves follow it, and
	-- anything that needs to stack above the shade has a real frame to anchor to.
	-- The textures stay on the parent so sitting on a child frame does not change
	-- the draw layer they were asked for.
	local holder = CreateFrame("Frame", nil, parent)
	shade.Holder = holder

	local left = parent:CreateTexture(nil, layer or "BACKGROUND", nil, subLevel or -1)
	local right = parent:CreateTexture(nil, layer or "BACKGROUND", nil, subLevel or -1)
	left:SetColorTexture(1, 1, 1)
	right:SetColorTexture(1, 1, 1)
	shade.Left, shade.Right = left, right

	left:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
	left:SetPoint("BOTTOMRIGHT", holder, "BOTTOM", 0, 0)
	right:SetPoint("TOPLEFT", holder, "TOP", 0, 0)
	right:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)

	-- Frame the given region, padded out by padX and padY.
	function shade:SetRegion(region, padX, padY)
		padX, padY = padX or 8, padY or 4
		holder:ClearAllPoints()
		holder:SetPoint("TOPLEFT", region, "TOPLEFT", -padX, padY)
		holder:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", padX, -padY)
	end

	-- Transparent at the outer edges, full in the middle where the text sits.
	function shade:SetColor(r, g, b, alpha)
		K.FadeGradient(left, r, g, b, 0, alpha or 1)
		K.FadeGradient(right, r, g, b, alpha or 1, 0)
	end

	function shade:SetShown(show)
		left:SetShown(show)
		right:SetShown(show)
	end

	function shade:Show()
		left:Show()
		right:Show()
	end

	function shade:Hide()
		left:Hide()
		right:Hide()
	end

	shade:Hide()
	return shade
end

-- Shared vertical gradient background, inset one pixel so our border stays clean.
-- Returns the texture so the caller can shift it on hover. Called without colours
-- it leaves the fill untinted, for a caller that follows up with K.ApplyGradient.
local function GradientBG(frame, r1, g1, b1, a1, r2, g2, b2, a2)
	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", 1, -1)
	bg:SetPoint("BOTTOMRIGHT", -1, 1)
	bg:SetColorTexture(1, 1, 1)
	if r1 then
		bg:SetGradient("VERTICAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
	end
	frame.KKUI_Background = bg
	return bg
end
K.GradientBG = GradientBG

-- Cooldown swipe. On Midnight the default radial swipe texture does not render, so
-- every cooldown frame we skin needs a real blank texture with our tint or it shows
-- no wipe at all, just the number. Colour defaults to a dark 80% swipe. Pass a
-- red-ish tint for loss-of-control cooldowns. Idempotent and safe to call once per
-- frame. Numbers stay Blizzard's native ones (the only ones that can read a secret
-- cooldown duration on Midnight), so this never touches SetHideCountdownNumbers.
local COOLDOWN_SWIPE_TEX = "Interface\\BUTTONS\\WHITE8X8"
function K.StyleCooldownSwipe(cooldown, r, g, b, a)
	if not (cooldown and cooldown.SetSwipeTexture) then
		return
	end
	cooldown:SetDrawSwipe(true)
	cooldown:SetSwipeTexture(COOLDOWN_SWIPE_TEX, r or 0, g or 0, b or 0, a or 0.8)
	cooldown:SetDrawEdge(false)
	if cooldown.SetUseCircularEdge then
		cooldown:SetUseCircularEdge(false)
	end
end

-- Panel backdrop. A subtle top-lit vertical gradient with a faint accent line at
-- the top edge, so large frames read with depth instead of a flat black slab.
-- Pair with K.CreateBorder. Returns the background texture.
function K.CreateGradientBackground(frame, alpha, keepOffFrame)
	local a = alpha or 0.95
	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1)
	K.ApplyGradient(bg, "panel", a)
	if not keepOffFrame then
		frame.KKUI_Background = bg
	end

	local top = frame:CreateTexture(nil, "BORDER")
	top:SetHeight(1)
	top:SetPoint("TOPLEFT", 1, -1)
	top:SetPoint("TOPRIGHT", -1, -1)
	top:SetColorTexture(accent[1], accent[2], accent[3], 0.18)
	return bg
end
local white = "Interface\\BUTTONS\\WHITE8X8"

-- ---------------------------------------------------------------------------
-- Button (UIPanelButtonTemplate and friends)
-- ---------------------------------------------------------------------------

-- The Gamepad UI shows its cursor by locking a button's highlight texture, and
-- the skins below clear that texture. With the Gamepad UI on, a faint fill goes
-- back in its place so the focused button can be seen. Off, the mouse hover the
-- skins draw themselves stays the only one.
local function GamepadFocus(button, color)
	if not (button.SetHighlightTexture and K.IsGamepadUI()) then
		return
	end
	button:SetHighlightTexture(white)
	local hl = button:GetHighlightTexture()
	if hl then
		hl:SetVertexColor(color[1], color[2], color[3], 0.25)
		hl:ClearAllPoints()
		hl:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		hl:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
	end
end

-- Hide every existing texture region on a frame (state textures included).
local function StripTextures(frame)
	if frame.SetNormalTexture then
		frame:SetNormalTexture(0)
		frame:SetPushedTexture(0)
		frame:SetDisabledTexture(0)
	end
	if frame.SetHighlightTexture then
		frame:SetHighlightTexture(0)
	end
	for _, region in ipairs({ frame:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "Texture" then
			region:SetAlpha(0)
		end
	end
	if frame.NineSlice then
		frame.NineSlice:SetAlpha(0)
	end
end
K.StripTextures = StripTextures

-- emphasize: gold text + gold hover border, for important actions (Reload, etc.).
function K.SkinButton(button, emphasize)
	if button.__skinned then
		return button
	end
	button.__skinned = true

	StripTextures(button)
	GamepadFocus(button, accent)

	local bg = GradientBG(button)
	K.ApplyGradient(bg, "buttonRest")
	K.CreateBorder(button)

	local restColor = emphasize and gold or K.Colors.offWhite
	local hoverColor = emphasize and K.Colors.text or K.Colors.info
	local hoverBorder = emphasize and gold or accent

	local fs = button:GetFontString()
	local dim = K.Colors.disabled
	-- The border lights up on hover, in the same colour the border takes.
	local glow = K.CreateHighlightBorder(button, hoverBorder[1], hoverBorder[2], hoverBorder[3], 0.45)
	-- Marked as this button's hover glow, so K.AddBorderHover (from the square
	-- button states) does not add a second one.
	button.KKUI_HoverGlow = glow

	-- A disabled button reads as grey and does not react to the mouse.
	local function RestText(self)
		if fs then
			local c = self:IsEnabled() and restColor or dim
			fs:SetTextColor(c[1], c[2], c[3])
		end
	end
	RestText(button)

	-- Hover. Lift the fill toward the accent and light the border, so every control
	-- reacts the same and the hover reads at a glance.
	-- Kept as a function so a caller can put the hover back, a frame that has its
	-- OnEnter or OnLeave replaced with SetScript loses these hooks, which the game
	-- menu does to its pooled buttons every time it rebuilds.
	local function HookHover()
		button:HookScript("OnEnter", function(self)
			if not self:IsEnabled() then
				return
			end
			K.ApplyGradient(bg, "buttonHover")
			if self.KKUI_Border then
				K.SetBorderColor(self.KKUI_Border, hoverBorder[1], hoverBorder[2], hoverBorder[3], 1)
			end
			if glow then
				glow:Show()
			end
			if fs then
				fs:SetTextColor(hoverColor[1], hoverColor[2], hoverColor[3])
			end
		end)
		button:HookScript("OnLeave", function(self)
			if glow then
				glow:Hide()
			end
			K.ApplyGradient(bg, "buttonRest")
			if self.KKUI_Border then
				K.ResetBorderColor(self.KKUI_Border)
			end
			RestText(self)
		end)
	end
	button.KKUI_HookHover = HookHover
	HookHover()

	-- The skin strips the pushed texture, so a held button shows it here.
	button:HookScript("OnMouseDown", function(self)
		if self:IsEnabled() then
			K.ApplyGradient(bg, "buttonPressed")
		end
	end)
	button:HookScript("OnMouseUp", function(self)
		if self:IsEnabled() then
			K.ApplyGradient(bg, self:IsMouseOver() and "buttonHover" or "buttonRest")
		end
	end)

	button:HookScript("OnEnable", RestText)
	button:HookScript("OnDisable", function(self)
		if glow then
			glow:Hide()
		end
		K.ApplyGradient(bg, "buttonRest")
		RestText(self)
	end)
	return button
end

-- ---------------------------------------------------------------------------
-- Checkbox
-- ---------------------------------------------------------------------------

function K.SkinCheckBox(check)
	if check.__skinned then
		return check
	end
	check.__skinned = true

	check:SetSize(16, 16)

	if check.SetNormalTexture then
		check:SetNormalTexture(0)
		check:SetPushedTexture(0)
		check:SetDisabledTexture(0)
	end

	-- One flat fill, no two-tone gradient, so the box does not read as a panel
	-- nested inside the frame.
	K.CreateBackground(check, 0.09, 0.114, 0.149, 0.9)
	K.CreateBorder(check)
	K.AddBorderHover(check, accent[1], accent[2], accent[3], 0.6)

	-- Highlight fills the whole box so hover reads clearly.
	local hl = check:GetHighlightTexture()
	if hl then
		hl:SetColorTexture(accent[1], accent[2], accent[3], 0.25)
		hl:ClearAllPoints()
		hl:SetPoint("TOPLEFT", check, "TOPLEFT", 1, -1)
		hl:SetPoint("BOTTOMRIGHT", check, "BOTTOMRIGHT", -1, 1)
	end

	-- A single crisp green checkmark, centred and drawn a little larger than the
	-- box so it reads boldly and slightly overhangs the frame.
	local checked = check:GetCheckedTexture()
	if checked then
		checked:SetAtlas("common-icon-checkmark", true)
		checked:SetVertexColor(K.Colors.positive[1], K.Colors.positive[2], K.Colors.positive[3], 1)
		checked:SetDrawLayer("OVERLAY", 7)
		checked:ClearAllPoints()
		checked:SetPoint("CENTER", check, "CENTER", 2, 2)
		checked:SetSize(22, 22)
	end

	return check
end

-- ---------------------------------------------------------------------------
-- Close button (UIPanelCloseButton)
-- ---------------------------------------------------------------------------

function K.SkinCloseButton(button)
	if button.__skinned then
		return button
	end
	button.__skinned = true

	button:SetSize(22, 22)
	if button.SetNormalTexture then
		button:SetNormalTexture(0)
		button:SetPushedTexture(0)
		button:SetHighlightTexture(0)
		button:SetDisabledTexture(0)
	end

	GamepadFocus(button, gold)

	-- Red gradient background so the close button reads as a distinct action.
	local bg = button:CreateTexture(nil, "BACKGROUND")
	bg:SetPoint("TOPLEFT", 1, -1)
	bg:SetPoint("BOTTOMRIGHT", -1, 1)
	bg:SetColorTexture(1, 1, 1)
	K.ApplyGradient(bg, "close")
	button.KKUI_Background = bg
	K.CreateBorder(button)

	-- Yellow X drawn from two rotated bars, so it stays crisp at any size.
	local function XBar(rotation)
		local t = button:CreateTexture(nil, "OVERLAY")
		t:SetColorTexture(gold[1], gold[2], gold[3])
		t:SetSize(13, 2.5)
		t:SetPoint("CENTER")
		t:SetRotation(rotation)
		return t
	end
	local a = XBar(0.7854) -- 45 degrees
	local b = XBar(-0.7854)

	button:HookScript("OnEnter", function()
		K.ApplyGradient(bg, "closeHover")
		a:SetColorTexture(1, 0.86, 0.4)
		b:SetColorTexture(1, 0.86, 0.4)
	end)
	button:HookScript("OnLeave", function()
		K.ApplyGradient(bg, "close")
		a:SetColorTexture(gold[1], gold[2], gold[3])
		b:SetColorTexture(gold[1], gold[2], gold[3])
	end)
	return button
end

-- ---------------------------------------------------------------------------
-- Edit box
-- ---------------------------------------------------------------------------

function K.SkinEditBox(edit)
	if edit.__skinned then
		return edit
	end
	edit.__skinned = true

	-- InputBoxTemplate art lives in named regions (when named) or the region
	-- list (when not). Hide both ways so it works either way.
	local name = edit:GetName()
	for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
		local region = name and _G[name .. suffix]
		if region then
			region:SetAlpha(0)
		end
	end
	for _, region in ipairs({ edit:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "Texture" then
			region:SetAlpha(0)
		end
	end

	K.CreateBackground(edit, K.Colors.panel[1], K.Colors.panel[2], K.Colors.panel[3], 0.85)
	K.CreateBorder(edit)
	K.AddBorderHover(edit, accent[1], accent[2], accent[3], 0.6)
	return edit
end

-- ---------------------------------------------------------------------------
-- Scroll bar (UIPanelScrollFrameTemplate's child scroll bar)
-- ---------------------------------------------------------------------------

function K.SkinScrollBar(bar)
	if not bar or bar.__skinned then
		return bar
	end
	bar.__skinned = true

	local name = bar:GetName()
	local up = bar.ScrollUpButton or (name and _G[name .. "ScrollUpButton"])
	local down = bar.ScrollDownButton or (name and _G[name .. "ScrollDownButton"])
	local thumb = bar.ThumbTexture
	if not thumb and bar.GetThumbTexture then
		thumb = bar:GetThumbTexture()
	end

	for _, arrow in ipairs({ up, down }) do
		if arrow then
			for _, region in ipairs({ arrow:GetRegions() }) do
				if region:GetObjectType() == "Texture" then
					region:SetTexture(nil)
				end
			end
			arrow:SetWidth(1)
			arrow:SetHeight(1)
		end
	end

	if not bar.KKUI_Background then
		K.CreateBackground(bar, K.Colors.panel[1], K.Colors.panel[2], K.Colors.panel[3], 0.6)
	end

	if thumb then
		thumb:SetTexture(white)
		thumb:SetVertexColor(accent[1], accent[2], accent[3], 0.8)
		-- A narrower thumb leaves a small gap to the track on both sides so the
		-- bar reads as thumb-inside-track rather than a solid filled column.
		thumb:SetWidth(6)
	end
	return bar
end
