--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/Core.lua
	Purpose:
		The Core module. Owns first login setup: applies the UI scale, refreshes
		pixel math on resolution changes, prints the welcome line, and registers
		the /kk slash command that opens the config GUI.
-----------------------------------------------------------------------------]]

local K, C, L = KkthnxUI[1], KkthnxUI[2], KkthnxUI[3]

local Module = K:NewModule("Core")

function Module:OnEnable()
	-- ActionButtonUseKeyDown is left to the player. The action bar KeyDown option
	-- ("Default" follows this setting) sets our own buttons per button instead.

	K:SetupUIScale()
	K.RefreshBorderColors()

	-- Recompute pixel math when the screen scale or resolution changes.
	self:RegisterEvent("UI_SCALE_CHANGED", function()
		K.ScreenWidth, K.ScreenHeight = GetPhysicalScreenSize()
		K:SetupUIScale()
	end)
	self:RegisterEvent("DISPLAY_SIZE_CHANGED", function()
		K.ScreenWidth, K.ScreenHeight = GetPhysicalScreenSize()
		K:SetupUIScale()
	end)

	if C.General.WelcomeMessage then
		K.Print(L["Version %s (build %s) loaded. Type %s for options."], K.Version, K.Build, K.ColorText("accent", "/kk"))
	end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

SLASH_KKTHNXUI1 = "/kk"
SLASH_KKTHNXUI2 = "/kkthnxui"
SlashCmdList.KKTHNXUI = function(msg)
	msg = (msg or ""):lower():gsub("%s+", "")

	if msg == "reset" then
		K:ResetProfile()
		return
	elseif msg == "rl" or msg == "reload" then
		ReloadUI()
		return
	elseif msg == "move" or msg == "unlock" then
		K.ToggleMovers()
		return
	elseif msg == "resetpos" then
		K.ResetMovers()
		return
	elseif msg == "install" then
		if K.OpenInstaller then
			K.OpenInstaller()
		end
		return
	elseif msg == "chat" then
		if K.InstallChat then
			K.InstallChat()
		end
		return
	elseif msg == "buttons" then
		if K.ToggleButtonPreview then
			K.ToggleButtonPreview()
		end
		return
	elseif msg == "test" then
		local uf = K:GetModule("UnitFrames", true)
		if uf and uf.ToggleTest then
			uf:ToggleTest()
		end
		return
	elseif msg == "nptest" then
		local np = K:GetModule("Nameplates", true)
		if np and np.TogglePreview then
			np:TogglePreview()
		end
		return
	elseif msg == "questblock" then
		local automation = K:GetModule("Automation", true)
		if automation and automation.ToggleBlockedNPC then
			automation:ToggleBlockedNPC()
		end
		return
	elseif msg == "flighttest" or msg == "flights" then
		local qol = K:GetModule("QoL", true)
		if qol and msg == "flighttest" and qol.ToggleFlightTest then
			qol:ToggleFlightTest()
		elseif qol and qol.ExportFlightTimes then
			qol:ExportFlightTimes()
		end
		return
	elseif msg == "swingtest" then
		local swing = K:GetModule("SwingTimer", true)
		if swing and swing.ToggleTest then
			swing:ToggleTest()
		end
		return
	elseif msg == "buffs" then
		local qol = K:GetModule("QoL", true)
		if qol and qol.PrintBuffs then
			qol:PrintBuffs()
		end
		return
	elseif msg == "auras" then
		local auras = K:GetModule("Auras", true)
		if auras and auras.ToggleTest then
			auras:ToggleTest()
		end
		return
	end

	if K.ToggleConfigGUI then
		K.ToggleConfigGUI()
	else
		K.Print(L["Config GUI is not available yet."])
	end
end
