--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Config/GUI/Profiles.lua
	Purpose:
		The Profiles panel. Create, switch, copy, delete, and reset profiles.
		Registered as a custom panel so the window renders it in place of a
		schema driven layout. Most actions prompt a reload to apply cleanly.
-----------------------------------------------------------------------------]]

local K, L = KkthnxUI[1], KkthnxUI[3]

local GUI = K.GUI

local format = string.format
local strtrim = strtrim

local function MakeButton(parent, text, width)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(width or 90, 22)
	button:SetText(text)
	K.SkinButton(button)
	return button
end

GUI.CustomPanels = GUI.CustomPanels or {}

local function AskReload()
	K.Confirm(L["Reload the UI now to apply this?"], ReloadUI)
end

function GUI.CustomPanels.Profiles(parent)
	-- The window already titles the page, so the panel starts with its contents.
	local current = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(current, 12)
	current:SetPoint("TOPLEFT", 12, -8)

	-- The list of profile rows is refreshed whenever profiles change.
	local listHolder = CreateFrame("Frame", nil, parent)
	listHolder:SetPoint("TOPLEFT", current, "BOTTOMLEFT", 0, -12)
	listHolder:SetSize(460, 10)
	-- Rows are made once and reused, so a click that refreshes the list does not
	-- leave a set of hidden frames and skinned buttons behind every time.
	local rows = {}

	local Refresh

	local function AcquireRow(index)
		local row = rows[index]
		if row then
			return row
		end
		row = CreateFrame("Frame", nil, listHolder)
		row:SetSize(460, 28)
		K.CreateBackground(row, K.Colors.raised[1], K.Colors.raised[2], K.Colors.raised[3], 0.5)
		K.CreateBorder(row)

		local label = row:CreateFontString(nil, "OVERLAY")
		K.SetFont(label, 12)
		label:SetPoint("LEFT", 8, 0)
		label:SetWidth(120)
		label:SetJustifyH("LEFT")
		label:SetWordWrap(false)
		row.Label = label

		local del = MakeButton(row, L["Delete"], 60)
		del:SetPoint("RIGHT", -8, 0)
		del:SetScript("OnClick", function()
			local name = row.name
			K.Confirm(format(L["Delete the profile %s?"], name), function()
				if K:DeleteProfile(name) then
					Refresh()
				else
					K.Print(L["Cannot delete the active profile."])
				end
			end)
		end)
		row.Delete = del

		local export = MakeButton(row, L["Export"], 60)
		export:SetPoint("RIGHT", del, "LEFT", -4, 0)
		export:SetScript("OnClick", function()
			local name = row.name
			local str, err = K:ExportProfile(name)
			if str then
				K.ShowCopyText(format(L["Export %s"], name), str)
			else
				K.Print(L[err])
			end
		end)

		local copy = MakeButton(row, L["Copy"], 60)
		copy:SetPoint("RIGHT", export, "LEFT", -4, 0)
		copy:SetScript("OnClick", function()
			local name = row.name
			K.Confirm(format(L["Replace the active profile with a copy of %s?"], name), function()
				if K:CopyProfile(name) then
					Refresh()
					AskReload()
				end
			end)
		end)
		row.Copy = copy

		local use = MakeButton(row, L["Use"], 60)
		use:SetPoint("RIGHT", copy, "LEFT", -4, 0)
		use:SetScript("OnClick", function()
			K:SetProfile(row.name)
			Refresh()
			AskReload()
		end)
		row.Use = use

		rows[index] = row
		return row
	end

	Refresh = function()
		local active = K:GetActiveProfileName()
		local pending = K:GetPendingProfileName()
		local text = format(L["Active profile %s"], K.ColorText("accent", active))
		if pending ~= active then
			text = text .. "   " .. format(L["Switches to %s after a reload"], K.ColorText("accent", pending))
		end
		current:SetText(text)

		local names = K:ListProfiles()
		table.sort(names)

		local y = 0
		for index, name in ipairs(names) do
			local row = AcquireRow(index)
			row.name = name
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 0, y)
			y = y - 36
			row.Label:SetText(name)
			row.Delete:SetEnabled(name ~= active)
			row.Copy:SetEnabled(name ~= active)
			row.Use:SetEnabled(name ~= pending)
			row:Show()
		end
		for index = #names + 1, #rows do
			rows[index]:Hide()
		end
		listHolder:SetHeight(-y + 4)
		parent:SetHeight(math.max(520, 330 - y))
	end

	-- Create a new profile from a text box.
	local createLabel = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(createLabel, 12)
	createLabel:SetPoint("TOPLEFT", listHolder, "BOTTOMLEFT", 0, -20)
	createLabel:SetText(L["New profile name"])

	local edit = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	edit:SetSize(200, 22)
	edit:SetPoint("TOPLEFT", createLabel, "BOTTOMLEFT", 6, -6)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(32)
	K.SkinEditBox(edit)

	local create = MakeButton(parent, L["Create"], 90)
	create:SetPoint("LEFT", edit, "RIGHT", 8, 0)

	-- Problems show here beside the box. Chat sits behind the window, where a
	-- message is easy to miss.
	local createStatus = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(createStatus, 11)
	createStatus:SetTextColor(K.Colors.warning[1], K.Colors.warning[2], K.Colors.warning[3])
	createStatus:SetPoint("LEFT", create, "RIGHT", 10, 0)

	local function Create()
		local name = strtrim(edit:GetText())
		if name == "" then
			createStatus:SetText(L["Type a name first."])
		elseif K:CreateProfile(name) then
			createStatus:SetText("")
			edit:SetText("")
			edit:ClearFocus()
			Refresh()
		else
			createStatus:SetText(L["That name is already used."])
		end
	end
	create:SetScript("OnClick", Create)
	edit:SetScript("OnEnterPressed", Create)
	edit:HookScript("OnTextChanged", function()
		createStatus:SetText("")
	end)

	-- Bring a profile in from text. The pasted string is checked first, so a bad
	-- one is reported in the import window before any name is asked for. A name
	-- that is taken asks again instead of dropping the pasted text.
	local function AskName(text, question, default)
		K.Prompt(question, default, function(name)
			name = strtrim(name or "")
			if name == "" then
				AskName(text, L["Type a name for the imported profile."], name)
				return
			elseif K:ProfileExists(name) then
				AskName(text, L["That name is already used. Pick another name for the imported profile."], name)
				return
			end
			local imported, err = K:ImportProfile(text, name)
			if imported then
				K.Print(L["Profile imported. Press Use on it to switch."])
				Refresh()
			else
				K.Print(L[err])
			end
		end)
	end

	local import = MakeButton(parent, L["Import Profile"], 180)
	import:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", -6, -16)
	import:SetScript("OnClick", function()
		K.ShowImportBox(L["Import Profile"], function(text)
			local ok, err = K:CheckProfileString(text)
			if not ok then
				-- Returning a message keeps the import window open with the
				-- pasted text, and shows the message there.
				return L[err]
			end
			AskName(text, L["Name for the imported profile"], L["Imported"])
		end)
	end)

	local reset = MakeButton(parent, L["Reset Active Profile"], 180)
	reset:SetPoint("TOPLEFT", import, "BOTTOMLEFT", 0, -10)
	reset:SetScript("OnClick", function()
		K.Confirm(L["Put every setting of the active profile back to its default?"], function()
			K:ResetProfile()
			Refresh()
			AskReload()
		end)
	end)

	Refresh()
end
