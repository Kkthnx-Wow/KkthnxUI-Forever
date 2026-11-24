--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/Bubbles.lua
	Purpose:
		Replace the in-world chat bubbles with compact ones of our own. Blizzard's
		bubble is kept, made invisible, and used only as a position: we draw our
		own bubble in its place with the chat font, a width cap, the speaker's
		name, emoji icons, the panel gradient and the nameplate shadow, and follow
		it every frame while any bubble is on screen.

		Bubbles in instances are forbidden to addons and are left exactly as the
		client draws them, as is any bubble whose text comes back secret.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Chat")

local pairs = pairs
local wipe = wipe
local abs = math.abs
local floor = math.floor
local math_min = math.min
local GetTime = GetTime
local GetCVarBool = GetCVarBool
local CreateFrame = CreateFrame
local WorldFrame = _G.WorldFrame
local Ambiguate = Ambiguate
local GetPlayerInfoByGUID = GetPlayerInfoByGUID
local UnitTokenFromGUID = UnitTokenFromGUID
local UnitLevel = UnitLevel
local GetMaxLevelForPlayerExpansion = GetMaxLevelForPlayerExpansion
local IsSecret = K.IsSecret
local GetAllChatBubbles = C_ChatBubbles and C_ChatBubbles.GetAllChatBubbles

-- The events that spawn a bubble, paired with the cvar that has to be on for that
-- kind to appear.
local SPAWN_EVENTS = {
	CHAT_MSG_SAY = "chatBubbles",
	CHAT_MSG_YELL = "chatBubbles",
	CHAT_MSG_MONSTER_SAY = "chatBubbles",
	CHAT_MSG_MONSTER_YELL = "chatBubbles",
	CHAT_MSG_PARTY = "chatBubblesParty",
	CHAT_MSG_PARTY_LEADER = "chatBubblesParty",
	CHAT_MSG_MONSTER_PARTY = "chatBubblesParty",
	CHAT_MSG_RAID = "chatBubblesRaid",
	CHAT_MSG_RAID_LEADER = "chatBubblesRaid",
	CHAT_MSG_RAID_WARNING = "chatBubblesRaid",
}

local PADDING = 8
-- Width cap in characters of chat font, so a bigger font gets a wider bubble.
local WIDTH_PER_FONT_PX = 22
-- How long after a spawning event we keep looking for the new bubble. It is not
-- on the list on the frame the message arrives.
local SCAN_WINDOW = 0.5
local FADE_IN = 0.15

-- A bubble carries no reference to whoever spoke, only the words. The chat event
-- does know, so the sender is stashed against the text and looked up when the
-- bubble shows. Capped and wiped on a loading screen so it cannot grow forever.
local senderByMessage = {}
local guidByMessage = {}
local stashed = 0
local MAX_STASHED = 300

local layer -- holds every bubble of ours, scaled to match UIParent
local driver -- runs the scan and the follow loop, only while there is work
local mirrors = {} -- Blizzard bubble -> our bubble, for every bubble adopted
local scanUntil = 0
local nextLevel = 0

local function FontSize()
	return C.Chat.FontSize or 13
end

-- The speaker's level, difficulty coloured, when they are under the level cap.
-- The bubble only has a GUID, so this works when the client can map it to a unit,
-- which in practice means the speaker has a nameplate or is your target or group.
local function SpeakerLevel(guid)
	local unit = guid and UnitTokenFromGUID and UnitTokenFromGUID(guid)
	if not unit or IsSecret(unit) then
		return ""
	end
	local level = UnitLevel(unit)
	local cap = GetMaxLevelForPlayerExpansion and GetMaxLevelForPlayerExpansion()
	if not level or IsSecret(level) or level <= 0 or (cap and level >= cap) then
		return ""
	end
	local color = K.UnitDifficultyColor and K.UnitDifficultyColor(unit)
	if color then
		return K.RGBToHex(color.r, color.g, color.b) .. level .. "|r "
	end
	-- White of its own, or it takes the chat colour of the text around it.
	return "|cffffffff" .. level .. "|r "
end

local function SpeakerPrefix(text)
	if not C.Chat.BubbleName then
		return ""
	end
	local sender = senderByMessage[text]
	if not sender then
		return ""
	end
	local color
	local guid = guidByMessage[text]
	if guid then
		local _, class = GetPlayerInfoByGUID(guid)
		if class and not IsSecret(class) then
			color = K.ClassColors[class]
		end
	end
	color = color or K.Colors.accent
	local r, g, b = color.r or color[1], color.g or color[2], color.b or color[3]
	return SpeakerLevel(guid) .. K.RGBToHex(r, g, b) .. sender .. ":|r "
end

local function CreateMirror()
	local frame = CreateFrame("Frame", nil, layer)
	frame:Hide()
	-- The same blue panel gradient as the config window, with the nameplate shadow.
	K.CreateGradientBackground(frame, 0.85)
	K.CreateShadow(frame)

	local text = frame:CreateFontString(nil, "OVERLAY")
	text:SetPoint("TOPLEFT", PADDING, -PADDING)
	text:SetJustifyH("LEFT")
	text:SetWordWrap(true)
	frame.text = text

	local fade = frame:CreateAnimationGroup()
	local alpha = fade:CreateAnimation("Alpha")
	alpha:SetFromAlpha(0)
	alpha:SetToAlpha(1)
	alpha:SetDuration(FADE_IN)
	frame.fade = fade
	return frame
end

-- The client colours a bubble's text by chat type (party blue, yell red, NPC
-- yellow), so the shadow borrows that colour, softly. Plain say is white text and
-- keeps the black shadow, since a white glow would only blur it.
local TINT_ALPHA = 0.6

local function TintShadow(mirror, r, g, b)
	if C.Chat.BubbleChatColor and not (r > 0.95 and g > 0.95 and b > 0.95) then
		K.SetShadowColor(mirror, r, g, b, TINT_ALPHA)
	else
		K.SetShadowColor(mirror, 0, 0, 0, 1)
	end
end

-- New words in a bubble: set the text, size the box around it, fade it in.
local function SetMirrorText(mirror, message, r, g, b)
	local fs = mirror.text
	local size = FontSize()
	fs:SetFont(K.GetFont(C.Chat.Font), size, C.Chat.FontOutline and "OUTLINE" or "")
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
	fs:SetTextColor(r, g, b)
	TintShadow(mirror, r, g, b)

	local shown = SpeakerPrefix(message) .. (Module.Emojify and Module.Emojify(message) or message)
	fs:SetText(shown)
	fs:SetWidth(0)
	local natural = fs.GetUnboundedStringWidth and fs:GetUnboundedStringWidth() or fs:GetStringWidth()
	local width = math_min(natural, size * WIDTH_PER_FONT_PX)
	fs:SetWidth(width + 1)
	mirror:SetSize(floor(width + 1 + PADDING * 2 + 0.5), floor(fs:GetStringHeight() + PADDING * 2 + 0.5))

	-- Newest bubble on top where two overlap.
	nextLevel = nextLevel % 100 + 1
	mirror:SetFrameLevel(nextLevel * 3)
	mirror.message = message
	mirror:Show()
	mirror.fade:Play()
end

local function Release(bubble, holder)
	local mirror = mirrors[bubble]
	if mirror then
		mirror:Hide()
		mirror.message = nil
	end
	if holder then
		holder:SetAlpha(1)
	end
end

-- Keep one bubble's mirror in step with it. Returns true while it is on screen.
local function Follow(bubble, mirror)
	if bubble:IsForbidden() or not bubble:IsShown() then
		mirror:Hide()
		mirror.message = nil
		return false
	end
	local holder = bubble:GetChildren()
	local str = holder and holder.String
	if not str then
		mirror:Hide()
		return false
	end

	local message = str:GetText()
	if not message or message == "" or IsSecret(message) then
		-- Nothing we may read, so hand the bubble back to the client.
		Release(bubble, holder)
		return false
	end
	holder:SetAlpha(0)

	if message ~= mirror.message then
		SetMirrorText(mirror, message, str:GetTextColor())
	end

	-- Centre over the bubble, bottom on its bottom, in our layer's coordinates.
	local cx, bottom = holder:GetCenter(), holder:GetBottom()
	if not cx or not bottom then
		return true
	end
	local ratio = holder:GetEffectiveScale() / layer:GetEffectiveScale()
	local x, y = cx * ratio, bottom * ratio
	if not mirror.x or abs(mirror.x - x) > 0.5 or abs(mirror.y - y) > 0.5 then
		mirror.x, mirror.y = x, y
		mirror:ClearAllPoints()
		mirror:SetPoint("BOTTOM", layer, "BOTTOMLEFT", x, y)
	end
	return true
end

local function Adopt(bubble)
	if mirrors[bubble] or bubble:IsForbidden() then
		return
	end
	local holder = bubble:GetChildren()
	if not holder or holder:IsForbidden() or not holder.String then
		return
	end
	mirrors[bubble] = CreateMirror()
	-- The client reuses bubbles, and ours keeps it invisible. Wake the follow loop
	-- whenever it comes back, whatever chat type brought it, so it is never left
	-- hidden with nothing drawn over it.
	bubble:HookScript("OnShow", function()
		driver:Show()
	end)
end

local function OnUpdate(self)
	if GetTime() < scanUntil then
		-- The list can come back as a secret table, which cannot be walked.
		local list = GetAllChatBubbles()
		if list and not IsSecret(list) then
			for _, bubble in pairs(list) do
				Adopt(bubble)
			end
		end
	end

	local active = false
	for bubble, mirror in pairs(mirrors) do
		if Follow(bubble, mirror) then
			active = true
		end
	end

	-- Sleep once nothing is on screen and no new bubble is expected. A chat event
	-- or a bubble's OnShow wakes us again.
	if not active and GetTime() >= scanUntil then
		self:Hide()
	end
end

local function Stash(message, sender, guid)
	if not (message and sender) or IsSecret(message) or IsSecret(sender) then
		return
	end
	if stashed >= MAX_STASHED then
		wipe(senderByMessage)
		wipe(guidByMessage)
		stashed = 0
	end
	stashed = stashed + 1
	senderByMessage[message] = Ambiguate(sender, "none")
	guidByMessage[message] = (guid and not IsSecret(guid)) and guid or nil
end

local function OnEvent(self, event, message, sender, _, _, _, _, _, _, _, _, _, guid)
	if event == "PLAYER_ENTERING_WORLD" then
		wipe(senderByMessage)
		wipe(guidByMessage)
		stashed = 0
		for bubble in pairs(mirrors) do
			mirrors[bubble]:Hide()
			mirrors[bubble].message = nil
		end
		return
	end
	if event == "UI_SCALE_CHANGED" or event == "DISPLAY_SIZE_CHANGED" then
		layer:SetScale(UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale())
		for _, mirror in pairs(mirrors) do
			mirror.x = nil
			mirror.message = nil -- resize on the next frame
		end
		return
	end

	local cvar = SPAWN_EVENTS[event]
	if not (cvar and GetCVarBool(cvar)) then
		return
	end
	Stash(message, sender, guid)
	scanUntil = GetTime() + SCAN_WINDOW
	self:Show()
end

function Module:SetupBubbles()
	if not C.Chat.SkinBubbles or not GetAllChatBubbles then
		return
	end

	-- On the WorldFrame so bubbles stay with the UI hidden, as the client's do,
	-- scaled so our shadow and font match the rest of the UI.
	layer = CreateFrame("Frame", nil, WorldFrame)
	layer:SetAllPoints(WorldFrame)
	layer:SetFrameStrata("BACKGROUND")
	layer:SetScale(UIParent:GetEffectiveScale() / WorldFrame:GetEffectiveScale())

	driver = CreateFrame("Frame", nil, layer)
	driver:Hide()
	for event in pairs(SPAWN_EVENTS) do
		driver:RegisterEvent(event)
	end
	driver:RegisterEvent("PLAYER_ENTERING_WORLD")
	driver:RegisterEvent("UI_SCALE_CHANGED")
	driver:RegisterEvent("DISPLAY_SIZE_CHANGED")
	driver:SetScript("OnEvent", OnEvent)
	driver:SetScript("OnUpdate", OnUpdate)
end
