--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/AFKScreen.lua
	Purpose:
		A full-screen view for while the player is away. The interface is hidden
		the way the game's own Hide UI key does it and the camera turns slowly.
		The time and date sit top left, a card of this session's numbers bottom
		left, the character in the middle, and on the right one panel with the
		time away, who and where the player is, gold, gear, bags, experience and
		the whispers and guild chat that came in meanwhile.

		When it opens:
		  Only when the AFK flag turns on, and never in combat, while dead, in a
		  cinematic, movie or pet battle. While casting or typing it waits and
		  tries again, since crafting a stack or writing a line is not being away.

		When it closes:
		  The AFK flag clears, or any key, click or gamepad button. It also steps
		  aside for anything the player has to answer, all of which the game
		  shows on the hidden interface: combat, a ready check, a summons, a
		  resurrection, a group, duel or trade request, a dungeon or battleground
		  invite, the logout countdown, a cinematic or movie, a pet battle, death
		  and leaving the world. The interface is shown again before combat
		  lockdown starts, since PLAYER_REGEN_DISABLED fires ahead of it.

		Session numbers:
		  Counted from login. They are kept in the saved variables against the
		  moment of login, so a reload carries on with them and a new login
		  starts over.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("AFKScreen")

local _G = _G
local abs = math.abs
local date = _G.date
local floor = math.floor
local format = string.format
local ipairs = ipairs
local pairs = pairs
local strlower = string.lower

local Ambiguate = Ambiguate
local CreateFrame = CreateFrame
local GameTime_GetTime = _G.GameTime_GetTime
local GetBattlefieldStatus = _G.GetBattlefieldStatus
local GetBindingAction = GetBindingAction
local GetCurrentKeyBoardFocus = _G.GetCurrentKeyBoardFocus
local GetGuildInfo = GetGuildInfo
local GetInventoryItemDurability = GetInventoryItemDurability
local GetMaxPlayerLevel = _G.GetMaxPlayerLevel
local GetMoney = GetMoney
local GetMoneyString = GetMoneyString
local GetPlayerInfoByGUID = GetPlayerInfoByGUID
local GetSessionTime = _G.GetSessionTime
local GetSubZoneText = _G.GetSubZoneText
local GetTime = GetTime
local GetXPExhaustion = GetXPExhaustion
local GetZoneText = _G.GetZoneText
local InCombatLockdown = InCombatLockdown
local IsResting = _G.IsResting
local IsXPUserDisabled = IsXPUserDisabled
local MoveViewLeftStart = _G.MoveViewLeftStart
local MoveViewLeftStop = _G.MoveViewLeftStop
local Screenshot = Screenshot
local SetUIVisibility = _G.SetUIVisibility
local UIParent = UIParent
local UnitAffectingCombat = UnitAffectingCombat
local UnitCastingInfo = _G.UnitCastingInfo
local UnitChannelInfo = UnitChannelInfo
local UnitClass = UnitClass
local UnitGUID = UnitGUID
local UnitIsAFK = UnitIsAFK
local UnitIsDead = UnitIsDead
local UnitLevel = UnitLevel
local UnitName = UnitName
local UnitRace = UnitRace
local UnitXP = UnitXP
local UnitXPMax = UnitXPMax
local WorldFrame = _G.WorldFrame
local securecall = _G.securecall
local time = _G.time
local C_Container = C_Container
local C_PetBattles = C_PetBattles
local C_Timer = C_Timer
local IsSecret = K.IsSecret

-- The UI's one spacing step. Everything here sits on multiples of it.
local GAP = 6
local MARGIN = GAP * 4 -- screen edge to the panel and the card
local PAD = GAP * 3 -- panel edge to content
local PANEL_WIDTH = 432
local INNER_WIDTH = PANEL_WIDTH - PAD * 2
local CARD_WIDTH = 312
local CARD_INNER = CARD_WIDTH - PAD * 2
local ROW_HEIGHT = GAP * 4
local LABEL_WIDTH = 120
local ICON_SIZE = GAP * 8
local XP_BAR_HEIGHT = GAP * 3
-- The bar's border band sits a little outside its edge, so the bar is pulled
-- in by that much to line up with the text above it.
local BAR_INSET = 2
-- The money string's coin icons carry a 2px right offset of their own.
local COIN_NUDGE = 2
-- Message list height in lines, growing as messages come in.
local LINE_HEIGHT = 18
local LINE_SPACING = 4
local MIN_LINES = 3
local MAX_SHOWN_LINES = 12
local MAX_LINES = 100

-- Multiplier on the player's own camera turn speed. Slow enough to read as a
-- drift, not a turn.
local SPIN_SPEED = 0.025
-- Seconds before trying again while the player is casting or typing.
local RETRY_DELAY = 10
-- A reload keeps the session when the login moment it saved matches the one
-- worked out now to within this many seconds.
local SESSION_SLACK = 5
-- Seconds of active play before a rate per hour is worth showing.
local MIN_RATE_TIME = 300

-- Animation IDs from the game's animation data. The character waves once on
-- open, then every EMOTE_INTERVAL seconds of standing it plays the next emote
-- in the list, so the screen is alive without fidgeting. An emote the model
-- lacks is skipped. A one-shot emote ends when its animation does, with
-- ONESHOT_LIMIT as a backstop. The dance loops, so it is given a length.
local ANIM_STAND = 0
local WAVE = { id = 67 }
local EMOTES = {
	{ id = 69, hold = 10 }, -- dance
	{ id = 113 }, -- salute
	{ id = 60 }, -- talk
	{ id = 74 }, -- roar
	{ id = 83 }, -- shy
	WAVE,
}
local EMOTE_INTERVAL = 45
local ONESHOT_LIMIT = 6
-- Radians. A turn toward the panel, so the character is not staring out.
local MODEL_FACING = 0.4

local WEEKDAYS = { "WEEKDAY_SUNDAY", "WEEKDAY_MONDAY", "WEEKDAY_TUESDAY", "WEEKDAY_WEDNESDAY", "WEEKDAY_THURSDAY", "WEEKDAY_FRIDAY", "WEEKDAY_SATURDAY" }
-- The full date month forms, as the calendar uses, since some languages decline
-- the month inside a date.
local MONTHS = { "FULLDATE_MONTH_JANUARY", "FULLDATE_MONTH_FEBRUARY", "FULLDATE_MONTH_MARCH", "FULLDATE_MONTH_APRIL", "FULLDATE_MONTH_MAY", "FULLDATE_MONTH_JUNE", "FULLDATE_MONTH_JULY", "FULLDATE_MONTH_AUGUST", "FULLDATE_MONTH_SEPTEMBER", "FULLDATE_MONTH_OCTOBER", "FULLDATE_MONTH_NOVEMBER", "FULLDATE_MONTH_DECEMBER" }

local FACTION_ATLAS = {
	Horde = "UI-Character-Info-Honor-Icon-Horde",
	Alliance = "UI-Character-Info-Honor-Icon-Alliance",
}

-- Keys that do nothing alone, so a modifier held while reaching for the mouse
-- does not close the screen.
local MODIFIER_KEYS = {
	LSHIFT = true,
	RSHIFT = true,
	LCTRL = true,
	RCTRL = true,
	LALT = true,
	RALT = true,
	LMETA = true,
	RMETA = true,
}

-- Things the player has to see or answer. Each one closes the screen and leaves
-- the AFK flag alone.
local EXIT_EVENTS = {
	"PLAYER_REGEN_DISABLED",
	"LFG_PROPOSAL_SHOW",
	"READY_CHECK",
	"CONFIRM_SUMMON",
	"RESURRECT_REQUEST",
	"PARTY_INVITE_REQUEST",
	"DUEL_REQUESTED",
	"TRADE_SHOW",
	"PLAYER_CAMPING",
	"PLAYER_DEAD",
	"CINEMATIC_START",
	"PLAY_MOVIE",
	"PET_BATTLE_OPENING_START",
	"PLAYER_LEAVING_WORLD",
	"PLAYER_LOGOUT",
}

-- Panel values that can change while the player is away.
local DETAIL_EVENTS = {
	"PLAYER_MONEY",
	"PLAYER_XP_UPDATE",
	"UPDATE_EXHAUSTION",
	"PLAYER_UPDATE_RESTING",
	"ZONE_CHANGED",
	"ZONE_CHANGED_INDOORS",
	"ZONE_CHANGED_NEW_AREA",
	"UPDATE_INVENTORY_DURABILITY",
	"BAG_UPDATE_DELAYED",
}

local IDENTITY_EVENTS = {
	"PLAYER_GUILD_UPDATE",
	"PLAYER_LEVEL_UP",
}

-- Chat event to its ChatTypeInfo key.
local CHAT_EVENTS = {
	CHAT_MSG_WHISPER = "WHISPER",
	CHAT_MSG_BN_WHISPER = "BN_WHISPER",
	CHAT_MSG_GUILD = "GUILD",
}

-- Session card rows, top to bottom. "leveling" rows only show below the level
-- cap, since they are about experience.
local STATS = {
	{ key = "online", label = L["Online"] },
	{ key = "away", label = L["Away"] },
	{ key = "gold", label = L["Gold"] },
	{ key = "xp", label = L["Experience"], leveling = true },
	{ key = "rate", label = L["Per Hour"], leveling = true },
	{ key = "next", label = L["Next Level"], leveling = true },
	{ key = "levels", label = L["Levels"], leveling = true },
	{ key = "quests", label = L["Quests"] },
	{ key = "deaths", label = L["Deaths"] },
}

local root, ui -- built on first open
local shown = false
local testing = false
local hidUI = false -- the interface was showing and this screen hid it
local spinning = false
local wasAFK = false -- the flag as last read, so only a fresh AFK opens the screen
local afkSince = 0
local afkSinceText = ""
local ticker, retryTimer
local messageCount = 0
local lastClock

-- This session's numbers (see the header). lastXP, lastMax and lastLevel are
-- the experience as last seen, to count what each update adds.
local session
local lastXP, lastMax, lastLevel = 0, 1, 0

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function Color(token)
	local c = K.Colors[token]
	return c[1], c[2], c[3]
end

local function Text(parent, size, token, justify)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(fs, size, K.FontOutlineStyle())
	fs:SetTextColor(Color(token))
	fs:SetJustifyH(justify or "LEFT")
	fs:SetWordWrap(false)
	return fs
end

local function Hairline(parent, width)
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetSize(width, 1)
	line:SetColorTexture(Color("line"))
	return line
end

-- A label on the left and its value on the right, one row tall.
local function Row(parent, label, width, labelWidth)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(width, ROW_HEIGHT)
	row.label = Text(row, 14, "muted")
	row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
	row.label:SetWidth(labelWidth)
	row.label:SetText(label)
	row.value = Text(row, 14, "text", "RIGHT")
	row.value:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	row.value:SetWidth(width - labelWidth - GAP)
	return row
end

local function SetValue(row, text, token)
	row.value:SetText(text)
	row.value:SetTextColor(Color(token or "text"))
end

local function FormatElapsed(seconds)
	seconds = floor(seconds)
	local hours = floor(seconds / 3600)
	local minutes = floor(seconds % 3600 / 60)
	if hours > 0 then
		return format("%d:%02d:%02d", hours, minutes, seconds % 60)
	end
	return format("%02d:%02d", minutes, seconds % 60)
end

local function FormatDuration(seconds)
	seconds = floor(seconds)
	local hours = floor(seconds / 3600)
	local minutes = floor(seconds % 3600 / 60)
	if hours > 0 then
		return format(L["%dh %dm"], hours, minutes)
	end
	return format(L["%dm"], minutes)
end

-- "Wednesday, November 26 2026", in the client's language.
local function FormatDate()
	local now = date("*t")
	local weekday = _G[WEEKDAYS[now.wday]] or ""
	local month = _G[MONTHS[now.month]] or ""
	-- The month number goes in fifth, as the calendar passes it.
	return format(_G.FULLDATE, weekday, month, now.day, now.year, now.month)
end

-- A secret value counts as busy, since it can not be looked at.
local function IsBusy()
	local cast = UnitCastingInfo("player")
	if IsSecret(cast) or cast ~= nil then
		return true
	end
	local channel = UnitChannelInfo("player")
	if IsSecret(channel) or channel ~= nil then
		return true
	end
	return GetCurrentKeyBoardFocus() ~= nil
end

local function InCombat()
	return InCombatLockdown() or UnitAffectingCombat("player")
end

-- Times the game shows full screen over the world, where this screen would sit
-- on top of them.
local function InSceneOrBattle()
	local cinematic, movie = _G.CinematicFrame, _G.MovieFrame
	if (cinematic and cinematic:IsShown()) or (movie and movie:IsShown()) then
		return true
	end
	return C_PetBattles and C_PetBattles.IsInBattle and C_PetBattles.IsInBattle() or false
end

local function IsLeveling()
	return UnitLevel("player") < GetMaxPlayerLevel() and not IsXPUserDisabled()
end

-- ---------------------------------------------------------------------------
-- Session numbers
-- ---------------------------------------------------------------------------

-- The wall clock moment of login. GetSessionTime counts from login, so this is
-- the same number across reloads of one login.
local function LoginMoment()
	return time() - GetSessionTime()
end

local function StartSession()
	lastXP, lastMax, lastLevel = UnitXP("player") or 0, UnitXPMax("player") or 1, UnitLevel("player")
	local db = _G.KkthnxUIDB
	local guid = UnitGUID("player")
	local moment = LoginMoment()
	local saved = db and db.afkSession
	if saved and saved.guid == guid and abs(saved.moment - moment) <= SESSION_SLACK then
		session = saved
		return
	end
	session = {
		guid = guid,
		moment = moment,
		money = GetMoney(),
		level = lastLevel,
		xp = 0,
		quests = 0,
		deaths = 0,
		away = 0,
	}
	if db then
		db.afkSession = session
	end
end

-- Seconds away this session, the current stretch included.
local function AwayTotal()
	return session.away + (wasAFK and (GetTime() - afkSince) or 0)
end

-- ---------------------------------------------------------------------------
-- Screen content
-- ---------------------------------------------------------------------------

local function RefreshStats()
	local rows = ui.stats
	local online = GetSessionTime()
	local away = AwayTotal()
	SetValue(rows.online, FormatDuration(online))
	SetValue(rows.away, FormatDuration(away))

	local delta = GetMoney() - session.money
	if delta > 0 then
		SetValue(rows.gold, "+" .. GetMoneyString(delta, true), "positive")
	elseif delta < 0 then
		SetValue(rows.gold, "-" .. GetMoneyString(-delta, true), "negative")
	else
		SetValue(rows.gold, L["No change"], "muted")
	end

	local leveling = IsLeveling()
	if leveling then
		SetValue(rows.xp, K.ShortValue(session.xp))
		-- The rate counts time at the keyboard only, so a long break does not
		-- drag it down.
		local active = online - away
		if active >= MIN_RATE_TIME and session.xp > 0 then
			local perSecond = session.xp / active
			SetValue(rows.rate, K.ShortValue(floor(perSecond * 3600)))
			local remaining = (UnitXPMax("player") or 0) - (UnitXP("player") or 0)
			SetValue(rows.next, remaining > 0 and FormatDuration(remaining / perSecond) or L["None"])
		else
			SetValue(rows.rate, L["Not yet"], "muted")
			SetValue(rows.next, L["Not yet"], "muted")
		end
		local levels = UnitLevel("player") - session.level
		SetValue(rows.levels, levels > 0 and ("+" .. levels) or "0", levels > 0 and "positive" or "text")
	end
	SetValue(rows.quests, session.quests)
	SetValue(rows.deaths, session.deaths, session.deaths > 0 and "warning" or "text")

	-- Rows are only laid out again when the leveling ones come or go.
	if ui.card.leveling ~= leveling then
		ui.card.leveling = leveling
		local previous, count = ui.cardTitle, 0
		for _, stat in ipairs(STATS) do
			local row = rows[stat.key]
			local show = leveling or not stat.leveling
			row:SetShown(show)
			if show then
				row:ClearAllPoints()
				row:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, previous == ui.cardTitle and -GAP or 0)
				previous = row
				count = count + 1
			end
		end
		ui.card:SetHeight(PAD * 2 + ROW_HEIGHT * (count + 1) + GAP)
	end
end

local function Tick()
	ui.timer:SetText(FormatElapsed(GetTime() - afkSince))
	local clock = GameTime_GetTime(true)
	if clock ~= lastClock then
		lastClock = clock
		ui.clock:SetText(clock)
		ui.date:SetText(FormatDate())
	end
	RefreshStats()
end

local function RefreshIdentity()
	-- Forever names are a first name and a surname, never a realm.
	local first, surname = UnitName("player")
	local name = (surname and surname ~= "") and (first .. " " .. surname) or first
	ui.name:SetText(K.ClassColorText(K.Class, name))

	local race = UnitRace("player")
	local className = UnitClass("player")
	ui.info:SetFormattedText(L["Level %d %s %s"], UnitLevel("player"), race or "", className or "")

	local guildName, rankName = GetGuildInfo("player")
	if guildName then
		ui.guild:SetFormattedText("<%s>  %s", guildName, rankName or "")
	else
		ui.guild:SetText(L["No Guild"])
	end
end

local function LowestDurability()
	local lowest
	for slot = _G.INVSLOT_FIRST_EQUIPPED or 1, _G.INVSLOT_LAST_EQUIPPED or 19 do
		local current, maximum = GetInventoryItemDurability(slot)
		if current and maximum and maximum > 0 then
			local share = current / maximum
			if not lowest or share < lowest then
				lowest = share
			end
		end
	end
	return lowest
end

-- Free and total slots in the bags that hold anything (family 0), so a quiver
-- or soul bag does not count as room for loot.
local function BagSpace()
	local free, total = 0, 0
	for bag = _G.BACKPACK_CONTAINER or 0, _G.NUM_BAG_SLOTS or 4 do
		local slots = C_Container.GetContainerNumSlots(bag) or 0
		local freeSlots, family = C_Container.GetContainerNumFreeSlots(bag)
		if slots > 0 and family == 0 then
			total = total + slots
			free = free + (freeSlots or 0)
		end
	end
	return free, total
end

local function RefreshDetails()
	local zone, subZone = GetZoneText() or "", GetSubZoneText() or ""
	SetValue(ui.zone, (subZone ~= "" and subZone ~= zone) and (subZone .. ", " .. zone) or zone)
	SetValue(ui.gold, GetMoneyString(GetMoney(), true))

	local lowest = LowestDurability()
	if lowest then
		SetValue(ui.durability, format("%d%%", floor(lowest * 100 + 0.5)), lowest <= 0.2 and "negative" or lowest <= 0.5 and "warning" or "text")
	else
		SetValue(ui.durability, L["None"], "muted")
	end

	local free, total = BagSpace()
	SetValue(ui.bags, format(L["%d of %d free"], free, total), free == 0 and "negative" or "text")

	local leveling = IsLeveling()
	ui.xp:SetShown(leveling)
	ui.xpBar:SetShown(leveling)
	if leveling then
		local current, maximum = UnitXP("player") or 0, UnitXPMax("player") or 1
		if maximum <= 0 then
			maximum = 1
		end
		local rested = GetXPExhaustion() or 0
		SetValue(ui.xp, K.ShortValue(current) .. " / " .. K.ShortValue(maximum))
		ui.xpFill:SetMinMaxValues(0, maximum)
		ui.xpFill:SetValue(current)
		ui.xpRest:SetMinMaxValues(0, maximum)
		ui.xpRest:SetValue(current + rested < maximum and current + rested or maximum)

		local text = format("%.1f%%", current / maximum * 100)
		if rested > 0 then
			local restedText = format(L["%d%% rested"], floor(rested / maximum * 100 + 0.5))
			text = text .. "    " .. K.ColorText(IsResting() and "positive" or "secondary", restedText)
		elseif IsResting() then
			text = text .. "    " .. K.ColorText("positive", L["Resting"])
		end
		ui.xpText:SetText(text)
	end

	-- The messages start below whatever is last, so no gap is left at the cap.
	ui.divider:ClearAllPoints()
	if leveling then
		ui.divider:SetPoint("TOPLEFT", ui.xpBar, "BOTTOMLEFT", -BAR_INSET, -PAD)
	else
		ui.divider:SetPoint("TOPLEFT", ui.bags, "BOTTOMLEFT", 0, -PAD)
	end
end

-- The list grows with the messages, between a few lines and a cap, and the
-- panel follows it since its bottom is tied to the footer.
local function SetCount()
	ui.count:SetText(messageCount > 0 and messageCount or "")
	ui.empty:SetShown(messageCount == 0)
	local lines = messageCount < MIN_LINES and MIN_LINES or messageCount > MAX_SHOWN_LINES and MAX_SHOWN_LINES or messageCount
	ui.inbox:SetHeight(lines * LINE_HEIGHT)
end

local function AddLine(prefix, sender, text, r, g, b)
	ui.inbox:AddMessage(format("%s %s%s: %s", K.ColorText("muted", GameTime_GetTime(true)), prefix, sender, text), r, g, b)
	messageCount = messageCount + 1
	SetCount()
end

-- ---------------------------------------------------------------------------
-- Model
-- ---------------------------------------------------------------------------

local function PlayEmote(model, emote)
	if not model:HasAnimation(emote.id) then
		return false
	end
	model.emote = emote
	model.emoteEnds = GetTime() + (emote.hold or ONESHOT_LIMIT)
	model:SetAnimation(emote.id)
	return true
end

local function EndEmote(model)
	model.emote = nil
	model.nextEmote = GetTime() + EMOTE_INTERVAL
	model:SetAnimation(ANIM_STAND)
end

local function PoseModel(model)
	model:SetFacing(MODEL_FACING)
	model.nextEmote = GetTime() + EMOTE_INTERVAL
	PlayEmote(model, WAVE)
end

-- Fires at the end of every animation loop, standing included, so only a
-- one-shot emote is ended here.
local function OnAnimFinished(model)
	local emote = model.emote
	if emote and not emote.hold then
		EndEmote(model)
	end
end

-- Called once a second while the screen is up.
local function UpdateEmote(model)
	local now = GetTime()
	if model.emote then
		if now >= model.emoteEnds then
			EndEmote(model)
		end
		return
	end
	if now < (model.nextEmote or 0) then
		return
	end
	for _ = 1, #EMOTES do
		model.emoteIndex = (model.emoteIndex or 0) % #EMOTES + 1
		if PlayEmote(model, EMOTES[model.emoteIndex]) then
			return
		end
	end
	model.nextEmote = now + EMOTE_INTERVAL
end

local function OnTick()
	Tick()
	UpdateEmote(ui.model)
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

local function BuildClock()
	ui.clock = Text(root, 72, "text")
	ui.clock:SetPoint("TOPLEFT", root, "TOPLEFT", MARGIN, -MARGIN)
	ui.date = Text(root, 18, "secondary")
	ui.date:SetPoint("TOPLEFT", ui.clock, "BOTTOMLEFT", 0, -GAP)
end

local function BuildCard()
	local card = CreateFrame("Frame", nil, root)
	card:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", MARGIN, MARGIN)
	card:SetWidth(CARD_WIDTH)
	K.CreateGradientBackground(card)
	K.CreateBorder(card)
	ui.card = card

	-- One row tall, so the card's height is whole rows plus padding.
	local title = CreateFrame("Frame", nil, card)
	title:SetSize(CARD_INNER, ROW_HEIGHT)
	title:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -PAD)
	local titleText = Text(title, 14, "accent")
	titleText:SetPoint("LEFT", title, "LEFT", 0, 0)
	titleText:SetText(L["This Session"])
	ui.cardTitle = title

	ui.stats = {}
	for _, stat in ipairs(STATS) do
		ui.stats[stat.key] = Row(card, stat.label, CARD_INNER, LABEL_WIDTH)
	end
	ui.stats.gold.value:SetPoint("RIGHT", ui.stats.gold, "RIGHT", -COIN_NUDGE, 0)
end

local function BuildPanel()
	-- The content hangs from this column, and the panel is drawn from the
	-- column's top down to the footer. Anchoring the content to the panel
	-- instead would make the panel's bottom depend on itself.
	local column = CreateFrame("Frame", nil, root)
	column:SetPoint("TOPRIGHT", root, "TOPRIGHT", -(MARGIN + PAD), -(MARGIN + PAD))
	column:SetSize(INNER_WIDTH, 1)

	local panel = CreateFrame("Frame", nil, root)
	panel:SetPoint("TOPLEFT", column, "TOPLEFT", -PAD, PAD)
	panel:SetPoint("TOPRIGHT", column, "TOPRIGHT", PAD, PAD)
	K.CreateGradientBackground(panel)
	K.CreateBorder(panel)
	ui.panel = panel

	ui.since = Text(panel, 12, "muted")
	ui.since:SetPoint("TOPLEFT", column, "TOPLEFT", 0, 0)
	ui.timer = Text(panel, 48, "highlight")
	ui.timer:SetPoint("TOPLEFT", ui.since, "BOTTOMLEFT", 0, -GAP)

	local line = Hairline(panel, INNER_WIDTH)
	line:SetPoint("TOPLEFT", ui.timer, "BOTTOMLEFT", 0, -PAD)

	-- Class icon, name and level, with the faction emblem across from them.
	-- The class icon in a bordered slot, styled like the UI's other icons.
	local classIcon = CreateFrame("Frame", nil, panel)
	classIcon:SetSize(ICON_SIZE, ICON_SIZE)
	classIcon:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -PAD)
	K.CreateBackground(classIcon, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.9)
	K.CreateBorder(classIcon)
	local classArt = classIcon:CreateTexture(nil, "ARTWORK")
	classArt:SetPoint("TOPLEFT", classIcon, "TOPLEFT", 1, -1)
	classArt:SetPoint("BOTTOMRIGHT", classIcon, "BOTTOMRIGHT", -1, 1)
	classArt:SetAtlas("classicon-" .. strlower(K.Class))

	local faction = panel:CreateTexture(nil, "ARTWORK")
	faction:SetSize(ICON_SIZE, ICON_SIZE)
	faction:SetPoint("TOPRIGHT", line, "BOTTOMRIGHT", 0, -PAD)
	local factionAtlas = FACTION_ATLAS[K.Faction]
	if factionAtlas then
		faction:SetAtlas(factionAtlas)
	else
		faction:Hide()
	end

	local nameWidth = INNER_WIDTH - (ICON_SIZE + GAP * 2) * 2
	ui.name = Text(panel, 24, "text")
	ui.name:SetPoint("TOPLEFT", classIcon, "TOPRIGHT", GAP * 2, 0)
	ui.name:SetWidth(nameWidth)
	ui.info = Text(panel, 14, "secondary")
	ui.info:SetPoint("TOPLEFT", ui.name, "BOTTOMLEFT", 0, -GAP)
	ui.info:SetWidth(nameWidth)
	ui.guild = Text(panel, 14, "muted")
	ui.guild:SetPoint("TOPLEFT", classIcon, "BOTTOMLEFT", 0, -GAP * 2)
	ui.guild:SetWidth(INNER_WIDTH)

	line = Hairline(panel, INNER_WIDTH)
	line:SetPoint("TOPLEFT", ui.guild, "BOTTOMLEFT", 0, -PAD)

	ui.zone = Row(panel, L["Location"], INNER_WIDTH, LABEL_WIDTH)
	ui.zone:SetPoint("TOPLEFT", line, "BOTTOMLEFT", 0, -GAP)
	ui.gold = Row(panel, L["Gold"], INNER_WIDTH, LABEL_WIDTH)
	ui.gold:SetPoint("TOPLEFT", ui.zone, "BOTTOMLEFT", 0, 0)
	ui.gold.value:SetPoint("RIGHT", ui.gold, "RIGHT", -COIN_NUDGE, 0)
	ui.durability = Row(panel, L["Durability"], INNER_WIDTH, LABEL_WIDTH)
	ui.durability:SetPoint("TOPLEFT", ui.gold, "BOTTOMLEFT", 0, 0)
	ui.bags = Row(panel, L["Bags"], INNER_WIDTH, LABEL_WIDTH)
	ui.bags:SetPoint("TOPLEFT", ui.durability, "BOTTOMLEFT", 0, 0)
	ui.xp = Row(panel, L["Experience"], INNER_WIDTH, LABEL_WIDTH)
	ui.xp:SetPoint("TOPLEFT", ui.bags, "BOTTOMLEFT", 0, 0)

	-- Experience with the rested part drawn behind it, both in the accent, and
	-- the numbers written on the bar.
	local xpBar = CreateFrame("Frame", nil, panel)
	xpBar:SetSize(INNER_WIDTH - BAR_INSET * 2, XP_BAR_HEIGHT)
	xpBar:SetPoint("TOPLEFT", ui.xp, "BOTTOMLEFT", BAR_INSET, -GAP)
	K.CreateBackground(xpBar, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.9)
	local texture = K.GetTexture(C.Unitframe and C.Unitframe.Texture or "KkthnxUI")
	local accent = K.Colors.accent
	local rest = CreateFrame("StatusBar", nil, xpBar)
	rest:SetAllPoints(xpBar)
	rest:SetStatusBarTexture(texture)
	rest:SetStatusBarColor(accent[1], accent[2], accent[3], 0.35)
	local fill = CreateFrame("StatusBar", nil, xpBar)
	fill:SetAllPoints(xpBar)
	fill:SetFrameLevel(rest:GetFrameLevel() + 1)
	fill:SetStatusBarTexture(texture)
	fill:SetStatusBarColor(accent[1], accent[2], accent[3], 1)
	-- The border goes on the top bar, since the bars are child frames and draw
	-- over anything on the holder.
	K.CreateBorder(fill)
	local xpText = Text(fill, 12, "text", "CENTER")
	xpText:SetPoint("CENTER", fill, "CENTER", 0, 0)
	ui.xpBar, ui.xpRest, ui.xpFill, ui.xpText = xpBar, rest, fill, xpText

	ui.divider = Hairline(panel, INNER_WIDTH)

	ui.messages = Text(panel, 14, "accent")
	ui.messages:SetPoint("TOPLEFT", ui.divider, "BOTTOMLEFT", 0, -PAD)
	ui.messages:SetText(L["Messages"])
	ui.count = Text(panel, 14, "muted", "RIGHT")
	ui.count:SetPoint("TOPRIGHT", ui.divider, "BOTTOMRIGHT", 0, -PAD)

	local inbox = CreateFrame("ScrollingMessageFrame", nil, panel)
	inbox:SetPoint("TOPLEFT", ui.messages, "BOTTOMLEFT", 0, -GAP * 2)
	inbox:SetWidth(INNER_WIDTH)
	K.SetFont(inbox, 14, K.FontOutlineStyle())
	inbox:SetSpacing(LINE_SPACING)
	inbox:SetJustifyH("LEFT")
	inbox:SetIndentedWordWrap(true)
	inbox:SetFading(false)
	inbox:SetMaxLines(MAX_LINES)
	inbox:EnableMouseWheel(true)
	inbox:SetScript("OnMouseWheel", function(self, delta)
		if delta > 0 then
			self:ScrollUp()
		else
			self:ScrollDown()
		end
	end)
	ui.inbox = inbox

	ui.empty = Text(inbox, 12, "muted")
	ui.empty:SetPoint("TOPLEFT", inbox, "TOPLEFT", 0, 0)
	ui.empty:SetWidth(INNER_WIDTH)
	ui.empty:SetWordWrap(true)
	ui.empty:SetText(L["Whispers and guild chat that come in while you are away show here."])

	local footerLine = Hairline(panel, INNER_WIDTH)
	footerLine:SetPoint("TOPLEFT", inbox, "BOTTOMLEFT", 0, -GAP * 2)
	ui.footer = Text(panel, 12, "muted")
	ui.footer:SetPoint("TOPLEFT", footerLine, "BOTTOMLEFT", 0, -PAD)
	ui.footer:SetText(L["Press any key to come back"])

	panel:SetPoint("BOTTOMLEFT", ui.footer, "BOTTOMLEFT", -PAD, -PAD)
end

local function Build()
	-- Parented to the world frame, so hiding the interface leaves it up. Its
	-- scale is matched to the interface's on every open, so one unit is the
	-- same pixel as everywhere else in the UI.
	root = CreateFrame("Frame", "KKUI_AFKScreen", WorldFrame)
	root:SetAllPoints(WorldFrame)
	root:SetFrameStrata("FULLSCREEN")
	root:EnableMouse(true)
	root:EnableKeyboard(true)
	root:EnableGamePadButton(true)
	root:Hide()

	root:SetScript("OnKeyDown", function(_, key)
		if MODIFIER_KEYS[key] then
			return
		end
		-- The screenshot key takes a picture of the screen as it is.
		if GetBindingAction(key) == "SCREENSHOT" then
			Screenshot()
			return
		end
		Module:Close()
	end)
	root:SetScript("OnGamePadButtonDown", function()
		Module:Close()
	end)
	root:SetScript("OnMouseDown", function()
		Module:Close()
	end)

	local fade = root:CreateAnimationGroup()
	local alpha = fade:CreateAnimation("Alpha")
	alpha:SetFromAlpha(0)
	alpha:SetToAlpha(1)
	alpha:SetDuration(0.3)
	fade:SetToFinalAlpha(true)
	root.fade = fade

	ui = {}

	-- A shade along the left edge, so the clock and the card read over a
	-- bright sky. Its width is set on open, from the screen width.
	local shade = root:CreateTexture(nil, "BACKGROUND")
	shade:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
	shade:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 0, 0)
	shade:SetColorTexture(1, 1, 1)
	local bg = K.Colors.bg
	K.FadeGradient(shade, bg[1], bg[2], bg[3], 0.75, 0)
	ui.shade = shade

	BuildClock()
	BuildCard()
	BuildPanel()

	-- Placed and sized on open, from the screen size.
	local model = CreateFrame("PlayerModel", nil, root)
	model:SetScript("OnModelLoaded", PoseModel)
	model:SetScript("OnAnimFinished", OnAnimFinished)
	ui.model = model
end

-- ---------------------------------------------------------------------------
-- Open and close
-- ---------------------------------------------------------------------------

local function CancelRetry()
	if retryTimer then
		retryTimer:Cancel()
		retryTimer = nil
	end
end

local function RestoreUI()
	if not hidUI then
		return
	end
	hidUI = false
	SetUIVisibility(true)
	-- Only reachable if combat somehow began first. Try once more as it ends
	-- rather than leave the player without an interface.
	if not UIParent:IsShown() then
		K.DeferCombat("AFKScreenUI", function()
			if not UIParent:IsShown() then
				SetUIVisibility(true)
			end
		end)
	end
end

-- Handlers are named on the way out too, so the always-on handlers for the
-- same events (death and experience counts) stay registered.
local function SetSessionEvents(on)
	local method = on and "RegisterEvent" or "UnregisterEvent"
	for _, event in ipairs(EXIT_EVENTS) do
		Module[method](Module, event, "OnExitEvent")
	end
	for _, event in ipairs(DETAIL_EVENTS) do
		Module[method](Module, event, "OnDetailEvent")
	end
	for _, event in ipairs(IDENTITY_EVENTS) do
		Module[method](Module, event, "OnIdentityEvent")
	end
	for event in pairs(CHAT_EVENTS) do
		Module[method](Module, event, "OnChatEvent")
	end
	Module[method](Module, "UPDATE_BATTLEFIELD_STATUS", "OnBattlefieldStatus")
	if on then
		Module:RegisterUnitEvent("UNIT_MODEL_CHANGED", "OnModelChanged", "player")
	else
		Module:UnregisterUnitEvent("UNIT_MODEL_CHANGED")
	end
end

-- The character stands on the floor midway between the card and the panel.
local function PlaceModel()
	local width, height = root:GetWidth(), root:GetHeight()
	local left = MARGIN + CARD_WIDTH
	local right = width - MARGIN - PANEL_WIDTH
	local model = ui.model
	model:ClearAllPoints()
	model:SetPoint("BOTTOM", root, "BOTTOMLEFT", floor((left + right) / 2), MARGIN)
	model:SetSize(floor(height * 0.5), floor(height * 0.7))
	ui.shade:SetWidth(floor(width * 0.45))
end

function Module:Open(test)
	if shown then
		return
	end
	if not root then
		Build()
	end
	shown = true
	testing = test and true or false

	-- The same steps as the game's Hide UI key, closing windows first so none
	-- is left half drawn behind the hidden interface.
	securecall("CloseAllWindows")
	if UIParent:IsShown() then
		SetUIVisibility(false)
		hidUI = true
	end
	if C.Misc.AFKSpin then
		MoveViewLeftStart(SPIN_SPEED)
		spinning = true
	end

	root:SetScale(UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale())

	ui.inbox:Clear()
	messageCount = 0
	SetCount()
	ui.since:SetFormattedText(L["Away since %s"], afkSinceText)
	lastClock = nil
	ui.card.leveling = nil
	RefreshIdentity()
	RefreshDetails()
	Tick()
	ticker = C_Timer.NewTicker(1, OnTick)
	SetSessionEvents(true)

	root:SetAlpha(0)
	root:Show()
	root.fade:Play()

	PlaceModel()
	local model = ui.model
	model:SetUnit("player")
	model:SetPortraitZoom(0)
	PoseModel(model)
end

function Module:Close()
	if not shown then
		return
	end
	shown = false
	testing = false
	if ticker then
		ticker:Cancel()
		ticker = nil
	end
	SetSessionEvents(false)
	if spinning then
		MoveViewLeftStop()
		spinning = false
	end
	root.fade:Stop()
	root:Hide()
	ui.model.emote = nil
	RestoreUI()
end

function Module:TryOpen()
	CancelRetry()
	if shown or not wasAFK or not C.Misc.AFKScreen then
		return
	end
	if InCombat() or UnitIsDead("player") or InSceneOrBattle() then
		return
	end
	if IsBusy() then
		retryTimer = C_Timer.NewTimer(RETRY_DELAY, function()
			retryTimer = nil
			Module:TryOpen()
		end)
		return
	end
	self:Open(false)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function Module:OnFlagsChanged(_, unit)
	if unit ~= "player" then
		return
	end
	local afk = UnitIsAFK("player")
	-- In chat messaging lockdown the flag can be secret. Nothing is changed
	-- until it can be read.
	if IsSecret(afk) then
		return
	end
	if afk then
		if not wasAFK then
			wasAFK = true
			afkSince = GetTime()
			afkSinceText = GameTime_GetTime(true)
			self:TryOpen()
		end
	elseif wasAFK then
		session.away = session.away + (GetTime() - afkSince)
		wasAFK = false
		CancelRetry()
		if shown and not testing then
			self:Close()
		end
	end
end

function Module:OnExitEvent(event)
	-- A duel the Automation module turns down needs no answer.
	if event == "DUEL_REQUESTED" and C.Automation.Enable and C.Automation.DeclineDuels then
		return
	end
	self:Close()
end

function Module:OnBattlefieldStatus(_, index)
	if index and GetBattlefieldStatus(index) == "confirm" then
		self:Close()
	end
end

function Module:OnDetailEvent()
	RefreshDetails()
end

function Module:OnIdentityEvent()
	RefreshIdentity()
	RefreshDetails()
end

function Module:OnModelChanged()
	ui.model:RefreshUnit()
end

function Module:OnChatEvent(event, text, sender, _, _, _, _, _, _, _, _, _, guid)
	local kind = CHAT_EVENTS[event]
	if not kind or IsSecret(text) or IsSecret(sender) then
		return
	end
	local name
	if kind == "BN_WHISPER" then
		-- A Battle.net name arrives as an escape the font string draws itself.
		name = K.ColorText("info", sender)
	else
		name = Ambiguate(sender, "short")
		local classFile
		if guid and not IsSecret(guid) and guid ~= "" then
			local _, englishClass = GetPlayerInfoByGUID(guid)
			classFile = englishClass
		end
		if classFile then
			name = K.ClassColorText(classFile, name)
		end
	end
	local prefix = kind == "GUILD" and K.ColorText("muted", L["Guild"] .. " ") or ""
	local info = _G.ChatTypeInfo and _G.ChatTypeInfo[kind]
	local r, g, b
	if info and info.r then
		r, g, b = info.r, info.g, info.b
	else
		r, g, b = Color("text")
	end
	AddLine(prefix, name, text, r, g, b)
end

-- Counts what each update adds. On a level up the rest of the old level is
-- added, then the new level's progress. Two levels from one reward would miss
-- the level between, which the game does not report.
function Module:OnXPUpdate(_, unit)
	if unit ~= "player" then
		return
	end
	local level, current, maximum = UnitLevel("player"), UnitXP("player") or 0, UnitXPMax("player") or 1
	if level > lastLevel then
		local rest = lastMax - lastXP
		session.xp = session.xp + (rest > 0 and rest or 0) + current
	elseif current > lastXP then
		session.xp = session.xp + (current - lastXP)
	end
	lastXP, lastMax, lastLevel = current, maximum, level
end

function Module:OnQuestTurnedIn()
	session.quests = session.quests + 1
end

function Module:OnPlayerDead()
	session.deaths = session.deaths + 1
end

function Module:PLAYER_ENTERING_WORLD()
	local afk = UnitIsAFK("player")
	if IsSecret(afk) then
		return
	end
	if afk and not wasAFK then
		afkSince = GetTime()
		afkSinceText = GameTime_GetTime(true)
	end
	wasAFK = afk and true or false
end

-- A reload or logout while away would drop the stretch so far, since it is
-- only added when the flag clears. The session table is saved, so add it now.
-- Fires on reload too, never on a zone change.
function Module:OnLogout()
	if wasAFK then
		session.away = session.away + (GetTime() - afkSince)
		wasAFK = false
	end
end

-- ---------------------------------------------------------------------------
-- Test mode
-- ---------------------------------------------------------------------------

-- /kk afktest. Opens the screen without the AFK flag, with one sample message,
-- so the layout can be checked. Any key closes it, as on the real screen.
function Module:ToggleTest()
	if shown then
		self:Close()
		return
	end
	if InCombat() then
		K.Print(L["The AFK screen can not open in combat."])
		return
	end
	if not wasAFK then
		afkSince = GetTime()
		afkSinceText = GameTime_GetTime(true)
	end
	self:Open(true)
	local r, g, b = Color("text")
	local info = _G.ChatTypeInfo and _G.ChatTypeInfo.WHISPER
	if info and info.r then
		r, g, b = info.r, info.g, info.b
	end
	AddLine("", K.ClassColorText(K.Class, K.Name), L["This is how a whisper shows while you are away."], r, g, b)
	K.Print(L["AFK screen test. Press any key to close it."])
end

function Module:OnEnable()
	StartSession()
	-- Always listened to, so turning the option on works without a reload and
	-- the session numbers count whether or not the screen is used. The option
	-- itself is read each time the flag turns on.
	self:RegisterEvent("PLAYER_FLAGS_CHANGED", "OnFlagsChanged")
	self:RegisterEvent("PLAYER_XP_UPDATE", "OnXPUpdate")
	self:RegisterEvent("QUEST_TURNED_IN", "OnQuestTurnedIn")
	self:RegisterEvent("PLAYER_DEAD", "OnPlayerDead")
	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("PLAYER_LOGOUT", "OnLogout")
	self:PLAYER_ENTERING_WORLD()
end
