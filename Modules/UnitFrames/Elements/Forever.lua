--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/UnitFrames/Elements/Forever.lua
	Purpose:
		The pieces of the unit frames that only exist on WoW Forever: the shaman
		totem row, the PvP flag icon and the hunter pet mood. The swing bars are
		in Modules/Misc/SwingTimer.lua.

		Each one is a thin skin over an oUF element. oUF owns the events and the
		game queries, so these builders only create the widgets, give them our
		bar texture, background and border, and park them on the frame's stacks.

		The totems fade to nothing while a slot is empty, so they take no room
		from the frame when they have nothing to say.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("UnitFrames")
local Build = Module.Build

local CreateFrame = CreateFrame

-- ---------------------------------------------------------------------------
-- Shaman totems
-- ---------------------------------------------------------------------------

local TOTEM_SIZE = 26
local TOTEM_SLOTS = 4

-- Four icons under the frame, spread across its width. Slots are filled in the
-- element's own priority order, so earth, fire, water and air always land in the
-- same place instead of shuffling as totems are dropped.
function Build.Totems(self)
	if K.Class ~= "SHAMAN" or not C.Unitframe.Player.Totems then
		return
	end

	local holder = CreateFrame("Frame", nil, self)
	Module.StackDown(self, holder, TOTEM_SIZE)

	local totems = {}
	for i = 1, TOTEM_SLOTS do
		local totem = CreateFrame("Button", nil, holder)
		totem:SetSize(TOTEM_SIZE, TOTEM_SIZE)
		totem:SetPoint("LEFT", holder, "LEFT", (i - 1) * (TOTEM_SIZE + Module.GAP), 0)
		K.CreateBackground(totem, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.9)
		K.CreateBorder(totem)

		local icon = totem:CreateTexture(nil, "ARTWORK")
		icon:SetPoint("TOPLEFT", 1, -1)
		icon:SetPoint("BOTTOMRIGHT", -1, 1)
		icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		totem.Icon = icon

		local cooldown = CreateFrame("Cooldown", nil, totem, "CooldownFrameTemplate")
		cooldown:SetAllPoints(icon)
		cooldown:SetHideCountdownNumbers(false)
		K.StyleCooldownSwipe(cooldown)
		totem.Cooldown = cooldown

		totems[i] = totem
	end

	self.TotemHolder = holder
	self.Totems = totems
end

-- ---------------------------------------------------------------------------
-- PvP flag
-- ---------------------------------------------------------------------------

-- The faction or free for all badge beside the portrait, on the outer side so it
-- never covers the frame. oUF picks the art and shows it only while flagged.
function Build.PvPIndicator(self, side)
	local cfg = C.Unitframe[self.mystyle == "player" and "Player" or "Target"]
	if cfg and cfg.PvPIcon == false then
		return
	end

	local anchor = self.Portrait or self.Health
	local icon = self:CreateTexture(nil, "OVERLAY")
	icon:SetSize(26, 26)
	if side == "left" then
		icon:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
	else
		icon:SetPoint("LEFT", anchor, "RIGHT", 4, 0)
	end

	self.PvPIndicator = icon
	return icon
end

-- ---------------------------------------------------------------------------
-- Hunter pet mood
-- ---------------------------------------------------------------------------

-- Happy, content or unhappy, shown on a hunter's pet only. oUF hides it for every
-- other unit and class, so the builder can be called for any pet frame.
function Build.PetHappiness(self)
	if K.Class ~= "HUNTER" or C.Unitframe.Pet.Happiness == false then
		return
	end

	local icon = self.Health:CreateTexture(nil, "OVERLAY")
	icon:SetSize(14, 14)
	icon:SetPoint("RIGHT", self.Health, "RIGHT", -2, 0)

	self.Happiness = icon
	return icon
end
