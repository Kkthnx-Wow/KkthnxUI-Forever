--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/LootRoll.lua
	Purpose:
		Compact group loot rolls. One slim row per roll: the item icon, its name in
		its quality colour, the time left as the row's fill, and Need, Greed and
		Pass buttons on the right (Transmog in place of Greed when the game offers
		it, Disenchant only when it is allowed). Rows stack from a mover.

		The game's own roll frames are left running so its bookkeeping stays
		intact (the queue past four rolls, the bind on pickup confirm, cancels).
		They are only made invisible and unclickable. Their container is a managed
		bottom frame, so it is never reparented or resized from here, which would
		run the managed layout under our taint.

		Rolling calls RollOnLoot, the same call the game's buttons make. A row
		stays up until the game cancels the roll, so declining the bind on pickup
		confirm leaves the roll open, as it does on the stock frames.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("LootRoll")

local _G = _G
local ipairs = ipairs
local next = next
local select = select
local tinsert = table.insert
local tremove = table.remove

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local UIParent = UIParent
local GetLootRollItemInfo = GetLootRollItemInfo
local GetLootRollItemLink = GetLootRollItemLink
local GetLootRollTimeLeft = GetLootRollTimeLeft
local GetActiveLootRollIDs = GetActiveLootRollIDs
local RollOnLoot = RollOnLoot
local HandleModifiedItemClick = HandleModifiedItemClick
local IsModifiedClick = IsModifiedClick
local CursorUpdate = CursorUpdate
local ResetCursor = ResetCursor
local GetItemQualityColor = C_Item and C_Item.GetItemQualityColor
local C_Loot = C_Loot

local IsSecret = K.IsSecret

-- Roll types as RollOnLoot takes them.
local PASS, NEED, GREED, DISENCHANT, TRANSMOG = 0, 1, 2, 3, 4

-- Art per roll type. The atlases are the ones the game's own Forever roll frame
-- uses. Disenchant has no atlas there, so it uses the older button file and is
-- only shown on rolls that allow it.
local BUTTON_ART = {
	[NEED] = { atlas = "lootroll-toast-icon-need-up", highlight = "lootroll-toast-icon-need-highlight", tip = _G.NEED },
	[GREED] = { atlas = "lootroll-toast-icon-greed-up", highlight = "lootroll-toast-icon-greed-highlight", tip = _G.GREED },
	[TRANSMOG] = { atlas = "lootroll-toast-icon-transmog-up", highlight = "lootroll-toast-icon-transmog-highlight", tip = _G.TRANSMOGRIFICATION },
	[DISENCHANT] = { file = "Interface\\Buttons\\UI-GroupLoot-DE-Up", highlight = "Interface\\Buttons\\UI-GroupLoot-DE-Highlight", tip = _G.ROLL_DISENCHANT },
	[PASS] = { atlas = "lootroll-toast-icon-pass-up", highlight = "lootroll-toast-icon-pass-highlight", tip = _G.PASS },
}

-- How often a row redraws its timer. The fill only needs to look smooth.
local TIMER_STEP = 0.05

local anchor
local rows = {} -- active rows in display order
local pool = {} -- hidden rows ready for reuse

local function QualityColor(quality)
	if quality and not IsSecret(quality) and GetItemQualityColor then
		local r, g, b = GetItemQualityColor(quality)
		if r then
			return r, g, b
		end
	end
	return 1, 1, 1
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

-- Rows grow away from the screen edge the mover is nearest, so the column never
-- runs off screen.
local function Layout()
	local spacing = 6
	local y = anchor:GetCenter() and select(2, anchor:GetCenter()) or 0
	local growDown = y > UIParent:GetHeight() / 2
	for index, row in ipairs(rows) do
		row:ClearAllPoints()
		local offset = (index - 1) * (row:GetHeight() + spacing)
		if growDown then
			row:SetPoint("TOP", anchor, "TOP", 0, -offset)
		else
			row:SetPoint("BOTTOM", anchor, "BOTTOM", 0, offset)
		end
	end
	K.LootRollActive = #rows > 0
end

-- ---------------------------------------------------------------------------
-- Row scripts
-- ---------------------------------------------------------------------------

local function IconEnter(icon)
	local row = icon:GetParent()
	GameTooltip:SetOwner(icon, "ANCHOR_RIGHT")
	GameTooltip:SetLootRollItem(row.rollID)
	CursorUpdate(icon)
end

local function IconLeave()
	GameTooltip:Hide()
	ResetCursor()
end

local function IconClick(icon)
	local row = icon:GetParent()
	if IsModifiedClick() then
		HandleModifiedItemClick(GetLootRollItemLink(row.rollID))
	end
end

local function ButtonEnter(button)
	GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
	GameTooltip:SetText(button.tip)
	if button.reason then
		GameTooltip:AddLine(button.reason, 1, 0.2, 0.2, true)
	end
	GameTooltip:Show()
end

local function ButtonLeave()
	GameTooltip:Hide()
end

local function ButtonClick(button)
	local row = button:GetParent()
	if row.rollID then
		RollOnLoot(row.rollID, button.rollType)
	end
end

local function RowUpdate(row, elapsed)
	row.elapsed = row.elapsed + elapsed
	if row.elapsed < TIMER_STEP then
		return
	end
	row.elapsed = 0
	local left = GetLootRollTimeLeft(row.rollID)
	if left and not IsSecret(left) then
		row.timer:SetValue(left)
	end
end

-- ---------------------------------------------------------------------------
-- Row factory
-- ---------------------------------------------------------------------------

local function CreateRollButton(row, rollType)
	local art = BUTTON_ART[rollType]
	local size = row:GetHeight() - 4
	local button = CreateFrame("Button", nil, row)
	button:SetSize(size, size)
	button:SetMotionScriptsWhileDisabled(true)
	if art.atlas then
		button:SetNormalAtlas(art.atlas)
		button:SetHighlightAtlas(art.highlight, "ADD")
	else
		button:SetNormalTexture(art.file)
		button:SetHighlightTexture(art.highlight, "ADD")
	end
	button.rollType = rollType
	button.tip = art.tip
	button:SetScript("OnEnter", ButtonEnter)
	button:SetScript("OnLeave", ButtonLeave)
	button:SetScript("OnClick", ButtonClick)
	return button
end

local function CreateRow()
	local db = C.Loot
	local height = db.RollHeight
	local row = CreateFrame("Frame", nil, UIParent)
	row:SetSize(db.RollWidth, height)
	row:SetFrameStrata("MEDIUM")
	row:Hide()

	local icon = CreateFrame("Button", nil, row)
	icon:SetSize(height, height)
	icon:SetPoint("LEFT", row, "LEFT")
	icon.texture = icon:CreateTexture(nil, "ARTWORK")
	icon.texture:SetAllPoints()
	icon.texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	K.CreateBorder(icon)
	icon:SetScript("OnEnter", IconEnter)
	icon:SetScript("OnLeave", IconLeave)
	icon:SetScript("OnClick", IconClick)
	row.icon = icon

	local count = icon:CreateFontString(nil, "OVERLAY")
	K.SetFont(count, 11, K.FontOutlineStyle())
	count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
	row.count = count

	-- The time left fills the bar, drained from the right as the roll runs out.
	local timer = CreateFrame("StatusBar", nil, row)
	timer:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 0)
	timer:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT")
	timer:SetStatusBarTexture(K.GetTexture(C.Unitframe and C.Unitframe.Texture or "KkthnxUI"))
	K.CreateGradientBackground(timer, 0.95)
	K.CreateBorder(timer)
	row.timer = timer

	-- Buttons sit on the bar's right end, right to left, so the name keeps the rest.
	row.buttons = {}
	local previous
	for _, rollType in ipairs({ PASS, DISENCHANT, GREED, TRANSMOG, NEED }) do
		local button = CreateRollButton(row, rollType)
		button:SetParent(timer)
		button:SetFrameLevel(timer:GetFrameLevel() + 2)
		row.buttons[rollType] = button
		if rollType ~= TRANSMOG then
			if previous then
				button:SetPoint("RIGHT", previous, "LEFT", -2, 0)
			else
				button:SetPoint("RIGHT", timer, "RIGHT", -3, 0)
			end
			previous = button
		end
	end
	-- Transmog takes Greed's place, the game never offers both.
	row.buttons[TRANSMOG]:SetPoint("CENTER", row.buttons[GREED], "CENTER")

	local bind = timer:CreateFontString(nil, "OVERLAY")
	K.SetFont(bind, 11, K.FontOutlineStyle())
	bind:SetPoint("RIGHT", row.buttons[NEED], "LEFT", -4, 0)
	row.bind = bind

	local name = timer:CreateFontString(nil, "OVERLAY")
	K.SetFont(name, 12, K.FontOutlineStyle())
	name:SetPoint("LEFT", timer, "LEFT", 4, 0)
	name:SetPoint("RIGHT", bind, "LEFT", -4, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	row.name = name

	row:SetScript("OnUpdate", RowUpdate)
	return row
end

-- ---------------------------------------------------------------------------
-- Roll lifecycle
-- ---------------------------------------------------------------------------

local function SetButton(button, allowed, reason)
	button:Show()
	button:SetEnabled(allowed and true or false)
	button:SetAlpha(allowed and 1 or 0.35)
	local normal = button:GetNormalTexture()
	if normal then
		normal:SetDesaturated(not allowed)
	end
	button.reason = (not allowed and reason) and _G["LOOT_ROLL_INELIGIBLE_REASON" .. reason] or nil
end

local function FindRow(rollID)
	for index, row in ipairs(rows) do
		if row.rollID == rollID then
			return row, index
		end
	end
end

local function ReleaseRow(index)
	local row = tremove(rows, index)
	row:Hide()
	row.rollID = nil
	if GameTooltip:IsOwned(row.icon) then
		GameTooltip:Hide()
	end
	tinsert(pool, row)
end

local function AddRoll(rollID, rollTime)
	if not rollID or FindRow(rollID) then
		return
	end

	local texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, reasonNeed, reasonGreed, reasonDisenchant, _, canTransmog = GetLootRollItemInfo(rollID)
	if not name then
		return
	end

	local row = tremove(pool) or CreateRow()
	row.rollID = rollID
	row.elapsed = TIMER_STEP

	local r, g, b = QualityColor(quality)
	row.icon.texture:SetTexture(texture)
	-- The helper's fourth return is a flag, not an alpha, so only take the colour.
	local br, bg, bb = K.ItemQualityColor(quality)
	K.SetBorderColor(K.GetBorder(row.icon), br, bg, bb)
	row.count:SetText((count and count > 1) and count or "")
	row.name:SetText(name)
	row.name:SetTextColor(r, g, b)
	row.bind:SetText(bindOnPickUp and L["BoP"] or "")
	row.bind:SetTextColor(K.Colors.highlight[1], K.Colors.highlight[2], K.Colors.highlight[3])

	local duration = rollTime
	if not duration and C_Loot and C_Loot.GetLootRollDuration then
		duration = C_Loot.GetLootRollDuration(rollID)
	end
	duration = duration or GetLootRollTimeLeft(rollID) or 1
	row.timer:SetMinMaxValues(0, duration)
	row.timer:SetValue(GetLootRollTimeLeft(rollID) or duration)
	row.timer:SetStatusBarColor(r * 0.6, g * 0.6, b * 0.6)

	local buttons = row.buttons
	SetButton(buttons[NEED], canNeed, reasonNeed)
	SetButton(buttons[PASS], true)
	if canTransmog then
		SetButton(buttons[TRANSMOG], true)
		buttons[GREED]:Hide()
	else
		buttons[TRANSMOG]:Hide()
		SetButton(buttons[GREED], canGreed, reasonGreed)
	end
	if canDisenchant then
		SetButton(buttons[DISENCHANT], true, reasonDisenchant)
		buttons[GREED]:SetPoint("RIGHT", buttons[DISENCHANT], "LEFT", -2, 0)
	else
		buttons[DISENCHANT]:Hide()
		buttons[GREED]:SetPoint("RIGHT", buttons[PASS], "LEFT", -2, 0)
	end

	tinsert(rows, row)
	row:Show()
	Layout()
end

function Module:START_LOOT_ROLL(_, rollID, rollTime)
	AddRoll(rollID, rollTime)
end

function Module:CANCEL_LOOT_ROLL(_, rollID)
	local row, index = FindRow(rollID)
	if row then
		ReleaseRow(index)
		Layout()
	end
end

function Module:CANCEL_ALL_LOOT_ROLLS()
	for index = #rows, 1, -1 do
		ReleaseRow(index)
	end
	Layout()
end

-- A reload or loading screen mid roll: pick up whatever is still open.
function Module:PLAYER_ENTERING_WORLD()
	if not GetActiveLootRollIDs then
		return
	end
	for _, rollID in ipairs(GetActiveLootRollIDs()) do
		AddRoll(rollID)
	end
end

-- ---------------------------------------------------------------------------
-- The game's roll frames
-- ---------------------------------------------------------------------------

-- Invisible and unclickable, but still shown as far as the game is concerned,
-- so its own events keep clearing them. Hiding them outright would unregister
-- those events and leave its four slots full for the session.
local function MuteFrame(frame)
	frame:SetAlpha(0)
	frame:EnableMouse(false)
	for _, child in next, { frame:GetChildren() } do
		child:EnableMouse(false)
		for _, grandchild in next, { child:GetChildren() } do
			grandchild:EnableMouse(false)
		end
	end
end

local function MuteBlizzardRolls()
	for index = 1, 4 do
		local frame = _G["GroupLootFrame" .. index]
		if frame then
			MuteFrame(frame)
			-- Its need animation fades children back in, so mute again each show.
			frame:HookScript("OnShow", MuteFrame)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Enable
-- ---------------------------------------------------------------------------

function Module:OnEnable()
	local db = C.Loot
	if not (db and db.RollFrames) then
		return
	end

	anchor = CreateFrame("Frame", "KKUI_LootRollAnchor", UIParent)
	anchor:SetSize(db.RollWidth, db.RollHeight)
	K.CreateMover(anchor, "LootRolls", L["Loot Rolls"], { "TOP", UIParent, "TOP", 0, -260 }, db.RollWidth, db.RollHeight)
	if anchor.KKUI_Mover then
		anchor:ClearAllPoints()
		anchor:SetPoint("TOPLEFT", anchor.KKUI_Mover, "TOPLEFT")
	end

	MuteBlizzardRolls()

	self:RegisterEvent("START_LOOT_ROLL")
	self:RegisterEvent("CANCEL_LOOT_ROLL")
	self:RegisterEvent("CANCEL_ALL_LOOT_ROLLS")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
end
