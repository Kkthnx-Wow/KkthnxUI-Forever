--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/Reminders.lua
	Purpose:
		A small row of icons for what your character is missing, shown out of
		combat. Each icon is a click to fix it:
			class self-buffs      cast the buff (armors, Intellect, Fortitude, ...)
			weapon enchants       apply a poison, oil or stone you carry, or cast
			                      the shaman imbue
			pet care              call, revive or feed the hunter pet, or summon
			                      the warlock demon
			talents and training  open the talents or the spellbook

		The icons are secure buttons, so the row is only rebuilt out of combat and
		is hidden for the whole fight. It also steps aside while you are dead,
		mounted or on a flight path. Buffs are matched by name, so any rank counts,
		and a buff someone else cast on you counts too. Only spells you know and
		items you carry are ever suggested.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local _G = _G
local ipairs = ipairs
local wipe = wipe
local format = string.format

local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local InCombatLockdown = InCombatLockdown
local IsMounted = IsMounted
local UIParent = UIParent
local UnitExists = UnitExists
local UnitIsDead = UnitIsDead
local UnitIsDeadOrGhost = UnitIsDeadOrGhost
local UnitLevel = UnitLevel
local UnitOnTaxi = UnitOnTaxi
local GetInventoryItemID = GetInventoryItemID
local C_ClassTalents = C_ClassTalents
local GetPetHappiness = C_PetInfo and C_PetInfo.GetPetHappiness
local C_Timer_After = C_Timer.After
local C_PaperDollInfo = C_PaperDollInfo
local C_Spell = C_Spell
local C_SpellBook = C_SpellBook
local C_UnitAuras = C_UnitAuras
local GetItemCount = C_Item.GetItemCount
local GetItemIcon = C_Item.GetItemIconByID
local GetItemInfoInstant = C_Item.GetItemInfoInstant

local MAIN_HAND, OFF_HAND = 16, 17
local SPACING = 6
local REFRESH_DELAY = 0.2

-- ---------------------------------------------------------------------------
-- Data
-- ---------------------------------------------------------------------------
-- Every list holds the lowest rank, which stays known once a higher one is
-- trained. Casting goes by name, so the highest rank is what gets cast.

-- Each group is satisfied by any one of its buffs. The first known spell in
-- `cast` is what the icon casts.
local BUFFS = {
	MAGE = {
		{ have = { 168, 7302, 6117 }, cast = { 6117, 7302, 168 } }, -- Frost, Ice or Mage Armor
		{ have = { 1459, 23028 }, cast = { 1459 } }, -- Arcane Intellect or Brilliance
	},
	PRIEST = {
		{ have = { 1243, 21562 }, cast = { 1243 } }, -- Power Word: Fortitude or Prayer
		{ have = { 588 }, cast = { 588 } }, -- Inner Fire
	},
	DRUID = {
		{ have = { 1126, 21849 }, cast = { 1126 } }, -- Mark or Gift of the Wild
	},
	WARLOCK = {
		{ have = { 687, 706 }, cast = { 706, 687 } }, -- Demon Skin or Demon Armor
	},
	PALADIN = {
		-- An aura, and any blessing at all.
		{ have = { 465, 7294, 19746, 19876, 19888, 19891, 20218 }, cast = { 465 } },
		{ have = { 19740, 19742, 20217, 1038, 19977, 20911 }, cast = { 20217, 19742, 19740 } },
	},
	HUNTER = {
		{ have = { 13165, 5118, 13159, 20043, 13163 }, cast = { 13165, 13163 } }, -- an aspect
	},
	SHAMAN = {
		{ have = { 324 }, cast = { 324 } }, -- Lightning Shield
	},
}

-- Rogue poisons, best first. The main hand wants a fast hitting poison, the off
-- hand a slow stacking one, and either falls back to whatever is in the bags.
local INSTANT = { 8928, 8927, 8926, 6950, 6949, 6947 }
local DEADLY = { 20844, 8985, 8984, 2893, 2892 }
local OTHER_POISONS = { 10922, 10921, 10920, 10918, 3776, 3775, 9186, 6951, 5237 }

-- Shaman imbues, cast on the main hand.
local IMBUES = { 8232, 8024, 8033, 8017 } -- Windfury, Flametongue, Frostbrand, Rockbiter

-- Oils go on any weapon. Stones depend on the edge.
local OILS = { 20749, 20748, 20750, 20747, 20746, 20745, 20744 }
local SHARPENING = { 18262, 12404, 7964, 2871, 2863, 2862 }
local WEIGHT = { 12643, 7965, 3241, 3240, 3239 }
-- Weapon subclasses that take a weightstone: maces, staves and fist weapons.
local BLUNT = { [4] = true, [5] = true, [10] = true, [13] = true }

local CALL_PET, REVIVE_PET, FEED_PET = 883, 982, 6991
local DEMONS = { 697, 688, 712, 691 } -- Voidwalker, Imp, Succubus, Felhunter
local DEMON_SET = {}
for _, id in ipairs(DEMONS) do
	DEMON_SET[id] = true
end

local TALENT_ICON = 132222 -- Ability_Marksmanship
local TRAINING_ICON = 133743 -- INV_Misc_Book_09

-- ---------------------------------------------------------------------------
-- Checks
-- ---------------------------------------------------------------------------

local function Known(spellID)
	return C_SpellBook.IsSpellKnown(spellID) and true or false
end

local function FirstKnown(list)
	for _, id in ipairs(list) do
		if Known(id) then
			return id
		end
	end
end

local function FirstCarried(list)
	for _, id in ipairs(list) do
		if (GetItemCount(id) or 0) > 0 then
			return id
		end
	end
end

local function HasBuff(list)
	for _, id in ipairs(list) do
		local name = C_Spell.GetSpellName(id)
		if name and C_UnitAuras.GetAuraDataBySpellName("player", name, "HELPFUL") then
			return true
		end
	end
	return false
end

local function WeaponClass(slot)
	local itemID = GetInventoryItemID("player", slot)
	if not itemID then
		return nil
	end
	local _, _, _, _, _, classID, subclassID = GetItemInfoInstant(itemID)
	if classID == 2 then
		return subclassID
	end
end

local function Enchanted(slot)
	return C_PaperDollInfo.GetTemporaryEnchantmentInfo(slot) ~= nil
end

-- Unlearned spells the player is already high enough for. They sit in the
-- spellbook as future spells until a trainer teaches them.
local function TrainableSpells(names)
	local bank = Enum.SpellBookSpellBank.Player
	local level = UnitLevel("player")
	for line = 1, C_SpellBook.GetNumSpellBookSkillLines() do
		local info = C_SpellBook.GetSpellBookSkillLineInfo(line)
		if info and not info.offSpecID and not info.shouldHide then
			for index = info.itemIndexOffset + 1, info.itemIndexOffset + info.numSpellBookItems do
				local itemType = C_SpellBook.GetSpellBookItemType(index, bank)
				if itemType == Enum.SpellBookItemType.FutureSpell then
					local learned = C_SpellBook.GetSpellBookItemLevelLearned(index, bank)
					if learned and learned > 0 and learned <= level then
						names[#names + 1] = C_SpellBook.GetSpellBookItemName(index, bank)
					end
				end
			end
		end
	end
	return names
end

-- ---------------------------------------------------------------------------
-- Building the list
-- ---------------------------------------------------------------------------

local wanted = {}
local lastDemon

-- A buff goes on the player. Without that a friendly target would get it.
local function AddSpell(spellID, reason, unit)
	wanted[#wanted + 1] = { kind = "spell", spell = spellID, reason = reason, unit = unit }
end

local function AddItem(itemID, slot, reason)
	wanted[#wanted + 1] = { kind = "item", item = itemID, slot = slot, reason = reason }
end

local function CollectBuffs()
	for _, group in ipairs(BUFFS[K.Class] or {}) do
		local cast = FirstKnown(group.cast)
		if cast and not HasBuff(group.have) then
			AddSpell(cast, L["Missing buff"], "player")
		end
	end
end

local function CollectWeapons()
	if not WeaponClass(MAIN_HAND) then
		return
	end
	local mainBare = not Enchanted(MAIN_HAND)

	if K.Class == "ROGUE" then
		if mainBare then
			local poison = FirstCarried(INSTANT) or FirstCarried(DEADLY) or FirstCarried(OTHER_POISONS)
			if poison then
				AddItem(poison, MAIN_HAND, L["Main hand has no poison"])
			end
		end
		if WeaponClass(OFF_HAND) and not Enchanted(OFF_HAND) then
			local poison = FirstCarried(DEADLY) or FirstCarried(INSTANT) or FirstCarried(OTHER_POISONS)
			if poison then
				AddItem(poison, OFF_HAND, L["Off hand has no poison"])
			end
		end
	elseif K.Class == "SHAMAN" then
		local imbue = mainBare and FirstKnown(IMBUES)
		if imbue then
			AddSpell(imbue, L["Main hand has no imbue"])
		end
	elseif mainBare then
		local class = WeaponClass(MAIN_HAND)
		local item = FirstCarried(OILS) or FirstCarried(BLUNT[class] and WEIGHT or SHARPENING)
		if item then
			AddItem(item, MAIN_HAND, L["Main hand has no oil or stone"])
		end
	end
end

local function CollectPet()
	if K.Class == "HUNTER" then
		if UnitExists("pet") then
			if UnitIsDead("pet") then
				if Known(REVIVE_PET) then
					AddSpell(REVIVE_PET, L["Your pet is dead"])
				end
			elseif GetPetHappiness and GetPetHappiness() == 1 and Known(FEED_PET) then
				AddSpell(FEED_PET, L["Your pet is unhappy"])
			end
		elseif Known(CALL_PET) then
			AddSpell(CALL_PET, L["No pet"])
		end
	elseif K.Class == "WARLOCK" and not UnitExists("pet") then
		local demon = (lastDemon and Known(lastDemon)) and lastDemon or FirstKnown(DEMONS)
		if demon then
			AddSpell(demon, L["No demon"])
		end
	end
end

local function CollectTalents()
	if C_ClassTalents and C_ClassTalents.HasUnspentTalentPoints then
		local has, classPoints, specPoints = C_ClassTalents.HasUnspentTalentPoints()
		if has then
			wanted[#wanted + 1] = {
				kind = "click",
				button = "TalentMicroButton",
				icon = TALENT_ICON,
				reason = format(L["%d unspent talent points"], (classPoints or 0) + (specPoints or 0)),
			}
		end
	end
	local names = TrainableSpells({})
	if #names > 0 then
		wanted[#wanted + 1] = {
			kind = "click",
			button = "SpellbookMicroButton",
			icon = TRAINING_ICON,
			reason = L["New spells to train"],
			lines = names,
		}
	end
end

-- ---------------------------------------------------------------------------
-- Buttons
-- ---------------------------------------------------------------------------

local holder
local buttons = {}

local function OnEnter(self)
	local entry = self.entry
	if not entry then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_TOP")
	if entry.kind == "spell" then
		GameTooltip:SetSpellByID(entry.spell)
	elseif entry.kind == "item" then
		GameTooltip:SetItemByID(entry.item)
	else
		GameTooltip:AddLine(entry.reason, 1, 1, 1)
		for _, line in ipairs(entry.lines or {}) do
			GameTooltip:AddLine(line, 0.8, 0.8, 0.8)
		end
	end
	if entry.kind ~= "click" then
		local warn = K.Colors.warning
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine(entry.reason, warn[1], warn[2], warn[3])
	end
	GameTooltip:AddLine(L["Click to fix"], 0.6, 0.6, 0.6)
	GameTooltip:Show()
end

local function OnLeave()
	GameTooltip:Hide()
end

local function CreateButton(index)
	local size = C.QoL.ReminderSize or 36
	local button = CreateFrame("Button", "KKUI_Reminder" .. index, holder, "SecureActionButtonTemplate")
	button:SetSize(size, size)
	button:RegisterForClicks("AnyUp", "AnyDown")

	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 1, -1)
	icon:SetPoint("BOTTOMRIGHT", -1, 1)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	button.Icon = icon

	local highlight = button:CreateTexture(nil, "HIGHLIGHT")
	highlight:SetAllPoints(icon)
	highlight:SetColorTexture(1, 1, 1, 0.15)

	K.CreateBorder(button)
	button:SetScript("OnEnter", OnEnter)
	button:SetScript("OnLeave", OnLeave)
	buttons[index] = button
	return button
end

-- Secure attributes for one entry. Runs out of combat only.
local function Assign(button, entry)
	button.entry = entry
	button:SetAttribute("type", nil)
	button:SetAttribute("unit", nil)
	button:SetAttribute("spell", nil)
	button:SetAttribute("macrotext", nil)
	button:SetAttribute("clickbutton", nil)

	if entry.kind == "spell" then
		button:SetAttribute("type", "spell")
		button:SetAttribute("unit", entry.unit)
		button:SetAttribute("spell", C_Spell.GetSpellName(entry.spell))
		button.Icon:SetTexture(C_Spell.GetSpellTexture(entry.spell))
	elseif entry.kind == "item" then
		-- Use the item, then point it at the weapon slot.
		button:SetAttribute("type", "macro")
		button:SetAttribute("macrotext", format("/use item:%d\n/use %d", entry.item, entry.slot))
		button.Icon:SetTexture(GetItemIcon(entry.item))
	else
		button:SetAttribute("type", "click")
		button:SetAttribute("clickbutton", _G[entry.button])
		button.Icon:SetTexture(entry.icon)
	end
end

local function Layout(count)
	local size = C.QoL.ReminderSize or 36
	local width = count > 0 and (count * size + (count - 1) * SPACING) or size
	holder:SetSize(width, size)
	for i = 1, count do
		local button = buttons[i]
		button:ClearAllPoints()
		button:SetPoint("LEFT", holder, "LEFT", (i - 1) * (size + SPACING), 0)
	end
end

-- ---------------------------------------------------------------------------
-- Refresh
-- ---------------------------------------------------------------------------

local function Blocked()
	return UnitIsDeadOrGhost("player") or IsMounted() or UnitOnTaxi("player")
end

local function Refresh()
	if not holder or InCombatLockdown() then
		return
	end
	wipe(wanted)
	if not Blocked() then
		local cfg = C.QoL
		if cfg.ReminderBuffs ~= false then
			CollectBuffs()
		end
		if cfg.ReminderWeapons ~= false then
			CollectWeapons()
		end
		if cfg.ReminderPet ~= false then
			CollectPet()
		end
		if cfg.ReminderTalents ~= false then
			CollectTalents()
		end
	end

	for i, entry in ipairs(wanted) do
		local button = buttons[i] or CreateButton(i)
		Assign(button, entry)
		button:Show()
	end
	for i = #wanted + 1, #buttons do
		buttons[i].entry = nil
		buttons[i]:Hide()
	end
	Layout(#wanted)
	holder:SetShown(#wanted > 0)
end

-- Aura and bag events come in bursts, so one refresh covers a whole burst.
local queued = false
local function QueueRefresh()
	if queued then
		return
	end
	queued = true
	C_Timer_After(REFRESH_DELAY, function()
		queued = false
		Refresh()
	end)
end

local function OnUnitEvent(_, _, unit)
	if unit == "player" or unit == "pet" then
		QueueRefresh()
	end
end

local function OnSpellcast(_, _, unit, _, spellID)
	if unit == "player" and DEMON_SET[spellID] then
		lastDemon = spellID
	end
end

-- Hidden before lockdown starts, which is the last moment a frame holding
-- secure buttons can still be hidden.
local function OnCombatStart()
	if holder then
		holder:Hide()
	end
end

-- For the per-type toggles, which apply without a reload.
function Module:RefreshReminders()
	QueueRefresh()
end

function Module:SetupReminders()
	if holder then
		return
	end
	local size = C.QoL.ReminderSize or 36
	holder = CreateFrame("Frame", "KKUI_Reminders", UIParent)
	holder:SetSize(size, size)
	holder:Hide()
	K.CreateMover(holder, "Reminders", L["Reminders"], { "BOTTOM", UIParent, "BOTTOM", 0, 320 }, size * 4 + SPACING * 3, size)

	local refresh = function()
		QueueRefresh()
	end
	for _, event in ipairs({
		"PLAYER_ENTERING_WORLD",
		"PLAYER_REGEN_ENABLED",
		"WEAPON_ENCHANT_CHANGED",
		"BAG_UPDATE_DELAYED",
		"PLAYER_LEVEL_UP",
		"SPELLS_CHANGED",
		"PLAYER_MOUNT_DISPLAY_CHANGED",
		"PLAYER_CONTROL_GAINED",
		"PLAYER_CONTROL_LOST",
		"PLAYER_ALIVE",
		"PLAYER_UNGHOST",
		"PLAYER_DEAD",
		"TRAIT_CONFIG_UPDATED",
	}) do
		self:RegisterEvent(event, refresh)
	end
	-- Player and pet changes, filtered by the game so other units never reach us.
	-- The pet's own health tells us when it dies.
	local valid = C_EventUtils and C_EventUtils.IsEventValid
	for _, event in ipairs({ "UNIT_AURA", "UNIT_INVENTORY_CHANGED", "UNIT_PET", "UNIT_HAPPINESS" }) do
		if not valid or valid(event) then
			self:RegisterUnitEvent(event, OnUnitEvent, "player", "pet")
		end
	end
	self:RegisterUnitEvent("UNIT_HEALTH", QueueRefresh, "pet")
	self:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", OnSpellcast, "player")
	self:RegisterEvent("PLAYER_REGEN_DISABLED", OnCombatStart)
end
