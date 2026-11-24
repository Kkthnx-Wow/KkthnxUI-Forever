--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Tooltip/Inspect.lua
	Purpose:
		Add an average item level line for players on the unit tooltip. Inspect
		data arrives asynchronously, so results are cached per GUID. While a
		request is out the line reads as loading, and that same line is rewritten
		when the answer comes, so a late reply never stacks a second line.

		Every NotifyInspect is a packet to the server, and servers disconnect
		clients that send them too fast. So a request is only sent once the mouse
		has rested on a player for a moment, never closer than INSPECT_LOCKOUT to
		any other inspect (ours or another addon's), never while the Blizzard
		inspect window is open, and a player who did not answer is not asked again
		for RETRY_AFTER seconds.

		The average itself comes from Core/ItemLevel.lua, which falls back to the
		item links when the game's own inspect average is not readable.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local Module = K:GetModule("Tooltip")

local _G = _G
local format = string.format
local tostring = tostring
local CreateFrame = CreateFrame
local GetTime = GetTime
local InCombatLockdown = InCombatLockdown
local UnitGUID = UnitGUID
local UnitIsUnit = UnitIsUnit
local hooksecurefunc = hooksecurefunc
local IsSecret = K.IsSecret
local CanInspect = _G.CanInspect
local NotifyInspect = _G.NotifyInspect
local ClearInspectPlayer = _G.ClearInspectPlayer
local GetAverageItemLevel = _G.GetAverageItemLevel
local C_Timer = C_Timer

-- The mouse must rest on a player this long before an inspect is sent.
local SETTLE_DELAY = 0.5
-- Minimum gap between any two inspect requests.
local INSPECT_LOCKOUT = 3
-- How long to wait for INSPECT_READY before giving up on a request.
local REPLY_TIMEOUT = 5
-- A player who did not answer is left alone this long.
local RETRY_AFTER = 30
-- Resolved item levels are reused this long, and the cache is capped.
local CACHE_TTL = 900
local CACHE_MAX = 200
-- INSPECT_READY can come before every link is in. A partial reply is read
-- again as the missing items load (or after this wait when none can be
-- loaded), this many times, before the request counts as failed.
local PARTIAL_DELAY = 0.5
local PARTIAL_TRIES = 5

local LABEL = (_G.STAT_AVERAGE_ITEM_LEVEL or "Item Level") .. ":"
local LOADING = _G.SEARCH_LOADING_TEXT or "Loading..."
local UNKNOWN = _G.UNKNOWN or "Unknown"
local LEFT_LINE = "GameTooltipTextLeft"

-- guid -> { ilvl, time }
local cache, cacheCount = {}, 0
-- guid -> time of the last unanswered request.
local failed, failedCount = {}, 0
-- The GUID we are currently waiting on, and the unit token that produced it.
local pending, pendingUnit
-- The GUID the currently shown tooltip was rendered for. Stamped as we add our
-- line, so a late INSPECT_READY can confirm the tooltip is still the same unit
-- without calling UnitGUID on the secret token GameTooltip:GetUnit() hands back.
local shownGUID
-- Our line on the shown tooltip, the GUID it was written for and its exact
-- text. Tooltip lines are reused, so the text match proves it is still ours.
local line, lineGUID, lineText
-- Time of the last NotifyInspect from anyone, a token for the settle timer and
-- the GUID that timer is for. A unit tooltip is rebuilt several times a second
-- while hovered, so a rebuild for the same player must not restart the timer.
local lastInspect = 0
local settleToken = 0
local settleGUID
local tooltipInspecting

-- Off unless switched on with /kkdebug ilvl. Secrets are logged as such.
local stream = K.Debug.Register("ilvl", "Tooltip and inspect window item level steps")
local function V(value)
	if IsSecret(value) then
		return "<secret>"
	end
	return tostring(value)
end

-- ---------------------------------------------------------------------------
-- The tooltip line
-- ---------------------------------------------------------------------------

-- "Item Level: 58.4", the label muted and the value in the highlight colour
-- like the other labelled lines. Blizzard already prints class and level.
local function LineText(value)
	return K.ColorText("muted", LABEL) .. " " .. K.ColorText("highlight", value)
end

local function FormatLevel(level)
	return format("%.1f", level)
end

local function AddLine(tt, guid, value)
	local text = LineText(value)
	tt:AddLine(text)
	line = _G[LEFT_LINE .. tt:NumLines()]
	lineGUID, lineText = guid, text
end

-- Put a late result on the tooltip, if it still shows that player. Our loading
-- line is rewritten in place. Without it, a real value is appended and a
-- failure is simply dropped.
local function PatchLine(guid, value, append)
	local tt = _G.GameTooltip
	if not tt:IsShown() or shownGUID ~= guid then
		return
	end
	if line and lineGUID == guid then
		local current = line:GetText()
		stream:Log("patch %s value=%s current=%s ours=%s", guid, V(value), V(current), V(lineText))
		if not IsSecret(current) and current == lineText then
			lineText = LineText(value)
			line:SetText(lineText)
			tt:Show()
			return
		end
	end
	if append then
		AddLine(tt, guid, value)
		tt:Show()
	end
end

-- ---------------------------------------------------------------------------
-- Cache
-- ---------------------------------------------------------------------------

local function Store(guid, ilvl)
	if not cache[guid] then
		if cacheCount >= CACHE_MAX then
			-- Bounded: drop everything rather than track ages for a tooltip nicety.
			cache, cacheCount = {}, 0
		end
		cacheCount = cacheCount + 1
	end
	cache[guid] = { ilvl = ilvl, time = GetTime() }
end

local function Forget(guid)
	if cache[guid] then
		cache[guid] = nil
		cacheCount = cacheCount - 1
	end
end

local function MarkFailed(guid)
	if failedCount >= CACHE_MAX then
		failed, failedCount = {}, 0
	end
	if not failed[guid] then
		failedCount = failedCount + 1
	end
	failed[guid] = GetTime()
end

local function ClearFailed(guid)
	if failed[guid] then
		failed[guid] = nil
		failedCount = failedCount - 1
	end
end

-- ---------------------------------------------------------------------------
-- Inspect requests
-- ---------------------------------------------------------------------------

-- True while the Blizzard inspect window owns the inspect target.
local function InspectWindowOpen()
	return _G.InspectFrame and _G.InspectFrame:IsShown()
end

local function GiveUp(guid)
	PatchLine(guid, UNKNOWN, false)
end

-- Send the request, if every guard still holds by the time the timer fires.
local function TryInspect(token, guid, unit)
	stream:Log("try %s token=%d/%d shown=%s pending=%s", guid, token, settleToken, V(shownGUID), V(pending))
	if token ~= settleToken then
		return
	end
	-- Every way out below ends this timer, except the retry that sets it again.
	settleGUID = nil
	local tt = _G.GameTooltip
	if shownGUID ~= guid or not tt:IsShown() then
		return
	end
	if InCombatLockdown() or InspectWindowOpen() then
		GiveUp(guid)
		return
	end

	-- Another request is in flight or one was sent moments ago. Try again once
	-- it is safe, for as long as the mouse stays on this player.
	local now = GetTime()
	local wait = pending and INSPECT_LOCKOUT or (lastInspect + INSPECT_LOCKOUT - now)
	if wait > 0 then
		settleGUID = guid
		C_Timer.After(wait, function()
			TryInspect(token, guid, unit)
		end)
		return
	end

	-- The token may now point at someone else, or at a unit we cannot read.
	local current = UnitGUID(unit)
	if not current or IsSecret(current) or current ~= guid or not (CanInspect and CanInspect(unit)) then
		GiveUp(guid)
		return
	end

	stream:Log("send %s unit=%s", guid, V(unit))
	pending, pendingUnit = guid, unit
	MarkFailed(guid)
	tooltipInspecting = true
	NotifyInspect(unit)
	tooltipInspecting = nil
	lastInspect = now

	-- Without a reply the request is abandoned so the next hover can try later.
	C_Timer.After(REPLY_TIMEOUT, function()
		if pending == guid then
			pending, pendingUnit = nil, nil
			GiveUp(guid)
		end
	end)
end

-- Leave the target alone when the Blizzard inspect window is using it.
local function Release()
	if ClearInspectPlayer and not InspectWindowOpen() then
		ClearInspectPlayer()
	end
end

local function Finish(guid, level)
	if not level or level <= 0 then
		GiveUp(guid)
		return
	end
	ClearFailed(guid)
	Store(guid, level)
	PatchLine(guid, FormatLevel(level), true)
end

-- Read the reply. The links are copied before the target is released, so items
-- that still have to load are waited on without holding the inspect.
local function Resolve(guid, unit, tries)
	local current = UnitGUID(unit)
	if not current or IsSecret(current) or current ~= guid then
		Release()
		GiveUp(guid)
		return
	end

	local links = {}
	local level, reason = K.GetInspectAverage(unit, links)
	stream:Log("resolve %s try=%d level=%s reason=%s", guid, tries, V(level), V(reason))
	if reason == "partial" and tries < PARTIAL_TRIES then
		-- Hold the target while the missing items load, then read again.
		local function Again()
			Resolve(guid, unit, tries + 1)
		end
		if not K.LoadMissingGear(unit, Again) then
			C_Timer.After(PARTIAL_DELAY, Again)
		end
		return
	end
	Release()

	if reason == "loading" then
		K.LoadGearLinks(links, function()
			Finish(guid, K.AverageFromLinks(links))
		end)
		return
	end
	Finish(guid, level)
end

-- ---------------------------------------------------------------------------
-- Entry points
-- ---------------------------------------------------------------------------

function Module:AddInspectInfo(tt, unit)
	local guid = UnitGUID(unit)
	if not guid or IsSecret(guid) then
		return
	end
	shownGUID = guid
	stream:Log("build %s unit=%s pending=%s settle=%s cached=%s failed=%s", guid, V(unit), V(pending), V(settleGUID), V(cache[guid] and cache[guid].ilvl), V(failed[guid]))

	-- Our own gear is available without an inspect request, and cheap enough to
	-- read every time, so it is never stale after a gear swap. UnitIsUnit is
	-- secret while unit comparison is restricted, so fall through to the inspect
	-- path rather than letting a secret drive the branch.
	local isSelf = UnitIsUnit(unit, "player")
	if not IsSecret(isSelf) and isSelf then
		local _, equipped = GetAverageItemLevel()
		if equipped and not IsSecret(equipped) and equipped > 0 then
			AddLine(tt, guid, FormatLevel(equipped))
		end
		return
	end

	local data = cache[guid]
	if data and GetTime() - data.time < CACHE_TTL then
		AddLine(tt, guid, FormatLevel(data.ilvl))
		return
	end

	-- The tooltip was rebuilt while our timer or request is out. Give it a line
	-- to fill and leave the timer alone.
	if pending == guid or settleGUID == guid then
		AddLine(tt, guid, LOADING)
		return
	end

	if not NotifyInspect then
		return
	end
	local lastTry = failed[guid]
	if lastTry and GetTime() - lastTry < RETRY_AFTER then
		return
	end
	-- No loading line for a request that could not be sent from here anyway.
	if InCombatLockdown() or InspectWindowOpen() or not (CanInspect and CanInspect(unit)) then
		return
	end

	AddLine(tt, guid, LOADING)

	-- Wait for the mouse to rest. Hovering someone else bumps the token and
	-- cancels this.
	settleToken = settleToken + 1
	settleGUID = guid
	local token = settleToken
	C_Timer.After(SETTLE_DELAY, function()
		TryInspect(token, guid, unit)
	end)
end

function Module:SetupInspect()
	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("INSPECT_READY")
	watcher:RegisterEvent("UNIT_INVENTORY_CHANGED")
	watcher:SetScript("OnEvent", function(_, event, arg)
		-- A cached player changed gear, so the next hover asks again.
		if event == "UNIT_INVENTORY_CHANGED" then
			local guid = arg and UnitGUID(arg)
			if guid and not IsSecret(guid) then
				Forget(guid)
			end
			return
		end

		stream:Log("ready %s pending=%s", V(arg), V(pending))
		if IsSecret(arg) or arg ~= pending then
			return
		end
		local unit = pendingUnit
		pending, pendingUnit = nil, nil
		Resolve(arg, unit, 0)
	end)
	self.inspectWatcher = watcher

	-- Count inspects sent by anything else (the inspect window, other addons) so
	-- ours never lands right behind one.
	if NotifyInspect then
		hooksecurefunc("NotifyInspect", function()
			if not tooltipInspecting then
				lastInspect = GetTime()
			end
		end)
	end
end
