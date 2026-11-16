--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Config/GUI/WhatsNew.lua
	Purpose:
		The What's New page. Lists every setting that carries a `since` tag, newest
		release first, with the unseen ones marked NEW. Each row says which page and
		section the setting lives on and has a Go button that opens that page,
		scrolls to the setting and lights it up.

		A setting stops being new once its own page has been opened, or all at once
		with Mark All As Seen.
-----------------------------------------------------------------------------]]

local K, L = KkthnxUI[1], KkthnxUI[3]

local GUI = K.GUI

local ipairs = ipairs

local ACCENT = K.Colors.accent
local ROW_HEIGHT = 50

GUI.CustomPanels = GUI.CustomPanels or {}

function GUI.CustomPanels.WhatsNew(parent)
	local intro = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(intro, 12)
	intro:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	intro:SetPoint("TOPLEFT", 12, -10)
	intro:SetPoint("RIGHT", parent, "RIGHT", -150, 0)
	intro:SetJustifyH("LEFT")
	intro:SetText(L["Settings added in recent versions. New ones are marked until you open their page."])

	local markAll = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	markAll:SetSize(130, 22)
	markAll:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -6, -8)
	markAll:SetText(L["Mark All As Seen"])
	K.SkinButton(markAll)

	local empty = parent:CreateFontString(nil, "OVERLAY")
	K.SetFont(empty, 12)
	empty:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
	empty:SetPoint("TOPLEFT", 12, -64)
	empty:SetText(L["Nothing new to show yet."])
	empty:Hide()

	local rows = {}

	local function Row(i)
		local row = rows[i]
		if row then
			return row
		end
		row = CreateFrame("Frame", nil, parent)
		row:SetHeight(ROW_HEIGHT - 4)
		K.GradientBG(row, 0.16, 0.17, 0.19, 0.55, 0.10, 0.10, 0.12, 0.55)

		row.new = row:CreateFontString(nil, "OVERLAY")
		K.SetFont(row.new, 11, "OUTLINE")
		row.new:SetTextColor(1, 0.82, 0)
		row.new:SetPoint("LEFT", 10, 0)
		row.new:SetWidth(44)
		row.new:SetJustifyH("LEFT")

		row.label = row:CreateFontString(nil, "OVERLAY")
		K.SetFont(row.label, 12)
		row.label:SetPoint("TOPLEFT", 62, -9)
		row.label:SetPoint("RIGHT", row, "RIGHT", -70, 0)
		row.label:SetJustifyH("LEFT")

		row.where = row:CreateFontString(nil, "OVERLAY")
		K.SetFont(row.where, 10)
		row.where:SetTextColor(K.Colors.muted[1], K.Colors.muted[2], K.Colors.muted[3])
		row.where:SetPoint("BOTTOMLEFT", 62, 8)
		row.where:SetPoint("RIGHT", row, "RIGHT", -70, 0)
		row.where:SetJustifyH("LEFT")

		row.go = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
		row.go:SetSize(50, 20)
		row.go:SetPoint("RIGHT", -8, 0)
		row.go:SetText(L["Go"])
		K.SkinButton(row.go)

		rows[i] = row
		return row
	end

	local headers = {}
	local function Header(i)
		local fs = headers[i]
		if not fs then
			fs = parent:CreateFontString(nil, "OVERLAY")
			K.SetFont(fs, 13, "OUTLINE")
			fs:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
			headers[i] = fs
		end
		return fs
	end

	function parent.KKUI_Refresh()
		local entries = GUI.ReleaseEntries()
		empty:SetShown(#entries == 0)
		local y = -60
		local lastSince
		local headerCount = 0
		for i, entry in ipairs(entries) do
			if entry.control.since ~= lastSince then
				lastSince = entry.control.since
				headerCount = headerCount + 1
				local header = Header(headerCount)
				header:ClearAllPoints()
				header:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, y)
				header:SetText(lastSince)
				header:Show()
				y = y - 24
			end
			local row = Row(i)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
			row:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, y)
			local unseen = GUI.IsNew(entry.control)
			row.new:SetText(unseen and L["NEW"] or "")
			row.label:SetText(entry.label)
			row.label:SetAlpha(unseen and 1 or 0.6)
			-- Name the section only when it says something the page title does not.
			local showSection = entry.section and entry.section ~= entry.category.title
			row.where:SetText(showSection and (entry.category.title .. "  >  " .. entry.section) or entry.category.title)
			row.go:SetScript("OnClick", function()
				GUI.JumpTo(entry)
			end)
			row:Show()
			y = y - ROW_HEIGHT
		end
		for i = #entries + 1, #rows do
			rows[i]:Hide()
		end
		for i = headerCount + 1, #headers do
			headers[i]:Hide()
		end
		parent:SetHeight(-y + 10)
	end

	markAll:SetScript("OnClick", function()
		GUI.MarkAllSeen()
		parent.KKUI_Refresh()
		if GUI.UpdateNav then
			GUI.UpdateNav()
		end
		if GUI.HideBadges then
			GUI.HideBadges()
		end
	end)

	parent.KKUI_Refresh()
end
