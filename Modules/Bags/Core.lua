--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Core.lua
	Purpose:
		An all-in-one, auto categorised bag and bank replacement built on the
		C_Container API. This file owns the module, the shared container window
		(backdrop, border, title, toolbar, item grid), the categorised layout,
		the refresh pipeline, and the hooks that hand the bag keys to us instead
		of Blizzard's ContainerFrame. Item buttons live in Slots.lua, the section
		rules in Categories.lua, and the bank window in Bank.lua.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

-- The bag window is built on C_Container. Core guards every call into the bank
-- window (Bank.lua), so the bags still work if that file is not loaded.
if not (C_Container and C_Container.GetContainerNumSlots) then
	return
end

local Module = K:NewModule("Bags")

local _G = _G
local ceil = math.ceil
local floor = math.floor
local max = math.max
local ipairs = ipairs
local select = select
local tinsert = table.insert
local tsort = table.sort
local pairs = pairs
local wipe = wipe
local Enum = Enum
local IsSecret = K.IsSecret

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local GetMoney = GetMoney
local GetCoinTextureString = C_CurrencyInfo.GetCoinTextureString
local C_Container = C_Container
local C_Item = C_Item
local SetItemButtonCount = SetItemButtonCount
local C_Timer = C_Timer
local C_CurrencyInfo = C_CurrencyInfo
local BreakUpLargeNumbers = BreakUpLargeNumbers

-- Bags carried on the character: backpack, the four bags, and the reagent bag.
Module.BagIDs = { 0, 1, 2, 3, 4, 5 }

-- Window geometry. The top band holds the title and search, the bottom band the
-- money and free-slot readouts, and the item grid sits between them.
local MARGIN = 12
local TOP_BAND = 40
local BOTTOM_BAND = 44 -- money / free slots on one line, currencies above them
Module.BOTTOM_BAND = BOTTOM_BAND -- exposed so the bag strip can sit above it
local HEADER_H = 16
local GROUP_GAP = 6

-- The dedicated reagent pouch, so its free slots can sit under its own shelf.
local REAGENT_BAG = Enum.BagIndex and Enum.BagIndex.ReagentBag or 5

-- The keyring is bag -1 and only exists where the game says it shows one (WoW
-- Forever does, Retail does not), so it is asked for rather than assumed.
local KEYRING_BAG = Enum.BagIndex and Enum.BagIndex.Keyring or -1
Module.KeyringBag = KEYRING_BAG

function Module.HasKeyring()
	return C_ActionBar and C_ActionBar.ShouldShowKeyring and C_ActionBar.ShouldShowKeyring() and true or false
end

-- Within a section: higher quality first, then group identical item ids. The
-- keys are captured secret-safe when the bucket is built (see LayoutContainer),
-- so this comparison never touches a tainted value.
local function SortEntry(a, b)
	if a[3] ~= b[3] then
		return a[3] > b[3]
	end
	return a[4] < b[4]
end

-- Whether an item id stacks, cached so a relayout does not re-query the client.
local mergeableCache = {}
local function Mergeable(itemID)
	if itemID == 0 then
		return false
	end
	local cached = mergeableCache[itemID]
	if cached == nil then
		local maxStack = select(8, C_Item.GetItemInfo(itemID))
		-- nil while the item is still loading. Treat as not mergeable for now, the
		-- next relayout re-checks once the data is in.
		cached = (maxStack and maxStack > 1) or false
		if maxStack then
			mergeableCache[itemID] = cached
		end
	end
	return cached
end

-- Fold entries for the same stackable item into one, summing their counts. The
-- kept entry gains a mergeCount so its button shows the combined total. Gear and
-- other unstackable items are left as separate buttons.
local function MergeList(list)
	local out, seen = {}, {}
	for _, entry in ipairs(list) do
		local id = entry[4]
		local mergeKey = (id ~= 0 and Mergeable(id)) and id or nil
		if mergeKey and seen[mergeKey] then
			local rep = seen[mergeKey]
			rep.mergeCount = (rep.mergeCount or rep[5] or 1) + (entry[5] or 1)
		else
			out[#out + 1] = entry
			if mergeKey then
				seen[mergeKey] = entry
			end
		end
	end
	return out
end

-- ---------------------------------------------------------------------------
-- Section headers (pooled per container)
-- ---------------------------------------------------------------------------

local function AcquireHeader(container)
	container.headers = container.headers or {}
	container.headerUsed = (container.headerUsed or 0) + 1
	local header = container.headers[container.headerUsed]
	if not header then
		header = CreateFrame("Button", nil, container)
		header:SetHeight(HEADER_H)
		header.Toggle = header:CreateFontString(nil, "OVERLAY")
		K.SetFont(header.Toggle, 13, K.FontOutlineStyle())
		header.Toggle:SetPoint("LEFT", header, "LEFT", 0, 0)
		header.Toggle:SetTextColor(K.Colors.gold[1], K.Colors.gold[2], K.Colors.gold[3])
		header.Text = header:CreateFontString(nil, "OVERLAY")
		K.SetFont(header.Text, 13, K.FontOutlineStyle())
		header.Text:SetPoint("LEFT", header.Toggle, "RIGHT", 4, 0)
		header.Text:SetTextColor(K.Colors.gold[1], K.Colors.gold[2], K.Colors.gold[3])
		header:RegisterForClicks("LeftButtonUp", "RightButtonUp")
		header:SetScript("OnClick", function(self, button)
			if button == "RightButton" then
				if Module.ShowGroupMenu then
					Module:ShowGroupMenu(self)
				end
			else
				Module:ToggleCategory(self.catKey)
			end
		end)
		container.headers[container.headerUsed] = header
	end
	-- Clear any identity a previous layout left on this pooled header, so a stale
	-- group name can never drive the right-click menu onto the wrong action.
	header.catKey = nil
	header.groupName = nil
	header:Show()
	return header
end

local function ReleaseHeaders(container)
	if container.headers then
		for i = 1, #container.headers do
			container.headers[i]:Hide()
		end
	end
	container.headerUsed = 0
end

-- Fold or unfold a section and remember the choice across sessions.
function Module:ToggleCategory(key)
	if not key then
		return
	end
	local collapsed = C.Bags.Collapsed
	K:SetConfig({ "Bags", "Collapsed", key }, not collapsed[key] or nil)
	self:UpdateAll()
end

-- ---------------------------------------------------------------------------
-- Categorised layout
-- ---------------------------------------------------------------------------

-- Rebuild one container's grid from the current contents of its bags. Empty
-- slots are gathered into a trailing block so items can still be dragged in.
-- Vendor value of a list of bag entries (bag, slot, quality, itemID, stack).
local function JunkShelfValue(list)
	local total = 0
	for _, entry in ipairs(list) do
		local itemID = entry[4]
		if itemID and itemID > 0 then
			local price = select(11, C_Item.GetItemInfo(itemID))
			if price and price > 0 then
				total = total + price * (entry[5] or 1)
			end
		end
	end
	return total
end

-- The free slot button's number. The stock count hides itself at one, which is
-- exactly when the number matters most, so the text is set directly.
local function SetFreeCount(button, count, total)
	-- Read by the tooltip hook in Slots.lua.
	button.__kkuiFree = count
	button.__kkuiTotal = total
	SetItemButtonCount(button, count)
	if button.Count then
		button.Count:SetText(count)
		button.Count:Show()
	end
end

-- Stand-in for the free slot button while there is no free slot to bind it to.
-- The real one is an item button on the first empty slot, so with full bags there
-- is nothing to hang it on. This keeps the spot, and the "0", instead of the
-- button vanishing right when it matters.
local function FullSlotButton(f)
	local button = f.FullSlot
	if button then
		return button
	end
	button = CreateFrame("Frame", nil, f)
	K.CreateBackground(button, 0.06, 0.06, 0.06, 0.9)
	K.CreateBorder(button)
	local art = button:CreateTexture(nil, "ARTWORK")
	art:SetPoint("TOPLEFT", 1, -1)
	art:SetPoint("BOTTOMRIGHT", -1, 1)
	art:SetAtlas("bags-item-slot64")
	local text = button:CreateFontString(nil, "OVERLAY")
	K.SetFont(text, 14, K.FontOutlineStyle())
	text:SetPoint("CENTER", 0, 0)
	text:SetText("0")
	local red = K.Colors.negative
	text:SetTextColor(red[1], red[2], red[3])
	button:EnableMouse(true)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L["No free slots"], 1, 1, 1)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", GameTooltip_Hide)
	f.FullSlot = button
	return button
end

function Module:LayoutContainer(f)
	if not f or not f:IsShown() then
		return
	end
	if f.FullSlot then
		f.FullSlot:Hide()
	end
	local cfg = C.Bags
	local size = cfg.ButtonSize
	local space = cfg.Spacing
	local perRow = f.perRow or cfg.BagsPerRow
	local step = size + space
	local rowWidth = perRow * step - space

	self:ReleaseSlots(f)
	ReleaseHeaders(f)

	-- The bag slot strip is its own panel attached below the frame, so it needs no
	-- room reserved inside. Just keep its icons current while it is shown.
	if f.BagStrip and f.BagStrip:IsShown() then
		self:UpdateBagStrip(f)
	end

	-- Sort every occupied slot into buckets, and pool the empties. When the reagent
	-- shelf is its own section, its empties pool apart so the free reagent slots can
	-- show under that shelf instead of vanishing into the general free-slot count.
	-- Reagent empties sit under that shelf when it is shown as its own ungrouped
	-- section, and get their own trailing free button otherwise. A single-pouch window (detached reagent bag) renders flat, so it opts out of
	-- categories for both the bucketing and the render below.
	-- Empties in a special bag (a quiver, ammo pouch, soul bag, the reagent pouch)
	-- only take items of that kind, so they never join the general pool. The free
	-- button is bound to the first empty slot, and a general item dropped onto a
	-- quiver slot is refused. Each special bag kind gets its own trailing button.
	local useCategories = cfg.Categories and not f.noCategories
	local splitReagent = useCategories and cfg.ReagentBagSection and self:IsSectionOn("ReagentBag") and not (cfg.CategoryGroup and cfg.CategoryGroup.ReagentBag)
	local buckets, empties, reagentEmpties = {}, {}, {}
	local special, specialOrder = {}, {}
	local totalSlots = 0
	for _, bag in ipairs(f.bags) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		-- A one-bag window (the detached reagent pouch, the keyring) treats its own bag
		-- as general, since there is nothing else for it to be kept apart from.
		local mixed = #f.bags > 1
		local _, family = C_Container.GetContainerNumFreeSlots(bag)
		local isReagent = mixed and bag == REAGENT_BAG and not f.isBank
		local pool = empties
		if isReagent then
			pool = splitReagent and reagentEmpties or nil
		elseif mixed and family and family ~= 0 then
			pool = nil
		end
		if not pool then
			local kind = isReagent and "reagent" or family
			pool = special[kind]
			if not pool then
				pool = { bag = bag }
				special[kind] = pool
				specialOrder[#specialOrder + 1] = kind
			end
		end
		if pool == empties then
			totalSlots = totalSlots + numSlots
		elseif pool ~= reagentEmpties then
			pool.total = (pool.total or 0) + numSlots
		end
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if info then
				local key = useCategories and self:GetCategory(bag, slot, info) or "All"
				buckets[key] = buckets[key] or {}
				-- Capture secret-safe sort keys now: rarer first, then by item id so
				-- identical items sit together. Secret fields drop to a low value so
				-- they never enter a tainted comparison.
				local quality = info.quality
				local itemID = info.itemID
				local stack = info.stackCount
				tinsert(buckets[key], {
					bag,
					slot,
					(quality and not IsSecret(quality)) and quality or -1,
					(itemID and not IsSecret(itemID)) and itemID or 0,
					(stack and not IsSecret(stack)) and stack or 1,
				})
			else
				tinsert(pool, { bag, slot })
			end
		end
	end

	local topBand = TOP_BAND + (f.extraTop or 0)
	local y = -topBand

	-- free (optional): a list of empty slots for this group. They collapse to one
	-- trailing button, in the grid flow after the items, showing how many are free.
	-- groupName (optional): set on the header so its menu offers group actions.
	local function placeGroup(list, label, key, free, groupName)
		list = list or {}
		-- The junk header carries what the shelf would sell for. Worked out before
		-- merging, while every entry is still one real stack.
		local value = key == "Junk" and JunkShelfValue(list) or 0
		if cfg.MergeStacks then
			list = MergeList(list)
		end
		local freeCount = free and #free or 0
		if #list == 0 and freeCount == 0 then
			return
		end
		local collapsed = key and cfg.Collapsed[key]
		if label then
			local header = AcquireHeader(f)
			header.catKey = key
			header.groupName = groupName
			header:ClearAllPoints()
			header:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN, y)
			header:SetWidth(rowWidth)
			header.Toggle:SetText(collapsed and "+" or "-")
			header.Text:SetText(label .. "  (" .. #list .. ")" .. (value > 0 and ("  -  " .. GetCoinTextureString(value)) or ""))
			header:SetEnabled(key ~= nil)
			y = y - HEADER_H
		end
		if collapsed then
			y = y - GROUP_GAP
			return
		end
		-- Breathing room between a header and the row it labels.
		if label then
			y = y - 4
		end
		for i, entry in ipairs(list) do
			local col = (i - 1) % perRow
			local row = floor((i - 1) / perRow)
			-- Nil while in combat when the pool is exhausted, the regen refresh fills it.
			local button = self:AcquireSlot(f)
			if button then
				local holder = button:GetParent()
				holder:ClearAllPoints()
				holder:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN + col * step, y - row * step)
				self:UpdateSlot(button, entry[1], entry[2])
				-- Merged stacks show the combined total, not the one slot's count.
				if entry.mergeCount then
					SetItemButtonCount(button, entry.mergeCount)
				end
			end
		end
		local total = #list
		if freeCount > 0 then
			total = total + 1
			local col = #list % perRow
			local row = floor(#list / perRow)
			local button = self:AcquireSlot(f)
			if button then
				local holder = button:GetParent()
				holder:ClearAllPoints()
				holder:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN + col * step, y - row * step)
				self:UpdateSlot(button, free[1][1], free[1][2])
				SetFreeCount(button, freeCount)
			end
		end
		local rows = ceil(total / perRow)
		y = y - rows * step - GROUP_GAP
	end

	-- Order each section so the rarest items lead and duplicates group up, giving
	-- a tidy read that does not depend on which physical slot an item sits in.
	-- Item counts per section for the bag sections panel, one table reused per window.
	local counts = f.sectionCounts or {}
	f.sectionCounts = counts
	wipe(counts)
	for key, bucket in pairs(buckets) do
		tsort(bucket, SortEntry)
		counts[key] = #bucket
	end

	if useCategories then
		-- Gear split by slot renders as one shelf per slot where Equipment stands.
		-- Gear with no slot shelf (none expected, but a new equip type would do it)
		-- keeps the plain Equipment shelf after them, so nothing goes missing.
		local bySlot = cfg.GroupGearBySlot
		local slotOrder = self.GearSlotOrder or {}
		local function sectionKeys(key)
			if key == "Equipment" and bySlot then
				local keys = {}
				for i, slotName in ipairs(slotOrder) do
					keys[i] = "Equipment:" .. slotName
				end
				keys[#keys + 1] = "Equipment"
				return keys
			end
			return { key }
		end

		for _, node in ipairs(self:BuildTree()) do
			if node.kind == "group" then
				-- Combine every member's items into one section under the group name.
				local combined = {}
				for _, child in ipairs(node.children) do
					for _, key in ipairs(sectionKeys(child.key)) do
						for _, entry in ipairs(buckets[key] or {}) do
							combined[#combined + 1] = entry
						end
					end
				end
				tsort(combined, SortEntry)
				placeGroup(combined, node.name, node.key, nil, node.name)
			else
				for _, key in ipairs(sectionKeys(node.key)) do
					local label = key:match("^Equipment:(.+)") or node.name
					placeGroup(buckets[key], label, key, key == "ReagentBag" and reagentEmpties or nil)
				end
			end
		end
	else
		placeGroup(buckets["All"], nil, nil)
	end

	-- Rather than pad the window with dozens of blank squares, the empty slots
	-- collapse to a single button that shows how many are free and still takes a
	-- dropped item (it is bound to the first empty slot).
	-- The general free button leads the row, then one per special bag kind that has
	-- room (a quiver, a soul bag), each bound to its own first empty slot.
	local col = 0
	if #empties > 0 then
		local first = empties[1]
		local button = self:AcquireSlot(f)
		if button then
			local holder = button:GetParent()
			holder:ClearAllPoints()
			holder:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN, y)
			self:UpdateSlot(button, first[1], first[2])
			SetFreeCount(button, #empties, totalSlots)
			col = 1
		end
	elseif f.bags and #f.bags > 0 then
		local full = FullSlotButton(f)
		full:SetSize(size, size)
		full:ClearAllPoints()
		full:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN, y)
		full:Show()
		col = 1
	end
	for _, kind in ipairs(specialOrder) do
		local pool = special[kind]
		if #pool > 0 then
			local button = self:AcquireSlot(f)
			if button then
				local holder = button:GetParent()
				holder:ClearAllPoints()
				holder:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN + (col % perRow) * step, y - floor(col / perRow) * step)
				self:UpdateSlot(button, pool[1][1], pool[1][2])
				SetFreeCount(button, #pool, pool.total)
				button.__kkuiFreeBag = pool.bag
				col = col + 1
			end
		end
	end
	if col > 0 then
		y = y - ceil(col / perRow) * step - GROUP_GAP
	end

	-- Size the window to the content, with a sane minimum width.
	local contentH = -y - topBand + GROUP_GAP
	-- The inventory window carries the search box and up to five toolbar buttons
	-- across its top band, which need about 310 units between them.
	local minRow = f:GetName() == "KKUI_BagFrame" and 310 or 160
	f:SetWidth(max(rowWidth, minRow) + MARGIN * 2)
	f:SetHeight(topBand + contentH + BOTTOM_BAND)

	self:UpdateInfoText(f)
	-- Pooled buttons keep the alpha the last search gave them, so a relayout while
	-- the box holds text would dim whatever item now sits on each button. Re-run it.
	if f.Search then
		self:ApplySearch(f, f.Search:GetText())
	end
end

-- The used buttons of one open window, for the light refreshes below that only
-- touch what an event changed instead of rebuilding the grid. Called per window
-- with a method and no closure, since these events fire often in play.
local function EachSlot(f, method, bag, slot)
	if not (f and f.pool and f:IsShown()) then
		return
	end
	for i = 1, (f.poolUsed or 0) do
		local button = f.pool[i]
		if not bag or (button:GetID() == slot and button:GetParent():GetID() == bag) then
			method(Module, button)
		end
	end
end

local function EachShownSlot(method, bag, slot)
	EachSlot(Module.BagFrame, method, bag, slot)
	EachSlot(Module.ReagentFrame, method, bag, slot)
	EachSlot(Module.KeyringFrame, method, bag, slot)
	EachSlot(Module.BankFrame, method, bag, slot)
end

-- BAG_UPDATE_COOLDOWN fires on every cooldown start, the global one included, so
-- it only redraws the cooldown swipes, the same as the game's own bags.
function Module:UpdateCooldowns()
	if self.UpdateSlotCooldown then
		EachShownSlot(self.UpdateSlotCooldown)
	end
end

-- ITEM_LOCK_CHANGED fires on every pickup and drop. Only the greyed look of that
-- one slot changes, and the BAG_UPDATE_DELAYED that follows a real move relays out.
-- An equipped item's lock comes without a slot and has no bag button to touch.
function Module:UpdateLocked(_, bag, slot)
	if bag and slot and self.UpdateSlotLock then
		EachShownSlot(self.UpdateSlotLock, bag, slot)
	end
end

-- ---------------------------------------------------------------------------
-- Toolbar / info readouts
-- ---------------------------------------------------------------------------

-- Refresh the money and free-slot readouts on a container.
function Module:UpdateInfoText(f)
	if f.Money then
		f.Money:SetText(GetCoinTextureString(GetMoney()))
	end
	-- General slots only, by the same rule as the free slot button and the game's own
	-- backpack count: special bags and the reagent pouch take only their own kind.
	if f.FreeSlots then
		local free, total = 0, 0
		local mixed = #f.bags > 1
		for _, bag in ipairs(f.bags) do
			local slots, family = C_Container.GetContainerNumFreeSlots(bag)
			local general = not mixed or ((family or 0) == 0 and not (bag == REAGENT_BAG and not f.isBank))
			if general then
				free = free + (slots or 0)
				total = total + (C_Container.GetContainerNumSlots(bag) or 0)
			end
		end
		f.FreeSlots:SetText(free .. " / " .. total)
	end
	self:UpdateCurrencies(f)
end

-- Lay the tracked backpack currencies along the bottom, centred between the
-- free-slot and money readouts. Icons and counts come from the pinned currency
-- list, so what shows here matches what the player chose to watch.
function Module:UpdateCurrencies(f)
	f.currencyPool = f.currencyPool or {}
	local shown = 0

	if C.Bags.ShowCurrencies and C_CurrencyInfo and C_CurrencyInfo.GetBackpackCurrencyInfo then
		for i = 1, 6 do
			local info = C_CurrencyInfo.GetBackpackCurrencyInfo(i)
			if not info then
				break
			end
			shown = shown + 1
			local element = f.currencyPool[shown]
			if not element then
				element = CreateFrame("Frame", nil, f)
				element:SetSize(16, 16)
				element:EnableMouse(true)
				element.Icon = element:CreateTexture(nil, "ARTWORK")
				element.Icon:SetPoint("LEFT")
				element.Icon:SetSize(14, 14)
				element.Icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
				element.Text = element:CreateFontString(nil, "OVERLAY")
				K.SetFont(element.Text, 12, K.FontOutlineStyle())
				element.Text:SetPoint("LEFT", element.Icon, "RIGHT", 2, 0)
				element:SetScript("OnEnter", function(self)
					if not self.currencyID then
						return
					end
					GameTooltip:SetOwner(self, "ANCHOR_TOP")
					GameTooltip:SetCurrencyByID(self.currencyID)
					GameTooltip:Show()
				end)
				element:SetScript("OnLeave", GameTooltip_Hide)
				f.currencyPool[shown] = element
			end
			element.currencyID = info.currencyTypesID
			element.Icon:SetTexture(info.iconFileID)
			element.Text:SetText(BreakUpLargeNumbers(info.quantity or 0))
			element:SetWidth(16 + 4 + element.Text:GetStringWidth())
			element:Show()
		end
	end

	for i = shown + 1, #f.currencyPool do
		f.currencyPool[i]:Hide()
	end

	-- Lay the currencies left to right on their own line, above the money and
	-- free-slot readouts, so nothing overlaps.
	local x = MARGIN
	for i = 1, shown do
		local element = f.currencyPool[i]
		element:ClearAllPoints()
		element:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", x, 24)
		x = x + element:GetWidth() + 12
	end
end

-- Build the lower-case haystack a search matches against: name, item type and
-- subtype, quality word (epic, rare), and a bind tag (boe, bou). So "epic",
-- "armor", or "boe" all filter as you would expect, not just item names.
local function SearchText(info)
	local parts = info.itemName and info.itemName:lower() or ""
	local link = info.hyperlink
	if link then
		local _, _, quality, _, _, itemType, itemSubType, _, _, _, _, _, _, bindType = C_Item.GetItemInfo(link)
		if itemType then
			parts = parts .. " " .. itemType:lower()
		end
		if itemSubType then
			parts = parts .. " " .. itemSubType:lower()
		end
		if quality then
			local q = _G["ITEM_QUALITY" .. quality .. "_DESC"]
			if q then
				parts = parts .. " " .. q:lower()
			end
		end
		if bindType == 2 then
			parts = parts .. " boe"
		elseif bindType == 3 then
			parts = parts .. " bou"
		end
	end
	return parts
end

-- Dim buttons that do not match the search text. An empty search clears it.
function Module:ApplySearch(f, text)
	text = (text or ""):lower()
	for i = 1, (f.poolUsed or 0) do
		local button = f.pool[i]
		local match = true
		if text ~= "" then
			local info = C_Container.GetContainerItemInfo(button:GetBagID(), button:GetID())
			match = info and SearchText(info):find(text, 1, true) and true or false
		end
		button:SetAlpha(match and 1 or 0.25)
	end
end

-- ---------------------------------------------------------------------------
-- Container window
-- ---------------------------------------------------------------------------

-- Build one bordered window: backdrop, title, close, search, sort, and the
-- money / free-slot bar. The grid is filled by LayoutContainer.
function Module:CreateContainer(name, title, bags, perRow)
	local f = CreateFrame("Frame", name, UIParent)
	f:SetFrameStrata("HIGH")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f.bags = bags
	f.perRow = perRow
	f.slotPrefix = name .. "Item"
	f:SetSize(360, 200)

	K.CreateGradientBackground(f, 0.95)
	K.CreateBorder(f)

	-- Line the close (and the toolbar buttons that anchor off it) up vertically with
	-- the search box in the top band: search sits at y -10 and is 20 tall, so a 22
	-- tall button at y -9 shares its centre.
	local close = CreateFrame("Button", name .. "Close", f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -MARGIN, -9)
	close:SetScript("OnClick", function()
		Module:CloseAll()
	end)
	K.SkinCloseButton(close)

	-- A square icon button sized to match the close button, for the top band.
	local function IconButton(suffix, atlas, texture, tip, onClick, iconName)
		local button = CreateFrame("Button", name .. suffix, f)
		button:SetSize(22, 22)
		K.SkinButton(button)
		-- The icon covers the button's fill, so the square states carry the hover
		-- and press, the same as an action button.
		K.StyleButtonStates(button, 1)
		local icon = button:CreateTexture(nil, "ARTWORK")
		-- Fill the button, leaving 1px for the border. An atlas carries its own
		-- coords, so only trim the transparent edge off a plain texture.
		icon:SetPoint("TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", -1, 1)
		-- Prefer a named game icon, then a game atlas, then a plain texture.
		if iconName and K.SetGUIIcon then
			K.SetGUIIcon(icon, iconName)
		elseif atlas and C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(atlas) then
			icon:SetAtlas(atlas)
		else
			icon:SetTexture(texture)
			icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		end
		button.icon = icon
		button:SetScript("OnClick", onClick)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(tip, 1, 1, 1)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", GameTooltip_Hide or function() GameTooltip:Hide() end)
		return button
	end

	-- Sort, top band, right before the close button. A broom for cleanup.
	local sort = IconButton("Sort", nil, 655994, L["Sort"], function()
		Module:SortContainer(f)
	end, "INV_Pet_Broom")
	sort:SetPoint("RIGHT", close, "LEFT", -6, 0)
	f.Sort = sort

	-- Bag bar toggle, folding the bag slot strip (bags) or the tab bar (bank) in and
	-- out of this window.
	local bagToggle = IconButton("BagToggle", nil, 133633, L["Toggle Bag Bar"], function()
		local strip = f.BagStrip or f.BankBar
		if strip then
			K:SetConfig({ "Bags", "ShowBagBar" }, not strip:IsShown())
			Module:ToggleBagStrip(f, C.Bags.ShowBagBar)
		end
	end, "INV_Misc_Bag_08")
	bagToggle:SetPoint("RIGHT", sort, "LEFT", -6, 0)
	f.BagToggle = bagToggle

	-- Category group manager and delete-cheapest, main bag window only.
	if name == "KKUI_BagFrame" then
		-- Keyring toggle, only where the game has a keyring. The keyring window stays
		-- closed until asked for. This goes through the game's own bag toggle, the same
		-- call its keyring button makes, so the open state the rest of the bags follow
		-- stays truthful and the sync below opens or closes our window to match.
		local anchor = bagToggle
		if Module.HasKeyring() then
			local keyring = IconButton("KeyringToggle", nil, nil, L["Keyring"], function()
				Module:ToggleKeyring()
			end, "INV_Misc_Key_03")
			keyring:SetPoint("RIGHT", bagToggle, "LEFT", -6, 0)
			f.KeyringButton = keyring
			anchor = keyring
		end

		local manager = IconButton("Manager", nil, "Interface\\ICONS\\INV_Misc_Book_09", L["Bag Sections"], function()
			if Module.ToggleManager then
				Module:ToggleManager()
			end
		end, "INV_Misc_Book_09")
		manager:SetPoint("RIGHT", anchor, "LEFT", -6, 0)
		f.ManagerButton = manager

		if C.Bags.DeleteButton then
			local delete = IconButton("Delete", nil, "Interface\\ICONS\\INV_Misc_Head_Goblin_01", L["Delete Cheapest Junk"], function()
				if Module.DeleteCheapestJunk then
					Module:DeleteCheapestJunk()
				end
			end, "INV_Misc_Bomb_05")
			delete:SetPoint("RIGHT", manager, "LEFT", -6, 0)
			f.DeleteButton = delete
		end
	end

	-- Search box, top band, pinned to the top-left where the title used to sit.
	local search = CreateFrame("EditBox", name .. "Search", f)
	search:SetSize(140, 20)
	search:SetPoint("TOPLEFT", f, "TOPLEFT", MARGIN, -10)
	search:SetAutoFocus(false)
	K.SetFont(search, 12, "")
	search:SetTextInsets(4, 4, 0, 0)
	search:SetScript("OnEscapePressed", search.ClearFocus)
	search:SetScript("OnEnterPressed", search.ClearFocus)
	search:SetScript("OnTextChanged", function(self)
		Module:ApplySearch(f, self:GetText())
		if self.Placeholder then
			self.Placeholder:SetShown(self:GetText() == "")
		end
	end)
	K.SkinEditBox(search)
	-- Faint prompt shown while the box is empty.
	local placeholder = search:CreateFontString(nil, "ARTWORK")
	K.SetFont(placeholder, 12, "")
	placeholder:SetPoint("LEFT", search, "LEFT", 4, 0)
	placeholder:SetTextColor(K.Colors.disabled[1], K.Colors.disabled[2], K.Colors.disabled[3])
	placeholder:SetText(L["Search"])
	search.Placeholder = placeholder
	f.Search = search

	-- Sell-junk button, shown only while a merchant is open, right of the search
	-- box. Its label carries the running junk value so you know what you get.
	local sell = CreateFrame("Button", name .. "Sell", f)
	sell:SetSize(110, 20)
	sell:SetPoint("LEFT", search, "RIGHT", 8, 0)
	sell.Text = sell:CreateFontString(nil, "OVERLAY")
	K.SetFont(sell.Text, 12, K.FontOutlineStyle())
	sell.Text:SetPoint("CENTER")
	sell:SetScript("OnClick", function()
		Module:SellJunk()
		Module:UpdateSellButton(f)
	end)
	K.SkinButton(sell)
	sell:Hide()
	f.SellButton = sell

	-- Bottom bar: free slots on the left, money on the right.
	local freeSlots = f:CreateFontString(nil, "OVERLAY")
	K.SetFont(freeSlots, 12, K.FontOutlineStyle())
	freeSlots:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", MARGIN, 6)
	freeSlots:SetTextColor(K.Colors.silver[1], K.Colors.silver[2], K.Colors.silver[3])
	f.FreeSlots = freeSlots

	local money = f:CreateFontString(nil, "OVERLAY")
	K.SetFont(money, 12, K.FontOutlineStyle())
	money:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 6)
	f.Money = money

	-- Thin rule between the item grid and the info bar.
	local divider = f:CreateTexture(nil, "ARTWORK")
	divider:SetColorTexture(K.Colors.borderSubtle[1], K.Colors.borderSubtle[2], K.Colors.borderSubtle[3], 0.8)
	divider:SetHeight(1)
	divider:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", MARGIN, BOTTOM_BAND)
	divider:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -MARGIN, BOTTOM_BAND)
	f.Divider = divider

	f:Hide()
	return f
end

-- Sort a container's bags, honouring the reverse-fill preference.
function Module:SortContainer(f)
	if InCombatLockdown() then
		return
	end
	local reverse = C.Bags.ReverseSort
	if C_Container.SetSortBagsRightToLeft then
		C_Container.SetSortBagsRightToLeft(reverse)
	end
	if C_Container.SetInsertItemsLeftToRight then
		C_Container.SetInsertItemsLeftToRight(not reverse)
	end
	if f.isBank and C_Container.SortBankBags then
		C_Container.SortBankBags()
	elseif C_Container.SortBags then
		C_Container.SortBags()
	end
end

-- ---------------------------------------------------------------------------
-- Refresh pipeline
-- ---------------------------------------------------------------------------

-- Combat blocks building item buttons, so a refresh that could not finish is
-- run once combat ends, after topping the button pools back up.
function Module:RefreshAfterCombat()
	K.DeferCombat("BagsRefresh", function()
		Module:PrewarmAll()
		Module:UpdateAll()
	end)
end

-- Mark the open windows for a relayout, coalescing a burst of events into one
-- pass on the next frame. Deferred out of combat.
function Module:MarkDirty()
	if self.dirty then
		return
	end
	self.dirty = true
	C_Timer.After(0, function()
		self.dirty = false
		if InCombatLockdown() then
			self:RefreshAfterCombat()
			return
		end
		self:UpdateAll()
	end)
end

-- Top up both windows' button pools while out of combat so nothing has to be
-- created mid-fight, where it would be tainted and lose item use.
function Module:PrewarmAll()
	if not self.PrewarmSlots then
		return
	end
	if self.BagFrame then
		self:PrewarmSlots(self.BagFrame)
	end
	if self.ReagentFrame then
		self:PrewarmSlots(self.ReagentFrame)
	end
	if self.KeyringFrame then
		self:PrewarmSlots(self.KeyringFrame)
	end
	if self.BankFrame then
		self:PrewarmSlots(self.BankFrame)
	end
end

function Module:UpdateAll()
	self:PrewarmAll()
	if self.BagFrame and self.BagFrame:IsShown() then
		self:LayoutContainer(self.BagFrame)
	end
	if self.ReagentFrame and self.ReagentFrame:IsShown() then
		self:LayoutContainer(self.ReagentFrame)
	end
	if self.KeyringFrame and self.KeyringFrame:IsShown() then
		self:LayoutContainer(self.KeyringFrame)
	end
	if self.BankFrame and self.BankFrame:IsShown() then
		self:LayoutContainer(self.BankFrame)
	end
	self:UpdateSellButton(self.BagFrame)
	-- The sections panel shows live counts and the current tree.
	if self.Manager and self.Manager:IsShown() then
		self:RefreshManager()
	end
end

-- ---------------------------------------------------------------------------
-- Merchant helpers
-- ---------------------------------------------------------------------------

-- Is this an item we should vendor: grey, or one the player flagged as junk.
local function IsSellable(info)
	if not info or not info.hyperlink or info.hasNoValue then
		return false
	end
	local poor = Enum.ItemQuality and Enum.ItemQuality.Poor or 0
	if not IsSecret(info.quality) and info.quality == poor and not K.IsUncollectedAppearance(info.hyperlink) then
		return true
	end
	return info.itemID and not IsSecret(info.itemID) and C.Bags.JunkList and C.Bags.JunkList[info.itemID] and true or false
end

-- Greys and the items the player flagged as junk, through the one shared seller
-- (Automation/SellJunk.lua), so this button and the auto sell never run two
-- queues at once.
function Module:SellJunk()
	if K.SellJunkItems then
		K.SellJunkItems(true)
	end
end

-- Total vendor value of the sellable items sitting in the bags.
function Module:GetJunkValue()
	local total = 0
	for _, bag in ipairs(self.BagIDs) do
		local numSlots = C_Container.GetContainerNumSlots(bag) or 0
		for slot = 1, numSlots do
			local info = C_Container.GetContainerItemInfo(bag, slot)
			if IsSellable(info) then
				local price = select(11, C_Item.GetItemInfo(info.hyperlink))
				if price and price > 0 then
					total = total + price * (info.stackCount or 1)
				end
			end
		end
	end
	return total
end

-- Show the sell button with its value while a merchant is open and there is
-- something to sell, otherwise keep it hidden.
function Module:UpdateSellButton(f)
	if not f or not f.SellButton then
		return
	end
	local open = _G.MerchantFrame and _G.MerchantFrame:IsShown()
	local value = open and self:GetJunkValue() or 0
	if not open or value <= 0 then
		f.SellButton:Hide()
		return
	end
	f.SellButton.Text:SetText(L["Sell Junk"] .. "  " .. GetCoinTextureString(value))
	f.SellButton:SetWidth(f.SellButton.Text:GetStringWidth() + 16)
	f.SellButton:Show()
end

-- ---------------------------------------------------------------------------
-- Open / close, and the hooks that replace Blizzard's bags
-- ---------------------------------------------------------------------------

function Module:OpenBags()
	if not self.BagFrame then
		return
	end
	self.BagFrame:Show()
	self:LayoutContainer(self.BagFrame)
	if self.ReagentFrame then
		self.ReagentFrame:Show()
		self:LayoutContainer(self.ReagentFrame)
	end
end

function Module:CloseBags()
	if self.BagFrame then
		self.BagFrame:Hide()
	end
	if self.ReagentFrame then
		self.ReagentFrame:Hide()
	end
	-- The keyring window is a companion of the inventory window, so it goes with it.
	self:CloseKeyring()
end

function Module:OpenKeyring()
	local keyring = self.KeyringFrame
	if keyring then
		keyring:Show()
		self:LayoutContainer(keyring)
		-- The window hangs off its mover by the top left corner, so the mover takes the
		-- window's real size once it is laid out. That keeps the right edge, which is
		-- what sits against the inventory window, where the default position put it.
		local mover = keyring.KKUI_Mover
		if mover then
			mover:SetSize(keyring:GetSize())
		end
	end
end

function Module:CloseKeyring()
	if self.KeyringFrame then
		self.KeyringFrame:Hide()
	end
end

-- The keyring window is closed until asked for, and it keeps its own open state.
-- The game's open state cannot stand in for it: with combined bags the game counts
-- the keyring as one of the bags in that frame, so it reads as open whenever the
-- bags are, and a window closed by its own button was opened straight back.
function Module:ToggleKeyring()
	if self.KeyringFrame and self.KeyringFrame:IsShown() then
		self:CloseKeyring()
	else
		self:OpenKeyring()
	end
end

function Module:CloseAll()
	self:CloseBags()
	self:CloseKeyring()
	if self.CloseBank then
		self:CloseBank()
	end
end

-- Follow Blizzard's bags with ours instead of replacing its functions. The stock
-- bag entry points are called from secure code all over the interface: the mail
-- window, the auction house, a merchant, item upgrade and others call them from
-- their show and hide handlers, and the gamepad radial calls ToggleBackpack and
-- then ToggleCharacter in one run. A global of ours standing in for any of them
-- runs in the middle of that chain and leaves the rest of it tainted, which is
-- what produced the secret value compare in the player frame text and the
-- forbidden SetPreferredGamepadInteractTarget call on WoW Forever. So every entry
-- point, the three toggles included, keeps running as Blizzard wrote it and a
-- post hook afterwards opens or closes our window to match whether Blizzard
-- considers any bag open.
-- Blizzard's own bag frames still open, so its open state stays truthful, but they
-- are parked under a small clipped frame at zero alpha. A hidden parent would make
-- IsShown false for them and break that state, which is why they are not hidden.
local BLIZZARD_ENTRY_POINTS = {
	"OpenAllBags",
	"CloseAllBags",
	"OpenBackpack",
	"CloseBackpack",
	"OpenBag",
	"CloseBag",
	"ToggleAllBags",
	"ToggleBackpack",
	"ToggleBackpack_Combined",
	"ToggleBag",
}

-- Where the stock bag and bank frames are parked: a shown frame one pixel big
-- that clips its children and draws nothing. Frames under it still report shown,
-- which is what keeps Blizzard's own open state truthful.
function Module:GetBlizzardSink()
	local sink = _G.KKUI_BagSink
	if not sink then
		sink = CreateFrame("Frame", "KKUI_BagSink", UIParent)
		sink:SetSize(1, 1)
		sink:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, 200)
		sink:SetClipsChildren(true)
		sink:SetAlpha(0)
	end
	return sink
end

function Module:HookBlizzard()
	local sink = self:GetBlizzardSink()

	-- A frame that holds secure item buttons cannot be reparented in combat, so this
	-- only runs out of it. The next sync after combat catches anything missed.
	local function Banish()
		if InCombatLockdown() then
			return
		end
		for i = 1, _G.NUM_CONTAINER_FRAMES or 13 do
			local frame = _G["ContainerFrame" .. i]
			if frame and frame:GetParent() ~= sink then
				frame:SetParent(sink)
			end
		end
		local combined = _G.ContainerFrameCombinedBags
		if combined and combined:GetParent() ~= sink then
			combined:SetParent(sink)
		end
	end

	local function Sync()
		Banish()
		if not (_G.IsBagOpen and self.BagFrame) then
			return
		end
		-- The keyring is not followed here, see ToggleKeyring.
		local wanted = false
		for _, bag in ipairs(self.BagIDs) do
			if _G.IsBagOpen(bag) then
				wanted = true
				break
			end
		end
		if wanted ~= (self.BagFrame:IsShown() and true or false) then
			if wanted then
				self:OpenBags()
			else
				self:CloseBags()
			end
		end
	end

	Banish()

	for _, name in ipairs(BLIZZARD_ENTRY_POINTS) do
		if type(_G[name]) == "function" then
			hooksecurefunc(name, Sync)
		end
	end

	-- Our window can be opened or closed without Blizzard knowing (the close button,
	-- the bank). Carry that over so the next key press toggles both from the same
	-- state. This runs from our own handlers, never from inside Blizzard's, and it
	-- is skipped in combat where its bag frames cannot be shown or hidden.
	if self.BagFrame then
		self.BagFrame:HookScript("OnHide", function()
			if not InCombatLockdown() and _G.IsAnyBagOpen and _G.CloseAllBags and _G.IsAnyBagOpen() then
				_G.CloseAllBags()
			end
		end)
		self.BagFrame:HookScript("OnShow", function()
			if not InCombatLockdown() and _G.IsAnyBagOpen and _G.OpenAllBags and not _G.IsAnyBagOpen() then
				_G.OpenAllBags()
			end
		end)
	end

	-- The game's own calls for the keyring (its keybind and its slot) open and close
	-- our window directly, whatever the game then thinks is open.
	if self.KeyringFrame then
		local keyringCalls = {
			ToggleBag = function()
				self:ToggleKeyring()
			end,
			OpenBag = function()
				self:OpenKeyring()
			end,
			CloseBag = function()
				self:CloseKeyring()
			end,
		}
		for name, action in pairs(keyringCalls) do
			if type(_G[name]) == "function" then
				hooksecurefunc(name, function(id)
					if id == KEYRING_BAG then
						action()
					end
				end)
			end
		end
	end
end

-- Where the bags open until the player moves them. The two side action bars hug
-- the right edge of the screen, and the old fixed spot landed on top of them, so
-- the window is placed just left of whichever of them are on. With neither on it
-- sits near the edge. The width comes from the same config the bars are laid out
-- from, so it follows their size and spacing.
local EDGE_GAP = 4 -- matches the side bars' own inset from the screen edge
local BAR_GAP = 6
local BAG_CLEARANCE = 6

local function SideBarsWidth()
	local bars = C.ActionBar
	local width, count = EDGE_GAP, 0
	if bars and bars.Enable then
		for _, key in ipairs({ "Bar4", "Bar5" }) do
			local cfg = bars[key]
			if cfg and cfg.Enable then
				local columns = math.min(cfg.PerRow, cfg.Buttons)
				width = width + columns * cfg.Size + (columns - 1) * cfg.Space + (count > 0 and BAR_GAP or 0)
				count = count + 1
			end
		end
	end
	return width + BAG_CLEARANCE
end

function Module:OnEnable()
	if not C.Bags.Enable then
		return
	end

	-- The reagent pouch can live in its own window. When detached, the main bag
	-- window drops the reagent bag and a small reagent window takes it, flat and
	-- uncategorised since it is a single pouch. Retail only, where a reagent bag
	-- exists at all.
	local detach = C.Bags.DetachReagentBag
	local mainBags = detach and { 0, 1, 2, 3, 4 } or self.BagIDs

	self.BagFrame = self:CreateContainer("KKUI_BagFrame", L["Inventory"], mainBags, C.Bags.BagsPerRow)
	K.CreateMover(self.BagFrame, "Bags", L["Inventory"], { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -SideBarsWidth(), 100 }, self.BagFrame:GetWidth(), self.BagFrame:GetHeight())
	K.EnableFrameDrag(self.BagFrame)

	if detach then
		local reagent = self:CreateContainer("KKUI_ReagentFrame", L["Reagent Bag"], { REAGENT_BAG }, C.Bags.BagsPerRow)
		reagent.noCategories = true
		self.ReagentFrame = reagent
		K.CreateMover(reagent, "ReagentBags", L["Reagent Bag"], { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -SideBarsWidth(), 100 + self.BagFrame:GetHeight() + 10 }, reagent:GetWidth(), reagent:GetHeight())
		K.EnableFrameDrag(reagent)
	end

	-- The keyring gets its own small window where the game has one, flat since it
	-- only ever holds keys. Blizzard's keyring button and the strip both toggle it.
	if self.HasKeyring() then
		local keyring = self:CreateContainer("KKUI_KeyringFrame", L["Keyring"], { KEYRING_BAG }, 8)
		keyring.noCategories = true
		-- Sorting and the bag strip mean nothing for a keyring.
		keyring.Sort:Hide()
		keyring.BagToggle:Hide()
		-- Its close button closes just this window, not the inventory beside it.
		local close = _G["KKUI_KeyringFrameClose"]
		if close then
			close:SetScript("OnClick", function()
				Module:CloseKeyring()
			end)
		end
		self.KeyringFrame = keyring
		-- Opens just left of the inventory window with the two tops level.
		K.CreateMover(keyring, "Keyring", L["Keyring"], { "TOPRIGHT", self.BagFrame, "TOPLEFT", -10, 0 }, keyring:GetWidth(), keyring:GetHeight())
		K.EnableFrameDrag(keyring)
	end

	-- The bag slot strip lives on the bag window and starts at its saved state.
	if self.CreateBagStrip then
		self:CreateBagStrip(self.BagFrame)
		self.BagFrame.BagStrip:SetShown(C.Bags.ShowBagBar)
	end

	-- Gold tracking: record this character now and hang the account total tooltip
	-- off the money text.
	if self.CaptureGold then
		self:CaptureGold()
		self:AttachGoldTooltip(self.BagFrame)
	end

	if self.SetupBank then
		self:SetupBank()
	end

	self:HookBlizzard()

	-- Keep the grid current as items move, and auto-sell junk at a merchant.
	self:RegisterEvent("BAG_UPDATE_DELAYED", "MarkDirty")
	self:RegisterEvent("BAG_UPDATE_COOLDOWN", "UpdateCooldowns")
	self:RegisterEvent("ITEM_LOCK_CHANGED", "UpdateLocked")
	self:RegisterEvent("QUEST_ACCEPTED", "MarkDirty")
	-- Your own quest log only. Party members' changes have nothing to do with your bags.
	self:RegisterUnitEvent("UNIT_QUEST_LOG_CHANGED", "MarkDirty", "player")
	self:RegisterEvent("PLAYER_MONEY", function()
		if self.CaptureGold then
			self:CaptureGold()
		end
		-- Money changes nothing in the grid, so only the readouts are redrawn.
		for _, f in ipairs({ self.BagFrame, self.ReagentFrame, self.BankFrame }) do
			if f and f:IsShown() then
				self:UpdateInfoText(f)
			end
		end
	end)
	-- Auto-sell on merchant open lives in Automation now (SellJunk.lua) so it works
	-- with the bags disabled. This only updates the manual Sell Junk button.
	self:RegisterEvent("MERCHANT_SHOW", function()
		self:UpdateSellButton(self.BagFrame)
	end)
	self:RegisterEvent("MERCHANT_CLOSED", function()
		self:UpdateSellButton(self.BagFrame)
	end)
	-- Build the pools up front while safely out of combat.
	self:PrewarmAll()
end
