--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/History.lua
	Purpose:
		Keep recent player chat across a reload or relog. We capture the finished
		line as it reaches the chat frame (player links, class colours, and channel
		prefix already in it), save it per character, and replay it under a quiet
		divider the next time you log in.

		Kept safe for Midnight: a secret line is never stored, capture only keeps
		real player chat (lines that carry a player link, so system and loot spam
		stay out), and replay only writes to the chat frame through AddMessage, so
		no protected or secret path is ever touched. Restore is skipped where the
		client has forced addon chat restrictions.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Chat")

local _G = _G
local ipairs = ipairs
local next = next
local type = type
local wipe = wipe
local tremove = table.remove
local UnitName = UnitName
local GetRealmName = GetRealmName
local GetServerTime = GetServerTime
local GetCVarBool = GetCVarBool
local IsSecret = K.IsSecret

local NUM_FRAMES = Constants.ChatFrameConstants.MaxChatWindows
local MAX_LINES = 100 -- how many lines we keep per character
local MAX_AGE = 60 * 60 * 24 * 3 -- drop anything older than three days on restore
local MAX_TEXT = 4096

local buffer = {}
local restoring = false -- replayed lines must not be captured again

local function CharKey()
	local name = UnitName("player")
	local realm = GetRealmName()
	if not name or not realm then
		return nil
	end
	return name .. " - " .. realm
end

-- Only keep genuine player chat: those lines carry a player or Battle.net link.
-- System, loot, and combat text do not, so this keeps the log clean on its own.
local function IsPlayerChat(text)
	return text:find("|Hplayer:", 1, true) or text:find("|HBNplayer:", 1, true)
end

local function Capture(frame, text, _, _, _, _, _, _, event)
	if restoring or not C.Chat.HistoryPersist then
		return
	end
	-- Opening a whisper window copies the conversation in without the chat event.
	-- Those lines were captured when they first arrived.
	if frame.isTemporary and not event then
		return
	end
	if type(text) ~= "string" or IsSecret(text) or #text > MAX_TEXT then
		return
	end
	if not IsPlayerChat(text) then
		return
	end
	local now, id = GetServerTime(), frame:GetID()
	-- A line shown in two windows reaches here once per window. Player lines carry a
	-- per-line ID in their link, so the same text in the same second is that line
	-- again, not a repeat. It is kept once and remembers every window it went to.
	local last = buffer[#buffer]
	if last and last.text == text and last.t == now and last.f ~= id then
		local also = last.also
		if not also then
			also = {}
			last.also = also
		end
		for _, seen in ipairs(also) do
			if seen == id then
				return
			end
		end
		also[#also + 1] = id
		return
	end
	buffer[#buffer + 1] = { text = text, t = now, f = id }
	if #buffer > MAX_LINES then
		tremove(buffer, 1)
	end
end

-- Replay the saved lines under a divider so it is clear where the old session
-- ends and the live one begins. Each line goes back to the window it came from,
-- so whispers return to the whisper tab and not into General. Lines saved before
-- the window was recorded go to the main window. The lines that are still fresh
-- seed the buffer with their original times, so a line ages out three days after
-- it was said rather than three days after it was last replayed.
local function Restore(saved)
	if not saved or #saved == 0 then
		return
	end
	if GetCVarBool and GetCVarBool("addonChatRestrictionsForced") then
		return
	end

	local now = GetServerTime()
	local dividers = {}
	local printed = {}
	restoring = true
	for _, line in ipairs(saved) do
		if type(line) == "table" and type(line.text) == "string" and not IsSecret(line.text) then
			if not line.t or (now - line.t) < MAX_AGE then
				-- A whisper tab is gone after a reload, so its lines fall back to the
				-- main window, and a line never prints twice in one window.
				wipe(printed)
				local id = line.f
				local count = 1 + (type(line.also) == "table" and #line.also or 0)
				for n = 1, count do
					if n > 1 then
						id = line.also[n - 1]
					end
					local frame = type(id) == "number" and _G["ChatFrame" .. id] or _G.ChatFrame1
					if frame and not printed[frame] then
						printed[frame] = true
						if not dividers[frame] then
							dividers[frame] = true
							frame:AddMessage(" ")
							local muted = K.Colors.muted
							frame:AddMessage(K.ColorText("accent", (K.Title or "KkthnxUI") .. ":") .. " previous chat", muted[1], muted[2], muted[3])
						end
						frame:AddMessage(line.text)
					end
				end
				if next(printed) then
					buffer[#buffer + 1] = line
				end
			end
		end
	end
	restoring = false

	while #buffer > MAX_LINES do
		tremove(buffer, 1)
	end
end

local active = false

-- Record what one window prints. Called from setup for the windows that exist and
-- from StyleFrame for ones opened later, so a new tab is captured too. The Combat
-- Log is never passed in.
function Module:HookHistoryFrame(frame)
	if not active or frame.KKUI_HistoryHooked or not frame.AddMessage then
		return
	end
	frame.KKUI_HistoryHooked = true
	hooksecurefunc(frame, "AddMessage", Capture)
end

function Module:SetupHistory()
	if not C.Chat.HistoryPersist then
		return
	end
	if type(_G.KkthnxUIDB) ~= "table" then
		return
	end
	_G.KkthnxUIDB.chatHistory = _G.KkthnxUIDB.chatHistory or {}

	local key = CharKey()
	if not key then
		return
	end

	-- Capture the line as each frame prints it. The hook gets the same arguments the
	-- frame did, before our own AddMessage wrappers reshape the text, which is what
	-- we want: the replay goes back through those wrappers.
	active = true
	for i = 1, NUM_FRAMES do
		local frame = _G["ChatFrame" .. i]
		if frame and i ~= 2 then
			self:HookHistoryFrame(frame)
		end
	end

	-- Replay last session. The fresh lines land in the buffer, so the next logout
	-- keeps a rolling window rather than resetting it.
	local saved = _G.KkthnxUIDB.chatHistory[key]
	if saved then
		Restore(saved)
	end

	-- Persist on logout and reload.
	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("PLAYER_LOGOUT")
	watcher:SetScript("OnEvent", function()
		if C.Chat.HistoryPersist then
			_G.KkthnxUIDB.chatHistory[key] = buffer
		end
	end)
end
