--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Bags/Groups.lua
	Purpose:
		The bag sections tree: the order sections render in, and categories folded
		together under a named group header. The top level holds ungrouped sections
		and groups side by side, and each group holds its own member sections.

		Positions live in SortOrder, one number per key among its siblings. A key
		with no number keeps its place from the default list, so nothing changes
		until the player moves something. Every edit renumbers the siblings it
		touched, which keeps the numbers small and free of ties.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:GetModule("Bags")
if not Module then
	return
end

local ipairs = ipairs
local pairs = pairs
local tsort = table.sort
local tinsert = table.insert
local strtrim = strtrim
local MenuUtil = MenuUtil

local GROUP_PREFIX = "group:"

local function GroupKey(name)
	return GROUP_PREFIX .. name
end

-- Groups live as a name -> number map so a leaf write persists each one. The
-- number is no longer the order (SortOrder is), it only marks the group as made.
local function GroupsTable()
	C.Bags.Groups = C.Bags.Groups or {}
	return C.Bags.Groups
end

local function CategoryGroupTable()
	C.Bags.CategoryGroup = C.Bags.CategoryGroup or {}
	return C.Bags.CategoryGroup
end

local function SetOrder(key, value)
	K:SetConfig({ "Bags", "SortOrder", key }, value)
end

-- ---------------------------------------------------------------------------
-- Tree
-- ---------------------------------------------------------------------------

-- Every real section in its default place, the built-in ones, with the player's
-- own categories dropped in just ahead of the Miscellaneous catch-all.
function Module:SectionList()
	local custom = C.Bags.CustomCategories
	local keys = {}
	if custom then
		for key in pairs(custom) do
			keys[#keys + 1] = key
		end
		tsort(keys, function(a, b)
			return custom[a] < custom[b]
		end)
	end
	local list = {}
	for _, cat in ipairs(self.Categories) do
		if cat.key == "Miscellaneous" then
			for _, key in ipairs(keys) do
				list[#list + 1] = { key = key, name = custom[key], custom = true }
			end
		end
		list[#list + 1] = cat
	end
	return list
end

-- Siblings sort by their saved position, falling back to the default place.
local function ByOrder(a, b)
	local order = C.Bags.SortOrder or {}
	local ra, rb = order[a.key] or a.default, order[b.key] or b.default
	if ra ~= rb then
		return ra < rb
	end
	return a.default < b.default
end

-- The tree as nodes: { kind = "section", key, name, default } at the top or under
-- a group, and { kind = "group", key = "group:Name", name, children } at the top.
-- A group sits at its first member's default place, an empty one just ahead of
-- Miscellaneous so a new group shows up in the middle of things.
function Module:BuildTree()
	local list = self:SectionList()
	local groupMap = CategoryGroupTable()
	local groups = GroupsTable()
	local top, byName = {}, {}
	local miscPlace = #list

	for index, cat in ipairs(list) do
		local node = { kind = "section", key = cat.key, name = cat.name, default = index, custom = cat.custom }
		if cat.key == "Miscellaneous" then
			miscPlace = index
		end
		local group = groupMap[cat.key]
		if group and groups[group] then
			local parent = byName[group]
			if not parent then
				parent = { kind = "group", key = GroupKey(group), name = group, default = index, children = {} }
				byName[group] = parent
				top[#top + 1] = parent
			end
			parent.children[#parent.children + 1] = node
		else
			top[#top + 1] = node
		end
	end

	for name in pairs(groups) do
		if not byName[name] then
			local parent = { kind = "group", key = GroupKey(name), name = name, default = miscPlace - 0.5, children = {} }
			byName[name] = parent
			top[#top + 1] = parent
		end
	end

	tsort(top, ByOrder)
	for _, parent in pairs(byName) do
		tsort(parent.children, ByOrder)
	end
	return top
end

-- Group names in tree order, for the menus.
function Module:GroupOrder()
	local names = {}
	for _, node in ipairs(self:BuildTree()) do
		if node.kind == "group" then
			names[#names + 1] = node.name
		end
	end
	return names
end

-- Write positions 1..n for a list of sibling nodes or keys.
local function Renumber(siblings)
	for index, entry in ipairs(siblings) do
		SetOrder(type(entry) == "table" and entry.key or entry, index)
	end
end

-- The top level as a list of keys, with one key left out.
local function TopKeys(skip)
	local keys = {}
	for _, node in ipairs(Module:BuildTree()) do
		if node.key ~= skip then
			keys[#keys + 1] = node.key
		end
	end
	return keys
end

local function IndexOf(keys, key)
	for index, value in ipairs(keys) do
		if value == key then
			return index
		end
	end
end

-- Put a key on the top level next to an anchor (before it, or after it with
-- after set), or at the end when the anchor is gone.
local function PlaceOnTop(key, anchor, after)
	local keys = TopKeys(key)
	local index = IndexOf(keys, anchor)
	if index then
		tinsert(keys, after and index + 1 or index, key)
	else
		keys[#keys + 1] = key
	end
	Renumber(keys)
end

-- Move a node one place up (-1) or down (1) among its siblings.
function Module:MoveNode(key, delta)
	local tree = self:BuildTree()
	local siblings = tree
	if not IndexOf(TopKeys(), key) then
		for _, node in ipairs(tree) do
			if node.children then
				for _, child in ipairs(node.children) do
					if child.key == key then
						siblings = node.children
					end
				end
			end
		end
	end
	for index, node in ipairs(siblings) do
		if node.key == key then
			local target = index + delta
			if target < 1 or target > #siblings then
				return
			end
			siblings[index], siblings[target] = siblings[target], siblings[index]
			Renumber(siblings)
			self:UpdateAll()
			return
		end
	end
end

-- Forget every saved position, back to the default order. Groups stay.
function Module:ResetSectionOrder()
	for key in pairs(C.Bags.SortOrder or {}) do
		SetOrder(key, nil)
	end
	self:UpdateAll()
end

function Module:SetSectionOn(key, on)
	if key == "Miscellaneous" then
		return
	end
	K:SetConfig({ "Bags", "DisabledCategories", key }, (not on) or nil)
	self:UpdateAll()
end

-- A new category or group goes in just ahead of Miscellaneous.
function Module:PlaceNewSection(key)
	PlaceOnTop(key, "Miscellaneous")
end

-- ---------------------------------------------------------------------------
-- Groups
-- ---------------------------------------------------------------------------

function Module:CreateGroup(name)
	name = name and strtrim(name)
	if not name or name == "" or GroupsTable()[name] then
		return
	end
	K:SetConfig({ "Bags", "Groups", name }, true)
	PlaceOnTop(GroupKey(name), "Miscellaneous")
	return name
end

-- Fold a section into a group (it goes last in the group), or take it back out
-- with groupName nil (it lands just below the group it left).
function Module:AssignCategoryGroup(catKey, groupName)
	local old = CategoryGroupTable()[catKey]
	if old == groupName then
		return
	end
	K:SetConfig({ "Bags", "CategoryGroup", catKey }, groupName)
	if groupName then
		SetOrder(catKey, nil)
		for _, node in ipairs(self:BuildTree()) do
			if node.key == GroupKey(groupName) then
				local members = {}
				for _, child in ipairs(node.children) do
					if child.key ~= catKey then
						members[#members + 1] = child.key
					end
				end
				members[#members + 1] = catKey
				Renumber(members)
			end
		end
		Renumber(TopKeys())
	else
		PlaceOnTop(catKey, old and GroupKey(old), true)
	end
	self:UpdateAll()
end

-- Deleting a group lets its members out where the group stood, in their order.
function Module:DeleteGroup(name)
	local gkey = GroupKey(name)
	local keys = {}
	for _, node in ipairs(self:BuildTree()) do
		if node.key == gkey then
			for _, child in ipairs(node.children) do
				keys[#keys + 1] = child.key
			end
		else
			keys[#keys + 1] = node.key
		end
	end
	for cat, group in pairs(CategoryGroupTable()) do
		if group == name then
			K:SetConfig({ "Bags", "CategoryGroup", cat }, nil)
		end
	end
	K:SetConfig({ "Bags", "Groups", name }, nil)
	K:SetConfig({ "Bags", "Collapsed", gkey }, nil)
	SetOrder(gkey, nil)
	Renumber(keys)
	self:UpdateAll()
end

function Module:RenameGroup(old, new)
	new = new and strtrim(new)
	if not new or new == "" or GroupsTable()[new] then
		return
	end
	local order = C.Bags.SortOrder or {}
	local oldKey, newKey = GroupKey(old), GroupKey(new)
	K:SetConfig({ "Bags", "Groups", new }, true)
	K:SetConfig({ "Bags", "Groups", old }, nil)
	SetOrder(newKey, order[oldKey])
	SetOrder(oldKey, nil)
	if C.Bags.Collapsed[oldKey] then
		K:SetConfig({ "Bags", "Collapsed", newKey }, true)
		K:SetConfig({ "Bags", "Collapsed", oldKey }, nil)
	end
	for cat, group in pairs(CategoryGroupTable()) do
		if group == old then
			K:SetConfig({ "Bags", "CategoryGroup", cat }, new)
		end
	end
	self:UpdateAll()
end

-- ---------------------------------------------------------------------------
-- Header right-click menu
-- ---------------------------------------------------------------------------

function Module:ShowGroupMenu(header)
	if not (MenuUtil and MenuUtil.CreateContextMenu) then
		return
	end
	local groupName = header.groupName
	local catKey = header.catKey

	MenuUtil.CreateContextMenu(header, function(_, root)
		if groupName then
			root:CreateTitle(groupName)
			root:CreateButton(L["Rename Group"], function()
				K.Prompt(L["Rename Group"], groupName, function(text)
					Module:RenameGroup(groupName, text)
				end)
			end)
			root:CreateButton(L["Delete Group"], function()
				Module:DeleteGroup(groupName)
			end)
		elseif catKey then
			-- A per-slot gear shelf answers to the Equipment section.
			local section = catKey:match("^Equipment:") and "Equipment" or catKey
			root:CreateTitle(header.Text and header.Text:GetText() or L["Category"])
			local groups = Module:GroupOrder()
			if #groups > 0 then
				local add = root:CreateButton(L["Add to Group"])
				for _, name in ipairs(groups) do
					add:CreateButton(name, function()
						Module:AssignCategoryGroup(section, name)
					end)
				end
			end
			if section ~= "Miscellaneous" then
				root:CreateButton(L["Turn Off Section"], function()
					Module:SetSectionOn(section, false)
				end)
			end
			if C.Bags.CustomCategories and C.Bags.CustomCategories[section] and Module.DeleteCustomCategory then
				root:CreateButton(L["Delete Category"], function()
					Module:DeleteCustomCategory(section)
				end)
			end
		end
		root:CreateDivider()
		root:CreateButton(L["Bag Sections"], function()
			Module:ToggleManager()
		end)
	end)
end
