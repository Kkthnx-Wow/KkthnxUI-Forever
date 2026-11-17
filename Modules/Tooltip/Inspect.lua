--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Tooltip/Inspect.lua
	Purpose:
		Add an item level line for players on the unit tooltip. Inspect data
		arrives asynchronously, so results are cached per GUID and the visible
		tooltip is patched in place once the inspect resolves.

		Every NotifyInspect is a packet to the server, and servers disconnect
		clients that send them too fast. So a request is only sent once the mouse
		has rested on a player for a moment, never closer than INSPECT_LOCKOUT to
		any other inspect (ours or another addon's), never while the Blizzard
		inspect window is open, and a player who did not answer is not asked again
		for RETRY_AFTER seconds.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local Module = K:GetModule("Tooltip")

local _G = _G
local floor = math.floor

local GetTime = GetTime
local UnitGUID = UnitGUID
local UnitIsUnit = UnitIsUnit
local IsSecret = K.IsSecret
local CanInspect = _G.CanInspect
local NotifyInspect = _G.NotifyInspect
local ClearInspectPlayer = _G.ClearInspectPlayer
local GetAverageItemLevel = _G.GetAverageItemLevel
local C_PaperDollInfo = _G.C_PaperDollInfo
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
-- Time of the last NotifyInspect from anyone, and a token for the settle timer.
local lastInspect = 0
local settleToken = 0
local tooltipInspecting

-- Append the cached line to a tooltip. Blizzard already prints spec and class,
-- so we only add the average item level it leaves out, as "Item Level: 646",
-- the label muted and the value in the highlight colour like the other
-- labelled lines.
local function AddLines(tt, data)
	if data.ilvl and data.ilvl > 0 then
		tt:AddLine(K.ColorText("muted", (STAT_AVERAGE_ITEM_LEVEL or "Item Level") .. ":") .. " " .. K.ColorText("highlight", data.ilvl))
	end
end

-- Pull the average item level off an inspectable unit.
local function ReadInspect(unit)
	local ilvl
	if C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel then
		ilvl = C_PaperDollInfo.GetInspectItemLevel(unit)
	end
	if not ilvl or IsSecret(ilvl) then
		return 0
	end
	return floor(ilvl)
end

local function Store(guid, ilvl)
	if not cache[guid] then
		if cacheCount >= CACHE_MAX then
			-- Bounded: drop everything rather than track ages for a tooltip nicety.
			cache, cacheCount = {}, 0
		end
		cacheCount = cacheCount + 1
	end
	local data = { ilvl = ilvl, time = GetTime() }
	cache[guid] = data
	return data
end

-- True while the Blizzard inspect window owns the inspect target.
local function InspectWindowOpen()
	return _G.InspectFrame and _G.InspectFrame:IsShown()
end

-- Send the request, if every guard still holds by the time the timer fires.
local function TryInspect(token, guid, unit)
	if token ~= settleToken then
		return
	end
	local tt = _G.GameTooltip
	if shownGUID ~= guid or not tt:IsShown() or pending then
		return
	end

	local now = GetTime()
	if now - lastInspect < INSPECT_LOCKOUT or InspectWindowOpen() or InCombatLockdown() then
		return
	end

	-- The token may now point at someone else, or at a unit we cannot read.
	local current = UnitGUID(unit)
	if not current or IsSecret(current) or current ~= guid then
		return
	end
	if not (CanInspect and CanInspect(unit)) then
		return
	end

	pending, pendingUnit = guid, unit
	if failedCount >= CACHE_MAX then
		failed, failedCount = {}, 0
	end
	if not failed[guid] then
		failedCount = failedCount + 1
	end
	failed[guid] = now
	tooltipInspecting = true
	NotifyInspect(unit)
	tooltipInspecting = nil
	lastInspect = now

	-- Without a reply the request is abandoned so the next hover can try later.
	C_Timer.After(REPLY_TIMEOUT, function()
		if pending == guid then
			pending, pendingUnit = nil, nil
		end
	end)
end

function Module:AddInspectInfo(tt, unit)
	local guid = UnitGUID(unit)
	if not guid or IsSecret(guid) then
		return
	end
	shownGUID = guid

	local data = cache[guid]
	if data and GetTime() - data.time < CACHE_TTL then
		AddLines(tt, data)
		return
	end

	-- Our own gear is available without an inspect request. UnitIsUnit is secret
	-- while unit comparison is restricted, so fall through to the inspect path
	-- rather than letting a secret drive the branch.
	local isSelf = UnitIsUnit(unit, "player")
	if not IsSecret(isSelf) and isSelf then
		local _, ilvl = GetAverageItemLevel()
		AddLines(tt, Store(guid, ilvl and floor(ilvl) or 0))
		return
	end

	if not NotifyInspect or pending then
		return
	end
	local lastTry = failed[guid]
	if lastTry and GetTime() - lastTry < RETRY_AFTER then
		return
	end

	-- Wait for the mouse to rest. A newer hover bumps the token and cancels this.
	settleToken = settleToken + 1
	local token = settleToken
	C_Timer.After(SETTLE_DELAY, function()
		TryInspect(token, guid, unit)
	end)
end

function Module:SetupInspect()
	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("INSPECT_READY")
	watcher:SetScript("OnEvent", function(_, _, guid)
		if IsSecret(guid) or guid ~= pending then
			return
		end

		local unit = pendingUnit
		pending, pendingUnit = nil, nil
		if failed[guid] then
			failed[guid] = nil
			failedCount = failedCount - 1
		end

		local data = Store(guid, ReadInspect(unit))
		-- Leave the target alone when the Blizzard inspect window is using it.
		if ClearInspectPlayer and not InspectWindowOpen() then
			ClearInspectPlayer()
		end

		-- If the tooltip still shows the unit we inspected, patch it in place.
		-- GameTooltip:GetUnit() returns a secret token here, which cannot be fed
		-- to UnitGUID, so we compare against the GUID stamped when we rendered.
		local tt = _G.GameTooltip
		if tt:IsShown() and shownGUID == guid then
			AddLines(tt, data)
			tt:Show()
		end
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
