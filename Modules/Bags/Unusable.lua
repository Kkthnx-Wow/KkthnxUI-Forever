--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Unusable.lua
	Purpose:
		Find gear you cannot use, so a bag slot can tint its icon red the way the
		stock bags do on merchants. Instead of a table of class proficiencies that
		would have to match this server's rules, it asks the game: an item the
		player cannot use has a red line in its own tooltip (wrong armor or weapon
		type, level too low, wrong class). Only weapons and armor are checked.

		The verdict is cached per item. A level up clears it all. A skill change
		only clears the items marked unusable, since a skill can lift a red
		requirement but never adds one, and skill ranks change all the time while
		gathering or crafting. The durability line is ignored, because a broken
		item shows it in red without being unusable. The cache is bounded.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local Module = K:GetModule("Bags")

local C_Item = C_Item
local C_TooltipInfo = C_TooltipInfo
local C_Timer = C_Timer
local Enum = Enum
local IsSecret = K.IsSecret
local wipe = wipe
local ipairs = ipairs
local next = next

-- "Durability %d / %d" turned into a pattern that matches the filled-in line.
local DURABILITY_PATTERN
do
	local template = _G.DURABILITY_TEMPLATE
	if type(template) == "string" then
		local escaped = template:gsub("%%d", "\001"):gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"):gsub("\001", "%%d+")
		DURABILITY_PATTERN = "^" .. escaped .. "$"
	end
end

local CACHE_LIMIT = 400

local cache = {}
local count = 0
local watching = false

-- A tooltip colour counts as the "cannot use" red when it is strongly red.
local function IsRed(color)
	if not color then
		return false
	end
	local r, g, b = color.r, color.g, color.b
	if not r or IsSecret(r) or IsSecret(g) or IsSecret(b) then
		return false
	end
	return r > 0.9 and g < 0.3 and b < 0.3
end

local function ScanTooltip(bag, slot)
	local data = C_TooltipInfo.GetBagItem(bag, slot)
	if not data or not data.lines then
		return nil
	end
	for _, line in ipairs(data.lines) do
		local text = line.leftText
		local durability = DURABILITY_PATTERN and text and not IsSecret(text) and text:match(DURABILITY_PATTERN)
		if not durability and (IsRed(line.leftColor) or IsRed(line.rightColor)) then
			return true
		end
	end
	return false
end

local function ClearCache()
	wipe(cache)
	count = 0
end

-- The level or skill change has to reach the item tooltips before a rescan can
-- see the red go, and the buttons keep their tint until they are drawn again.
-- So the cache is cleared a moment later and the open bags are redrawn then.
-- Repeated events in that moment share one pass.
local pending = false
local onlyUnusable = true

local function RefreshLater(clearAll)
	if clearAll then
		onlyUnusable = false
	end
	if pending then
		return
	end
	pending = true
	C_Timer.After(1, function()
		pending = false
		local changed = false
		if onlyUnusable then
			for itemID, unusable in next, cache do
				if unusable then
					cache[itemID] = nil
					count = count - 1
					changed = true
				end
			end
		else
			ClearCache()
			changed = true
		end
		onlyUnusable = true
		if changed then
			Module:MarkDirty()
		end
	end)
end

local function OnLevelUp()
	RefreshLater(true)
end

local function OnSkillsChanged()
	RefreshLater(false)
end

-- Returns true when the item in this slot is gear the player cannot use.
function Module:IsUnusableGear(bag, slot, itemID)
	if not itemID or IsSecret(itemID) or not (C_TooltipInfo and C_TooltipInfo.GetBagItem) then
		return false
	end
	local cached = cache[itemID]
	if cached ~= nil then
		return cached
	end

	local _, _, _, _, _, classID = C_Item.GetItemInfoInstant(itemID)
	local isGear = classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
	local result = isGear and ScanTooltip(bag, slot)
	-- Item data that has not loaded yet gives no tooltip, so try again next time.
	if result == nil then
		return false
	end

	if not watching then
		watching = true
		self:RegisterEvent("PLAYER_LEVEL_UP", OnLevelUp)
		-- A weapon skill learned at a trainer, or a profession rank reached,
		-- can lift the red.
		self:RegisterEvent("SKILL_LINES_CHANGED", OnSkillsChanged)
	end
	if count >= CACHE_LIMIT then
		ClearCache()
	end
	cache[itemID] = result
	count = count + 1
	return result
end
