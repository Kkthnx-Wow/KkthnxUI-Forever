--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/Hyperlink.lua
	Purpose:
		Show a tooltip when the mouse rests on a chat hyperlink (item, spell,
		achievement, quest) without having to click it. Kept safe with pcall so an
		unsupported link type never errors.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

local Module = K:GetModule("Chat")

local _G = _G
local pcall = pcall

local NUM_FRAMES = Constants.ChatFrameConstants.MaxChatWindows

local function OnHyperlinkEnter(frame, link)
	-- A link inside a secret message can itself be secret, and cannot be matched.
	if K.IsSecret(link) then
		return
	end
	local kind = link:match("^(%a+):")
	-- Only object links have a useful tooltip, plain URLs and player links do not.
	if not kind or kind == "kkurl" or kind == "player" or kind == "channel" or kind == "BNplayer" then
		return
	end
	GameTooltip:SetOwner(frame, "ANCHOR_CURSOR")
	local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
	if ok then
		GameTooltip:Show()
	else
		GameTooltip:Hide()
	end
end

-- Only a tooltip this window took is hidden, so leaving a link does not close one
-- that something else owns.
local function OnHyperlinkLeave(frame)
	if GameTooltip:IsOwned(frame) then
		GameTooltip:Hide()
	end
end

-- Hook one window. Idempotent, and also called from StyleFrame so a whisper or new
-- tab opened after login gets the tooltips too.
function Module:HookHyperlinkFrame(frame)
	if frame and not frame.__kkuiHyperlink then
		frame.__kkuiHyperlink = true
		frame:HookScript("OnHyperlinkEnter", OnHyperlinkEnter)
		frame:HookScript("OnHyperlinkLeave", OnHyperlinkLeave)
	end
end

function Module:EnableHyperlinkTooltips()
	self.hyperlinkTooltips = true
	for i = 1, NUM_FRAMES do
		self:HookHyperlinkFrame(_G["ChatFrame" .. i])
	end
end
