--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Skins/Battlenet.lua
	Purpose:
		Give the Battle.net friend/broadcast toast our border and gradient, and move
		it to a clean spot at the top of the screen instead of floating over the chat.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:NewModule("Battlenet")

local _G = _G
local ipairs = ipairs
local hooksecurefunc = hooksecurefunc

-- Border and gradient on a toast frame, with its stock plate art blanked. The
-- social toasts inherit BackdropTemplate (BACKDROP_TOAST_12_12) rather than a
-- NineSlice, so the dark plate is a real backdrop that has to be cleared, and the
-- close button is a child we reskin to match ours.
local function SkinToast(frame)
	if not frame or frame.KKUI_Skinned then
		return
	end
	frame.KKUI_Skinned = true
	if frame.NineSlice then
		frame.NineSlice:SetAlpha(0)
	end
	if frame.Background then
		frame.Background:SetAlpha(0)
	end
	if frame.SetBackdrop then
		frame:SetBackdrop(nil)
	end
	K.CreateGradientBackground(frame, 0.9)
	K.CreateBorder(frame)

	if frame.CloseButton and K.SkinCloseButton then
		K.SkinCloseButton(frame.CloseButton)
	end
end

function Module:OnEnable()
	if not C.Chat.Enable then
		return
	end

	local toast = _G.BNToastFrame
	if toast then
		SkinToast(toast)
		-- Pin it to the top of the screen and hold it there, since the client
		-- re-anchors the toast as it grows and shrinks.
		local function reanchor()
			if toast.__kkuiAnchoring then
				return
			end
			toast.__kkuiAnchoring = true
			toast:ClearAllPoints()
			toast:SetPoint("TOP", UIParent, "TOP", 0, -160)
			toast.__kkuiAnchoring = false
		end
		reanchor()
		hooksecurefunc(toast, "SetPoint", reanchor)
	end

	-- The GM ticket and time-alert toasts share the same plate, and so do the
	-- shard transfer countdown and the small button beside it that hides and
	-- shows it. Its close button was already parented away by the game.
	SkinToast(_G.TimeAlertFrame)

	-- The game pins the shard toast 30px right of the chat's alert anchor and
	-- hangs the 24px minimize button 5px left of it. That anchor is worked out
	-- from the chat's button strip, which sits left of the window, so with our
	-- chat 6px from the edge the button landed off screen. Both are pinned to our
	-- chat holder instead: the button lines up with the chat's left edge, one gap
	-- before the toast, and the pair sits one gap above the open edit box (26px
	-- up, 22 tall). The game only places them once, when they load.
	local shard = _G.ShardTransferImminentFrame
	local shardButton = _G.ShardTransferImminentMinimizeButton
	local chat = _G.KKUI_ChatHolder
	SkinToast(shard)
	-- The minimize button folds the toast away and back, so it gets our fold
	-- button, a minus while the toast shows and a plus once it is folded.
	if shard and shardButton and K.SkinFoldButton then
		local setOpen = K.SkinFoldButton(shardButton)
		setOpen(shard:IsShown())
		shard:HookScript("OnShow", function()
			setOpen(true)
		end)
		shard:HookScript("OnHide", function()
			setOpen(false)
		end)
	end
	if shard and shardButton and chat then
		local gap = 6
		shard:ClearAllPoints()
		shard:SetPoint("BOTTOMLEFT", chat, "TOPLEFT", shardButton:GetWidth() + gap, 26 + 22 + gap)
		shardButton:ClearAllPoints()
		shardButton:SetPoint("TOPRIGHT", shard, "TOPLEFT", -gap, 0)
	end

	-- Trim any leftover inner textures the toast leaves behind.
	if toast then
		for _, region in ipairs({ toast:GetRegions() }) do
			if region.GetObjectType and region:GetObjectType() == "Texture" and region:GetDrawLayer() == "BORDER" then
				region:SetAlpha(0)
			end
		end
	end
end
