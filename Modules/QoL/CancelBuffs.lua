--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/CancelBuffs.lua
	Purpose:
		Take off buffs you never want, such as a holiday costume or the shrink
		and slow fall from Noggenfogger Elixir, the moment they land on you. The
		list is spell IDs you set in the options. /kk buffs prints the buffs you
		have now with their IDs, so a new one is easy to add.

		Cancelling a buff is blocked in combat, so a listed buff that lands
		during a fight comes off as soon as it ends.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local _G = _G
local gmatch = string.gmatch
local tonumber = tonumber
local wipe = wipe

local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local CancelUnitBuff = _G.CancelUnitBuff
local IsSecret = K.IsSecret

-- Buffs a player has at once stay well under this.
local MAX_BUFFS = 40

local unwanted = {}

local function ReadList()
	wipe(unwanted)
	for id in gmatch(C.QoL.CancelBuffList or "", "%d+") do
		unwanted[tonumber(id)] = true
	end
end

-- Walk the buffs backwards, since removing one moves the ones after it down.
local function CancelListed()
	for index = MAX_BUFFS, 1, -1 do
		local aura = K.GetAuraData("player", index, "HELPFUL")
		if aura then
			local spellID = aura.spellId
			if spellID and not IsSecret(spellID) and unwanted[spellID] then
				CancelUnitBuff("player", index, "HELPFUL")
			end
		end
	end
end

local function Sweep()
	if InCombatLockdown() then
		K.DeferCombat("CancelBuffs", Sweep)
		return
	end
	CancelListed()
end

-- Only sweep when an added buff is on the list, or when the game sends the
-- whole set again. Most aura updates are other buffs ticking.
local function OnAura(_, _, _, info)
	if not info or info.isFullUpdate then
		Sweep()
		return
	end
	local added = info.addedAuras
	if not added then
		return
	end
	for i = 1, #added do
		local spellID = added[i].spellId
		if spellID and not IsSecret(spellID) and unwanted[spellID] then
			Sweep()
			return
		end
	end
end

-- Called by the options when the list is edited.
function Module:RefreshCancelBuffs()
	ReadList()
	if C.QoL.CancelBuffs then
		Sweep()
	end
end

-- /kk buffs. Each current buff with its spell ID.
function Module:PrintBuffs()
	local found = false
	for index = 1, MAX_BUFFS do
		local aura = K.GetAuraData("player", index, "HELPFUL")
		if not aura then
			break
		end
		local spellID, name = aura.spellId, aura.name
		if spellID and not IsSecret(spellID) and name and not IsSecret(name) then
			K.Print(name .. "  " .. K.ColorText("muted", spellID))
			found = true
		end
	end
	if not found then
		K.Print(L["You have no buffs to list."])
	end
end

function Module:SetupCancelBuffs()
	if not CancelUnitBuff then
		return
	end
	ReadList()
	-- A frame of its own. The module keeps one unit event frame per event, and
	-- registering it for the player alone would drop the pet that Reminders
	-- listens to on the same event.
	local watcher = CreateFrame("Frame")
	watcher:RegisterUnitEvent("UNIT_AURA", "player")
	watcher:SetScript("OnEvent", OnAura)
	Sweep()
end
