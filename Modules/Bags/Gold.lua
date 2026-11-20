--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Gold.lua
	Purpose:
		Track gold on every character on the account and show the running total in a
		tooltip on the bag and bank money text.
-----------------------------------------------------------------------------]]

local K, _, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Bags")
if not Module then
	return
end

local _G = _G
local ipairs = ipairs
local pairs = pairs
local tsort = table.sort
local time = time

local GetMoney = GetMoney
local GetRealmName = GetRealmName
local UnitName = UnitName
local UnitClass = UnitClass
local UnitFactionGroup = UnitFactionGroup
local GetCoinTextureString = C_CurrencyInfo.GetCoinTextureString
local CreateFrame = CreateFrame

-- Account wide store, kept on the saved variable so every character sees the same
-- ledger. { chars = { [key] = { gold, class, faction, updated } } }
local function DB()
	local root = _G.KkthnxUIDB
	if not root then
		return nil
	end
	root.goldTracker = root.goldTracker or { chars = {} }
	root.goldTracker.chars = root.goldTracker.chars or {}
	return root.goldTracker
end

local function CharKey()
	return UnitName("player") .. " - " .. GetRealmName()
end

-- Strip the realm off a stored key for a tidy tooltip name.
local function ShortName(key)
	return key:match("^(.-) %- ") or key
end

-- Record this character's gold.
function Module:CaptureGold()
	local db = DB()
	if not db then
		return
	end

	local _, class = UnitClass("player")
	db.chars[CharKey()] = {
		gold = GetMoney(),
		class = class,
		faction = UnitFactionGroup("player"),
		updated = time(),
	}
end

-- ---------------------------------------------------------------------------
-- Tooltip
-- ---------------------------------------------------------------------------

local function ShowGoldTooltip(anchor, point)
	local db = DB()
	if not db then
		return
	end

	GameTooltip:SetOwner(anchor, point or "ANCHOR_RIGHT")
	GameTooltip:AddLine(L["Gold"], 1, 1, 1)
	GameTooltip:AddLine(" ")

	-- Sort characters by gold, richest first.
	local list, total = {}, 0
	for key, data in pairs(db.chars) do
		list[#list + 1] = { key = key, gold = data.gold or 0, class = data.class }
		total = total + (data.gold or 0)
	end
	tsort(list, function(a, b)
		return a.gold > b.gold
	end)

	for _, entry in ipairs(list) do
		GameTooltip:AddDoubleLine(
			K.ClassColorText(entry.class, ShortName(entry.key)),
			GetCoinTextureString(entry.gold), 1, 1, 1, 1, 1, 1
		)
	end

	GameTooltip:AddLine(" ")
	GameTooltip:AddDoubleLine(L["Total"], GetCoinTextureString(total), 1, 0.82, 0, 1, 1, 1)
	GameTooltip:Show()
end

-- Put an invisible mouse catcher over a money font string so it can carry the
-- tooltip, since a font string takes no mouse of its own.
function Module:AttachGoldTooltip(f)
	if not f or not f.Money or f.MoneyHover then
		return
	end
	local hover = CreateFrame("Button", nil, f)
	hover:SetPoint("TOPLEFT", f.Money, "TOPLEFT", -2, 2)
	hover:SetPoint("BOTTOMRIGHT", f.Money, "BOTTOMRIGHT", 2, -2)
	hover:SetScript("OnEnter", function(self)
		ShowGoldTooltip(self)
	end)
	hover:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	f.MoneyHover = hover
end

