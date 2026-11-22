--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/ButtonStyle.lua
	Purpose:
		Button options for LibActionButtonKit and per button styling. The library
		draws state only (icon, tints, cooldowns, text) and never touches fonts,
		anchors or art, so everything visual is set here once per button.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("ActionBars")

local _G = _G

-- The border set's button states, so every button reads the same: a soft
-- inner glow on hover, an inner shadow while pressed, and a gold inner ring
-- while checked (active stance, toggled-on pet ability). Shared by the library
-- buttons and the stock buttons we reuse. The icon is inset 1, so are these.
function Module:StyleInteractionTextures(button)
	K.StyleButtonStates(button, 1)
end

-- Hover also lights the rail itself, on top of the inner glow. The glow is a
-- plain child frame, so showing it from these hooks is fine in combat on a
-- secure button. Built once per button.
local glowOf = setmetatable({}, { __mode = "k" })

function Module:AttachBorderGlow(button)
	if glowOf[button] then
		return
	end
	glowOf[button] = K.AddBorderHover(button, 1, 1, 1, 0.5)
end

-- Pet autocast ring. Blizzard's overlay is a fixed 28px frame with corner art
-- that pokes past our border and does not track the button size. Stretch the
-- ants to the icon and drop the corners so only the spinning ring shows.
function Module:SkinAutoCast(button)
	local overlay = button.AutoCastOverlay
	if not overlay then
		return
	end
	overlay:SetAllPoints(button)
	if overlay.Corners then
		overlay.Corners:SetAlpha(0)
	end
	if overlay.Shine then
		overlay.Shine:ClearAllPoints()
		overlay.Shine:SetPoint("TOPLEFT", button, "TOPLEFT", -3, 3)
		overlay.Shine:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 3, -3)
	end
end

-- Skin a stock Blizzard button (stance, extra, zone) with our slot + border,
-- for buttons we reuse rather than build through LibActionButtonKit.
function Module:StyleAuxButton(button)
	if not button or button.__auxStyled then
		return
	end
	button.__auxStyled = true

	local name = button:GetName()
	local icon = button.icon or (name and _G[name .. "Icon"])
	local normal = button.GetNormalTexture and button:GetNormalTexture()

	if normal then
		normal:SetAlpha(0)
	end
	if button.SetNormalTexture then
		button:SetNormalTexture(0)
	end
	local floating = name and _G[name .. "FloatingBG"]
	if floating then
		floating:Hide()
	end
	if button.Flash then
		button.Flash:SetTexture(nil)
	end

	-- Pet and stance buttons inherit the 12.0 ActionButtonTemplate, so they carry
	-- the same leftover slot art the main buttons do. Hide it under our slot.
	if button.SlotArt then
		button.SlotArt:SetAlpha(0)
	end
	if button.SlotBackground then
		button.SlotBackground:SetAlpha(0)
	end

	if icon then
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		icon:ClearAllPoints()
		icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
	end

	local slot = button:CreateTexture(nil, "BACKGROUND", nil, -8)
	slot:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
	slot:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
	slot:SetAtlas("UI-HUD-ActionBar-IconFrame-Slot")

	local cooldown = button.cooldown or (name and _G[name .. "Cooldown"])
	if cooldown then
		cooldown:ClearAllPoints()
		cooldown:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		cooldown:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
		K.StyleCooldownSwipe(cooldown)
	end

	self:StyleInteractionTextures(button)
	self:SkinAutoCast(button)

	K.CreateBorder(button)
	self:AttachBorderGlow(button)

	local hotkey = button.HotKey or (name and _G[name .. "HotKey"])
	if hotkey then
		self:StyleHotKey({ HotKey = hotkey })
	end
end

-- The options setting's out of range choice, in the library's terms.
local RANGE_TINT = { button = "icon", hotkey = "hotkey", none = false }

-- Library options for one button. Text visibility is per bar, the tints and the
-- grid are global. Rebuilt each call so live edits take effect.
function Module:GetButtonOptions(key, bindName)
	local db = C.ActionBar
	local bar = db[key] or db.Bar1
	local tint = RANGE_TINT[db.RangeColoring or "button"]
	return {
		showGrid = db.ShowGrid,
		rangeTint = tint == nil and "icon" or tint,
		colors = {
			range = db.RangeColor or { 0.8, 0.1, 0.1 },
			mana = db.ManaColor or { 0.5, 0.5, 1.0 },
		},
		showMacroName = bar.MacroName and true or false,
		showHotKey = bar.HotKey and true or false,
		showCount = bar.Count ~= false,
		bindingName = bindName,
	}
end

-- Fonts for a button's text, from the action bar font settings.
function Module:ApplyButtonFonts(button)
	local db = C.ActionBar
	local font = K.GetFont(db.Font)
	local size = db.FontSize
	local flag = db.FontFlag ~= "NONE" and db.FontFlag or ""
	button.HotKey:SetFont(font, size, flag)
	button.Count:SetFont(font, size, flag)
	button.Name:SetFont(font, size - 2, flag)
end

-- Apply our border, fonts and anchors on a single library button.
function Module:StyleButton(button)
	if button.__styled then
		return
	end
	button.__styled = true

	local icon = button.icon
	local count = button.Count
	local hotkey = button.HotKey
	local macro = button.Name

	-- Blizzard slot atlas as the button background. The atlas has transparent
	-- padding, so we stretch it a couple pixels past every edge to make the
	-- opaque art reach the button edges (any overshoot tucks under the border).
	local slot = button:CreateTexture(nil, "BACKGROUND", nil, -8)
	slot:SetPoint("TOPLEFT", button, "TOPLEFT", -2, 2)
	slot:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 2, -2)
	slot:SetAtlas("UI-HUD-ActionBar-IconFrame-Slot")
	button.KKUI_Slot = slot

	-- Crop the icon inside our border and keep it above the slot art.
	if icon then
		icon:SetDrawLayer("ARTWORK")
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		icon:ClearAllPoints()
		icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
	end

	-- Cooldowns: crop to the icon and give the dark radial swipe a real texture,
	-- since SetCooldownFromDurationObject never sets one. Charges keep their edge
	-- only. Loss of control gets the swipe in a dark red.
	for _, cooldown in ipairs({ button.cooldown, button.chargeCooldown, button.lossOfControlCooldown }) do
		cooldown:ClearAllPoints()
		cooldown:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		cooldown:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
	end
	K.StyleCooldownSwipe(button.cooldown)
	K.StyleCooldownSwipe(button.lossOfControlCooldown, 0.35, 0, 0)

	-- The equipped-item wash, in the border green at a softer strength.
	button.Border:ClearAllPoints()
	button.Border:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
	button.Border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
	button.Border:SetColorTexture(0, 1, 0, 0.2)

	-- The attack and auto repeat flash, inside the border and above the icon.
	button.Flash:SetDrawLayer("ARTWORK", 1)
	button.Flash:ClearAllPoints()
	button.Flash:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
	button.Flash:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)

	-- Clean interaction-state textures: pushed and hover glow, checked outline.
	self:StyleInteractionTextures(button)
	self:ApplyButtonFonts(button)

	K.CreateBorder(button)
	self:AttachBorderGlow(button)

	-- Shorten the hotkey text and keep it shortened on rebind.
	Module:StyleHotKey(button)

	-- Text placement.
	if count then
		count:ClearAllPoints()
		count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 2)
	end
	if hotkey then
		hotkey:ClearAllPoints()
		hotkey:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, -2)
	end
	if macro then
		macro:ClearAllPoints()
		macro:SetPoint("BOTTOM", button, "BOTTOM", 0, 2)
	end
end
