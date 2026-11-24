--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Manager.lua
	Purpose:
		The bag sections panel, opened from a button on the bag window. It lists
		the sections in the same top to bottom order the bags draw them, with
		groups as folding parents and their member sections nested underneath.

		Each row carries an on switch (an off section stops catching items and they
		fall to the next one that fits), its live item count, up and down arrows
		for its place among its siblings, and a menu for the rest. An item dropped
		on a section row is filed under that section. The list is virtual, a fixed
		set of row frames reused as it scrolls, so a long list costs nothing.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Bags")
if not Module then
	return
end

local ipairs = ipairs
local type = type
local tonumber = tonumber
local max = math.max
local min = math.min
local strtrim = strtrim
local CreateFrame = CreateFrame
local MenuUtil = MenuUtil
local GameTooltip = GameTooltip
local GetCursorInfo = GetCursorInfo
local CursorHasItem = CursorHasItem
local ClearCursor = ClearCursor

local WIDTH = 330
local PAD = 10
local ROW_H = 22
local VISIBLE = 16
local INDENT = 16
local LIST_TOP = 96 -- below the title, the button row and the two line hint
local ARROW = K.MediaFolder .. "Textures\\DropdownArrow.tga"

local muted, gold, text, disabled = K.Colors.muted, K.Colors.gold, K.Colors.text, K.Colors.disabled

-- Assign whatever item sits on the cursor to a section, then drop it back into
-- its slot. The rows are plain frames, so reading the cursor here cannot taint.
local function AssignCursorTo(catKey)
	if not catKey or not CursorHasItem() then
		return
	end
	local kind, a, b = GetCursorInfo()
	if kind ~= "item" then
		return
	end
	local itemID = (type(a) == "number" and a) or (type(b) == "string" and tonumber(b:match("item:(%d+)")))
	if itemID then
		Module:AssignItem(itemID, catKey)
		ClearCursor()
	end
end

-- Items the bag window put under a section on its last layout. Gear split by slot
-- counts under Equipment, and a group sums its members.
local function CountOf(key)
	local counts = Module.BagFrame and Module.BagFrame.sectionCounts
	if not counts then
		return 0
	end
	local total = counts[key] or 0
	if key == "Equipment" then
		for _, slotName in ipairs(Module.GearSlotOrder or {}) do
			total = total + (counts["Equipment:" .. slotName] or 0)
		end
	end
	return total
end

local function SmallButton(parent, label, width, onClick)
	local button = CreateFrame("Button", nil, parent)
	button:SetSize(width, 20)
	button.Text = button:CreateFontString(nil, "OVERLAY")
	K.SetFont(button.Text, 12, K.FontOutlineStyle())
	button.Text:SetPoint("CENTER")
	button.Text:SetText(label)
	K.SkinButton(button)
	button:SetScript("OnClick", onClick)
	return button
end

local function ArrowButton(row, up)
	local button = CreateFrame("Button", nil, row)
	button:SetSize(16, 16)
	local icon = button:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints()
	icon:SetTexture(ARROW)
	-- The art points down, so the up arrow is the same art flipped.
	if up then
		icon:SetTexCoord(0, 1, 1, 0)
	end
	icon:SetVertexColor(muted[1], muted[2], muted[3])
	button.Icon = icon
	button:SetScript("OnEnter", function(self)
		self.Icon:SetVertexColor(1, 1, 1)
	end)
	button:SetScript("OnLeave", function(self)
		self.Icon:SetVertexColor(muted[1], muted[2], muted[3])
	end)
	button:SetScript("OnClick", function(self)
		local node = self:GetParent().node
		if node then
			Module:MoveNode(node.key, up and -1 or 1)
		end
	end)
	return button
end

-- ---------------------------------------------------------------------------
-- Row menu
-- ---------------------------------------------------------------------------

local function ShowRowMenu(owner, node)
	if not (node and MenuUtil and MenuUtil.CreateContextMenu) then
		return
	end
	MenuUtil.CreateContextMenu(owner, function(_, root)
		root:CreateTitle(node.name)
		if node.kind == "group" then
			root:CreateButton(L["Rename Group"], function()
				K.Prompt(L["Rename Group"], node.name, function(value)
					Module:RenameGroup(node.name, value)
				end)
			end)
			root:CreateButton(L["Delete Group"], function()
				Module:DeleteGroup(node.name)
			end)
			return
		end

		local key = node.key
		local current = C.Bags.CategoryGroup and C.Bags.CategoryGroup[key]
		local move = root:CreateButton(L["Move to Group"])
		move:CreateButton(L["New Group"], function()
			K.Prompt(L["New Group"], "", function(value)
				local name = Module:CreateGroup(strtrim(value or ""))
				if name then
					Module:AssignCategoryGroup(key, name)
				end
			end)
		end)
		for _, name in ipairs(Module:GroupOrder()) do
			if name ~= current then
				move:CreateButton(name, function()
					Module:AssignCategoryGroup(key, name)
				end)
			end
		end
		if current then
			root:CreateButton(L["Remove from Group"], function()
				Module:AssignCategoryGroup(key, nil)
			end)
		end
		root:CreateDivider()
		root:CreateButton(L["Clear Assigned Items"], function()
			Module:ClearCategoryItems(key)
		end)
		if node.custom and Module.DeleteCustomCategory then
			root:CreateButton(L["Delete Category"], function()
				Module:DeleteCustomCategory(key)
			end)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Rows
-- ---------------------------------------------------------------------------

local function RowOnEnter(self)
	self.Hover:Show()
	local node = self.node
	if node and node.kind == "section" and CursorHasItem() then
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:SetText(L["Drop to file the item here"], 1, 1, 1)
		GameTooltip:Show()
	end
end

local function RowOnLeave(self)
	self.Hover:Hide()
	GameTooltip:Hide()
end

local function RowOnClick(self, button)
	local node = self.node
	if not node then
		return
	end
	if node.kind == "section" and CursorHasItem() then
		AssignCursorTo(node.key)
		return
	end
	if button == "RightButton" then
		ShowRowMenu(self, node)
	elseif node.kind == "group" then
		local panel = Module.Manager
		panel.folded[node.key] = not panel.folded[node.key] or nil
		Module:RefreshManager()
	end
end

local function CheckOnClick(self)
	local node = self:GetParent().node
	if node then
		Module:SetSectionOn(node.key, self:GetChecked() and true or false)
	end
end

local function CheckOnEnter(self)
	local node = self:GetParent().node
	if not node then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	if node.key == "Miscellaneous" then
		GameTooltip:SetText(L["Always on"], 1, 1, 1)
		GameTooltip:AddLine(L["Everything no other section takes lands here."], muted[1], muted[2], muted[3], true)
	else
		GameTooltip:SetText(L["Use this section"], 1, 1, 1)
		GameTooltip:AddLine(L["Turned off, its items go to the next section that fits."], muted[1], muted[2], muted[3], true)
	end
	GameTooltip:Show()
end

local function CreateRow(panel)
	local row = CreateFrame("Button", nil, panel)
	row:SetSize(WIDTH - PAD * 2 - 8, ROW_H)
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:SetScript("OnClick", RowOnClick)
	row:SetScript("OnReceiveDrag", function(self)
		if self.node and self.node.kind == "section" then
			AssignCursorTo(self.node.key)
		end
	end)
	row:SetScript("OnEnter", RowOnEnter)
	row:SetScript("OnLeave", RowOnLeave)

	local hover = row:CreateTexture(nil, "BACKGROUND")
	hover:SetAllPoints()
	hover:SetColorTexture(1, 1, 1, 0.06)
	hover:Hide()
	row.Hover = hover

	-- Group rows get a band so the parents read apart from their members.
	local band = row:CreateTexture(nil, "BACKGROUND", nil, -1)
	band:SetAllPoints()
	band:SetColorTexture(K.Colors.accent[1], K.Colors.accent[2], K.Colors.accent[3], 0.12)
	row.Band = band

	local check = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
	K.SkinCheckBox(check)
	check:SetScript("OnClick", CheckOnClick)
	check:SetScript("OnEnter", CheckOnEnter)
	check:SetScript("OnLeave", GameTooltip_Hide)
	row.Check = check

	local fold = row:CreateFontString(nil, "OVERLAY")
	K.SetFont(fold, 13, K.FontOutlineStyle())
	fold:SetTextColor(gold[1], gold[2], gold[3])
	fold:SetWidth(16)
	row.Fold = fold

	local menu = CreateFrame("Button", nil, row)
	menu:SetSize(18, 18)
	menu:SetPoint("RIGHT", row, "RIGHT", 0, 0)
	menu.Text = menu:CreateFontString(nil, "OVERLAY")
	K.SetFont(menu.Text, 13, K.FontOutlineStyle())
	menu.Text:SetPoint("CENTER", 0, 3)
	menu.Text:SetText("...")
	menu.Text:SetTextColor(muted[1], muted[2], muted[3])
	menu:SetScript("OnClick", function(self)
		ShowRowMenu(self, self:GetParent().node)
	end)
	menu:SetScript("OnEnter", function(self)
		self.Text:SetTextColor(1, 1, 1)
	end)
	menu:SetScript("OnLeave", function(self)
		self.Text:SetTextColor(muted[1], muted[2], muted[3])
	end)
	row.Menu = menu

	row.Down = ArrowButton(row, false)
	row.Down:SetPoint("RIGHT", menu, "LEFT", -2, 0)
	row.Up = ArrowButton(row, true)
	row.Up:SetPoint("RIGHT", row.Down, "LEFT", -2, 0)

	local count = row:CreateFontString(nil, "OVERLAY")
	K.SetFont(count, 12, K.FontOutlineStyle())
	count:SetPoint("RIGHT", row.Up, "LEFT", -8, 0)
	count:SetJustifyH("RIGHT")
	row.Count = count

	local name = row:CreateFontString(nil, "OVERLAY")
	K.SetFont(name, 12, K.FontOutlineStyle())
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)
	name:SetPoint("RIGHT", count, "LEFT", -6, 0)
	row.Name = name

	return row
end

local function SetArrow(button, enabled)
	button:SetEnabled(enabled)
	button:SetAlpha(enabled and 1 or 0.25)
end

local function FillRow(row, entry)
	local node, depth = entry.node, entry.depth
	row.node = node
	local isGroup = node.kind == "group"
	local left = depth * INDENT

	row.Band:SetShown(isGroup)
	row.Check:SetShown(not isGroup)
	row.Fold:SetShown(isGroup)

	local lead
	if isGroup then
		row.Fold:ClearAllPoints()
		row.Fold:SetPoint("LEFT", row, "LEFT", left + 2, 0)
		row.Fold:SetText(Module.Manager.folded[node.key] and "+" or "-")
		lead = row.Fold
	else
		row.Check:ClearAllPoints()
		row.Check:SetPoint("LEFT", row, "LEFT", left + 2, 0)
		local on = Module:IsSectionOn(node.key)
		row.Check:SetChecked(on)
		row.Check:SetEnabled(node.key ~= "Miscellaneous")
		lead = row.Check
	end
	row.Name:ClearAllPoints()
	row.Name:SetPoint("LEFT", lead, "RIGHT", 6, 0)
	row.Name:SetPoint("RIGHT", row.Count, "LEFT", -6, 0)
	row.Name:SetText(node.name)

	local count = 0
	if isGroup then
		for _, child in ipairs(node.children) do
			count = count + CountOf(child.key)
		end
	else
		count = CountOf(node.key)
	end
	local active = isGroup or Module:IsSectionOn(node.key)
	local c = (not active) and disabled or (isGroup and gold) or (count > 0 and text or muted)
	row.Name:SetTextColor(c[1], c[2], c[3])
	row.Count:SetText(active and count > 0 and count or "")
	row.Count:SetTextColor(muted[1], muted[2], muted[3])

	SetArrow(row.Up, entry.index > 1)
	SetArrow(row.Down, entry.index < entry.siblings)
end

-- The tree flattened into the rows the panel shows, folded groups closed.
local function Flatten(panel)
	local list = {}
	local tree = Module:BuildTree()
	for index, node in ipairs(tree) do
		list[#list + 1] = { node = node, depth = 0, index = index, siblings = #tree }
		if node.kind == "group" and not panel.folded[node.key] then
			for childIndex, child in ipairs(node.children) do
				list[#list + 1] = { node = child, depth = 1, index = childIndex, siblings = #node.children }
			end
		end
	end
	return list
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

function Module:BuildManager()
	if self.Manager then
		return self.Manager
	end
	local f = CreateFrame("Frame", "KKUI_BagManager", UIParent)
	f:SetSize(WIDTH, 400)
	f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	K.CreateGradientBackground(f, 0.95)
	K.CreateBorder(f)
	f:Hide()
	f.folded = {} -- panel only, this session
	f.offset = 0

	local title = f:CreateFontString(nil, "OVERLAY")
	K.SetFont(title, 15, K.FontOutlineStyle())
	title:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -10)
	title:SetTextColor(K.Colors.accent[1], K.Colors.accent[2], K.Colors.accent[3])
	title:SetText(L["Bag Sections"])

	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
	K.SkinCloseButton(close)

	local newGroup = SmallButton(f, L["New Group"], 96, function()
		K.Prompt(L["New Group"], "", function(value)
			if Module:CreateGroup(value) then
				Module:UpdateAll()
			end
		end)
	end)
	newGroup:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -36)

	local newCat = SmallButton(f, L["New Category"], 106, function()
		K.Prompt(L["New Category"], "", function(value)
			local key = Module:CreateCustomCategory(value)
			if key then
				Module:PlaceNewSection(key)
				Module:UpdateAll()
			end
		end)
	end)
	newCat:SetPoint("LEFT", newGroup, "RIGHT", 6, 0)

	local reset = SmallButton(f, L["Reset Order"], 90, function()
		K.Confirm(L["Put every section back in its default order?"], function()
			Module:ResetSectionOrder()
		end)
	end)
	reset:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, -36)

	local hint = f:CreateFontString(nil, "OVERLAY")
	K.SetFont(hint, 11, "")
	hint:SetPoint("TOPLEFT", newGroup, "BOTTOMLEFT", 0, -8)
	hint:SetWidth(WIDTH - PAD * 2)
	hint:SetJustifyH("LEFT")
	hint:SetWordWrap(true)
	hint:SetTextColor(muted[1], muted[2], muted[3])
	hint:SetText(L["Drop an item on a section to file it there. Right-click a row for more."])

	-- Thin scroll track on the right edge, shown only when the list overflows.
	local track = f:CreateTexture(nil, "ARTWORK")
	track:SetColorTexture(1, 1, 1, 0.05)
	track:SetWidth(3)
	f.Track = track
	local thumb = f:CreateTexture(nil, "OVERLAY")
	thumb:SetColorTexture(muted[1], muted[2], muted[3], 0.6)
	thumb:SetWidth(3)
	f.Thumb = thumb

	f:EnableMouseWheel(true)
	f:SetScript("OnMouseWheel", function(self, delta)
		self.offset = self.offset - delta * 2
		Module:RefreshManager()
	end)

	f.rows = {}
	for i = 1, VISIBLE do
		local row = CreateRow(f)
		row:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -LIST_TOP - (i - 1) * ROW_H)
		row:Hide()
		f.rows[i] = row
	end

	self.Manager = f
	return f
end

-- Redraw the visible slice of the tree.
function Module:RefreshManager()
	local f = self.Manager
	if not f then
		return
	end
	local list = Flatten(f)
	local shown = min(#list, VISIBLE)
	f.offset = max(0, min(f.offset, #list - VISIBLE))

	for i = 1, VISIBLE do
		local row = f.rows[i]
		local entry = list[i + f.offset]
		if entry then
			FillRow(row, entry)
			row:Show()
		else
			row.node = nil
			row:Hide()
		end
	end

	local listH = max(shown, 1) * ROW_H
	f:SetHeight(LIST_TOP + listH + PAD)

	local scrollable = #list > VISIBLE
	f.Track:SetShown(scrollable)
	f.Thumb:SetShown(scrollable)
	if scrollable then
		f.Track:ClearAllPoints()
		f.Track:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -LIST_TOP)
		f.Track:SetHeight(listH)
		local thumbH = max(16, listH * VISIBLE / #list)
		local travel = listH - thumbH
		f.Thumb:ClearAllPoints()
		f.Thumb:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -LIST_TOP - travel * f.offset / (#list - VISIBLE))
		f.Thumb:SetHeight(thumbH)
	end
end

function Module:ToggleManager()
	local f = self:BuildManager()
	if f:IsShown() then
		f:Hide()
	else
		self:RefreshManager()
		f:Show()
	end
end
