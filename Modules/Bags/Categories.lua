--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Categories.lua
	Purpose:
		Sort each item into one of our display sections. The order here is the
		order the sections appear in the window, top to bottom. Classification
		reads the container and item data, so it stays correct as items load in.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

-- Match Core.lua: load wherever C_Container is present, not only on retail.
if not (C_Container and C_Container.GetContainerNumSlots) then
	return
end

local Module = K:GetModule("Bags")

local IsSecret = K.IsSecret
local Enum = Enum
local C_NewItems = C_NewItems
local GetContainerItemQuestInfo = C_Container.GetContainerItemQuestInfo
local GetItemInfoInstant = C_Item.GetItemInfoInstant

local ItemClass = Enum.ItemClass
local POOR = Enum.ItemQuality and Enum.ItemQuality.Poor or 0

-- The sections, in the order they render. key is used internally, name is shown.
Module.Categories = {
	{ key = "Favourites", name = L["Favourites"] },
	{ key = "New", name = L["New"] },
	{ key = "Equipment", name = L["Equipment"] },
	{ key = "Consumable", name = L["Consumables"] },
	{ key = "Ammo", name = L["Ammunition"] },
	{ key = "TradeGoods", name = L["Trade Goods"] },
	{ key = "ReagentBag", name = L["Reagent Bag"] },
	{ key = "GearEnhancement", name = L["Gear Enhancements"] },
	{ key = "Profession", name = L["Professions"] },
	{ key = "Housing", name = L["Housing"] },
	{ key = "Collectible", name = L["Collectibles"] },
	{ key = "Container", name = L["Bags"] },
	{ key = "Quest", name = L["Quest"] },
	{ key = "Miscellaneous", name = L["Miscellaneous"] },
	{ key = "Junk", name = L["Junk"] },
}


-- Render order of the gear slots when the group-by-slot layout is on.
local GEAR_ORDER = {
	"Head", "Neck", "Shoulder", "Back", "Chest", "Wrist", "Hands", "Waist",
	"Legs", "Feet", "Ring", "Trinket", "Weapon", "Off Hand", "Ranged", "Shirt", "Tabard",
}

-- Gear slot shelves, in render order, for the group-gear-by-slot layout. Core
-- renders them in place of the Equipment section.
Module.GearSlotOrder = GEAR_ORDER

-- A section the player turned off in the bag sections panel stops catching items,
-- and they fall through to the next section that fits. Miscellaneous is the
-- catch-all and cannot be turned off.
function Module:IsSectionOn(key)
	if key == "Miscellaneous" then
		return true
	end
	local off = C.Bags.DisabledCategories
	return not (off and off[key])
end

-- Miscellaneous subclasses that are really collectibles (mounts and pets).
local MiscSub = Enum.ItemMiscellaneousSubclass
local COLLECTIBLE_MISC = {
	[MiscSub.CompanionPet] = true,
	[MiscSub.Mount] = true,
	[MiscSub.MountEquipment] = true,
}

-- Item classes that read as wearable gear.
local EQUIP_CLASS = {
	[ItemClass.Weapon] = true,
	[ItemClass.Armor] = true,
}

-- Equip location to a slot name, for the optional group-gear-by-slot layout.
local EQUIP_SLOT = {
	INVTYPE_HEAD = "Head",
	INVTYPE_NECK = "Neck",
	INVTYPE_SHOULDER = "Shoulder",
	INVTYPE_CLOAK = "Back",
	INVTYPE_CHEST = "Chest",
	INVTYPE_ROBE = "Chest",
	INVTYPE_BODY = "Shirt",
	INVTYPE_TABARD = "Tabard",
	INVTYPE_WRIST = "Wrist",
	INVTYPE_HAND = "Hands",
	INVTYPE_WAIST = "Waist",
	INVTYPE_LEGS = "Legs",
	INVTYPE_FEET = "Feet",
	INVTYPE_FINGER = "Ring",
	INVTYPE_TRINKET = "Trinket",
	INVTYPE_WEAPON = "Weapon",
	INVTYPE_2HWEAPON = "Weapon",
	INVTYPE_WEAPONMAINHAND = "Weapon",
	INVTYPE_WEAPONOFFHAND = "Weapon",
	INVTYPE_HOLDABLE = "Off Hand",
	INVTYPE_SHIELD = "Off Hand",
	INVTYPE_RANGED = "Ranged",
	INVTYPE_RANGEDRIGHT = "Ranged",
	-- Thrown weapons and relics sit in the ranged slot on Forever.
	INVTYPE_THROWN = "Ranged",
	INVTYPE_RELIC = "Ranged",
}

-- Raw crafting and gathering stock.
local TRADE_CLASS = {
	[ItemClass.Tradegoods] = true,
	[ItemClass.Reagent] = true,
}

-- Gems and enchants: things you slot or apply to gear, kept apart from raw
-- trade goods so upgrade mats are easy to find.
local ENHANCE_CLASS = {
	[ItemClass.Gem] = true,
	[ItemClass.ItemEnhancement] = true,
}

-- Recipes and profession tools/equipment.
local PROFESSION_CLASS = {
	[ItemClass.Recipe] = true,
	[ItemClass.Profession] = true,
}

-- The dedicated reagent pouch, so its contents can group as one shelf.
local REAGENT_BAG = Enum.BagIndex and Enum.BagIndex.ReagentBag or 5

-- The section a class-based rule picked, or the catch-all when the player turned
-- that section off. Gear shelves follow the Equipment switch.
local function Pick(key, base)
	if Module:IsSectionOn(base or key) then
		return key
	end
	return "Miscellaneous"
end

-- Return the section key an item belongs to. bag/slot locate it, info is the
-- already fetched container info so callers do not query twice. Every rule skips
-- a section the player turned off, so its items land in the next one that fits.
function Module:GetCategory(bag, slot, info)
	if not info then
		return "Miscellaneous"
	end
	local cfg = C.Bags

	local itemID = info.itemID
	if itemID and not IsSecret(itemID) then
		-- An explicit per-item assignment wins over the automatic sorting.
		local assigned = cfg.ItemAssignments and cfg.ItemAssignments[itemID]
		if assigned and self:IsSectionOn(assigned) then
			return assigned
		end
		-- Player-pinned favourites sit above everything else.
		if cfg.Favorites[itemID] and self:IsSectionOn("Favourites") then
			return "Favourites"
		end
		-- Items the player flagged as junk sort with the rest of the trash.
		if cfg.JunkList and cfg.JunkList[itemID] and self:IsSectionOn("Junk") then
			return "Junk"
		end
	end

	-- Anything sitting in the dedicated reagent bag groups together, so crafters
	-- can see that pouch as one shelf rather than scattered through Trade Goods.
	if cfg.ReagentBagSection and bag == REAGENT_BAG and self:IsSectionOn("ReagentBag") then
		return "ReagentBag"
	end

	-- Freshly looted items float to the top while the flag lasts.
	if cfg.ShowNewItems and C_NewItems and C_NewItems.IsNewItem and self:IsSectionOn("New") and C_NewItems.IsNewItem(bag, slot) then
		return "New"
	end

	-- Grey items are junk. An uncollected transmog appearance is not junk, it falls
	-- through to its normal shelf. A player-flagged item went to Junk above.
	local quality = info.quality
	if not IsSecret(quality) and quality == POOR and self:IsSectionOn("Junk") and not K.IsUncollectedAppearance(info.hyperlink) then
		return "Junk"
	end

	-- Quest items get their own shelf so they are easy to find.
	local questOn = self:IsSectionOn("Quest")
	local quest = questOn and GetContainerItemQuestInfo and GetContainerItemQuestInfo(bag, slot)
	if quest and (quest.isQuestItem or quest.questID) then
		return "Quest"
	end

	if itemID and not IsSecret(itemID) then
		local _, _, _, equipLoc, _, classID, subclassID = GetItemInfoInstant(itemID)
		if classID == ItemClass.Questitem then
			return Pick("Quest")
		elseif classID == ItemClass.Battlepet then
			return Pick("Collectible")
		elseif classID == ItemClass.Miscellaneous and COLLECTIBLE_MISC[subclassID] then
			return Pick("Collectible")
		elseif classID == ItemClass.Container or classID == ItemClass.Quiver then
			return Pick("Container")
		elseif classID == ItemClass.Projectile then
			-- Arrows and bullets, which Forever's ranged weapons still use.
			return Pick("Ammo")
		elseif classID == ItemClass.Housing then
			return Pick("Housing")
		elseif EQUIP_CLASS[classID] then
			-- Optionally split gear into its own per-slot shelves.
			local gearSlot = cfg.GroupGearBySlot and EQUIP_SLOT[equipLoc]
			if gearSlot then
				return Pick("Equipment:" .. gearSlot, "Equipment")
			end
			return Pick("Equipment")
		elseif classID == ItemClass.Consumable then
			return Pick("Consumable")
		elseif ENHANCE_CLASS[classID] then
			return Pick("GearEnhancement")
		elseif PROFESSION_CLASS[classID] then
			return Pick("Profession")
		elseif TRADE_CLASS[classID] then
			return Pick("TradeGoods")
		end
	end

	return "Miscellaneous"
end
