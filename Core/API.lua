--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/API.lua
	Purpose:
		Engine level helpers used everywhere: player info, pixel perfect
		scaling, colors, fonts, printing, and small utility creators.
		Kept dependency free so it can load right after the engine.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

-- ---------------------------------------------------------------------------
-- Local caching
-- ---------------------------------------------------------------------------

local _G = _G
local next = next
local select = select
local type = type
local tostring = tostring
local floor = math.floor
local ceil = math.ceil
local max = math.max
local min = math.min
local format = string.format
local strfind = string.find

local CreateFrame = CreateFrame
local UIParent = UIParent
local GetPhysicalScreenSize = GetPhysicalScreenSize
local InCombatLockdown = InCombatLockdown
local UnitCanAttack = UnitCanAttack
local UnitEffectiveLevel = UnitEffectiveLevel

-- ---------------------------------------------------------------------------
-- Player info
-- ---------------------------------------------------------------------------

local name, realm = UnitName("player"), GetRealmName()
local _, class = UnitClass("player")
local _, race = UnitRace("player")
local faction = UnitFactionGroup("player")

K.Name = name
K.Realm = realm
K.Class = class
K.Race = race
K.Faction = faction
K.Level = UnitLevel("player")
K.Locale = GetLocale()
K.GUID = UnitGUID("player")

-- K.ClassColor, the player's class colour, is set in Core/Palette.lua with the
-- rest of the theme's class colours.

-- One hidden frame for parking Blizzard frames we replace. A frame parented here
-- is never drawn, however often Blizzard shows it.
K.HiddenParent = CreateFrame("Frame", "KKUI_HiddenParent", UIParent)
K.HiddenParent:SetAllPoints(UIParent)
K.HiddenParent:Hide()

K.MediaFolder = "Interface\\AddOns\\KkthnxUI\\Media\\"

-- ---------------------------------------------------------------------------
-- Printing
-- ---------------------------------------------------------------------------

-- The "KkthnxUI:" chat prefix, built on first use because the palette
-- (Core/Palette.lua) loads after this file.
local titleTag
local function TitleTag()
	if not titleTag then
		titleTag = K.ColorText("accent", "KkthnxUI") .. ": "
	end
	return titleTag
end

-- Chat output goes through the default chat frame and not the global print. The
-- global one is handled on the C side and taints the chat frame, and a tainted
-- chat frame is how a whisper window ends up opening from tainted code. Output is
-- also dropped where addon chat is restricted, in raid combat and combat in a
-- battleground or arena, since adding a line there is itself the taint. Nothing
-- printed from this addon is worth that.
local function ChatAllowed()
	local _, instanceType = IsInInstance()
	if instanceType == "raid" and InCombatLockdown() then
		return false
	end
	if (instanceType == "pvp" or instanceType == "arena") and InCombatLockdown() then
		return false
	end
	return true
end

function K.PrintRaw(text)
	local frame = DEFAULT_CHAT_FRAME
	if frame and ChatAllowed() then
		frame:AddMessage(text)
	end
end

function K.Print(...)
	-- A single argument is a finished message, only several are a format string.
	if select("#", ...) > 1 then
		K.PrintRaw(TitleTag() .. format(...))
	else
		K.PrintRaw(TitleTag() .. tostring((...)))
	end
end

-- Midnight-safe aura read. C_UnitAuras.GetAuraDataByIndex throws ("Auras cannot
-- be accessed when secret while tainted") for a secret aura while our code is on
-- the stack (enemies, and some hidden player auras). Wrap it so callers get nil
-- instead of an error. The full display for secret-aura units needs the
-- CustomAuraContainer intrinsic system, which is a larger rework.
local GetAuraDataByIndex = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
function K.GetAuraData(unit, index, filter)
	if not GetAuraDataByIndex then
		return nil
	end
	local ok, data = pcall(GetAuraDataByIndex, unit, index, filter)
	if ok then
		return data
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- Combat queue
-- ---------------------------------------------------------------------------
-- The one way to put work off until combat ends. Anything a lockdown blocks
-- (secure frames, bindings, reparenting, attributes) goes through here rather
-- than through its own PLAYER_REGEN_ENABLED registration.
--
--   K.DeferCombat(key, fn)   run fn once, after the next combat ends
--
-- A key is one pending job. Deferring it again keeps its place in the line and
-- swaps in the new function, so a burst of requests runs once. The line drains
-- in the order keys first arrived, each function isolated so one error cannot
-- stop the rest. The event is only registered while something is waiting.
--
-- A call made out of combat still waits for the next combat to end, so a caller
-- checks InCombatLockdown() itself and runs the work directly when it can. A
-- function should read live state when it runs, not what was true when it was
-- queued, and may defer itself again for the drain after that.
local combatFrame = CreateFrame("Frame")
local combatKeys, combatJobs = {}, {}

local function DrainCombatQueue()
	combatFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
	-- Swap the line out first, so a job that defers again lands in a fresh one.
	local keys, jobs = combatKeys, combatJobs
	combatKeys, combatJobs = {}, {}
	for index = 1, #keys do
		K.SafeCall(jobs[keys[index]])
	end
end

combatFrame:SetScript("OnEvent", DrainCombatQueue)

function K.DeferCombat(key, fn)
	if key == nil or type(fn) ~= "function" then
		return
	end
	if combatJobs[key] == nil then
		local count = #combatKeys
		combatKeys[count + 1] = key
		if count == 0 then
			combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
		end
	end
	combatJobs[key] = fn
end

-- ---------------------------------------------------------------------------
-- Math helpers
-- ---------------------------------------------------------------------------

function K.Round(number, decimals)
	decimals = decimals or 0
	local mult = 10 ^ decimals
	return floor(number * mult + 0.5) / mult
end

function K.Clamp(value, low, high)
	return max(low, min(high, value))
end

-- Short numeric formatting (12.3k, 4.5m, ...)
function K.ShortValue(value)
	local absValue = value < 0 and -value or value
	if absValue >= 1e9 then
		return format("%.1fb", value / 1e9)
	elseif absValue >= 1e6 then
		return format("%.1fm", value / 1e6)
	elseif absValue >= 1e3 then
		return format("%.1fk", value / 1e3)
	end
	return tostring(value)
end

-- ---------------------------------------------------------------------------
-- Colors
-- ---------------------------------------------------------------------------

function K.RGBToHex(r, g, b)
	if type(r) == "table" then
		r, g, b = r.r or r[1], r.g or r[2], r.b or r[3]
	end
	-- Rounded, the same as K.ColorHex, so both give the same code for a colour.
	return format("|cff%02x%02x%02x", r * 255 + 0.5, g * 255 + 0.5, b * 255 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Pixel perfect scaling (K.Pixel)
-- ---------------------------------------------------------------------------
-- 768 is WoW's reference height, so perfect = 768 / physicalHeight is the size
-- of one physical pixel at scale 1.0. mult is that pixel size at the current
-- UIParent scale. When the UIParent scale equals perfect, mult == 1 and every
-- integer is already pixel aligned. Pixel.Scale snaps any value onto that grid.

local Pixel = {}
K.Pixel = Pixel

Pixel.physicalWidth, Pixel.physicalHeight = GetPhysicalScreenSize()
Pixel.perfect = 768 / Pixel.physicalHeight
Pixel.mult = Pixel.perfect / (UIParent and UIParent:GetScale() or 1)

-- Mirror onto the engine for older call sites and the border system.
K.ScreenWidth, K.ScreenHeight = Pixel.physicalWidth, Pixel.physicalHeight
K.Resolution = format("%dx%d", K.ScreenWidth, K.ScreenHeight)
K.Mult = Pixel.mult

-- Ideal pixel perfect scale, clamped to WoW's valid range.
function Pixel.BestScale()
	return K.Clamp(Pixel.perfect, 0.4, 1.15)
end
K.GetPerfectScale = Pixel.BestScale

-- Recalculate mult after a scale or resolution change.
function Pixel.UpdateMult()
	Pixel.physicalWidth, Pixel.physicalHeight = GetPhysicalScreenSize()
	Pixel.perfect = 768 / Pixel.physicalHeight
	local uiScale = (C.General and C.General.UIScale) or Pixel.BestScale()
	Pixel.mult = Pixel.perfect / (uiScale ~= 0 and uiScale or 1)

	K.ScreenWidth, K.ScreenHeight = Pixel.physicalWidth, Pixel.physicalHeight
	K.Resolution = format("%dx%d", K.ScreenWidth, K.ScreenHeight)
	K.Mult = Pixel.mult
end
K.UpdatePixelMult = Pixel.UpdateMult

-- Snap a value onto the physical pixel grid, rounding magnitude toward zero
-- so opposite edges stay symmetric.
function Pixel.Scale(value)
	if value == 0 then
		return 0
	end
	local m = Pixel.mult
	if m == 1 then
		return value
	end
	local pixels = value / m
	pixels = value > 0 and floor(pixels) or ceil(pixels)
	local snapped = pixels * m
	return snapped == 0 and (value > 0 and m or -m) or snapped
end
K.Scale = Pixel.Scale

-- Apply the configured (or auto) UIParent scale. Deferred in combat.
function K:SetupUIScale(init)
	local general = C.General or {}
	if general.AutoScale then
		general.UIScale = Pixel.BestScale()
	end
	-- An imported or damaged value can be anything, and SetScale with 0 or a
	-- huge number breaks the whole interface. Keep it in the slider's range. The
	-- clamped value is written back to the live table only, so the pixel math
	-- below reads the same scale UIParent gets.
	local scale = general.UIScale
	if type(scale) ~= "number" or scale ~= scale then
		scale = Pixel.BestScale()
	end
	scale = K.Clamp(scale, 0.4, 1.15)
	general.UIScale = scale

	if init then
		Pixel.UpdateMult()
		return
	end

	if InCombatLockdown() then
		K.DeferCombat("UIScale", function()
			K:SetupUIScale()
		end)
		return
	end

	UIParent:SetScale(scale)
	Pixel.UpdateMult()
end

-- Some retail values are "secret" (protected) and cannot be read in combat.
K.IsSecret = _G.issecretvalue or function()
	return false
end

-- A friend, a Battle.net friend or a guild member, going by GUID so a look-alike
-- name cannot pass. False for a missing or secret GUID.
function K.IsKnownPlayer(guid)
	if not guid or K.IsSecret(guid) then
		return false
	end
	return _G.C_FriendList.IsFriend(guid) or _G.C_BattleNet.GetAccountInfoByGUID(guid) ~= nil or _G.IsGuildMember(guid) or false
end

-- Difficulty colour for a unit's level, shared by the unit frames, nameplates and
-- tooltip so they always agree. Only units we can attack get one, as on the
-- Blizzard target frame, since the colour says how hard a fight would be. It asks
-- the server, which accounts for scaled zones and level sync, and falls back to
-- the level gap. Returns nil for everyone else, who keep the plain text colour.
function K.UnitDifficultyColor(unit)
	if not UnitCanAttack("player", unit) then
		return nil
	end
	local PlayerInfo = _G.C_PlayerInfo
	if PlayerInfo and PlayerInfo.GetContentDifficultyCreatureForPlayer and _G.GetDifficultyColor then
		local difficulty = PlayerInfo.GetContentDifficultyCreatureForPlayer(unit)
		if difficulty ~= nil and not K.IsSecret(difficulty) then
			return _G.GetDifficultyColor(difficulty)
		end
	end
	if not _G.GetCreatureDifficultyColor then
		return nil
	end
	local level = UnitEffectiveLevel(unit)
	if level == nil or K.IsSecret(level) then
		return nil
	end
	-- Skull level reads as far above you.
	return _G.GetCreatureDifficultyColor(level > 0 and level or 999)
end

-- One of the game's format strings, such as LOOT_ITEM_SELF, turned into an
-- anchored pattern with a capture for each %s and %d, so a chat line built from
-- it can be read back in any client language. A string with numbered arguments
-- (%1$s) can put them in another order in some languages, so it gives nil and
-- the caller leaves that line alone.
function K.FormatToPattern(text)
	if type(text) ~= "string" or text:find("%$") then
		return nil
	end
	text = text:gsub("%%s", "\001"):gsub("%%d", "\002")
	text = text:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
	text = text:gsub("\001", "(.-)"):gsub("\002", "(%%d+)")
	return "^" .. text .. "$"
end

-- Equipment slots a piece of gear goes in, by its equip location. Trinkets are
-- left out on purpose, their worth is in the effect and not the item level, and
-- so are shirts and tabards, which are cosmetic. Used by the junk seller and
-- the quest reward picker to compare gear against what is worn.
K.GearSlotsFor = {
	INVTYPE_HEAD = { 1 },
	INVTYPE_NECK = { 2 },
	INVTYPE_SHOULDER = { 3 },
	INVTYPE_CHEST = { 5 },
	INVTYPE_ROBE = { 5 },
	INVTYPE_WAIST = { 6 },
	INVTYPE_LEGS = { 7 },
	INVTYPE_FEET = { 8 },
	INVTYPE_WRIST = { 9 },
	INVTYPE_HAND = { 10 },
	INVTYPE_FINGER = { 11, 12 },
	INVTYPE_CLOAK = { 15 },
	INVTYPE_WEAPON = { 16, 17 },
	INVTYPE_2HWEAPON = { 16 },
	INVTYPE_WEAPONMAINHAND = { 16 },
	INVTYPE_WEAPONOFFHAND = { 17 },
	INVTYPE_SHIELD = { 17 },
	INVTYPE_HOLDABLE = { 17 },
	INVTYPE_RANGED = { 18 },
	INVTYPE_RANGEDRIGHT = { 18 },
	INVTYPE_THROWN = { 18 },
	INVTYPE_RELIC = { 18 },
}

-- Gear whose look is not in the transmog collection yet. A grey piece like that is
-- still worth keeping, so the junk logic leaves it alone. Asks the game for the
-- appearance of this exact item, and anything it cannot answer for (not gear, no
-- appearance, API missing, a hidden link) counts as not protected.
function K.IsUncollectedAppearance(itemInfo)
	local T = C_TransmogCollection
	if not itemInfo or K.IsSecret(itemInfo) or not (T and T.GetItemInfo and T.GetAppearanceInfoBySource) then
		return false
	end
	local _, sourceID = T.GetItemInfo(itemInfo)
	if not sourceID then
		return false
	end
	local info = T.GetAppearanceInfoBySource(sourceID)
	return info ~= nil and info.appearanceIsCollected == false
end

-- Keep one of our frames out of the Gamepad UI cursor. With the Gamepad UI on,
-- the game scans a focused Blizzard panel for every button inside it, ours
-- included, and then drives what it found from secure code. A button of ours in
-- that list tainted the chat focus path (SELECTED_CHAT_FRAME and the active edit
-- box globals in the taint log). This is the game's own opt out, and it is safe
-- to call from addon code because it writes the flag through a secure handler.
-- Children of the frame are ignored with it. Does nothing without the Gamepad UI.
function K.IgnoreGamepadNav(frame)
	local mark = _G.SmartNavigation_MarkFrameIgnored
	if mark and frame then
		mark(frame)
	end
end

-- Whether the game's Gamepad UI is on. Modules that hand a job back to the
-- game's own gamepad frames check this once when they enable, the same as the
-- action bars, so switching it needs a reload.
function K.IsGamepadUI()
	local inputUtil = _G.InputUtil
	return (inputUtil and inputUtil.IsGamepadUIEnabled and inputUtil.IsGamepadUIEnabled()) and true or false
end

-- Let the Gamepad UI cursor reach one of our windows. The game's frame manager
-- only drives Blizzard panels and frames that tell it they are shown, so the
-- window is handed to it on show and taken back on hide. B clicks the frame's
-- CloseButton, so one is set when given. The manager refuses addon calls in
-- combat, so a show or hide that lands in combat is passed on once it ends.
-- Does nothing while the Gamepad UI is off.
local gamepadPending = {}
local gamepadWatcher

local function GamepadManager()
	local mode = _G.GamepadMode
	return mode and mode.FrameControlsManager
end

local function SyncGamepadFrame(frame)
	local manager = GamepadManager()
	if not manager then
		return
	end
	if frame:IsShown() then
		manager:FrameShown(frame, frame.KKUI_GamepadPopup)
	else
		manager:FrameHidden(frame)
	end
end

local function QueueGamepadFrame(frame)
	if not K.IsGamepadUI() then
		return
	end
	if not InCombatLockdown() then
		SyncGamepadFrame(frame)
		return
	end
	gamepadPending[frame] = true
	if not gamepadWatcher then
		gamepadWatcher = CreateFrame("Frame")
		gamepadWatcher:SetScript("OnEvent", function(self)
			self:UnregisterEvent("PLAYER_REGEN_ENABLED")
			for pending in next, gamepadPending do
				gamepadPending[pending] = nil
				SyncGamepadFrame(pending)
			end
		end)
	end
	gamepadWatcher:RegisterEvent("PLAYER_REGEN_ENABLED")
end

function K.RegisterGamepadFrame(frame, closeButton, isPopup)
	if not frame or frame.KKUI_GamepadFrame then
		return
	end
	frame.KKUI_GamepadFrame = true
	frame.KKUI_GamepadPopup = isPopup and true or nil
	if closeButton then
		frame.CloseButton = closeButton
	end
	frame:HookScript("OnShow", QueueGamepadFrame)
	frame:HookScript("OnHide", QueueGamepadFrame)
	if frame:IsShown() then
		QueueGamepadFrame(frame)
	end
end

-- Coordinates as text, in the precision the player asked for. "Game" follows the
-- game's own coordinates setting (the same one its map panel and minimap readout
-- use, a CVar from 12.1.5), so every readout on screen agrees. Tenths or whole
-- numbers can also be forced from the options.
function K.FormatCoords(x, y)
	local general = C.General
	local mode = general and general.CoordPrecision
	local tenths
	if mode == "Tenths" then
		tenths = true
	elseif mode == "Whole" then
		tenths = false
	else
		tenths = GetCVarBool("coordsByTenths")
	end
	if tenths then
		return format("%.1f, %.1f", x, y)
	end
	return format("%d, %d", floor(x + 0.5), floor(y + 0.5))
end

-- True while the unit is channelling, so castbars can paint it green as Blizzard
-- does. oUF keeps that state private, so ask the client. A secret spell name
-- cannot be tested, so it counts as a normal cast.
do
	local UnitChannelInfo = UnitChannelInfo
	function K.IsChanneling(unit)
		if not unit then
			return false
		end
		local spell = UnitChannelInfo(unit)
		if K.IsSecret(spell) then
			return false
		end
		return spell ~= nil and spell ~= ""
	end
end

-- Threat colouring shared by nameplates and unit frames, so both read the same
-- way. The colour flips by role, a tank wants aggro (green while holding it), while
-- everyone else wants none (red the moment they pull it). A nil result means the
-- safe case, so the caller keeps the normal reaction colour.
do
	-- Blizzard's threat hues (green, yellow, red) in the same softened tones as the
	-- reaction palette. Aggro uses the rage red, a shade deeper than hostile.
	local THREAT_HOLD = { 0.25, 0.72, 0.30 }
	local THREAT_WARN = { 0.93, 0.76, 0.15 }
	local THREAT_AGGRO = { 0.89, 0.18, 0.18 }
	-- Defensive Stance, Bear Form, Dire Bear Form, Righteous Fury.
	local TANK_AURAS = { 71, 5487, 9634, 25780 }

	-- Are we tanking right now? Assigned group role first, then the stance, form
	-- or aura, so it still reads correctly while solo.
	local function ReadIsTank()
		local role = _G.UnitGroupRolesAssigned and _G.UnitGroupRolesAssigned("player")
		if role == "TANK" then
			return true
		end
		-- Forever has no specializations, so a tank is read from what the player is
		-- doing, such as a warrior in Defensive Stance, a druid in a bear form, or a paladin
		-- with Righteous Fury up.
		local getAura = C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID
		if getAura then
			for _, spellID in ipairs(TANK_AURAS) do
				-- The aura can come back secret while auras are restricted, and a
				-- secret value cannot be tested for truth.
				local aura = getAura(spellID)
				if aura ~= nil and not K.IsSecret(aura) then
					return true
				end
			end
		end
		return false
	end

	-- Every nameplate asks on each colour update, so the answer is kept until the
	-- player's auras or group role change.
	local tankCached
	local tankWatch = CreateFrame("Frame")
	tankWatch:RegisterUnitEvent("UNIT_AURA", "player")
	tankWatch:RegisterEvent("PLAYER_ROLES_ASSIGNED")
	tankWatch:RegisterEvent("GROUP_ROSTER_UPDATE")
	tankWatch:RegisterEvent("PLAYER_ENTERING_WORLD")
	tankWatch:SetScript("OnEvent", function()
		tankCached = nil
	end)

	function K.PlayerIsTank()
		if tankCached == nil then
			tankCached = ReadIsTank()
		end
		return tankCached
	end

	function K.ThreatFillColor(status, isTank)
		if isTank then
			if status == 3 then
				return THREAT_HOLD
			elseif status == 2 or status == 1 then
				return THREAT_WARN
			end
			return THREAT_AGGRO -- someone else is tanking
		else
			if status == 3 then
				return THREAT_AGGRO -- you pulled aggro
			elseif status == 2 or status == 1 then
				return THREAT_WARN
			end
		end
	end
end

-- Disable pixel snapping on a texture or line so our own snap wins.
function K.DisablePixelSnap(object)
	if object.SetSnapToPixelGrid then
		object:SetSnapToPixelGrid(false)
		object:SetTexelSnappingBias(0)
	end
end

-- ---------------------------------------------------------------------------
-- Fonts
-- ---------------------------------------------------------------------------

-- An outlined glyph already has a hard edge, so a drop shadow on top of it just
-- reads as mud. Only offset the shadow when the font is not outlined.
local function ShadowOffset(style)
	if style and strfind(style, "OUTLINE") then
		return 0, 0
	end
	return 1, -1
end

-- Return the outline flag string based on the user preference.
function K.FontOutlineStyle()
	return (C.General and C.General.FontOutline) and "OUTLINE" or ""
end

-- Convenience. Apply the addon font at a size to an existing FontString.
function K.SetFont(fontString, size, style)
	fontString:SetFont(K.GetFont(C.General and C.General.Font), size or 12, style or "")
	fontString:SetShadowColor(0, 0, 0, 1)
	fontString:SetShadowOffset(ShadowOffset(style))
	return fontString
end

-- A font size that fits inside a bar of the given height. Text on a thin bar
-- otherwise spills over its top and bottom edges. The chosen size still wins
-- whenever it is the smaller one, so a tall bar keeps the size the user picked.
function K.FitFontSize(size, height, ratio)
	local fit = floor((height or 0) * (ratio or 0.7))
	if fit < 7 then
		fit = 7
	end
	return (size and size < fit) and size or fit
end

-- ---------------------------------------------------------------------------
-- Small creators
-- ---------------------------------------------------------------------------

-- Create a plain textured backdrop layer on a frame. Border comes separately.
function K.CreateBackground(frame, r, g, b, a)
	local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -8)
	bg:SetAllPoints()
	bg:SetColorTexture(r or 0.06, g or 0.06, b or 0.06, a or 0.9)
	K.DisablePixelSnap(bg)
	frame.KKUI_Background = bg
	return bg
end

-- ---------------------------------------------------------------------------
-- GUI icons
-- ---------------------------------------------------------------------------
-- Config and bag toolbar icons come straight from the game's own icon library, so
-- there is no art of ours to keep in step with the client. SetGUIIcon points a
-- texture at an icon path and trims the baked border the same way an item button
-- does, which is what makes the art sit flush inside our frames.

local GUI_ICON_PATH = "Interface\\ICONS\\"

function K.SetGUIIcon(texture, icon)
	if not texture or type(icon) ~= "string" then
		return
	end
	-- Accept a bare icon name or a full path, so a caller can pass either.
	if not icon:find("\\") then
		icon = GUI_ICON_PATH .. icon
	end
	texture:SetTexture(icon)
	texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
end
