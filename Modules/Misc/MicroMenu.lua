--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Misc/MicroMenu.lua
	Purpose:
		A compact, movable micro menu. The Blizzard micro buttons (character,
		spellbook, collections, and so on) are reparented onto our own bar, sized
		to a row, and given our border. An optional mouseover fade keeps it out of
		the way.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("MicroMenu")

local _G = _G
local pcall = pcall
local hooksecurefunc = hooksecurefunc
local InCombatLockdown = InCombatLockdown

-- Fallback names for the micro buttons, in display order, used only when the
-- client's own MicroMenu cannot be read. WoW Forever splits the spellbook and the
-- talents into two buttons and has no achievement button, so the list that is
-- really used comes from CollectButtons below.
local BUTTONS = {
	"CharacterMicroButton",
	"ProfessionMicroButton",
	"SpellbookMicroButton",
	"TalentMicroButton",
	"LegacyMicroButton",
	"QuestLogMicroButton",
	"HousingMicroButton",
	"GuildMicroButton",
	"LFDMicroButton",
	"CollectionsMicroButton",
	"EJMicroButton",
	"HelpMicroButton",
	"StoreMicroButton",
	"MainMenuMicroButton",
}

-- The buttons the game put in its own micro menu, in its order. The menu decides
-- which ones exist (a game rule can remove one), and a button the client defines
-- but never adds to it is not part of the interface, so taking it onto our bar
-- shows a dead icon.
local buttonNames = BUTTONS

local function CollectButtons()
	local menu = _G.MicroMenu
	if not (menu and menu.GetChildren) then
		return BUTTONS
	end
	local found = {}
	for _, child in ipairs({ menu:GetChildren() }) do
		if child.layoutIndex and child.GetName and child:GetName() then
			found[#found + 1] = child
		end
	end
	if #found == 0 then
		return BUTTONS
	end
	table.sort(found, function(a, b)
		return a.layoutIndex < b.layoutIndex
	end)
	local names = {}
	for i, child in ipairs(found) do
		names[i] = child:GetName()
	end
	return names
end

local bar

-- The game's micro button art is an atlas with transparent padding, so it sits
-- small inside our box. Every state texture is stretched to the button and cropped
-- to the same window. SetTexCoord on an atlas texture works inside the atlas
-- region, which the game's own SetNormalAtlas and SetHighlightAtlas calls keep.
local CROP_LEFT, CROP_RIGHT, CROP_TOP, CROP_BOTTOM = 0.18, 0.82, 0.2, 0.8

local function Fill(btn, tex)
	if tex then
		tex:ClearAllPoints()
		tex:SetAllPoints(btn)
		tex:SetTexCoord(CROP_LEFT, CROP_RIGHT, CROP_TOP, CROP_BOTTOM)
	end
end

-- The character button draws a live portrait on top of its frame. The game moves it
-- a couple of pixels when the button is pushed and puts it back when released, so
-- the fit is applied again after both, with a one pixel nudge while pushed.
local function FitPortrait(btn)
	local portrait = btn.Portrait
	if not portrait then
		return
	end
	local push = btn:GetButtonState() == "PUSHED" and 1 or 0
	portrait:ClearAllPoints()
	portrait:SetPoint("TOPLEFT", btn, "TOPLEFT", 1 + push, -1 - push)
	portrait:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1 + push, 1 - push)
	portrait:SetTexCoord(0.1, 0.9, 0.1, 0.9)
end

-- The main menu button carries a latency bar sized for the game's 32 by 41 button.
-- Scale it with the button so it stays inside it.
local function FitExtras(btn)
	local latency = btn.MainMenuBarPerformanceBar
	if latency then
		local w, h = btn:GetSize()
		latency:SetSize(math.max(2, K.Round(w * 19 / 32)), math.max(2, K.Round(h * 39 / 41)))
		latency:ClearAllPoints()
		latency:SetPoint("BOTTOM", btn, "BOTTOM", 0, 0)
	end
end

-- Blizzard resets these on UpdateMicroButtons, so this is re-applied from the hook.
local function CropButton(btn, name)
	Fill(btn, btn:GetNormalTexture())
	Fill(btn, btn:GetPushedTexture())
	Fill(btn, btn:GetDisabledTexture())
	-- The hover art has the icon baked in, which is why the game fades the normal
	-- texture out on mouseover. It has to be cropped the same way or the icon
	-- would jump size under the cursor.
	Fill(btn, btn:GetHighlightTexture())
	-- The pulse shown when a button wants attention.
	Fill(btn, btn.FlashContent)

	if name == "CharacterMicroButton" then
		-- The portrait shadow is sized for the game's button and spills past ours.
		if btn.Shadow then
			btn.Shadow:SetAlpha(0)
		end
		if btn.PushedShadow then
			btn.PushedShadow:SetAlpha(0)
		end
		if btn.PortraitMask then
			btn.PortraitMask:Hide()
		end
		FitPortrait(btn)
	end
end

local function ReapplyIcons()
	for _, name in ipairs(buttonNames) do
		local btn = _G[name]
		if btn and btn.__kkuiMicro then
			CropButton(btn, name)
		end
	end
end

-- Lay the reparented buttons into a single row and size the bar to fit.
local function Layout()
	if not bar then
		return
	end
	local cfg = C.MicroMenu
	local h = cfg.ButtonSize
	-- Micro buttons keep their portrait aspect so the icons do not distort.
	local w = K.Round(h * 0.82)
	local space = cfg.Spacing
	local vertical = cfg.Orientation == "VERTICAL"

	local list, count = {}, 0
	for _, name in ipairs(buttonNames) do
		local btn = _G[name]
		-- Skip buttons the client currently hides, so they leave no blank gap.
		if btn and btn.__kkuiMicro and btn:IsShown() then
			count = count + 1
			list[count] = btn
		end
	end

	local reverse = cfg.Order == "REVERSE"
	local pos = 0
	for i = 1, count do
		local btn = list[reverse and (count - i + 1) or i]
		btn:ClearAllPoints()
		btn:SetSize(w, h)
		FitExtras(btn)
		if vertical then
			btn:SetPoint("TOP", bar, "TOP", 0, -pos)
			pos = pos + h + space
		else
			btn:SetPoint("LEFT", bar, "LEFT", pos, 0)
			pos = pos + w + space
		end
	end

	local length = math.max(1, pos - space)
	if vertical then
		bar:SetSize(w, length)
	else
		bar:SetSize(length, h)
	end
	return count
end

local function Skin(btn, name)
	if btn.__kkuiMicro then
		return
	end
	btn.__kkuiMicro = true

	-- Reparent out of the Blizzard container so its layout no longer moves them.
	btn:SetParent(bar)
	btn:SetHitRectInsets(0, 0, 0, 0)

	-- Clear the game's button plate so only the icon and our border show. The game
	-- still shows and hides these as the button is pushed, which is harmless. The
	-- flash art is left alone so an alert pulse is still visible.
	if btn.Background then
		btn.Background:SetTexture()
	end
	if btn.PushedBackground then
		btn.PushedBackground:SetTexture()
	end

	K.CreateBackground(btn, 0.06, 0.06, 0.06, 0.9)
	CropButton(btn, name)

	-- The game swaps the hover atlas on every state change (and the main menu button
	-- every second), so the crop is applied again each time it does.
	if btn.SetHighlightAtlas then
		hooksecurefunc(btn, "SetHighlightAtlas", function(self)
			Fill(self, self:GetHighlightTexture())
		end)
	end

	if name == "CharacterMicroButton" then
		if btn.SetPushed then
			hooksecurefunc(btn, "SetPushed", FitPortrait)
		end
		if btn.SetNormal then
			hooksecurefunc(btn, "SetNormal", FitPortrait)
		end
	end

	if not btn.KKUI_Border then
		K.CreateBorder(btn)
	end
end

function Module:Setup()
	if self.setupDone then
		return
	end
	self.setupDone = true

	bar = CreateFrame("Frame", "KKUI_MicroMenu", UIParent)
	bar:SetSize(200, C.MicroMenu.ButtonSize)

	buttonNames = CollectButtons()

	-- The game's own menu keeps drawing its frame art once its buttons have moved to
	-- our bar, which leaves an empty dark panel behind. Only the art is faded, the
	-- container stays so the game's layout code keeps working.
	local stock = _G.MicroMenu
	if stock then
		if stock.BorderArt then
			stock.BorderArt:SetAlpha(0)
		end
		if stock.BackgroundArt then
			stock.BackgroundArt:SetAlpha(0)
		end
	end

	for _, name in ipairs(buttonNames) do
		local btn = _G[name]
		if btn then
			pcall(Skin, btn, name)
		end
	end

	Layout()
	K.CreateMover(bar, "MicroMenu", L["Micro Menu"], { "BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -4, 4 }, bar:GetWidth(), bar:GetHeight())

	-- Blizzard relays out the micro menu on many events. Reparenting takes the
	-- buttons out of that flow, but re-apply on its update just in case.
	if _G.UpdateMicroButtons then
		hooksecurefunc("UpdateMicroButtons", function()
			ReapplyIcons()
			if not InCombatLockdown() then
				Layout()
			end
		end)
	end

	-- Late-set atlases (some buttons finish their art after login) get one more pass.
	self:RegisterEvent("PLAYER_ENTERING_WORLD", function()
		ReapplyIcons()
		Layout()
	end)
end

function Module:OnEnable()
	if not C.MicroMenu.Enable then
		-- With ours off, the stock micro menu is parked on the hidden parent when the
		-- player asked for that, and left as the game made it otherwise. The menu
		-- itself is untouched, so the game's own layout code keeps working, and
		-- keybinds still open every panel.
		local stock = C.MicroMenu.HideStock and _G.MicroMenuContainer
		if stock then
			local hidden = _G.KKUI_HiddenParent
			if not hidden then
				hidden = CreateFrame("Frame", "KKUI_HiddenParent", UIParent)
				hidden:Hide()
			end
			if InCombatLockdown() then
				K.DeferCombat("MicroMenuStockHide", function()
					stock:SetParent(hidden)
				end)
			else
				stock:SetParent(hidden)
			end
		end
		return
	end
	self:Setup()
end
