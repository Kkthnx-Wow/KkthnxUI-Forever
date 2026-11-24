--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/ItemLevel.lua
	Purpose:
		Average equipped item level of another player, shared by the unit
		tooltip (Modules/Tooltip/Inspect.lua) and the Inspect window
		(Modules/Skins/CharacterFrames.lua).

		The game's own inspect average is used when it gives a plain number.
		When it is missing, secret or zero, the average is worked out from the
		item links, which is split in two steps on purpose. Links are copied out
		while the inspect data is held, and the levels are read from those links
		later, so the inspect target can be released while item data loads.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local pairs = pairs
local wipe = wipe
local C_Item = C_Item
local C_PaperDollInfo = C_PaperDollInfo
local Item = Item
local GetInventoryItemID = GetInventoryItemID
local GetInventoryItemLink = GetInventoryItemLink
local GetInventoryItemTexture = GetInventoryItemTexture
local IsSecret = K.IsSecret
local C_Timer = C_Timer

-- An item the server never answers for would leave a wait open for good, and the
-- tooltip holds the inspect target while it waits. Give up after this long.
local LOAD_TIMEOUT = 3

-- Every worn slot except shirt (4), tabard (19) and ammo (0). Ranged (18) is a
-- real gear slot on Forever.
local SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18 }
local MAIN_HAND, OFF_HAND = 16, 17
-- Empty slots count as zero, so the divisor is the full slot count. UNKNOWN for
-- Forever: whether its own average counts the ranged slot (17) or not (16). This
-- is only used when the game's number is not available.
local DIVISOR = #SLOTS

local function ItemID(link)
	return C_Item.GetItemInfoInstant(link)
end

local function IsCached(link)
	local id = ItemID(link)
	return not id or not C_Item.IsItemDataCachedByID or C_Item.IsItemDataCachedByID(id)
end

-- Copy the unit's gear links into links (slot -> link). Returns false while the
-- inspect data is still partial (a slot shows an icon but has no link yet), and
-- false, true when a link reads as secret. Waiting does not change a secret, so
-- the caller stops at once instead of spending its retries.
function K.CollectGearLinks(unit, links)
	wipe(links)
	for _, slot in pairs(SLOTS) do
		local link = GetInventoryItemLink(unit, slot)
		if link and IsSecret(link) then
			return false, true
		elseif link then
			links[slot] = link
		elseif GetInventoryItemTexture(unit, slot) then
			return false
		end
	end
	return true
end

-- Average from links. Returns nil while any item is not cached, so the caller
-- can wait with K.LoadGearLinks and ask again.
function K.AverageFromLinks(links)
	local total = 0
	for slot, link in pairs(links) do
		if not IsCached(link) then
			return nil
		end
		local level = C_Item.GetDetailedItemLevelInfo(link)
		if level and not IsSecret(level) then
			total = total + level
			-- A two-hander with nothing in the off hand fills both hands.
			if slot == MAIN_HAND and not links[OFF_HAND] then
				local _, _, _, equipLoc = C_Item.GetItemInfoInstant(link)
				if equipLoc == "INVTYPE_2HWEAPON" then
					total = total + level
				end
			end
		end
	end
	return total / DIVISOR
end

-- A countdown that calls done once, when every load is in or the timeout runs
-- out, whichever comes first.
local function Waiter(done)
	local waiting, finished = 0, false
	local function Finish()
		if not finished then
			finished = true
			done()
		end
	end
	local function OnLoad()
		waiting = waiting - 1
		if waiting == 0 then
			Finish()
		end
	end
	local function Add()
		waiting = waiting + 1
	end
	local function Count()
		return waiting
	end
	return OnLoad, Add, Count, Finish
end

-- Call done once every uncached item in links has loaded. Each item is asked
-- for once, and done runs a single time, on time out too.
function K.LoadGearLinks(links, done)
	local OnLoad, Add, Count, Finish = Waiter(done)
	for _, link in pairs(links) do
		if not IsCached(link) then
			Add()
			Item:CreateFromItemLink(link):ContinueOnItemLoad(OnLoad)
		end
	end
	if Count() == 0 then
		Finish()
	else
		C_Timer.After(LOAD_TIMEOUT, Finish)
	end
end

-- An inspected slot has no link until its item is cached on this client, but
-- the item ID is already known. Load those items and call done once they are
-- all in, so the links can be read again. Returns false when there is nothing
-- to wait on, and the caller falls back to a short timer.
function K.LoadMissingGear(unit, done)
	local OnLoad, Add, Count, Finish = Waiter(done)
	for _, slot in pairs(SLOTS) do
		local id = not GetInventoryItemLink(unit, slot) and GetInventoryItemID and GetInventoryItemID(unit, slot)
		if id and not IsSecret(id) and not (C_Item.IsItemDataCachedByID and C_Item.IsItemDataCachedByID(id)) then
			Add()
			Item:CreateFromItemID(id):ContinueOnItemLoad(OnLoad)
		end
	end
	if Count() == 0 then
		return false
	end
	C_Timer.After(LOAD_TIMEOUT, Finish)
	return true
end

-- Average for an inspected unit while its inspect data is held. Returns the
-- level, or nil and a reason: "partial" (links still arriving, wait on
-- K.LoadMissingGear and read again), "loading" (links are in links, wait on
-- K.LoadGearLinks) or "secret" (a link cannot be read, nothing to wait for).
function K.GetInspectAverage(unit, links)
	local api = C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel
	local level = api and api(unit)
	if level and not IsSecret(level) and level > 0 then
		return level
	end
	local complete, secret = K.CollectGearLinks(unit, links)
	if secret then
		return nil, "secret"
	elseif not complete then
		return nil, "partial"
	end
	level = K.AverageFromLinks(links)
	if not level then
		return nil, "loading"
	end
	return level
end
