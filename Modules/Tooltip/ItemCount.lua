--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Tooltip/ItemCount.lua
	Purpose:
		Tell the player how many of an item they hold, in the bags and in the bank,
		at the bottom of the item tooltip. Only shown when it adds something: more
		than one in the bags, or any in the bank. The bank count is the difference
		between the total and the bag count, so it follows whatever the client
		counts as bank on this build.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Tooltip")

local C_Item = C_Item
local IsSecret = K.IsSecret

function Module:SetupItemCount()
	if not C.Tooltip.ShowItemCount then
		return
	end
	if not (TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType and Enum.TooltipDataType.Item) then
		return
	end
	if not (C_Item and C_Item.GetItemCount) then
		return
	end

	TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
		if tt:IsForbidden() or not data then
			return
		end
		local id = data.id
		if not id or IsSecret(id) then
			return
		end

		local bags = C_Item.GetItemCount(id, false) or 0
		local total = C_Item.GetItemCount(id, true) or 0
		local bank = total - bags
		if bags < 2 and bank < 1 then
			return
		end

		local muted, info = K.Colors.muted, K.Colors.info
		local right = bank > 0 and format("%d  |cff%02x%02x%02x%s %d|r", bags, muted[1] * 255, muted[2] * 255, muted[3] * 255, BANK or "Bank", bank) or tostring(bags)
		tt:AddDoubleLine(BAGSLOT or "Bags", right, muted[1], muted[2], muted[3], info[1], info[2], info[3])
		tt:Show()
	end)
end
