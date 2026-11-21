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
local print = print
local select = select
local tonumber = tonumber
local tostring = tostring
local tconcat = table.concat
local tinsert = table.insert
local tremove = table.remove

local CreateFrame = CreateFrame
local EnumerateFrames = EnumerateFrames
local GetInventoryItemLink = GetInventoryItemLink
local C_Timer = C_Timer
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
local GetDetailedItemLevelInfo = C_Item and C_Item.GetDetailedItemLevelInfo
local GetItemInfo = C_Item and C_Item.GetItemInfo or GetItemInfo
local IsEquippableItem = C_Item and C_Item.IsEquippableItem or IsEquippableItem
local Item = Item
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
	if row.fake then
		GameTooltip:SetHyperlink(row.link)
	else
		GameTooltip:SetLootRollItem(row.rollID)
	end
	CursorUpdate(icon)
end

local function IconLeave()
	GameTooltip:Hide()
	ResetCursor()
end

local function IconClick(icon)
	local row = icon:GetParent()
	if IsModifiedClick() and row.link then
		HandleModifiedItemClick(row.link)
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
	-- Buttons are parented to the timer bar, so the row is one level further up.
	local row = button:GetParent():GetParent()
	if row.fake then
		print("|cff5cc4ffKkthnxUI|r test roll: clicked", button.tip)
		return
	end
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
	local left
	if row.fake then
		-- Roll times are in milliseconds, as the game reports them.
		row.fakeLeft = row.fakeLeft - TIMER_STEP * 1000
		left = row.fakeLeft > 0 and row.fakeLeft or 0
	else
		left = GetLootRollTimeLeft(row.rollID)
		if not left or IsSecret(left) then
			return
		end
	end
	row.timer:SetValue(left)
	-- An empty bar has no edge to mark.
	row.spark:SetShown(left > 0)
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

	-- Item level in the top left corner, where the character slots show it.
	local level = icon:CreateFontString(nil, "OVERLAY")
	K.SetFont(level, 10, K.FontOutlineStyle())
	level:SetPoint("TOPLEFT", icon, "TOPLEFT", 1, -1)
	row.level = level

	-- The time left fills the bar, drained from the right as the roll runs out.
	local timer = CreateFrame("StatusBar", nil, row)
	timer:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 0)
	timer:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT")
	timer:SetStatusBarTexture(K.GetTexture(C.Unitframe and C.Unitframe.Texture or "KkthnxUI"))
	K.CreateGradientBackground(timer, 0.95)
	K.CreateBorder(timer)
	row.timer = timer

	-- The UI's own spark rides the edge of the fill, as on the cast bars. It sits
	-- on top of the fill but under the item name, so it never cuts through text.
	local spark = timer:CreateTexture(nil, "ARTWORK", nil, 7)
	spark:SetTexture(C.Media.Textures.Spark)
	spark:SetBlendMode("ADD")
	spark:SetSize(16, height)
	spark:SetPoint("CENTER", timer:GetStatusBarTexture(), "RIGHT", 0, 0)
	row.spark = spark

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
	row.link = nil
	row.fake = nil
	if GameTooltip:IsOwned(row.icon) then
		GameTooltip:Hide()
	end
	tinsert(pool, row)
end

-- Item level for gear only. Cloth and potions have a level too, but it means
-- nothing on a roll. An item the client has not loaded yet fills in once it
-- arrives, if the row still shows that roll.
local function SetItemLevel(row, link, r, g, b)
	row.level:SetText("")
	if not (link and GetDetailedItemLevelInfo) or (IsEquippableItem and not IsEquippableItem(link)) then
		return
	end
	local level = GetDetailedItemLevelInfo(link)
	if level and not IsSecret(level) then
		if level > 1 then
			row.level:SetText(level)
			row.level:SetTextColor(r, g, b)
		end
		return
	end
	if Item then
		local rollID = row.rollID
		Item:CreateFromItemLink(link):ContinueOnItemLoad(function()
			if row.rollID == rollID then
				SetItemLevel(row, link, r, g, b)
			end
		end)
	end
end

-- fake is a test roll from /kkroll: its item info, with no roll behind it.
local function AddRoll(rollID, rollTime, fake)
	if not rollID or FindRow(rollID) then
		return
	end

	local texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, reasonNeed, reasonGreed, reasonDisenchant, _, canTransmog
	local link
	if fake then
		texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, canTransmog = fake.texture, fake.name, fake.count or 1, fake.quality, fake.bop, fake.need, not fake.transmog, fake.de, fake.transmog
		link = fake.link
	else
		texture, name, count, quality, bindOnPickUp, canNeed, canGreed, canDisenchant, reasonNeed, reasonGreed, reasonDisenchant, _, canTransmog = GetLootRollItemInfo(rollID)
		link = GetLootRollItemLink(rollID)
	end
	if not name then
		return
	end

	local row = tremove(pool) or CreateRow()
	row.rollID = rollID
	row.link = link
	row.fake = fake and true or nil
	row.fakeLeft = fake and fake.left or rollTime
	row.elapsed = TIMER_STEP
	row.spark:Show()

	local r, g, b = QualityColor(quality)
	row.icon.texture:SetTexture(texture)
	-- The helper's fourth return is a flag, not an alpha, so only take the colour.
	local br, bg, bb = K.ItemQualityColor(quality)
	K.SetBorderColor(K.GetBorder(row.icon), br, bg, bb)
	row.count:SetText((count and count > 1) and count or "")
	SetItemLevel(row, link, r, g, b)
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
	row.timer:SetValue(fake and row.fakeLeft or GetLootRollTimeLeft(rollID) or duration)
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
-- Test rolls (/kkroll)
-- ---------------------------------------------------------------------------

-- Fake rolls to check the rows without a group. Their ids are negative so they
-- can never meet a real one, and their buttons print instead of rolling. The
-- items are real ones from the game, picked to cover every quality, the longest
-- names, a stack, and each set of buttons. left is how full the timer starts.
local TEST_ITEMS = {
	{ id = 19019, need = true, left = 0.95 }, -- legendary, very long name
	{ id = 17076, need = true, de = true, left = 0.8 }, -- epic with Disenchant
	{ id = 18803, need = true, de = true, left = 0.6 },
	{ id = 13340, need = true, transmog = true, left = 0.45 }, -- rare, Transmog in place of Greed
	{ id = 2589, count = 20, need = false, left = 0.25 }, -- stack, Need not allowed
}
local TEST_TIME = 60000
local nextTestID = -1

local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6, FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
local overlay
local marks = {}
local markRun = 0

local function Say(...)
	print("|cff5cc4ffKkthnxUI|r roll test:", ...)
end

-- The frame that would take a click at this screen point: the highest strata,
-- then the highest level, among shown frames that take mouse clicks.
-- Some frames answer with secret values, which cannot be tested. They are
-- skipped and counted, so a blocker hidden among them is not ruled out.
local function TopFrameAt(x, y)
	local best, bestStrata, bestLevel
	local unreadable = 0
	local frame = EnumerateFrames()
	while frame do
		local visible, mouse = false, false
		if frame ~= overlay and not frame:IsForbidden() then
			visible, mouse = frame:IsVisible(), frame:IsMouseEnabled()
			if IsSecret(visible) or IsSecret(mouse) then
				unreadable = unreadable + 1
				visible = false
			end
		end
		if visible and mouse then
			local left, bottom, width, height = frame:GetRect()
			if IsSecret(left) or IsSecret(bottom) or IsSecret(width) or IsSecret(height) then
				unreadable = unreadable + 1
				left = nil
			end
			if left then
				local scale = frame:GetEffectiveScale()
				left, bottom, width, height = left * scale, bottom * scale, width * scale, height * scale
				if x >= left and x <= left + width and y >= bottom and y <= bottom + height then
					local strata = STRATA[frame:GetFrameStrata()] or 0
					local level = frame:GetFrameLevel()
					if not best or strata > bestStrata or (strata == bestStrata and level > bestLevel) then
						best, bestStrata, bestLevel = frame, strata, level
					end
				end
			end
		end
		frame = EnumerateFrames(frame)
	end
	return best, unreadable
end

local function Mark(index, target, r, g, b)
	local mark = marks[index]
	if not mark then
		mark = overlay:CreateTexture(nil, "OVERLAY")
		marks[index] = mark
	end
	mark:ClearAllPoints()
	mark:SetAllPoints(target)
	mark:SetColorTexture(r, g, b, 0.45)
	mark:Show()
end

local function ClearMarks()
	for _, mark in ipairs(marks) do
		mark:Hide()
	end
end

local function FrameName(frame)
	return frame:GetDebugName() or tostring(frame)
end

-- Paint every shown roll button green when a click there reaches it, or red
-- when another frame would take the click, and name that frame in chat.
local function HitTest()
	if not overlay then
		overlay = CreateFrame("Frame", nil, UIParent)
		overlay:SetAllPoints(UIParent)
		overlay:SetFrameStrata("TOOLTIP")
		overlay:EnableMouse(false)
	end
	ClearMarks()

	local count, blocked, unreadable = 0, 0, 0
	for _, row in ipairs(rows) do
		for rollType, button in next, row.buttons do
			if button:IsVisible() then
				count = count + 1
				local x, y = button:GetCenter()
				local scale = button:GetEffectiveScale()
				local top, skipped = TopFrameAt(x * scale, y * scale)
				unreadable = skipped
				local roll = ButtonClick == button:GetScript("OnClick") and (button:GetParent():GetParent().rollID ~= nil)
				if top == button and roll then
					Mark(count, button, 0, 1, 0)
				else
					blocked = blocked + 1
					Mark(count, button, 1, 0, 0)
					if top ~= button then
						Say(BUTTON_ART[rollType].tip, "is covered by", top and FrameName(top) or "nothing that takes clicks")
					end
					if not roll then
						Say(BUTTON_ART[rollType].tip, "has no roll to act on")
					end
				end
			end
		end
	end
	Say(count, "buttons checked,", blocked, "blocked,", unreadable, "frames unreadable. Marks clear in 10 seconds.")
	-- Only the latest check clears its marks, so a quick rerun keeps them up.
	markRun = markRun + 1
	local run = markRun
	C_Timer.After(10, function()
		if run == markRun then
			ClearMarks()
		end
	end)
end

local function AddTestRoll(spec, link)
	local name, itemLink, quality, _, _, _, _, _, _, texture, _, _, _, bindType = GetItemInfo(link or spec.id)
	if not name then
		Say("item", link or spec.id, "is not in this client.")
		return
	end
	AddRoll(nextTestID, TEST_TIME, {
		name = name,
		link = itemLink,
		quality = quality,
		texture = texture,
		count = spec.count,
		bop = bindType == 1,
		need = spec.need,
		de = spec.de,
		transmog = spec.transmog,
		left = TEST_TIME * (spec.left or 1),
	})
	nextTestID = nextTestID - 1
end

-- Wait for each item to load, so the first run after login shows them too.
local function LoadTestRoll(spec, link)
	if not Item then
		AddTestRoll(spec, link)
		return
	end
	local item = link and Item:CreateFromItemLink(link) or Item:CreateFromItemID(spec.id)
	-- A missing item never calls back, so rule it out first.
	local exists = C_Item and C_Item.DoesItemExistByID
	if item:IsItemEmpty() or (spec.id and exists and not exists(spec.id)) then
		Say("item", link or spec.id, "is not in this client.")
		return
	end
	item:ContinueOnItemLoad(function()
		AddTestRoll(spec, link)
	end)
end

local function AddTestRolls()
	for _, spec in ipairs(TEST_ITEMS) do
		LoadTestRoll(spec)
	end
	-- The weapon you have on, so one row shows an item from this character.
	local weapon = GetInventoryItemLink("player", 16)
	if weapon then
		LoadTestRoll({ need = true, left = 0.1 }, weapon)
	end
	Say("adding test rolls. Click their buttons, or /kkroll hit to check them.")
end

local function ClearTestRolls()
	for index = #rows, 1, -1 do
		if rows[index].fake then
			ReleaseRow(index)
		end
	end
	Layout()
	ClearMarks()
end

-- Names cut short with an ellipsis, to judge whether a width is enough.
local function ReportTruncated()
	local cut = {}
	for _, row in ipairs(rows) do
		if row.name:IsTruncated() then
			tinsert(cut, row.name:GetText())
		end
	end
	Say(#cut, "of", #rows, "names cut:", #cut > 0 and tconcat(cut, ", ") or "none")
end

-- Try a width on the rows that are up, for this session only. The setting in
-- the options is what new rows and the next login use.
local function TryWidth(width)
	width = tonumber(width)
	if not width then
		Say("width needs a number, for example /kkroll width 380")
		return
	end
	for _, row in ipairs(rows) do
		row:SetWidth(width)
	end
	for _, row in ipairs(pool) do
		row:SetWidth(width)
	end
	Say("rows set to", width, "wide.")
	ReportTruncated()
end

-- Try a spark blend mode, or mix to alternate them row by row so both show at once.
local function TryBlend(mode)
	mode = mode and mode:upper()
	if mode ~= "ADD" and mode ~= "BLEND" and mode ~= "MIX" then
		Say("blend takes add, blend or mix")
		return
	end
	for index, row in ipairs(rows) do
		local rowMode = mode
		if mode == "MIX" then
			rowMode = index % 2 == 1 and "ADD" or "BLEND"
		end
		row.spark:SetBlendMode(rowMode)
	end
	-- Pooled rows too, so a later roll shows the mode being tried.
	for _, row in ipairs(pool) do
		row.spark:SetBlendMode(mode == "MIX" and "ADD" or mode)
	end
	Say("spark blend set to", mode == "MIX" and "ADD on odd rows, BLEND on even rows" or mode)
end

local function RollSlash(msg)
	local command, arg = (msg or ""):lower():match("^%s*(%S*)%s*(%S*)")
	if command == "test" then
		AddTestRolls()
	elseif command == "hit" then
		HitTest()
	elseif command == "clear" then
		ClearTestRolls()
	elseif command == "width" then
		TryWidth(arg)
	elseif command == "blend" then
		TryBlend(arg)
	elseif command == "cut" then
		ReportTruncated()
	else
		Say("/kkroll test, hit, clear, cut, width <number>, blend add|blend|mix")
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

	_G.SLASH_KKUI_LOOTROLL1 = "/kkroll"
	_G.SlashCmdList.KKUI_LOOTROLL = RollSlash
end
