--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/MoveFrames.lua
	Purpose:
		Drag Blizzard's windows out of the way for as long as you need them.

		Nothing is saved. A dragged window stays where it was dropped until
		Blizzard's panel layout places it again, which happens when it or another
		managed window opens or closes. That is deliberate. The window stays part
		of the panel system, so Escape, panel pushing and Blizzard's own layout
		keep working, and no layout attribute is ever written onto a Blizzard
		frame.

		How a drag reaches the window. A press lands on whatever frame under the
		cursor takes the mouse. For most windows that is the window itself around
		its edges and title. Some are covered by a full size child (the character
		pane, the reputation list), so that child is hooked too and moves its
		window. Interactive children such as lists and buttons keep their clicks.

		Rules kept on Blizzard frames:
			- Only HookScript, never SetScript, so their own handlers still run.
			- No fields written on them. Our state lives in weak tables.
			- Nothing is touched in combat. A protected window is never moved in
			  combat, and frames that arrive in combat are hooked once it ends.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("MoveFrames")

local InCombatLockdown = InCombatLockdown
local pairs = pairs
local setmetatable = setmetatable
local strgmatch = string.gmatch
local type = type

-- Frame to hook -> what it moves.
--   true      the frame moves itself
--   "parent"  the frame moves its parent
--   "Path"    the frame moves the named frame ("Name" or "Name.key.key")
--
-- Every name here was confirmed to exist in the Forever client on 2026-11-16 by
-- loading its Blizzard addon and resolving it. Retail windows whose addon the
-- client refuses to load (the dungeon finder, Encounter Journal, keystones, PvP
-- queue, landing page) are not listed, and neither is the retail stable or
-- profession book, which Forever does not create. The list is walked again as
-- each Blizzard addon loads, so load on demand windows are picked up then.
--
-- Left out on purpose
--   World map and Edit Mode place themselves.
--   Bank and loot windows are replaced by our bags and loot modules.
--   Death Recap and the stopwatch already drag on their own.
--   Barber shop and player choice are full screen.
--
-- Collections, talents and spellbook, professions and transmog are protected
-- frames on Forever. They are listed, and OnMouseDown refuses them in combat.
local FRAMES = {
	-- Always loaded
	AddonList = true,
	ChannelFrame = true,
	ChatConfigFrame = true,
	CharacterFrame = true,
	PaperDollFrame = "parent",
	ReputationFrame = "parent",
	TokenFrame = "parent",
	CurrencyTransferMenu = true,
	DressUpFrame = true,
	FriendsFrame = true,
	GossipFrame = true,
	GuildInviteFrame = true,
	GuildRegistrarFrame = true,
	HelpFrame = true,
	ItemTextFrame = true,
	LFGParentFrame = true,
	MailFrame = true,
	SendMailFrame = "parent",
	OpenMailFrame = true,
	MerchantFrame = true,
	ModelPreviewFrame = true,
	PetitionFrame = true,
	PetStableFrame = true,
	PVPMatchResults = true,
	PVPMatchScoreboard = true,
	QuestFrame = true,
	QuestLogPopupDetailFrame = true,
	RaidParentFrame = true,
	SettingsPanel = true,
	SocialUIFrame = true,
	SplashFrame = true,
	StackSplitFrame = true,
	TabardFrame = true,
	TaxiFrame = true,
	TimeManagerFrame = true,
	TradeFrame = true,
	TutorialFrame = true,

	-- Communities, loaded at login on Forever
	CommunitiesFrame = true,
	CommunitiesGuildLogFrame = true,
	CommunitiesGuildNewsFiltersFrame = true,
	CommunitiesGuildTextEditFrame = true,
	GuildControlUI = true,

	-- Load on demand
	AchievementFrame = true,
	["AchievementFrame.Header"] = "AchievementFrame",
	AlliedRacesFrame = true,
	ArchaeologyFrame = true,
	AuctionHouseFrame = true,
	BlackMarketFrame = true,
	CalendarFrame = true,
	CalendarCreateEventFrame = true,
	ClassTrainerFrame = true,
	ClickBindingFrame = true,
	CollectionsJournal = true,
	CooldownViewerSettings = true,
	FlightMapFrame = true,
	GenericTraitFrame = true,
	GuideFrame = true,
	GuildBankFrame = true,
	InspectFrame = true,
	InspectRecipeFrame = true,
	ItemInteractionFrame = true,
	ItemSocketingFrame = true,
	ItemUpgradeFrame = true,
	MacroFrame = true,
	PlayerSpellsFrame = true,
	ProfessionsCustomerOrdersFrame = true,
	ProfessionsFrame = true,
	ScrappingMachineFrame = true,
	TransmogFrame = true,
	WeeklyRewardsFrame = true,
}

local hooked = {} -- names already hooked, so a rescan skips them
local targetOf = setmetatable({}, { __mode = "k" }) -- hooked frame -> window it moves
local watched = setmetatable({}, { __mode = "k" }) -- windows with a hide hook
local dragging -- the window being dragged, if any

-- Resolve "Name" or "Name.key.key" without creating anything along the way.
local function Resolve(path)
	local frame
	for part in strgmatch(path, "[^%.]+") do
		if frame == nil then
			frame = _G[part]
		elseif type(frame) == "table" then
			frame = frame[part]
		else
			return nil
		end
		if frame == nil then
			return nil
		end
	end
	if type(frame) == "table" and frame.GetObjectType then
		return frame
	end
end

local function StopDrag()
	local frame = dragging
	if not frame then
		return
	end
	dragging = nil
	frame:StopMovingOrSizing()
	-- StartMoving marks the window as user placed, which would make the client
	-- write it to layout-cache.txt and restore it next session. This feature
	-- deliberately forgets, so take the mark off again.
	frame:SetUserPlaced(false)
end

local function OnMouseDown(source, button)
	if button ~= "LeftButton" or dragging then
		return
	end
	local frame = targetOf[source]
	if not frame or (InCombatLockdown() and frame:IsProtected()) then
		return
	end
	dragging = frame
	frame:StartMoving()
end

local function OnMouseUp(_, button)
	if button == "LeftButton" then
		StopDrag()
	end
end

-- A window that closes mid drag never sees the mouse come back up.
local function OnTargetHide(frame)
	if dragging == frame then
		StopDrag()
	end
end

local function Hook(name, spec)
	local source = Resolve(name)
	if not source then
		return
	end

	local target
	if spec == true then
		target = source
	elseif spec == "parent" then
		target = source:GetParent()
	else
		target = Resolve(spec)
	end
	if not target or target == UIParent then
		return
	end

	hooked[name] = true
	targetOf[source] = target

	target:SetMovable(true)
	target:SetClampedToScreen(true)
	source:EnableMouse(true)
	source:HookScript("OnMouseDown", OnMouseDown)
	source:HookScript("OnMouseUp", OnMouseUp)

	if not watched[target] then
		watched[target] = true
		target:HookScript("OnHide", OnTargetHide)
	end
end

local function Scan()
	-- EnableMouse and SetMovable on a protected frame are blocked in combat.
	-- Try again once it ends rather than hook half a window now.
	if InCombatLockdown() then
		K.DeferCombat("MoveFramesScan", Scan)
		return
	end
	for name, spec in pairs(FRAMES) do
		if not hooked[name] then
			Hook(name, spec)
		end
	end
end

function Module:ADDON_LOADED(_, addon)
	-- Only Blizzard's own addons bring windows from the list.
	if type(addon) == "string" and addon:find("^Blizzard_") then
		Scan()
	end
end

function Module:OnEnable()
	if not C.Misc.MoveFrames then
		return
	end

	Scan()
	self:RegisterEvent("ADDON_LOADED", "ADDON_LOADED")
end

-- Exposed for testing from the chat box. Names in the list that resolve to a
-- frame right now but are not hooked, which points at a broken entry.
function Module:Unhooked()
	local list = {}
	for name in pairs(FRAMES) do
		if not hooked[name] and Resolve(name) then
			list[#list + 1] = name
		end
	end
	return list
end
