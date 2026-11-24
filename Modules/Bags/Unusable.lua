--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Unusable.lua
	Purpose:
		Find gear you cannot use, so a bag slot can tint its icon red the way the
		stock bags do on merchants. Instead of a table of class proficiencies that
		would have to match this server's rules, it asks the game: an item the
		player cannot use has a red line in its own tooltip (wrong armor or weapon
		type, level too low, wrong class). Only weapons and armor are checked.

		The verdict is cached per item and cleared on level up and when a skill
		is learned, since a level or weapon skill requirement stops being red
		once it is met. The cache is bounded.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local Module = K:GetModule("Bags")

local C_Item = C_Item
local C_TooltipInfo = C_TooltipInfo
local Enum = Enum
local IsSecret = K.IsSecret
local wipe = wipe
local ipairs = ipairs

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
		if IsRed(line.leftColor) or IsRed(line.rightColor) then
			return true
		end
	end
	return false
end

local function ClearCache()
	wipe(cache)
	count = 0
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
		self:RegisterEvent("PLAYER_LEVEL_UP", ClearCache)
		-- Weapon skills are learned at a trainer here, which also lifts the red.
		self:RegisterEvent("SKILL_LINES_CHANGED", ClearCache)
	end
	if count >= CACHE_LIMIT then
		ClearCache()
	end
	cache[itemID] = result
	count = count + 1
	return result
end
