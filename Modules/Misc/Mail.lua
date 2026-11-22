--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/Mail.lua
	Purpose:
		The mailbox jobs Blizzard leaves you to do one click at a time.

		Open All Mail already exists and is good, so this does not reimplement it.
		What is missing is taking only the gold and leaving the items, emptying a
		single opened mail in one click, and seeing what is attached without
		opening anything.

		Retrieval is paced the way Blizzard paces its own: the server processes one
		mail command at a time, so each step waits on C_Mail.IsCommandPending
		rather than firing on a fixed schedule. OPEN_ALL_MAIL_MIN_DELAY is 0.15 in
		MailFrame.lua and the same floor is used here, so a slow server stretches
		the gap instead of dropping requests on the floor.

		C_Mail.SetOpeningAll is set for the duration, which is what stops the
		inbox re-sorting under the loop while it runs.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("Mail")

local CreateFrame = CreateFrame
local hooksecurefunc = hooksecurefunc
local GetInboxNumItems = GetInboxNumItems
local GetInboxHeaderInfo = GetInboxHeaderInfo
local GetInboxItem = GetInboxItem
local TakeInboxMoney = TakeInboxMoney
local TakeInboxItem = TakeInboxItem
local HasInboxItem = HasInboxItem
local C_Mail = C_Mail
local C_Item = C_Item
local GetCoinTextureString = C_CurrencyInfo.GetCoinTextureString
local wipe, pairs, select, format = wipe, pairs, select, string.format

-- Matches OPEN_ALL_MAIL_MIN_DELAY in Blizzard's mail frame. Anything shorter
-- just queues requests the server will not answer any faster.
local STEP_DELAY = 0.15

local goldRunner, inboxIndex, collecting

-- Scratch tables for the attachment tooltip, by item ID, reused so hovering a
-- full inbox does not churn tables per row.
local attachCount, attachName, attachTexture, attachQuality = {}, {}, {}, {}

-- ---------------------------------------------------------------------------
-- Collect gold
-- ---------------------------------------------------------------------------

-- What is sitting in the inbox, so the button says whether it is worth clicking.
local function TotalGold()
	local total = 0
	for i = 1, GetInboxNumItems() do
		local _, _, _, _, money, codAmount = GetInboxHeaderInfo(i)
		if money and money > 0 and not (codAmount and codAmount > 0) then
			total = total + money
		end
	end
	return total
end

-- Clickable only when there is gold to take, so an idle click never looks like
-- it did something. Left alone while a run is going, which owns the button.
local function UpdateGoldButton()
	local gold = Module.GoldButton
	if gold and not collecting then
		gold:SetEnabled(TotalGold() > 0)
	end
end

local function StopCollecting()
	collecting = false
	goldRunner:SetScript("OnUpdate", nil)
	goldRunner.wait = nil
	C_Mail.SetOpeningAll(false)
	if Module.GoldButton then
		Module.GoldButton:SetText(L["Collect Gold"])
		UpdateGoldButton()
	end
end

local function TakeNextGold()
	while inboxIndex >= 1 do
		-- COD mail wants a payment confirmation, so it is never taken silently.
		local _, _, _, _, money, codAmount = GetInboxHeaderInfo(inboxIndex)
		local skip = (codAmount and codAmount > 0) or not money or money <= 0
		if not skip and C_Mail.HasInboxMoney(inboxIndex) then
			TakeInboxMoney(inboxIndex)
			inboxIndex = inboxIndex - 1
			return true
		end
		inboxIndex = inboxIndex - 1
	end
	return false
end

local function OnGoldUpdate(self, elapsed)
	self.wait = (self.wait or 0) - elapsed
	if self.wait > 0 then
		return
	end
	-- One command at a time. Until the server answers the last one, waiting is
	-- the only correct thing to do.
	if C_Mail.IsCommandPending() then
		self.wait = STEP_DELAY
		return
	end
	if TakeNextGold() then
		self.wait = STEP_DELAY
	else
		StopCollecting()
	end
end

local function StartCollecting()
	if collecting then
		return
	end
	local count = GetInboxNumItems()
	if count == 0 then
		return
	end

	collecting = true
	inboxIndex = count
	C_Mail.SetOpeningAll(true)

	Module.GoldButton:Disable()
	Module.GoldButton:SetText(L["Collecting"])

	goldRunner.wait = 0
	goldRunner:SetScript("OnUpdate", OnGoldUpdate)
end

-- ---------------------------------------------------------------------------
-- Take every attachment on the open mail
-- ---------------------------------------------------------------------------

-- The mail Take All was pressed on, by index and by what it says. Taking the last
-- attachment can delete the mail, and the next mail then moves into its index,
-- so the index alone could carry the loop into a mail nobody asked to empty.
local takeID, takeSender, takeSubject

local function MailIdentity(index)
	local _, _, sender, subject = GetInboxHeaderInfo(index)
	return sender, subject
end

-- COD mail charges for its items, and Blizzard asks before paying. Taking them
-- straight from here would pay without that question.
local function IsCOD(index)
	local codAmount = select(6, GetInboxHeaderInfo(index))
	return codAmount and codAmount > 0
end

local function TakeNextAttachment()
	local openMail = _G.OpenMailFrame
	local mailID = _G.InboxFrame and _G.InboxFrame.openMailID
	if not (mailID and openMail and openMail:IsShown()) or mailID ~= takeID then
		return false
	end
	local sender, subject = MailIdentity(mailID)
	if sender ~= takeSender or subject ~= takeSubject or IsCOD(mailID) then
		return false
	end
	for i = 1, _G.ATTACHMENTS_MAX_RECEIVE do
		if HasInboxItem(mailID, i) then
			TakeInboxItem(mailID, i)
			return true
		end
	end
	if C_Mail.HasInboxMoney(mailID) then
		TakeInboxMoney(mailID)
		return true
	end
	return false
end

local function OnTakeUpdate(self, elapsed)
	self.wait = (self.wait or 0) - elapsed
	if self.wait > 0 then
		return
	end
	if C_Mail.IsCommandPending() then
		self.wait = STEP_DELAY
		return
	end
	if TakeNextAttachment() then
		self.wait = STEP_DELAY
	else
		self:SetScript("OnUpdate", nil)
		self.wait = nil
	end
end

-- ---------------------------------------------------------------------------
-- Attachment tooltip
-- ---------------------------------------------------------------------------

-- Blizzard shows only the first attachment icon on a row. This lists the rest,
-- stacked by item, so a mail can be judged without opening it.
local function ShowAttachments(self)
	local index = self.index
	if not index then
		return
	end

	local _, _, _, _, money, _, _, itemCount = GetInboxHeaderInfo(index)
	if not itemCount or itemCount < 2 then
		return
	end

	-- The mail itself carries each attachment's name, icon and quality, so the
	-- list is complete the first time even for items the client has not cached.
	-- The item cache is only asked when the mail gave no name.
	wipe(attachCount)
	wipe(attachName)
	wipe(attachTexture)
	wipe(attachQuality)
	for slot = 1, _G.ATTACHMENTS_MAX_RECEIVE do
		local name, itemID, texture, count, quality = GetInboxItem(index, slot)
		if itemID and count and count > 0 then
			attachCount[itemID] = (attachCount[itemID] or 0) + count
			if not attachName[itemID] then
				if not name then
					local cachedName, _, cachedQuality, _, _, _, _, _, _, cachedTexture = C_Item.GetItemInfo(itemID)
					name, quality, texture = cachedName, cachedQuality, cachedTexture
				end
				attachName[itemID] = name
				attachTexture[itemID] = texture
				attachQuality[itemID] = quality
			end
		end
	end

	local tooltip = _G.GameTooltip
	tooltip:AddLine(" ")
	tooltip:AddLine(L["Attached"])
	for itemID, count in pairs(attachCount) do
		local r, g, b = C_Item.GetItemQualityColor(attachQuality[itemID] or 1)
		local label = attachName[itemID] or ("item:" .. itemID)
		local texture = attachTexture[itemID]
		if texture then
			label = format("|T%s:12:12:0:0:64:64:5:59:5:59|t %s", texture, label)
		end
		tooltip:AddDoubleLine(label, count, r, g, b, r, g, b)
	end
	if money and money > 0 then
		tooltip:AddDoubleLine(L["Gold"], GetCoinTextureString(money), 1, 1, 1, 1, 1, 1)
	end
	tooltip:Show()
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

local function BuildButtons()
	local inbox = _G.InboxFrame
	if not inbox or Module.GoldButton then
		return
	end

	-- Open All Mail already handles the full sweep, so this sits beside it rather
	-- than replacing it. The bottom row is full (page buttons either side of Open
	-- All), so it goes in the strip under the title, on the right, beside the
	-- centred "too much mail" warning. It keeps the stock red button look so it
	-- reads as part of the mail frame like Open All does.
	local gold = CreateFrame("Button", "KKUI_MailCollectGold", inbox, "UIPanelButtonTemplate")
	gold:SetSize(100, 22)
	gold:SetPoint("TOPRIGHT", inbox, "TOPRIGHT", -8, -30)
	gold:SetText(L["Collect Gold"])
	gold:SetScript("OnClick", StartCollecting)
	gold:SetScript("OnEnter", function(self)
		local total = TotalGold()
		_G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		_G.GameTooltip:AddLine(L["Collect Gold"])
		_G.GameTooltip:AddLine(L["Take the money from every mail and leave the items alone."], K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3], true)
		if total > 0 then
			_G.GameTooltip:AddLine(" ")
			_G.GameTooltip:AddDoubleLine(L["Waiting"], GetCoinTextureString(total), 1, 1, 1, 1, 1, 1)
		end
		_G.GameTooltip:Show()
	end)
	gold:SetScript("OnLeave", _G.GameTooltip_Hide)
	-- Greyed out with no gold waiting, but the tooltip still says what it does.
	gold:SetMotionScriptsWhileDisabled(true)
	Module.GoldButton = gold
	UpdateGoldButton()

	local openMail = _G.OpenMailFrame
	local reply = _G.OpenMailReplyButton
	if openMail and reply then
		-- First in the stock Reply, Delete, Cancel row, sized and chained the same
		-- way, which fills the room left of Reply exactly.
		local takeAll = CreateFrame("Button", "KKUI_MailTakeAll", openMail, "UIPanelButtonTemplate")
		takeAll:SetSize(reply:GetWidth(), reply:GetHeight())
		takeAll:SetPoint("RIGHT", reply, "LEFT", 0, 0)
		takeAll:SetText(L["Take All"])
		takeAll:SetScript("OnClick", function(self)
			local mailID = _G.InboxFrame.openMailID
			if not mailID or IsCOD(mailID) then
				return
			end
			takeID = mailID
			takeSender, takeSubject = MailIdentity(mailID)
			self.wait = 0
			self:SetScript("OnUpdate", OnTakeUpdate)
		end)
		-- COD mail is left to Blizzard's own confirmation, so the button is off
		-- for it. Clicking another mail while this one is open does not show the
		-- frame again, so the inbox click is hooked as well.
		local function UpdateTakeAll()
			local mailID = _G.InboxFrame.openMailID
			takeAll:SetEnabled(mailID ~= nil and not IsCOD(mailID))
		end
		openMail:HookScript("OnShow", UpdateTakeAll)
		if _G.InboxFrame_OnClick then
			hooksecurefunc("InboxFrame_OnClick", UpdateTakeAll)
		end
		Module.TakeAllButton = takeAll
	end
end

function Module:MAIL_CLOSED()
	if collecting then
		StopCollecting()
	end
	if Module.TakeAllButton then
		Module.TakeAllButton:SetScript("OnUpdate", nil)
	end
end

function Module:OnEnable()
	if not C.Misc.EnhancedMail then
		return
	end

	goldRunner = CreateFrame("Frame")

	-- The mail frame is load on demand, so wait for it rather than assuming it is
	-- already there.
	if _G.InboxFrame then
		BuildButtons()
	else
		self:RegisterEventOnce("MAIL_SHOW", BuildButtons)
	end

	self:RegisterEvent("MAIL_CLOSED", "MAIL_CLOSED")
	-- The inbox fills in after the frame opens and changes as mail is taken, so
	-- the gold button follows it.
	self:RegisterEvent("MAIL_INBOX_UPDATE", UpdateGoldButton)

	-- Inbox rows are recycled, so hook the shared handler once rather than each
	-- row. InboxFrameItem_OnEnter is what the XML calls and it carries self.index.
	if _G.InboxFrameItem_OnEnter then
		hooksecurefunc("InboxFrameItem_OnEnter", ShowAttachments)
	else
		self:RegisterEventOnce("MAIL_SHOW", function()
			if _G.InboxFrameItem_OnEnter then
				hooksecurefunc("InboxFrameItem_OnEnter", ShowAttachments)
			end
		end)
	end
end
