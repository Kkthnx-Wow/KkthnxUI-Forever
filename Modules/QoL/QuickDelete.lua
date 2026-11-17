--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/QuickDelete.lua
	Purpose:
		Fill in the word Blizzard makes you type before destroying a good item or
		a quest item, so deleting one is a click on Yes like any other item.

		Blizzard's dialog is left exactly as it is. Only the text of its edit box
		is set, after Blizzard has shown it. The dialog's own text handler then
		enables Yes, and Yes still runs Blizzard's own accept, which matters
		because the delete call is restricted. Replacing the dialog definition
		instead would run the delete from addon code.

		The dialog still names the item, No or Escape still cancels, and the
		box is left without focus so Enter does nothing to it. A delete takes a
		click on Yes.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("QoL")

local hooksecurefunc = hooksecurefunc
local StaticPopup_FindVisible = StaticPopup_FindVisible

-- The two dialogs that ask for the typed word. Their gamepad versions are
-- already a plain Yes and No.
local TYPED = {
	DELETE_GOOD_ITEM = true,
	DELETE_GOOD_QUEST_ITEM = true,
}

local function OnPopupShown(which)
	if not TYPED[which] or not C.QoL.QuickDelete then
		return
	end
	local dialog = StaticPopup_FindVisible(which)
	local editBox = dialog and dialog.GetEditBox and dialog:GetEditBox()
	if editBox and DELETE_ITEM_CONFIRM_STRING then
		editBox:SetText(DELETE_ITEM_CONFIRM_STRING)
		-- Blizzard focuses the box on show, and Enter in a filled box presses
		-- Yes. Dropping the focus means an Enter meant for chat cannot destroy
		-- the item. Escape still cancels through the dialog's own handling.
		editBox:ClearFocus()
	end
end

function Module:SetupQuickDelete()
	if self.quickDeleteHooked then
		return
	end
	self.quickDeleteHooked = true
	-- A post hook. StaticPopup_Show has already built and shown the dialog by
	-- the time this runs, and nothing it returns or does is changed.
	hooksecurefunc("StaticPopup_Show", OnPopupShown)
end
