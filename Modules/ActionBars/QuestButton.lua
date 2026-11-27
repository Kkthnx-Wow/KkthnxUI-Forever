--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/ActionBars/QuestButton.lua
	Purpose:
		One button that holds the usable item of the nearest quest in your zone,
		so a quest item can be used from a key instead of the tracker or the bags.
		It has its own key binding (Key Bindings, AddOns, KkthnxUI), its own mover,
		and the same skin as the extra action button.

		It only reads what the game's own quest tracker reads on WoW Forever: the
		quest's special item, whether the quest is on the current map, and the
		distance to it. There is no list of hand-picked quests or items.

		The button is a secure item button. Its item, and whether it is shown, can
		only change out of combat, so a change found during a fight waits for the
		fight to end. A pet battle or a vehicle hides it through a state driver.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("QuestItemButton")

local _G = _G
local math_huge = math.huge
local string_match = string.match
local tonumber = tonumber

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GetBindingKey = GetBindingKey
local GetBindingText = GetBindingText
local GetQuestLogSpecialItemInfo = GetQuestLogSpecialItemInfo
local IsQuestLogSpecialItemInRange = IsQuestLogSpecialItemInRange
local InCombatLockdown = InCombatLockdown
local RegisterStateDriver = RegisterStateDriver
local UIParent = UIParent
local UnitExists = UnitExists
local C_Item = C_Item
local C_QuestLog = C_QuestLog
local C_Timer = C_Timer

local BUTTON_NAME = "KKUI_QuestItemButton"
local BINDING = "CLICK " .. BUTTON_NAME .. ":LeftButton"

-- Names for the Key Bindings window. Set at load so the entry is labelled even
-- before the module runs. Bindings.xml declares the binding itself.
_G.BINDING_HEADER_KKTHNXUI = "KkthnxUI"
_G["BINDING_NAME_" .. BINDING] = L["Use Nearest Quest Item"]

-- How often the nearest quest is looked for again while walking. The scan only
-- runs while at least one quest in the log has a usable item.
local SCAN_INTERVAL = 1
-- Events can arrive in bursts (a quest log update fires several times at once),
-- so they are folded into one scan this long after the first.
local EVENT_DELAY = 0.2
-- How often the out of range tint is checked while the button shows.
local RANGE_INTERVAL = 0.2
-- The question mark, for the /kk questtest preview.
local TEST_ICON = 134400

local button
local scanTicker
local scanQueued = false
local testing = false

-- ---------------------------------------------------------------------------
-- Finding the item
-- ---------------------------------------------------------------------------

local function ItemIDFromLink(link)
	return tonumber(string_match(link, "item:(%d+)"))
end

-- The usable item of the nearest quest on the current map, and whether any quest
-- in the log has a usable item at all (which keeps the scan running). Uses the
-- same rule as the game's tracker for a finished quest: its item only stays when
-- the quest says so. Only entries that carry an item are looked at closer, since
-- the calls for that are the cheap ones.
local function FindNearest()
	local bestIndex, bestLink
	local bestDistance = math_huge
	local anyItem = false

	local numEntries = C_QuestLog.GetNumQuestLogEntries()
	for index = 1, numEntries do
		local link, _, _, showWhenComplete = GetQuestLogSpecialItemInfo(index)
		if link then
			local questID = C_QuestLog.GetQuestIDForLogIndex(index)
			if questID and questID > 0 and (showWhenComplete or not C_QuestLog.IsComplete(questID)) and C_Item.GetItemCount(link) > 0 then
				anyItem = true
				if C_QuestLog.IsOnMap(questID) then
					-- A quest whose area is on another continent has no useful
					-- distance, so it ranks behind every one that has.
					local distanceSq, onContinent = C_QuestLog.GetDistanceSqToQuest(questID)
					local distance = (onContinent and distanceSq) or math_huge
					if not bestLink or distance < bestDistance then
						bestIndex, bestLink, bestDistance = index, link, distance
					end
				end
			end
		end
	end

	return bestIndex, bestLink, anyItem
end

-- ---------------------------------------------------------------------------
-- Button state
-- ---------------------------------------------------------------------------

local function UpdateHotKey()
	local key = GetBindingKey(BINDING)
	button.HotKey:SetText(key and GetBindingText(key, true) or "")
end

local function UpdateCount()
	local count = button.itemID and C_Item.GetItemCount(button.itemID) or 0
	button.Count:SetText(count > 1 and count or "")
end

local function UpdateCooldown()
	if not button.itemID then
		button.cooldown:Clear()
		return
	end
	local start, duration = C_Item.GetItemCooldown(button.itemID)
	if start and duration and duration > 0 then
		button.cooldown:SetCooldown(start, duration)
	else
		button.cooldown:Clear()
	end
end

-- Tint the icon while the target is out of the item's reach. The quest log index
-- is checked against the item first, since the log can reorder during a fight
-- while the button has to keep the item it was given.
local function UpdateRange()
	local out = false
	local index = button.questIndex
	if index and UnitExists("target") and GetQuestLogSpecialItemInfo(index) == button.itemLink then
		out = IsQuestLogSpecialItemInRange(index) == 0
	end
	if out ~= button.outOfRange then
		button.outOfRange = out
		if out then
			local color = C.ActionBar.RangeColor or K.Colors.negative
			button.icon:SetVertexColor(color[1], color[2], color[3])
		else
			button.icon:SetVertexColor(1, 1, 1)
		end
	end
end

-- Put an item on the button, or clear it. Out of combat only, since the item
-- attribute and the button's visibility are protected.
local function Apply(index, link)
	button.questIndex = index
	local itemID = link and ItemIDFromLink(link)
	if itemID then
		button.itemLink = link
		button.itemID = itemID
		button:SetAttribute("item", "item:" .. itemID)
		button.icon:SetTexture(C_Item.GetItemIconByID(itemID))
		button.outOfRange = nil
		UpdateRange()
		UpdateCount()
		UpdateCooldown()
		button:Show()
	else
		button.itemLink = nil
		button.itemID = nil
		button:SetAttribute("item", nil)
		button:Hide()
	end
end

local function Scan()
	scanQueued = false
	if testing then
		return
	end

	local index, link, anyItem = FindNearest()

	-- Keep walking-distance scans going only while some quest has an item.
	if anyItem and not scanTicker then
		scanTicker = C_Timer.NewTicker(SCAN_INTERVAL, Scan)
	elseif not anyItem and scanTicker then
		scanTicker:Cancel()
		scanTicker = nil
	end

	if link == button.itemLink then
		-- Same item. The log can reorder, so keep the index the range check uses.
		button.questIndex = index
		return
	end

	if InCombatLockdown() then
		K.DeferCombat("QuestItemButton", Scan)
		return
	end
	Apply(index, link)
end

local function QueueScan()
	if scanQueued then
		return
	end
	scanQueued = true
	C_Timer.After(EVENT_DELAY, Scan)
end

-- ---------------------------------------------------------------------------
-- Building
-- ---------------------------------------------------------------------------

local function OnEnter(self)
	if not self.itemLink then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_LEFT")
	GameTooltip:SetHyperlink(self.itemLink)
	GameTooltip:Show()
end

local function OnLeave()
	GameTooltip:Hide()
end

local rangeElapsed = 0
local function OnUpdate(_, elapsed)
	rangeElapsed = rangeElapsed + elapsed
	if rangeElapsed < RANGE_INTERVAL then
		return
	end
	rangeElapsed = 0
	if not testing then
		UpdateRange()
	end
end

-- Default spot: off the top-right corner of bar 1, straight above the leave
-- vehicle button, which sits off its bottom-right corner, lined up on its left
-- edge with bar 1's spacing. The action bars enable before this module, so bar
-- 1's mover already exists here.
local function DefaultPoint()
	local bar1 = C.ActionBar.Bar1
	local bars = K:GetModule("ActionBars", true)
	local anchor = bars and bars.bars and bars.bars.Bar1 and bars.bars.Bar1.KKUI_Mover
	if anchor then
		return { "BOTTOMLEFT", anchor, "TOPRIGHT", bar1.Space, bar1.Space }
	end
	return { "BOTTOM", UIParent, "BOTTOM", -80, 320 }
end

-- Larger than a bar 1 button, so the quest item stands out from the bar beside it.
local BUTTON_SIZE = 50
-- The quest badge's edge as a share of the button's.
local BADGE_SCALE = 0.6

local function Build()
	local size = BUTTON_SIZE

	-- The holder carries the mover and the state driver that hides the button in
	-- a pet battle or a vehicle, which works in combat where Show and Hide do not.
	local holder = CreateFrame("Frame", BUTTON_NAME .. "Holder", UIParent)
	holder:SetSize(size, size)
	K.CreateMover(holder, "QuestItemButton", L["Quest Item Button"], DefaultPoint(), size, size)
	RegisterStateDriver(holder, "visibility", "[petbattle][overridebar][vehicleui] hide; show")

	button = CreateFrame("Button", BUTTON_NAME, holder, "SecureActionButtonTemplate")
	button:SetSize(size, size)
	button:SetPoint("CENTER", holder, "CENTER", 0, 0)
	-- Both edges, so the secure handler can act on the press or the release to
	-- follow the "cast on key down" setting, the same as an action button.
	button:RegisterForClicks("AnyUp", "AnyDown")
	button:SetAttribute("type", "item")
	button:Hide()

	local icon = button:CreateTexture(nil, "ARTWORK")
	button.icon = icon

	local cooldown = CreateFrame("Cooldown", nil, button, "CooldownFrameTemplate")
	button.cooldown = cooldown

	local font = K.GetFont(C.ActionBar.Font)
	local fontSize = C.ActionBar.FontSize
	local fontFlag = C.ActionBar.FontFlag ~= "NONE" and C.ActionBar.FontFlag or ""

	-- Text above the cooldown, so the swipe never covers it.
	local text = CreateFrame("Frame", nil, button)
	text:SetAllPoints(button)
	text:SetFrameLevel(cooldown:GetFrameLevel() + 1)

	local hotkey = text:CreateFontString(nil, "OVERLAY")
	hotkey:SetFont(font, fontSize, fontFlag)
	hotkey:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, -3)
	hotkey:SetJustifyH("RIGHT")
	button.HotKey = hotkey

	-- Quest badge in the top-left corner, the one corner the key text (top-right)
	-- and the count (bottom-right) leave free. On the text layer, so the cooldown
	-- swipe never covers it.
	local badge = text:CreateTexture(nil, "OVERLAY")
	badge:SetAtlas("QuestLog-tab-icon-quest")
	badge:SetSize(size * BADGE_SCALE, size * BADGE_SCALE)
	-- The atlas carries clear padding around the mark, so it is pulled out past
	-- the left edge to sit the mark itself against the corner.
	badge:SetPoint("TOPLEFT", button, "TOPLEFT", -6, -2)
	button.QuestBadge = badge

	local count = text:CreateFontString(nil, "OVERLAY")
	count:SetFont(font, fontSize, fontFlag)
	count:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -2, 3)
	count:SetJustifyH("RIGHT")
	button.Count = count

	-- Scripts first. The skin below hooks OnEnter and OnLeave for its hover glow,
	-- and setting a script afterwards would throw those hooks away.
	button:SetScript("OnEnter", OnEnter)
	button:SetScript("OnLeave", OnLeave)
	button:SetScript("OnUpdate", OnUpdate)

	-- The extra action button's skin: slot, border, hover glow, cooldown swipe and
	-- shortened key text.
	local bars = K:GetModule("ActionBars", true)
	if bars and bars.StyleAuxButton then
		bars:StyleAuxButton(button)
	else
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		icon:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
		cooldown:SetAllPoints(icon)
		K.StyleCooldownSwipe(cooldown)
		K.CreateBorder(button)
	end
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

function Module:PLAYER_ENTERING_WORLD()
	UpdateHotKey()
	QueueScan()
end

function Module:UPDATE_BINDINGS()
	UpdateHotKey()
end

function Module:BAG_UPDATE_COOLDOWN()
	if button.itemID and not testing then
		UpdateCooldown()
	end
end

-- Bags changed: the count may have, and an item may have been used up or picked
-- up, so look again as well.
function Module:BAG_UPDATE_DELAYED()
	if button.itemID and not testing then
		UpdateCount()
	end
	QueueScan()
end

function Module:PLAYER_TARGET_CHANGED()
	if button.itemID and not testing then
		UpdateRange()
	end
end

-- ---------------------------------------------------------------------------
-- Test
-- ---------------------------------------------------------------------------

-- /kk questtest. Shows the button with a stand-in icon so it can be placed and
-- its skin checked without a quest. It holds no item, so a click does nothing.
-- Showing it is protected, so the preview waits for combat to end.
function Module:ToggleTest()
	if not button then
		K.Print(L["The quest item button is turned off."])
		return
	end
	if InCombatLockdown() then
		K.Print(L["Try again out of combat."])
		return
	end
	testing = not testing
	if testing then
		button.questIndex = nil
		button.itemLink = nil
		button.itemID = nil
		button:SetAttribute("item", nil)
		button.icon:SetTexture(TEST_ICON)
		button.icon:SetVertexColor(1, 1, 1)
		button.outOfRange = false
		button.Count:SetText("3")
		button.cooldown:Clear()
		button:Show()
		K.Print(L["Quest item button test on. Type /kk questtest again to stop."])
	else
		button.icon:SetTexture(nil)
		button.Count:SetText("")
		button:Hide()
		Scan()
		K.Print(L["Quest item button test off."])
	end
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function Module:OnEnable()
	local db = C.ActionBar.QuestButton
	if not (db and db.Enable) then
		return
	end
	if not (GetQuestLogSpecialItemInfo and C_QuestLog and C_QuestLog.GetDistanceSqToQuest) then
		return
	end

	Build()

	self:RegisterEvent("PLAYER_ENTERING_WORLD")
	self:RegisterEvent("UPDATE_BINDINGS")
	self:RegisterEvent("BAG_UPDATE_COOLDOWN")
	self:RegisterEvent("BAG_UPDATE_DELAYED")
	self:RegisterEvent("PLAYER_TARGET_CHANGED")
	self:RegisterEvent("QUEST_LOG_UPDATE", QueueScan)
	self:RegisterEvent("QUEST_POI_UPDATE", QueueScan)
	self:RegisterEvent("QUEST_WATCH_LIST_CHANGED", QueueScan)
	self:RegisterEvent("ZONE_CHANGED", QueueScan)
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA", QueueScan)

	UpdateHotKey()
	QueueScan()
end
