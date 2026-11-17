--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Automation/Gossip.lua
	Purpose:
		Click through a lone gossip option so single-step NPCs do not need a second
		click. Skipped when the NPC is a quest giver, a taxi node, or inside a raid,
		and for an option the game shows as locked or unavailable. A short chain is
		followed, but never more than a few pages or the same option twice, so an
		NPC that loops back to itself cannot keep clicking.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Automation")

local IsSecret = K.IsSecret
local C_GossipInfo = C_GossipInfo
local C_PlayerInteractionManager = C_PlayerInteractionManager
local Enum = Enum
local GetInstanceInfo = GetInstanceInfo
local GetTime = GetTime

local MAX_SKIPS = 3
-- Pages picked closer together than this count as one chain. A timer rather
-- than GOSSIP_CLOSED, since the game may close and reopen between pages.
local CHAIN_WINDOW = 2
local AVAILABLE = Enum.GossipOptionStatus and Enum.GossipOptionStatus.Available or 0

-- Pages skipped in the current chain, the option picked last, and when.
local skipCount, lastOptionID, lastSkipTime = 0, nil, 0

-- Called from the gossip handler, after it found no quest to pick.
function Module:HandleGossipSkip()
	if not C.AutoQuest.SkipGossip then
		return
	end

	-- Leave taxi nodes to the flight-map, never auto-click those.
	if C_PlayerInteractionManager and C_PlayerInteractionManager.IsInteractingWithNpcOfType and Enum.PlayerInteractionType then
		if C_PlayerInteractionManager.IsInteractingWithNpcOfType(Enum.PlayerInteractionType.TaxiNode) then
			return
		end
	end

	-- A quest giver whose quests were left alone: let you read them.
	if (C_GossipInfo.GetNumActiveQuests() + C_GossipInfo.GetNumAvailableQuests()) > 0 then
		return
	end

	local options = C_GossipInfo.GetOptions()
	if not options or #options ~= 1 then
		return
	end

	local option = options[1]
	local optionID = option.gossipOptionID
	if not optionID or IsSecret(optionID) then
		return
	end
	local status = option.status
	if status ~= nil and (IsSecret(status) or status ~= AVAILABLE) then
		return
	end

	-- Inside a raid a lone option is often a story or pull trigger, so leave it.
	local _, instanceType = GetInstanceInfo()
	if instanceType == "raid" then
		return
	end

	local now = GetTime()
	if now - lastSkipTime > CHAIN_WINDOW then
		skipCount, lastOptionID = 0, nil
	end
	if skipCount >= MAX_SKIPS or optionID == lastOptionID then
		return
	end
	skipCount = skipCount + 1
	lastOptionID = optionID
	lastSkipTime = now

	C_GossipInfo.SelectOption(optionID)
end

function Module:SetupGossip()
	-- No event of its own: HandleGossipSkip runs from the gossip handler in Accept.lua.
end
