--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/QoL/TradeInfo.lua
	Purpose:
		Say who you are trading with, under their name on the trade window. A
		friend, a Battle.net friend, a guild member, or someone you do not know,
		so a trade from a stranger pretending to be someone stands out.

		Checks go by the other player's GUID. When the client hands that over as
		a secret value nothing is shown, rather than a guess.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("QoL")

local C_BattleNet = C_BattleNet
local C_FriendList = C_FriendList
local CreateFrame = CreateFrame
local IsGuildMember = IsGuildMember
local UnitGUID = UnitGUID
local IsSecret = K.IsSecret

-- The trade partner is the "NPC" unit while the trade window is open.
local UNIT = "NPC"

local label

-- Returns the text and its colour for a GUID, or nil when nothing can be said.
local function Describe(guid)
	if not guid or IsSecret(guid) then
		return
	end
	if C_FriendList.IsFriend(guid) then
		return L["Friend"], 0.3, 1, 0.3
	end
	local account = C_BattleNet.GetAccountInfoByGUID(guid)
	if account and account.isFriend then
		return L["Battle.net Friend"], 0.3, 0.75, 1
	end
	if IsGuildMember(guid) then
		return L["Guild Member"], 0.25, 1, 0.25
	end
	return L["Stranger"], 1, 0.3, 0.3
end

local function Update()
	if not C.QoL.TradeInfo then
		label:SetText("")
		return
	end
	local text, r, g, b = Describe(UnitGUID(UNIT))
	label:SetText(text or "")
	if text then
		label:SetTextColor(r, g, b)
	end
end

function Module:SetupTradeInfo()
	if label or not TradeFrame or not TradeFrameRecipientNameText then
		return
	end
	-- Our own frame, high enough to sit over the window's title art the way the
	-- name it labels does. Nothing is written onto the trade window itself.
	local holder = CreateFrame("Frame", nil, TradeFrame)
	holder:SetAllPoints(TradeFrameRecipientNameText)
	holder:SetFrameStrata("HIGH")
	label = holder:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("TOPLEFT", TradeFrameRecipientNameText, "BOTTOMLEFT", 0, -4)
	label:SetJustifyH("LEFT")

	TradeFrame:HookScript("OnShow", Update)
	self:RegisterEvent("TRADE_SHOW", Update)
end

-- Exposed for testing. Shows the label for any unit without opening a trade.
function Module:DescribeTradeUnit(unit)
	return Describe(UnitGUID(unit))
end
