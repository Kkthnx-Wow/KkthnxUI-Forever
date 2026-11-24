--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/Filter.lua
	Purpose:
		A light spam filter: drop a message that is identical to one the same
		author sent in the public channels within the last half minute. Only the
		noisy public channels are filtered so guild, party, and whispers are never
		touched.

		Separately, an option hides the "attempts to run away in fear!" emote
		creatures send when they flee at low health.
-----------------------------------------------------------------------------]]

local K, L = KkthnxUI[1], KkthnxUI[3]

local Module = K:GetModule("Chat")

local ipairs = ipairs
local pairs = pairs
local wipe = wipe
local GetTime = GetTime
local UnitName = UnitName
local Ambiguate = Ambiguate
local IsSecret = K.IsSecret

local FILTER_EVENTS = {
	"CHAT_MSG_CHANNEL",
	"CHAT_MSG_SAY",
	"CHAT_MSG_YELL",
}

local WINDOW = 30 -- seconds a message counts as a repeat

function Module:EnableFilter()
	local seen = {}
	-- Blizzard runs every filter once per chat window that shows the event, so a
	-- line shown in two windows reaches this function twice. Without a memory of the
	-- first answer the second window would see its own sibling as a repeat and drop
	-- the line. The verdict is kept per line ID so every window gets the same one.
	local verdicts = {}
	local lastSweep = 0
	local player = UnitName("player")

	local function RepeatFilter(_, _, msg, author, _, _, _, _, _, _, _, _, lineID)
		-- Never touch a secret string (cannot be keyed or compared) or your own
		-- messages, so what you send is always shown even if you repeat it.
		if not msg or not author or IsSecret(msg) or IsSecret(author) then
			return false
		end
		if player and (author == player or Ambiguate(author, "short") == player) then
			return false
		end

		if lineID and verdicts[lineID] ~= nil then
			return verdicts[lineID]
		end

		local now = GetTime()

		-- Sweep expired keys now and then so the tables do not grow all session.
		if now - lastSweep > WINDOW then
			lastSweep = now
			for key, stamp in pairs(seen) do
				if now - stamp >= WINDOW then
					seen[key] = nil
				end
			end
			wipe(verdicts)
		end

		local key = author .. "\001" .. msg
		local repeated = seen[key] and (now - seen[key]) < WINDOW or false
		-- A repeat restarts the window too, so a line spammed every 20 seconds stays
		-- hidden instead of slipping through once each window.
		seen[key] = now
		if lineID then
			verdicts[lineID] = repeated
		end
		return repeated
	end

	for _, event in ipairs(FILTER_EVENTS) do
		ChatFrameUtil.AddMessageEventFilter(event, RepeatFilter)
	end
end

-- Creature emotes arrive with a literal %s where the name goes, and the chat
-- frame fills it in later, so the flee line is one fixed string to match.
-- Other locales can add their own text under this key. Read when the filter is
-- enabled, after every locale file has loaded.
local flee

local function FleeFilter(_, _, msg)
	if not msg or IsSecret(msg) then
		return false
	end
	return msg == flee
end

function Module:EnableFleeFilter()
	flee = L["%s attempts to run away in fear!"]
	ChatFrameUtil.AddMessageEventFilter("CHAT_MSG_MONSTER_EMOTE", FleeFilter)
end
