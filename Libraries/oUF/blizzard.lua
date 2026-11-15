local _, ns = ...
local oUF = ns.oUF

-- sourced from Blizzard_UnitFrame/Mainline/TargetFrame.lua
local MAX_BOSS_FRAMES = _G.MAX_BOSS_FRAMES or 5

-- sourced from Blizzard_FrameXMLBase/Shared/Constants.lua
local MEMBERS_PER_RAID_GROUP = _G.MEMBERS_PER_RAID_GROUP or 5

local isPlayerHooked = false
local isArenaHooked = false
local isBossHooked = false
local isPartyHooked = false

local function handleFrame(baseName)
	local frame
	if(type(baseName) == 'string') then
		frame = _G[baseName]
	else
		frame = baseName
	end

	if(frame) then
		frame:UnregisterAllEvents()
		-- SetRolesets keeps a frame out of retail's edit-mode layout manager. It
		-- does not exist on older flavours (TBC Anniversary), which also have no
		-- layout manager, so there we just hide the frame and keep it hidden.
		if(frame.SetRolesets) then
			frame:SetRolesets('alwaysBlocked')
		else
			frame:Hide()
			frame:HookScript('OnShow', frame.Hide)
		end

		local health = frame.healthBar or frame.healthbar or frame.HealthBar or (frame.HealthBarsContainer and frame.HealthBarsContainer.healthBar)
		if(health) then
			health:UnregisterAllEvents()
		end

		local power = frame.manabar or frame.ManaBar
		if(power) then
			power:UnregisterAllEvents()
		end

		local castbar = frame.castBar or frame.spellbar or frame.CastingBarFrame or (frame.CastBarsContainer and frame.CastBarsContainer.castBar)
		if(castbar) then
			castbar:UnregisterAllEvents()
		end

		local altpowerbar = frame.powerBarAlt or frame.PowerBarAlt
		if(altpowerbar) then
			altpowerbar:UnregisterAllEvents()
		end

		local buffFrame = frame.BuffFrame or frame.AurasFrame
		if(buffFrame) then
			buffFrame:UnregisterAllEvents()
		end

		local petFrame = frame.petFrame or frame.PetFrame
		if(petFrame) then
			petFrame:UnregisterAllEvents()
		end

		local totFrame = frame.totFrame
		if(totFrame) then
			totFrame:UnregisterAllEvents()
		end

		local ccRemoverFrame = frame.CcRemoverFrame
		if(ccRemoverFrame) then
			ccRemoverFrame:UnregisterAllEvents()
		end

		local debuffFrame = frame.DebuffFrame
		if(debuffFrame) then
			debuffFrame:UnregisterAllEvents()
		end
	end
end

function oUF:DisableBlizzard(unit)
	if(not unit) then return end

	if(unit == 'player') then
		handleFrame(PlayerFrame)

		-- The standalone alternate power bars hang off the player frame but keep
		-- their own power, spec and world entry events after the frame is silenced.
		-- Those events still run the player frame art update, which refreshes the
		-- stock buff frame, and that read of the player's auras fails while the
		-- execution is tainted. Unregistering their events is taint safe and legal
		-- in combat, and our own elements draw these resources.
		for _, name in next, { 'AlternatePowerBar', 'MonkStaggerBar', 'EvokerEbonMightBar', 'DemonHunterSoulFragmentsBar' } do
			local bar = _G[name]
			if(bar and bar.UnregisterAllEvents) then
				bar:UnregisterAllEvents()
			end
		end

		if(not isPlayerHooked) then
			isPlayerHooked = true

			-- Silencing PlayerFrame also silences the sound played when the player
			-- toggles pvp status on WoW Forever, so it is played from here instead.
			local f = CreateFrame('Frame')
			f:RegisterEvent('PLAYER_PVP_FLAG_CHANGED')
			f:SetScript('OnEvent', function(_, _, isFlagged)
				if(isFlagged) then
					PlaySound(SOUNDKIT.IG_PVP_UPDATE)
				end
			end)
		end
	elseif(unit == 'pet') then
		handleFrame(PetFrame)
	elseif(unit == 'target') then
		handleFrame(TargetFrame)
	elseif(unit == 'focus') then
		handleFrame(FocusFrame)
	elseif(unit:match('boss%d?$')) then
		if(not isBossHooked) then
			isBossHooked = true

			-- it's needed because the layout manager can bring frames that are
			-- controlled by containers back from the dead when a user chooses
			-- to revert all changes
			-- for now I'll just reparent it, but more might be needed in the
			-- future, watch it
			handleFrame(BossTargetFrameContainer)

			for i = 1, MAX_BOSS_FRAMES do
				handleFrame('Boss' .. i .. 'TargetFrame')
			end
		end
	elseif(unit:match('party%d?$')) then
		if(not isPartyHooked) then
			isPartyHooked = true

			handleFrame(PartyFrame)

			if(PartyFrame and PartyFrame.PartyMemberFramePool) then
				for frame in PartyFrame.PartyMemberFramePool:EnumerateActive() do
					handleFrame(frame)
				end
			end

			for i = 1, MEMBERS_PER_RAID_GROUP do
				handleFrame('CompactPartyFrameMember' .. i)
			end
		end
	elseif(unit:match('arena%d?$')) then
		if(not isArenaHooked) then
			isArenaHooked = true

			-- Forever has no CompactArenaFrame, so every container is checked first
			handleFrame(CompactArenaFrame)

			if(CompactArenaFrame and CompactArenaFrame.memberUnitFrames) then
				for _, frame in next, CompactArenaFrame.memberUnitFrames do
					handleFrame(frame)
				end
			end

			-- old arena frames, they're still used for flag carriers etc in battlegrounds
			handleFrame(ArenaEnemyMatchFramesContainer)

			if(ArenaEnemyMatchFramesContainer and ArenaEnemyMatchFramesContainer.UnitFrames) then
				for _, frame in next, ArenaEnemyMatchFramesContainer.UnitFrames do
					handleFrame(frame)
				end
			end
		end
	elseif(unit:match('nameplate%d?%d?%d?$')) then
		local frame = C_NamePlate.GetNamePlateForUnit(unit)
		handleFrame(frame.UnitFrame)
	end
end
