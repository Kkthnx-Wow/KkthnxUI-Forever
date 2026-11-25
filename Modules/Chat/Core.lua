--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/Core.lua
	Purpose:
		Skin the chat: a bordered edit box, clean tabs, our font, mouse wheel
		scrolling, shortened channel prefixes, and a copy button. Applies to every
		chat window, including ones created after login.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("Chat")

local _G = _G
local ipairs = ipairs
local pairs = pairs
local type = type
local hooksecurefunc = hooksecurefunc
local gsub = string.gsub
local concat = table.concat
local IsSecret = K.IsSecret
local GetCVar = GetCVar
local SetCVar = SetCVar

-- The chat timestamp format this module writes to the showTimestamps setting.
local TIMESTAMP_FORMAT = "%H:%M "

local NUM_FRAMES = Constants.ChatFrameConstants.MaxChatWindows

-- The frame the chat window is pinned to. Edit Mode saves the chat anchor by
-- frame name and re-applies it on EDIT_MODE_LAYOUTS_UPDATED, which arrives before
-- PLAYER_LOGIN. Created here at file load so that lookup always finds it. Made
-- in OnEnable it did not exist yet and the client logged "Couldn't find region
-- named KKUI_ChatHolder" on every login. Sized and placed in OnEnable.
local ChatHolder = CreateFrame("Frame", "KKUI_ChatHolder", UIParent)
ChatHolder:SetSize(1, 1)
ChatHolder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 6, 6)

-- ---------------------------------------------------------------------------
-- Gradient backdrop
-- ---------------------------------------------------------------------------
-- A soft horizontal fade behind the chat (dark at the left, transparent to the
-- right) with a class-coloured accent line along the top and bottom that fades
-- the same way. Kept on the BACKGROUND layer of a low frame so the messages
-- always draw over it.


local function CreateGradient(frame)
	if frame.KKUI_Gradient then
		return frame.KKUI_Gradient
	end
	local color = K.ClassColor or { r = 0.4, g = 0.6, b = 1 }

	-- Anchor to the frame's own background region, not the frame. On the Combat Log
	-- the frame's top is pushed down by the quick-filter bar, but Blizzard sizes the
	-- background region to still cover that bar (its top point carries the quick
	-- button height). Tracking that region keeps our gradient covering the full chat
	-- on every tab, so the Combat Log shows no light gap up top. Falls back
	-- to the frame on any window without a background region.
	local region = frame.Background or _G[frame:GetName() .. "Background"] or frame
	local holder = CreateFrame("Frame", nil, frame)
	holder:SetFrameLevel(0)
	holder:SetPoint("TOPLEFT", region, "TOPLEFT", -2, 3)
	holder:SetPoint("BOTTOMRIGHT", region, "BOTTOMRIGHT", 2, -3)

	local bg = holder:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints()
	bg:SetColorTexture(1, 1, 1)
	K.ShadeGradient(bg)

	local top = holder:CreateTexture(nil, "ARTWORK")
	top:SetHeight(1)
	top:SetPoint("TOPLEFT")
	top:SetPoint("TOPRIGHT")
	top:SetColorTexture(1, 1, 1)
	K.FadeGradient(top, color.r, color.g, color.b, K.GradientAlpha.line)

	local bottom = holder:CreateTexture(nil, "ARTWORK")
	bottom:SetHeight(1)
	bottom:SetPoint("BOTTOMLEFT")
	bottom:SetPoint("BOTTOMRIGHT")
	bottom:SetColorTexture(1, 1, 1)
	K.FadeGradient(bottom, color.r, color.g, color.b, K.GradientAlpha.line)

	frame.KKUI_Gradient = holder
	return holder
end

-- ---------------------------------------------------------------------------
-- Font
-- ---------------------------------------------------------------------------

local function ApplyFont(frame)
	local db = C.Chat
	local font = K.GetFont(db.Font)
	local flag = db.FontOutline and "OUTLINE" or ""
	frame:SetFont(font, db.FontSize, flag)
	frame:SetShadowColor(0, 0, 0, 1)
	frame:SetShadowOffset(1, -1)
end

-- ---------------------------------------------------------------------------
-- Edit box
-- ---------------------------------------------------------------------------

-- Tint the edit box hairlines to the channel you are typing in (whisper pink, say
-- white, guild green, and so on), read from Blizzard's own ChatTypeInfo, the same
-- way the chat frame carries a class-coloured line. In 12.x the header refreshes
-- through the edit box mixin method UpdateHeader, not the old global, so we read
-- the type and channel off the box the same way it does, GetChatType and, for a
-- numbered channel, its per-channel colour. Falls back to the class colour.
local function ColorEditBox(editBox)
	local lines = editBox.KKUI_Lines
	if not lines then
		return
	end

	local chatType = editBox.GetChatType and editBox:GetChatType() or editBox:GetAttribute("chatType")
	local info = chatType and ChatTypeInfo[chatType]
	if chatType == "CHANNEL" then
		local target = editBox.GetChannelTarget and editBox:GetChannelTarget()
		local localID = target and GetChannelName(target)
		if localID and localID > 0 then
			info = ChatTypeInfo["CHANNEL" .. localID] or info
		end
	end

	local color = info or K.ClassColor
	for _, line in ipairs(lines) do
		K.FadeGradient(line, color.r, color.g, color.b, K.GradientAlpha.line)
	end
end

-- ---------------------------------------------------------------------------
-- Characters left
-- ---------------------------------------------------------------------------
-- A count of what is left to type, on the right of the box, that warms from
-- quiet grey through gold to red as the message nears the limit. The limit is
-- the box's own visible byte limit (255 for chat), which counts what you see:
-- an item link costs its name, not its hidden link code, and an accented letter
-- costs the two or three bytes it takes. So the count strips those codes and
-- counts bytes, the same way the box itself does.

local COUNTER_ROOM = 30 -- right inset kept clear of typed text for the count
local WARN_AT = 60 -- the count starts warming up from here

-- Visible bytes in the box. Colour codes, links and texture tags take no room.
local function VisibleBytes(text)
	text = gsub(text, "|c%x%x%x%x%x%x%x%x", "")
	text = gsub(text, "|r", "")
	text = gsub(text, "|H.-|h", "")
	text = gsub(text, "|h", "")
	text = gsub(text, "|T.-|t", "")
	text = gsub(text, "|A.-|a", "")
	text = gsub(text, "||", "|")
	return #text
end

local function UpdateCounter(editBox)
	local counter = editBox.KKUI_Counter
	if not counter then
		return
	end
	local text = editBox:GetText()
	if not text or text == "" then
		counter:Hide()
		return
	end
	local limit = editBox.GetVisibleTextByteLimit and editBox:GetVisibleTextByteLimit() or 0
	if not limit or limit <= 0 then
		limit = 255
	end
	local left = limit - VisibleBytes(text)
	if left < 0 then
		left = 0
	end
	counter:SetText(left)
	if left > WARN_AT then
		local c = K.Colors.muted
		counter:SetTextColor(c[1], c[2], c[3])
	else
		-- Gold at the warning point, full red at the limit.
		local t = 1 - left / WARN_AT
		local a, b = K.Colors.highlight, K.Colors.negative
		counter:SetTextColor(a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t)
	end
	counter:Show()
end

-- Blizzard sets the right inset on every header refresh, so widen it after.
local function KeepCounterRoom(editBox)
	if not editBox.KKUI_Counter then
		return
	end
	local left, right, top, bottom = editBox:GetTextInsets()
	if left and right and right < COUNTER_ROOM then
		editBox:SetTextInsets(left, COUNTER_ROOM, top or 0, bottom or 0)
	end
end

local function AddCounter(editBox)
	if editBox.KKUI_Counter or not C.Chat.CharacterCount then
		return
	end
	local counter = editBox:CreateFontString(nil, "OVERLAY")
	K.SetFont(counter, (C.Chat.FontSize or 12) - 1, K.FontOutlineStyle())
	counter:SetPoint("RIGHT", editBox, "RIGHT", -6, 0)
	counter:SetJustifyH("RIGHT")
	counter:Hide()
	editBox.KKUI_Counter = counter
	editBox:HookScript("OnTextChanged", UpdateCounter)
	KeepCounterRoom(editBox)
end

local function SkinEditBox(editBox)
	if editBox.__skinned then
		return
	end
	editBox.__skinned = true

	local fullName = editBox:GetName()

	-- Kill the stock chrome. The Left/Mid/Right backdrop and, crucially, the
	-- FocusLeft/Mid/Right glow Blizzard lights up when the box activates. Left in
	-- place, that glow sits as a faded ghost over the tabs on a tab switch.
	for _, suffix in ipairs({ "Left", "Mid", "Right", "FocusLeft", "FocusMid", "FocusRight" }) do
		local tex = _G[fullName .. suffix]
		if tex then
			tex:SetTexture(nil)
			tex:Hide()
		end
	end
	for _, region in ipairs({ editBox:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "Texture" then
			region:SetAlpha(0)
		end
	end

	-- Same horizontal gradient the chat and channel bar wear, with a hairline along
	-- the top and bottom that ColorEditBox tints to the channel you are typing in.
	local grad = editBox:CreateTexture(nil, "BACKGROUND")
	grad:SetAllPoints()
	grad:SetColorTexture(1, 1, 1)
	K.ShadeGradient(grad)
	editBox.KKUI_Lines = {}
	for _, edge in ipairs({ "TOP", "BOTTOM" }) do
		local line = editBox:CreateTexture(nil, "ARTWORK")
		line:SetHeight(1)
		line:SetPoint(edge .. "LEFT")
		line:SetPoint(edge .. "RIGHT")
		line:SetColorTexture(1, 1, 1)
		editBox.KKUI_Lines[#editBox.KKUI_Lines + 1] = line
	end

	-- Left/right arrows move the cursor instead of cycling chat channels.
	editBox:SetAltArrowKeyMode(false)
	editBox:SetClampedToScreen(true)

	-- Sit above the chat frame, clearing the tab strip. Re-applied on every focus
	-- because a tab switch can re-anchor the box and drift it out of place.
	local parent = _G[fullName:gsub("EditBox", "")]
	local function Reposition(self)
		if not parent then
			return
		end
		self:ClearAllPoints()
		-- Nudged 4px left so the box gradient lines up with the chat and bar
		-- gradients, which reach the same amount past the frame edge.
		self:SetPoint("BOTTOMLEFT", parent, "TOPLEFT", -4, 26)
		self:SetPoint("BOTTOMRIGHT", parent, "TOPRIGHT", 0, 26)
		self:SetHeight(22)
	end
	Reposition(editBox)

	-- Visibility is driven purely by focus. The tricky part is that Blizzard
	-- re-activates an already-shown box on a tab click by fading its alpha up, with
	-- no OnShow or focus event to hook, which is what left it faded over the tabs.
	-- So we intercept SetAlpha itself. Any alpha above zero while the box is not
	-- focused is forced back to zero. Our own focus-in alpha is allowed because the
	-- box holds focus by then.
	editBox:SetAlpha(0)
	editBox:EnableMouse(false)
	hooksecurefunc(editBox, "SetAlpha", function(self, alpha)
		if alpha > 0 and not self:HasFocus() then
			self:SetAlpha(0)
		end
	end)
	-- Recolour the border to the active channel whenever the box refreshes its
	-- header (channel switch, tab change, reply cycle). Hooked on the instance
	-- method because the old global ChatEdit_UpdateHeader is gone in 12.x.
	if editBox.UpdateHeader then
		hooksecurefunc(editBox, "UpdateHeader", ColorEditBox)
		hooksecurefunc(editBox, "UpdateHeader", KeepCounterRoom)
	end
	ColorEditBox(editBox)
	AddCounter(editBox)

	editBox:HookScript("OnEditFocusGained", function(self)
		Reposition(self)
		self:EnableMouse(true)
		self:SetAlpha(1)
		ColorEditBox(self)
	end)
	editBox:HookScript("OnEditFocusLost", function(self)
		self:EnableMouse(false)
		self:SetAlpha(0)
	end)
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------

-- Blizzard re-applies tab textures constantly (FCFTab_UpdateColors, hover), so
-- rather than chase named regions we blank every texture on the tab and keep it
-- blanked. Only the label stays.
local function StripTab(tab)
	for _, region in ipairs({ tab:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "Texture" then
			region:SetTexture(nil)
			region:SetAtlas(nil)
		end
	end
end

local function SkinTab(tab)
	if not tab or tab.__skinned then
		return
	end
	tab.__skinned = true

	StripTab(tab)
	if tab.SetNormalTexture then
		tab:SetNormalTexture(0)
		tab:SetHighlightTexture(0)
		tab:SetPushedTexture(0)
	end

	local text = tab.Text or _G[tab:GetName() .. "Text"]
	if text then
		K.SetFont(text, C.Chat.FontSize, K.FontOutlineStyle())
	end
end

-- Colour the selected tab in the class colour and dim the rest, so the active
-- tab reads at a glance. Blizzard passes the selected flag to FCFTab_UpdateColors,
-- so we recolour from the same call that repaints the tab.
local function ColorTab(tab, selected)
	local text = tab and (tab.Text or (tab.GetName and _G[tab:GetName() .. "Text"]))
	if not text then
		return
	end
	-- Remember the state so the flash hooks can restore the right colour, and so a
	-- tab still flagged as alerting is not overwritten back to grey.
	tab.KKUI_Selected = selected
	if tab.KKUI_Alerting and not selected then
		text:SetTextColor(K.Colors.ember[1], K.Colors.ember[2], K.Colors.ember[3])
		return
	end
	if selected then
		local color = K.ClassColor
		text:SetTextColor(color.r, color.g, color.b)
	else
		text:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	end
end

-- We blank every tab texture, which also blanks the glow the client flashes when
-- an inactive tab gets a new message. Put that unread cue back by lighting the
-- tab label a warm orange while it is alerting, cleared once the tab is read.
local function TabAlertStart(chatFrame)
	local tab = _G[chatFrame:GetName() .. "Tab"]
	local text = tab and (tab.Text or _G[tab:GetName() .. "Text"])
	if text and not tab.KKUI_Selected then
		tab.KKUI_Alerting = true
		text:SetTextColor(K.Colors.ember[1], K.Colors.ember[2], K.Colors.ember[3])
	end
end

local function TabAlertStop(chatFrame)
	local tab = _G[chatFrame:GetName() .. "Tab"]
	if tab then
		tab.KKUI_Alerting = nil
		ColorTab(tab, tab.KKUI_Selected)
	end
end

-- ---------------------------------------------------------------------------
-- Mouse wheel
-- ---------------------------------------------------------------------------

local function OnMouseWheel(frame, delta)
	if delta > 0 then
		if IsShiftKeyDown() then
			frame:ScrollToTop()
		else
			frame:ScrollUp()
		end
	else
		if IsShiftKeyDown() then
			frame:ScrollToBottom()
		else
			frame:ScrollDown()
		end
	end
end

-- ---------------------------------------------------------------------------
-- Channel shortening
-- ---------------------------------------------------------------------------
-- The channel tag is shortened after the line is stored, never on the way in.
--
-- Swapping our own function into frame.AddMessage put addon code in the middle
-- of every chat event. Blizzard's handler carries on after AddMessage (sound,
-- reply target, the text to speech observer), and all of that then ran tainted.
-- Blizzard wraps its own message filters in securecallfunction for this reason.
-- hooksecurefunc runs after the original call has finished, so the handler stays
-- clean. The hook then rewrites the text of the line just stored, which is the
-- newest entry in the frame's history buffer.
--
-- Built-in tags are matched on the channel link token and the label inside the
-- brackets. The leader variants share the plain token (party leader is
-- |Hchannel:PARTY|h[Party Leader]|h), so the label is read from the client's own
-- format strings to tell them apart in any locale.

local CHANNEL_SHORT = {
	GUILD = "G",
	OFFICER = "O",
	PARTY = "P",
	PARTY_LEADER = "PL",
	RAID = "R",
	RAID_LEADER = "RL",
	INSTANCE_CHAT = "I",
	INSTANCE_CHAT_LEADER = "IL",
}

-- token .. label -> short tag, built once from the CHAT_<TYPE>_GET strings.
local tagShort = {}
-- token -> short tag, for a label the client's strings did not cover.
local tokenShort = {}
for chatType, short in pairs(CHANNEL_SHORT) do
	local fmt = _G["CHAT_" .. chatType .. "_GET"]
	local token, label
	if type(fmt) == "string" then
		token, label = fmt:match("|Hchannel:([^|]+)|h%[([^%]]+)%]|h")
	end
	if token then
		tagShort[token .. label] = short
		tokenShort[token] = tokenShort[token] or CHANNEL_SHORT[token]
	end
end

local function ShortTag(token, label)
	local short = tagShort[token .. label] or tokenShort[token]
	if short then
		return "|Hchannel:" .. token .. "|h[" .. short .. "]|h"
	end
end

local function ShortenLine(text)
	-- Numbered custom channels: [5. General] becomes [5].
	text = gsub(text, "(|Hchannel:channel:%d+|h)%[(%d+)%. [^%]]+%]|h", "%1[%2]|h")
	-- Built-in channels by link token and label: [Party Leader] becomes [PL].
	return (gsub(text, "|Hchannel:(%u[%u_]+)|h%[([^%]]+)%]|h", ShortTag))
end

local function ShortenNewest(frame, text)
	-- A secret line can be neither read nor compared, so it is left as it is.
	if type(text) ~= "string" or IsSecret(text) or not text:find("|Hchannel:", 1, true) then
		return
	end
	local buffer = frame.historyBuffer
	local entry = buffer and buffer:GetEntryAtIndex(1)
	local message = entry and entry.message
	-- Only the entry this call stored. Compared only once it is known not to be
	-- secret, since comparing a secret errors.
	if not message or IsSecret(message) or message ~= text then
		return
	end
	local short = ShortenLine(text)
	if short ~= text then
		entry.message = short
		frame:MarkDisplayDirty()
	end
end

local shortened = {}

local function HookShortening(frame)
	if shortened[frame] or not frame.historyBuffer then
		return
	end
	shortened[frame] = true
	hooksecurefunc(frame, "AddMessage", ShortenNewest)
end

-- ---------------------------------------------------------------------------
-- Class colored names
-- ---------------------------------------------------------------------------
-- Uses Blizzard's own per-group class colouring so it stays correct and needs
-- no message parsing.

local COLOR_GROUPS = {
	"SAY",
	"YELL",
	"GUILD",
	"OFFICER",
	"WHISPER",
	"BN_WHISPER",
	"PARTY",
	"PARTY_LEADER",
	"RAID",
	"RAID_LEADER",
	"RAID_WARNING",
	"INSTANCE_CHAT",
	"INSTANCE_CHAT_LEADER",
	"CHANNEL",
}

local function EnableClassColors()
	for _, group in ipairs(COLOR_GROUPS) do
		if ToggleChatColorNamesByClassGroup then
			ToggleChatColorNamesByClassGroup(true, group)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Clickable URLs
-- ---------------------------------------------------------------------------
-- Wrap anything that looks like a link in a custom hyperlink, clicking it opens
-- a small box with the URL selected for copying.

local URL_PATTERNS = {
	"%f[%a]https?://%S+", -- scheme://...
	"%f[%w]www%.[%w_.%-]+%.%a%a+%S*", -- www.something.tld
	"%f[%d]%d%d?%d?%.%d%d?%d?%.%d%d?%d?%.%d%d?%d?:?%d*", -- ip[:port]
}

-- Cheap test so ordinary chat lines never reach the matching loop.
local function MayHaveURL(text)
	return text:find("://", 1, true) or text:find("www.", 1, true) or text:find("%d%.%d+%.%d+%.%d")
end

-- One left to right pass that takes the earliest match of any pattern. Running
-- the patterns one after another let a later pattern match inside the link the
-- earlier one had just written, which broke the hyperlink. A match stops at any
-- escape sequence and sheds trailing punctuation, so "see www.x.com." links
-- the address and not the full stop.
local function LinkURLs(text)
	-- A secret chat string cannot be indexed or searched, so pass it through as is.
	if type(text) ~= "string" or IsSecret(text) or not MayHaveURL(text) then
		return text
	end

	local info = K.ColorHex("info")
	local out, pos = {}, 1
	while true do
		local first
		for _, pattern in ipairs(URL_PATTERNS) do
			local s = text:find(pattern, pos)
			if s and (not first or s < first) then
				first = s
			end
		end
		if not first then
			break
		end

		-- Re-match from the chosen start to get this pattern's own end.
		local url
		for _, pattern in ipairs(URL_PATTERNS) do
			local s, e = text:find(pattern, first)
			if s == first then
				url = text:sub(s, e)
				break
			end
		end
		url = url:match("^[^|]+") or ""
		url = url:gsub("[%.,;:!%?%)%]]+$", "")

		if url == "" then
			-- Nothing usable here, step past it so the loop always advances.
			out[#out + 1] = text:sub(pos, first)
			pos = first + 1
		else
			out[#out + 1] = text:sub(pos, first - 1)
			out[#out + 1] = info .. "|Hkkurl:" .. url .. "|h[" .. url .. "]|h|r"
			pos = first + #url
		end
	end
	out[#out + 1] = text:sub(pos)
	return concat(out)
end

-- Run fn over the parts of a chat string that sit outside hyperlinks, leaving every
-- |H...|h...|h span untouched. Item links and player links carry text and data a
-- rewrite must never reach into. Shared with the keyword highlighter.
function Module.OutsideLinks(text, fn)
	if not text:find("|H", 1, true) then
		return fn(text)
	end
	local out, pos = {}, 1
	while true do
		local s, e = text:find("|H.-|h.-|h", pos)
		if not s then
			break
		end
		out[#out + 1] = fn(text:sub(pos, s - 1))
		out[#out + 1] = text:sub(s, e)
		pos = e + 1
	end
	out[#out + 1] = fn(text:sub(pos))
	return concat(out)
end

-- A message event filter, not an AddMessage wrapper. The filter sees the spoken
-- text before the client adds the player link and channel prefix, so it can link a
-- URL in any line, and it keeps our code out of the call path of the client's own
-- AddMessage. Blizzard runs it once per window, which is cheap because of the
-- MayHaveURL test.
local URL_EVENTS = {
	"CHAT_MSG_SAY",
	"CHAT_MSG_YELL",
	"CHAT_MSG_EMOTE",
	"CHAT_MSG_GUILD",
	"CHAT_MSG_OFFICER",
	"CHAT_MSG_PARTY",
	"CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID",
	"CHAT_MSG_RAID_LEADER",
	"CHAT_MSG_RAID_WARNING",
	"CHAT_MSG_INSTANCE_CHAT",
	"CHAT_MSG_INSTANCE_CHAT_LEADER",
	"CHAT_MSG_CHANNEL",
	"CHAT_MSG_WHISPER",
	"CHAT_MSG_WHISPER_INFORM",
	"CHAT_MSG_BN_WHISPER",
	"CHAT_MSG_BN_WHISPER_INFORM",
}

local function URLFilter(_, _, text, ...)
	if type(text) ~= "string" or IsSecret(text) or not MayHaveURL(text) then
		return false
	end
	local linked = Module.OutsideLinks(text, LinkURLs)
	if linked == text then
		return false
	end
	return false, linked, ...
end

-- One shared box for copying a clicked URL.
local urlBox
local function ShowURL(url)
	if not urlBox then
		urlBox = CreateFrame("EditBox", "KKUI_ChatURLBox", UIParent, "InputBoxTemplate")
		urlBox:SetSize(360, 24)
		urlBox:SetPoint("CENTER")
		urlBox:SetFrameStrata("DIALOG")
		urlBox:SetAutoFocus(true)
		-- Hiding drops focus too. Closing on Ctrl+C means the box is gone as soon as
		-- the address is copied, and the text is put back if someone types over it.
		urlBox:SetScript("OnEscapePressed", urlBox.Hide)
		urlBox:SetScript("OnEnterPressed", urlBox.Hide)
		urlBox:SetScript("OnEditFocusLost", urlBox.Hide)
		urlBox:SetScript("OnKeyUp", function(self, key)
			if key == "C" and IsControlKeyDown() then
				self:Hide()
			end
		end)
		urlBox:SetScript("OnTextChanged", function(self, userInput)
			if userInput and self.KKUI_URL then
				self:SetText(self.KKUI_URL)
				self:HighlightText()
			end
		end)
		K.SkinEditBox(urlBox)
	end
	urlBox.KKUI_URL = url
	urlBox:SetText(url)
	urlBox:HighlightText()
	urlBox:Show()
	urlBox:SetFocus()
end

-- ---------------------------------------------------------------------------
-- Copy button
-- ---------------------------------------------------------------------------

function Module:CreateCopyWindow()
	local frame = CreateFrame("Frame", "KKUI_ChatCopy", UIParent)
	frame:SetSize(700, 400)
	frame:SetPoint("CENTER")
	frame:SetFrameStrata("DIALOG")
	frame:EnableMouse(true)
	frame:SetMovable(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	K.CreateBackground(frame, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.95)
	K.CreateBorder(frame)
	frame:Hide()

	local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)
	K.SkinCloseButton(close)

	local scroll = CreateFrame("ScrollFrame", "KKUI_ChatCopyScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 10, -30)
	scroll:SetPoint("BOTTOMRIGHT", -28, 10)
	K.SkinScrollBar(scroll.ScrollBar)

	-- The edit box is a fixed size that fills the scroll viewport (its own name so
	-- the mouse wheel and scroll bar drive it). Multi-line text is laid out inside
	-- it and the visible slice is controlled by the hit-rect insets on scroll, the
	-- way the reference UIs do it, so the whole log shows and scrolls cleanly.
	local edit = CreateFrame("EditBox", nil, frame)
	edit:SetMultiLine(true)
	edit:SetMaxLetters(0)
	edit:SetAutoFocus(false)
	edit:EnableMouse(true)
	edit:SetFontObject(ChatFontNormal)
	edit:SetTextColor(K.Colors.offWhite[1], K.Colors.offWhite[2], K.Colors.offWhite[3])
	-- Explicit size, not scroll:GetWidth(). The window is built on first click and
	-- is not laid out yet, so GetWidth would be 0 and the text would have nowhere to
	-- draw (which is why the copy box looked empty). 700 wide frame minus the insets.
	edit:SetWidth(662)
	edit:SetHeight(360)
	edit:SetScript("OnEscapePressed", function()
		frame:Hide()
	end)
	-- Show the newest lines when fresh text is set (userInput is nil then). One jump
	-- to the end of the range rather than a mouse wheel step per unit.
	edit:SetScript("OnTextChanged", function(_, userInput)
		if userInput then
			return
		end
		local _, maxVal = scroll.ScrollBar:GetMinMaxValues()
		scroll.ScrollBar:SetValue(maxVal)
	end)
	scroll:SetScrollChild(edit)
	scroll:HookScript("OnVerticalScroll", function(self, offset)
		edit:SetHitRectInsets(0, 0, offset, (edit:GetHeight() - offset - self:GetHeight()))
	end)

	self.copyFrame = frame
	self.copyEdit = edit
	self.copyScroll = scroll
	return frame
end

-- Drop textures and atlases so the copied text is clean, keeping the colour.
local function CleanMessage(msg, r, g, b)
	-- Emoji icons go back to the text that was typed rather than vanishing.
	if Module.RestoreEmojis then
		msg = Module.RestoreEmojis(msg)
	end
	msg = gsub(msg, "|T(.-):.-|t", "")
	msg = gsub(msg, "|A(.-):.-|a", "")
	return K.RGBToHex(r or 1, g or 1, b or 1) .. msg .. "|r"
end

function Module:CopyChat(chatFrame)
	if not self.copyFrame then
		self:CreateCopyWindow()
	end
	chatFrame = chatFrame or _G.SELECTED_DOCK_FRAME or _G.SELECTED_CHAT_FRAME or _G.ChatFrame1

	local lines = {}
	for i = 1, chatFrame:GetNumMessages() do
		local msg, r, g, b = chatFrame:GetMessageInfo(i)
		if msg and not IsSecret(msg) then
			lines[#lines + 1] = CleanMessage(msg, r, g, b)
		end
	end

	self.copyFrame:Show()
	self.copyEdit:SetText(concat(lines, "\n"))
	self.copyEdit:HighlightText()
end

local function AddCopyButton(chatFrame)
	local button = CreateFrame("Button", nil, chatFrame)
	button:SetSize(20, 20)
	button:SetPoint("TOPRIGHT", chatFrame, "TOPRIGHT", -2, 20)
	button:SetAlpha(0)
	K.CreateBackground(button, K.Colors.panel[1], K.Colors.panel[2], K.Colors.panel[3], 0.8)
	K.CreateBorder(button)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture(C.Media.Textures.Copy or "Interface\\BUTTONS\\UI-GuildButton-PublicNote-Up")
	button:SetScript("OnEnter", function(self)
		self:SetAlpha(1)
	end)
	button:SetScript("OnLeave", function(self)
		self:SetAlpha(0)
	end)
	button:SetScript("OnClick", function()
		Module:CopyChat(chatFrame)
	end)
	K.IgnoreGamepadNav(button)
	return button
end

-- ---------------------------------------------------------------------------
-- Social (quick-join) button
-- ---------------------------------------------------------------------------

-- Reskin and reposition the quick-join toast button above the chat. It is kept
-- rather than hidden because hiding it also hides the toasts other features fire.
function Module:SkinSocialButton()
	local button = _G.QuickJoinToastButton
	if not button or button.KKUI_Skinned then
		return
	end
	button.KKUI_Skinned = true

	button:ClearAllPoints()
	button:SetPoint("BOTTOMLEFT", _G.ChatFrame1, "TOPLEFT", 0, 60)
	button:SetSize(24, 24)

	-- The stock friends and queue art fill the whole button, and a friend-online
	-- toast animates the queue art and a fly-out panel to full alpha over it. Rather
	-- than fight those animations, our skin lives on an overlay frame a few levels
	-- above everything on the button, so it always sits on top. The button keeps its
	-- mouse and click behaviour underneath (the overlay takes no mouse input).
	if not button.KKUI_Skin then
		local skin = CreateFrame("Frame", nil, button)
		skin:SetAllPoints(button)
		skin:SetFrameLevel(button:GetFrameLevel() + 5)
		K.CreateGradientBackground(skin, 0.85)
		K.CreateBorder(skin)

		local icon = skin:CreateTexture(nil, "ARTWORK")
		icon:SetPoint("CENTER", skin, "CENTER", 0, 0)
		icon:SetSize(20, 20)
		local preferred = "housefinder_neighborhood-list-friend-icon"
		if C_Texture and C_Texture.GetAtlasInfo and not C_Texture.GetAtlasInfo(preferred) then
			preferred = "friends-icon-friendsAvailable"
		end
		icon:SetAtlas(preferred)

		button.KKUI_Skin = skin
		button.KKUI_Icon = icon

		-- Move the online friend count onto the overlay so it reads over our skin.
		if button.FriendCount then
			button.FriendCount:SetParent(skin)
			button.FriendCount:ClearAllPoints()
			button.FriendCount:SetPoint("BOTTOMRIGHT", skin, "BOTTOMRIGHT", 2, -2)
			-- Stock font is small and unoutlined, which is unreadable sitting on the
			-- icon art. Give it our outlined font in gold so the number reads at a
			-- glance, and drop it on the overlay layer so nothing draws over it.
			K.SetFont(button.FriendCount, 12, K.FontOutlineStyle())
			button.FriendCount:SetTextColor(K.Colors.gold[1], K.Colors.gold[2], K.Colors.gold[3])
			button.FriendCount:SetDrawLayer("OVERLAY", 7)
		end
	end
end

-- ---------------------------------------------------------------------------
-- Combat log (load-on-demand)
-- ---------------------------------------------------------------------------

-- Skin the Combat Log once its addon is present, strip and reskin the quick
-- filter bar, and re-hide the combat-log frame's own background, which the addon
-- re-shows when it loads (this is what washed our gradient out on that tab).
function Module:StyleCombatLog()
	local quickButtons = _G.CombatLogQuickButtonFrame_Custom
	if not quickButtons or quickButtons.KKUI_Skinned then
		return
	end
	quickButtons.KKUI_Skinned = true

	local function StripQuickButtons()
		for _, region in ipairs({ quickButtons:GetRegions() }) do
			if region.GetObjectType and region:GetObjectType() == "Texture" then
				region:SetTexture(nil)
				region:SetAtlas(nil)
			end
		end
		if _G.CombatLogQuickButtonFrame_CustomTexture then
			_G.CombatLogQuickButtonFrame_CustomTexture:SetTexture(nil)
			_G.CombatLogQuickButtonFrame_CustomTexture:Hide()
		end
	end
	StripQuickButtons()
	quickButtons:HookScript("OnShow", StripQuickButtons)
	if _G.CombatLogQuickButtonFrame_CustomTexture then
		hooksecurefunc(_G.CombatLogQuickButtonFrame_CustomTexture, "SetTexture", function(self, tex)
			if tex then
				self:SetTexture(nil)
			end
		end)
	end

	K.CreateBackground(quickButtons, K.Colors.bg[1], K.Colors.bg[2], K.Colors.bg[3], 0.85)
	K.CreateBorder(quickButtons)
	local progress = _G.CombatLogQuickButtonFrame_CustomProgressBar
	if progress then
		progress:SetStatusBarTexture(0)
		progress:SetAlpha(0)
	end

	local filterButton = _G.CombatLogQuickButtonFrame_CustomAdditionalFilterButton
	if filterButton then
		StripTab(filterButton)
	end

	-- Loading the addon calls FCF_SetWindowAlpha on the combat-log frame, which
	-- re-shows the stock backdrop and border behind our gradient. Re-run the skin,
	-- which kills those textures again and keeps them killed through its show hook.
	self:StyleFrame(2)
end

-- Run the combat-log skin now if its addon is already up, otherwise wait for it.
function Module:SetupCombatLog()
	local loaded = C_AddOns and C_AddOns.IsAddOnLoaded and C_AddOns.IsAddOnLoaded("Blizzard_CombatLog")
	if loaded then
		self:StyleCombatLog()
		return
	end

	local watcher = CreateFrame("Frame")
	watcher:RegisterEvent("ADDON_LOADED")
	watcher:SetScript("OnEvent", function(self2, _, addon)
		if addon == "Blizzard_CombatLog" then
			Module:StyleCombatLog()
			self2:UnregisterEvent("ADDON_LOADED")
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Enable
-- ---------------------------------------------------------------------------

-- Blank the frame's own stock backdrop and border textures. DisableDrawLayer does
-- most of it, but hide the textures directly too so nothing lingers if the Combat
-- Log re-shows them on load.
local function KillFrameTextures(frame)
	for _, region in ipairs({ frame:GetRegions() }) do
		if region.GetObjectType and region:GetObjectType() == "Texture" then
			local layer = region:GetDrawLayer()
			if layer == "BACKGROUND" or layer == "BORDER" then
				region:SetAlpha(0)
				region:Hide()
			end
		end
	end
end

-- Style one window. The frame is passed in for temporary windows, which are found by
-- walking the client's own window list rather than guessed from an index.
function Module:StyleFrame(index, target)
	local frame = target or _G["ChatFrame" .. index]
	if not frame then
		return
	end
	local name = frame:GetName()
	local db = C.Chat
	frame.KKUI_Styled = true

	ApplyFont(frame)

	-- frame.oldAlpha is deliberately not seeded here. It is Blizzard's field, and a
	-- value written by us is tainted. FocusGamepad reads it through
	-- FCF_FadeInChatFrame and then activates the chat footer bindings, so with the
	-- Gamepad UI on that one write tainted the gamepad binding state and ended in a
	-- forbidden SetPreferredGamepadInteractTarget call. The fade helpers on this
	-- client already fall back to DEFAULT_CHATFRAME_ALPHA when it is nil.

	-- Blank the stock backdrop and border. The Combat Log re-shows its frame
	-- textures when its addon loads, so re-apply this on every show as well.
	frame:DisableDrawLayer("BACKGROUND")
	frame:DisableDrawLayer("BORDER")
	frame:SetClampRectInsets(0, 0, 0, 0)
	KillFrameTextures(frame)

	if not frame.KKUI_BackdropGuard then
		frame.KKUI_BackdropGuard = true
		frame:HookScript("OnShow", function(self)
			self:DisableDrawLayer("BACKGROUND")
			self:DisableDrawLayer("BORDER")
			KillFrameTextures(self)
		end)
	end

	-- Park the minimal scroll bar and the jump-to-bottom button on the hidden
	-- parent. Scrolling is on the mouse wheel and the side strip has its own
	-- jump-to-newest button, so both are just clutter down the right edge of the
	-- messages. Hiding or zeroing their alpha was not enough, the game fades the
	-- bar back in whenever the mouse is over the chat. On the hidden parent they
	-- are never drawn, and the game's own calls on them still work.
	if frame.ScrollBar then
		frame.ScrollBar:SetParent(K.HiddenParent)
	end
	if frame.ScrollToBottomButton then
		frame.ScrollToBottomButton:SetParent(K.HiddenParent)
	end

	SkinTab(_G[name .. "Tab"])
	SkinEditBox(_G[name .. "EditBox"])

	if db.MouseWheelScroll then
		frame:SetScript("OnMouseWheel", OnMouseWheel)
		frame:EnableMouseWheel(true)
	end

	-- Fade idle windows using the built-in fade timers. Skipped when our own idle
	-- fade is on, since that dims the whole frame instead of dropping old lines.
	frame:SetFading(db.Fade and not db.IdleFade)
	if db.Fade then
		frame:SetTimeVisible(db.FadeTime)
	end

	-- The side strip carries its own copy button, so the per window one is only
	-- added when the strip is off.
	if db.CopyButton and not db.SideButtons and not frame.KKUI_Copy then
		frame.KKUI_Copy = AddCopyButton(frame)
	end

	-- The Combat Log (window 2) prints a line per event and its text is not player
	-- chat, so the rewrite and the history capture stay off it.
	if name ~= "ChatFrame2" then
		if db.ShortenChannels then
			HookShortening(frame)
		end

		if Module.HookHistoryFrame then
			Module:HookHistoryFrame(frame)
		end
	end

	if db.GradientBackdrop then
		CreateGradient(frame)
	end

	if Module.hyperlinkTooltips then
		Module:HookHyperlinkFrame(frame)
	end
end

-- One-click chat layout. Reset to a single window,
-- then dock General, Combat Log, Whispers, Trade, and Loot tabs with sensible
-- message groups, and set a few chat CVars. Run from the installer or /kk.
function Module:InstallChat()
	FCF_ResetChatWindows()
	FCF_SetLocked(_G.ChatFrame1, true)
	FCF_SetWindowName(_G.ChatFrame1, GENERAL or "General")
	_G.ChatFrame1:Show()

	-- General. Everything but trade and the recruitment channels.
	_G.ChatFrame1:RemoveAllMessageGroups()
	for _, channel in ipairs({ TRADE, GENERAL, "LocalDefense", "LookingForGroup", "GuildRecruitment", "Services" }) do
		if channel then
			_G.ChatFrame1:RemoveChannel(channel)
		end
	end
	local general = {
		"SAY",
		"EMOTE",
		"YELL",
		"GUILD",
		"OFFICER",
		"GUILD_ACHIEVEMENT",
		"MONSTER_SAY",
		"MONSTER_EMOTE",
		"MONSTER_YELL",
		"MONSTER_WHISPER",
		"MONSTER_BOSS_EMOTE",
		"MONSTER_BOSS_WHISPER",
		"PARTY",
		"PARTY_LEADER",
		"RAID",
		"RAID_LEADER",
		"RAID_WARNING",
		"INSTANCE_CHAT",
		"INSTANCE_CHAT_LEADER",
		"BG_HORDE",
		"BG_ALLIANCE",
		"BG_NEUTRAL",
		"SYSTEM",
		"ERRORS",
		"AFK",
		"DND",
		"IGNORED",
		"ACHIEVEMENT",
	}
	for _, group in ipairs(general) do
		_G.ChatFrame1:AddMessageGroup(group)
	end

	-- Combat log stays docked as the second tab.
	FCF_DockFrame(_G.ChatFrame2)
	FCF_SetLocked(_G.ChatFrame2, true)
	FCF_SetWindowName(_G.ChatFrame2, COMBAT_LOG or "Combat Log")
	_G.ChatFrame2:Show()

	local whispers = FCF_OpenNewWindow(L["Whispers"])
	FCF_SetLocked(whispers, true)
	FCF_DockFrame(whispers)
	whispers:RemoveAllMessageGroups()
	for _, group in ipairs({ "WHISPER", "BN_WHISPER", "BN_CONVERSATION" }) do
		whispers:AddMessageGroup(group)
	end

	-- Trade and the general channels.
	local trade = FCF_OpenNewWindow(L["Trade"])
	FCF_SetLocked(trade, true)
	FCF_DockFrame(trade)
	trade:RemoveAllMessageGroups()
	-- The frame carries the channel methods now, the old global wrappers are deprecated.
	if TRADE then
		trade:AddChannel(TRADE)
	end
	if GENERAL then
		trade:AddChannel(GENERAL)
	end

	-- Loot, money, and gains.
	local loot = FCF_OpenNewWindow(L["Loot"])
	FCF_SetLocked(loot, true)
	FCF_DockFrame(loot)
	loot:RemoveAllMessageGroups()
	for _, group in ipairs({ "COMBAT_XP_GAIN", "COMBAT_HONOR_GAIN", "COMBAT_FACTION_CHANGE", "LOOT", "CURRENCY", "MONEY", "SKILL" }) do
		loot:AddMessageGroup(group)
	end

	-- Chat behaviour CVars.
	SetCVar("chatMouseScroll", 1)
	SetCVar("chatStyle", "im")
	SetCVar("whisperMode", "inline")
	SetCVar("removeChatDelay", 1)
	SetCVar("colorChatNamesByClass", 1)

	_G.ChatFrame1:SetUserPlaced(true)
	K.Print(L["Chat layout applied."])
end
K.InstallChat = function()
	Module:InstallChat()
end

function Module:OnEnable()
	if not C.Chat.Enable then
		return
	end

	-- Timestamps through the built-in CVar (24h HH:MM). With the option off, our
	-- own format is put back to the game's default, a format the player chose
	-- in the game's settings is left alone.
	if C.Chat.Timestamps then
		SetCVar("showTimestamps", TIMESTAMP_FORMAT)
	elseif GetCVar("showTimestamps") == TIMESTAMP_FORMAT then
		SetCVar("showTimestamps", "none")
	end

	if C.Chat.ClassColorNames then
		EnableClassColors()
	end

	-- A soft sound on an incoming whisper, throttled so a burst is one chime, and a
	-- taskbar flash so a whisper still lands while the game is in the background.
	if C.Chat.WhisperSound then
		local lastPlay = 0
		local function OnWhisper()
			local now = GetTime()
			if now - lastPlay > 3 then
				lastPlay = now
				PlaySound(SOUNDKIT.TELL_MESSAGE, "Master")
			end
			if FlashClientIcon then
				FlashClientIcon()
			end
		end
		self:RegisterEvent("CHAT_MSG_WHISPER", OnWhisper)
		self:RegisterEvent("CHAT_MSG_BN_WHISPER", OnWhisper)
	end

	-- Remove the stock chat clutter around the frames. The quick-join social button
	-- is kept and skinned instead, since hiding it also hides the toasts other
	-- features rely on.
	for _, name in ipairs({
		"ChatFrameMenuButton",
		"ChatFrameChannelButton",
		"ChatFrameToggleVoiceDeafenButton",
		"ChatFrameToggleVoiceMuteButton",
	}) do
		local frame = _G[name]
		if frame then
			frame:Hide()
			frame:HookScript("OnShow", frame.Hide)
		end
	end

	self:SkinSocialButton()

	-- Pin the chat to the bottom-left corner. Edit Mode keeps trying to place it,
	-- so we hook SetPoint and re-apply, guarded against re-entry. The y offset
	-- leaves room for the quick-bar that sits just below the frame.
	-- Edit Mode owns the default chat frame (FCF_RestorePositionAndDimensions
	-- bails out for it). The chat window is not one of Edit Mode's managed
	-- frames on this client (no isManagedFrame), so nothing has to be detached
	-- from a container, and no field is written on ChatFrame1, which secure
	-- gamepad chat focus reads.

	-- A frame of ours that owns the spot, with the chat window stretched across it.
	-- Chasing the chat's own single anchor never held, because the client restores
	-- geometry with SetSize as well as SetPoint and a SetPoint hook cannot see a
	-- resize. Pinned by two opposing corners the size is derived from the anchors
	-- instead of stored on the frame, so a SetSize behind our back changes nothing
	-- on screen and there is only one thing left to defend.
	local bottom = C.Chat.ChatBar and 34 or 6
	local holder = ChatHolder
	holder:ClearAllPoints()
	holder:SetSize(C.Chat.Width, C.Chat.Height)
	holder:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 6, bottom)

	-- Edit Mode owns the chat frame's clamp insets and rewrites them on every system
	-- update (a teleport, a layout swap, anything that reapplies the layout), the
	-- chat template is clamped to the screen, and UpdateClampOffsets sets the insets
	-- to the Selection overlay's rect, which reaches 32 out to the left, 32 below
	-- and 60 above the window. The engine then keeps that whole rect on screen, so a
	-- chat sitting closer than that to an edge is pushed in to roughly Blizzard's own
	-- default spot, whatever our anchors say. Insets of zero make the clamp use the
	-- window itself, which is what the anchors describe.
	local function ClearClampInsets()
		local frame = _G.ChatFrame1
		local l, r, t, b = frame:GetClampRectInsets()
		if l ~= 0 or r ~= 0 or t ~= 0 or b ~= 0 then
			local stream = K.Debug and K.Debug.Get("chat")
			if stream then
				stream:Log("clamp insets were %s %s %s %s, cleared", l, r, t, b)
			end
			frame:SetClampRectInsets(0, 0, 0, 0)
		end
	end

	local anchoring
	local function AnchorChat()
		if anchoring then
			return
		end
		anchoring = true
		ClearClampInsets()
		local frame = _G.ChatFrame1
		frame:SetUserPlaced(true)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", holder, "TOPLEFT", 0, 0)
		frame:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 0, 0)
		anchoring = false

		-- Record the state we actually leave behind. An event snapshot later shows
		-- what survived, which is not the same thing.
		local stream = K.Debug and K.Debug.Get("chat")
		if stream then
			stream:SnapshotSettled(frame, "after AnchorChat")
		end
	end
	AnchorChat()

	-- The function the client calls to put a chat window back where its saved
	-- settings say. It returns early for the default frame, but the call still
	-- happens, so it is the earliest reliable point to re-assert from.
	if _G.FCF_RestorePositionAndDimensions then
		hooksecurefunc("FCF_RestorePositionAndDimensions", AnchorChat)
	end

	-- Moving the holder moves the chat, and the client never touches the holder, so
	-- a dragged position is the one thing here that cannot be fought over.
	K.CreateMover(holder, "Chat", L["Chat"], { "BOTTOMLEFT", UIParent, "BOTTOMLEFT", 6, bottom }, C.Chat.Width, C.Chat.Height)
	hooksecurefunc(_G.ChatFrame1, "SetPoint", AnchorChat)
	-- Re-pin straight after Edit Mode re-applies its own anchor, since that call
	-- puts the window back under the frame manager.
	if _G.ChatFrame1.ApplySystemAnchor then
		hooksecurefunc(_G.ChatFrame1, "ApplySystemAnchor", AnchorChat)
	end
	-- The pass that actually moved the window is EditModeManagerFrame:UpdateLayoutInfo.
	-- It runs on EDIT_MODE_LAYOUTS_UPDATED and whenever the game swaps to an
	-- override layout, which is what a teleport into an instance does. Inside it,
	-- InitSystemAnchors resets every system with ClearAllPoints followed by
	-- SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0), and UpdateSystems then calls
	-- ApplySystemAnchor for each one. ChatFrame1 is an Edit Mode system frame
	-- (EditModeChatFrameSystemTemplate), so it is caught by both.
	--
	-- Hooking UpdateLayoutInfo re-pins once, after the whole layout pass has
	-- finished, so nothing later in the pass can undo it.
	if _G.EditModeManagerFrame then
		hooksecurefunc(_G.EditModeManagerFrame, "UpdateLayoutInfo", AnchorChat)
	end
	-- The call that rewrites the insets. UpdateSystem runs ApplySystemAnchor (hooked
	-- above) and then AnchorSelectionFrame, which lands on this, so the insets are
	-- set after our anchor pass and need clearing again right behind it.
	if _G.ChatFrame1.UpdateClampOffsets then
		hooksecurefunc(_G.ChatFrame1, "UpdateClampOffsets", ClearClampInsets)
	end
	self:RegisterEvent("PLAYER_ENTERING_WORLD", AnchorChat)
	-- A scale change re-derives the window from Blizzard's stored fractions, so it
	-- has to be pinned again afterwards.
	self:RegisterEvent("UI_SCALE_CHANGED", AnchorChat)
	-- The two that were actually letting it drift. Both fire on a zone change and
	-- both run FloatingChatFrame_Update, which re-applies the window geometry the
	-- client has stored. That path resizes as well as moves, so a SetPoint hook
	-- never sees half of it.
	self:RegisterEvent("UPDATE_CHAT_WINDOWS", AnchorChat)
	self:RegisterEvent("UPDATE_FLOATING_CHAT_WINDOWS", AnchorChat)

	-- Write the result into Blizzard's own saved chat settings. Without this the
	-- client keeps re-deriving a position from its stored values and we spend the
	-- session correcting it.
	if _G.FCF_SavePositionAndDimensions then
		_G.FCF_SavePositionAndDimensions(_G.ChatFrame1)
	end

	-- Lift the tab dock off the chat frame's top edge so the tabs are not
	-- crammed against the messages. Guarded against the hook re-entering.
	local dock = _G.GeneralDockManager
	if dock then
		local fixing
		local function LiftDock()
			if fixing then
				return
			end
			fixing = true
			dock:ClearAllPoints()
			dock:SetPoint("BOTTOMLEFT", _G.ChatFrame1, "TOPLEFT", 0, 6)
			dock:SetPoint("BOTTOMRIGHT", _G.ChatFrame1, "TOPRIGHT", 0, 6)
			fixing = false
		end
		LiftDock()
		hooksecurefunc(dock, "SetPoint", LiftDock)
	end

	-- Blizzard re-textures tabs on colour/hover updates, keep them blanked and
	-- recolour the label so the selected tab stands out.
	if _G.FCFTab_UpdateColors then
		hooksecurefunc("FCFTab_UpdateColors", function(tab, selected)
			StripTab(tab)
			ColorTab(tab, selected)
		end)
	end

	-- The stripped tab glow was the unread cue, so give that cue back here.
	if _G.FCF_StartAlertFlash then
		hooksecurefunc("FCF_StartAlertFlash", TabAlertStart)
	end
	if _G.FCF_StopAlertFlash then
		hooksecurefunc("FCF_StopAlertFlash", TabAlertStop)
	end


	-- Kill the per-frame scroll button clutter and combat-log quick button art.
	for i = 1, NUM_FRAMES do
		local buttonFrame = _G["ChatFrame" .. i .. "ButtonFrame"]
		if buttonFrame then
			buttonFrame:Hide()
			buttonFrame:HookScript("OnShow", buttonFrame.Hide)
		end
	end
	-- The Combat Log lives in a load-on-demand addon (Blizzard_CombatLog) that only
	-- loads the first time its tab is opened, well after we skin the chat. So its
	-- quick-filter bar and the combat-log frame's own washed background do not exist
	-- yet here. Defer that work until the addon loads.
	self:SetupCombatLog()

	for i = 1, NUM_FRAMES do
		self:StyleFrame(i)
	end

	-- Style temporary (whisper) windows and permanent ones the user opens, as they
	-- appear. A post-hook cannot read the window the call returned, and
	-- FCF_GetCurrentChatFrame only tracks the window under an FCF config action, so
	-- instead walk the client's list of windows and style any we have not seen. The
	-- walk is cheap and a styled window is flagged, so repeat calls do nothing.
	local function StyleNewWindows()
		local list = _G.CHAT_FRAMES
		if list then
			for _, frameName in ipairs(list) do
				local frame = _G[frameName]
				if frame and not frame.KKUI_Styled then
					Module:StyleFrame(frame:GetID(), frame)
				end
			end
		else
			for i = NUM_FRAMES + 1, NUM_FRAMES + 10 do
				local frame = _G["ChatFrame" .. i]
				if frame and not frame.KKUI_Styled then
					Module:StyleFrame(i, frame)
				end
			end
		end
	end
	hooksecurefunc("FCF_OpenTemporaryWindow", StyleNewWindows)
	if _G.FCF_OpenNewWindow then
		hooksecurefunc("FCF_OpenNewWindow", StyleNewWindows)
	end

	-- Link URLs in chat text through a filter, and open a copy box when one of our
	-- links is clicked.
	if C.Chat.URLLinks then
		for _, event in ipairs(URL_EVENTS) do
			ChatFrameUtil.AddMessageEventFilter(event, URLFilter)
		end
		-- A registered handler answers the click as handled, so SetItemRef stops
		-- there. A plain hook ran after SetItemRef had already opened an empty
		-- ItemRefTooltip for a link type the client did not know.
		local LinkUtil = LinkUtil
		if LinkUtil and LinkUtil.RegisterLinkHandler and LinkProcessorResponse then
			if not LinkUtil.IsLinkHandlerRegistered("kkurl") then
				LinkUtil.RegisterLinkHandler("kkurl", function(link)
					local url = link:match("^kkurl:(.+)")
					if url then
						ShowURL(url)
					end
					return LinkProcessorResponse.Handled
				end)
			end
		else
			hooksecurefunc("SetItemRef", function(link)
				local url = link:match("^kkurl:(.+)")
				if url then
					ShowURL(url)
				end
			end)
		end
	end

	if C.Chat.HyperlinkTooltip then
		self:EnableHyperlinkTooltips()
	end
	if C.Chat.ChatBar then
		self:CreateChatBar()
	end
	if C.Chat.SideButtons then
		self:CreateSideButtons()
	end
	if C.Chat.SpamFilter then
		self:EnableFilter()
	end
	if C.Chat.HideFleeEmotes then
		self:EnableFleeFilter()
	end
	if C.Chat.SkinBubbles then
		self:SetupBubbles()
	end
	if self.SetupLinkInfo then
		self:SetupLinkInfo()
	end
	if self.SetupKeywords then
		self:SetupKeywords()
	end
	if self.SetupEmojis then
		self:SetupEmojis()
	end
	if self.SetupHistory then
		self:SetupHistory()
	end
	if self.SetupLeaveChannel then
		self:SetupLeaveChannel()
	end

	-- Idle fade. Dim the whole chat to a resting alpha when the mouse is away and
	-- lift it back on hover or while the edit box is focused. Only our own frames
	-- are faded (the message frame and the channel bar) - the tab dock is left to
	-- Blizzard, since writing tab alpha taints the dock update on 12.1.
	if C.Chat.IdleFade then
		local rest = C.Chat.IdleFadeAlpha or 0.25
		-- Every docked window gets the same alpha, since each tab is its own frame and
		-- only one is on screen. Hover is read off the tab you are looking at, so a
		-- window pulled out of the dock is left at full alpha.
		local main = _G.ChatFrame1
		local windows = {}
		-- Edit box names built once, since the hover check runs ten times a second.
		local editBoxNames = {}
		for i = 1, NUM_FRAMES do
			windows[#windows + 1] = _G["ChatFrame" .. i]
			editBoxNames[i] = "ChatFrame" .. i .. "EditBox"
		end
		local bar = C.Chat.ChatBar and _G.KKUI_ChatBar
		local function IsDocked(f)
			return f == main or f.isDocked
		end
		local fadeFrame = CreateFrame("Frame")
		local elapsed = 0
		local target = 1
		local STEP = 3 -- alpha per second
		fadeFrame:SetScript("OnUpdate", function(_, delta)
			local shown = _G.SELECTED_DOCK_FRAME or _G.ChatFrame1

			-- The hover read is the costly part, so it runs on a throttle and the
			-- frames in between only move the alpha.
			elapsed = elapsed + delta
			if elapsed >= 0.1 then
				elapsed = 0
				local over = false
				for i = 1, NUM_FRAMES do
					local editBox = _G[editBoxNames[i]]
					if editBox and editBox:HasFocus() then
						over = true
						break
					end
				end
				over = over or shown:IsMouseOver() or (dock and dock:IsMouseOver())
				if not over and _G.KKUI_ChatBar then
					over = _G.KKUI_ChatBar:IsMouseOver()
				end
				target = over and 1 or rest

				for _, f in ipairs(windows) do
					if not IsDocked(f) and f:GetAlpha() ~= 1 then
						f:SetAlpha(1)
					end
				end
			end

			-- The main window is always docked, so it carries the group's alpha.
			local current = main:GetAlpha()
			if current ~= target then
				local move = STEP * delta
				current = current < target and math.min(target, current + move) or math.max(target, current - move)
				for _, f in ipairs(windows) do
					if IsDocked(f) then
						f:SetAlpha(current)
					end
				end
				if bar then
					bar:SetAlpha(current)
				end
			end
			-- A temporary window (a whisper tab) sits past the permanent ones, and one
			-- selected again may still hold the alpha it was left at.
			if shown ~= main and shown:GetAlpha() ~= current then
				shown:SetAlpha(current)
			end
		end)
	end

	-- Sticky whispers. Keep the edit box on WHISPER after you reply, so a back and
	-- forth does not need re-selecting the channel each line.
	-- ChatFrameEditBoxMixin:OnEnterPressed reads ChatTypeInfo[type].sticky, so a flag
	-- written here is read by Blizzard's secure Enter handler as a tainted value.
	-- That is why this is off unless asked for.
	if C.Chat.StickyWhisper and _G.ChatTypeInfo then
		_G.ChatTypeInfo.WHISPER.sticky = 1
		_G.ChatTypeInfo.BN_WHISPER.sticky = 1
	end
end
