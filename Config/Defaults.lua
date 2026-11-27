--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Config/Defaults.lua
	Purpose:
		The default value tree for every user facing setting. Core/Config.lua
		deep merges the active profile onto a copy of this tree and exposes the
		result as C. Add new settings here first so profiles pick them up.
-----------------------------------------------------------------------------]]

local K = KkthnxUI[1]

-- Stored on the engine so Core/Config.lua can read it without a global.
K.ConfigDefaults = {
	General = {
		AutoScale = true,
		UIScale = 0.71,
		BorderStyle = "KkthnxUI",
		BorderColor = { 1, 1, 1, 1 },
		ForeverGold = false, -- use Forever's own gold trim instead of BorderColor
		Font = "Normal",
		FontOutline = true,
		WelcomeMessage = true,
		CoordPrecision = "Game", -- Game follows the game's coordinates setting, Tenths and Whole force one
	},

	ActionBar = {
		Enable = true,
		ShowGrid = true,
		AutoUpgradeRanks = true, -- swap a newly learned spell rank into the slots holding a lower rank
		RangeColoring = "button", -- how out-of-range shows: button, hotkey, or none
		RangeColor = { 0.8, 0.1, 0.1 }, -- out-of-range tint
		ManaColor = { 0.5, 0.5, 1.0 }, -- out-of-mana tint
		KeyDown = "Default", -- Default follows the game setting, Press casts on key press, Release on key release
		ProcGlow = "Pixel", -- spell-activation glow style: Pixel, Autocast, or Default
		Font = "Normal",
		FontSize = 12,
		FontFlag = "OUTLINE",
		-- Each bar is fully self-contained, with size, spacing, layout, opacity,
		-- mouseover fade, and its own text toggles. Sizes and spacing match the
		-- original KkthnxUI (38px buttons, 6px spacing).
		Bar1 = { Enable = true, Buttons = 12, PerRow = 12, Size = 38, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		Bar2 = { Enable = true, Buttons = 12, PerRow = 12, Size = 38, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		Bar3 = { Enable = true, Buttons = 12, PerRow = 12, Size = 38, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		Bar4 = { Enable = true, Buttons = 12, PerRow = 1, Size = 38, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		Bar5 = { Enable = true, Buttons = 12, PerRow = 1, Size = 38, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		-- Bars 6-8 are the extra multibars, off by default so they do not clutter.
		Bar6 = { Enable = false, Buttons = 12, PerRow = 12, Size = 34, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		Bar7 = { Enable = false, Buttons = 12, PerRow = 12, Size = 34, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		Bar8 = { Enable = false, Buttons = 12, PerRow = 12, Size = 34, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true, MacroName = true, Count = true },
		-- Pet, stance, and the extra/zone ability button.
		PetBar = { Enable = true, PerRow = 10, Size = 30, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true },
		StanceBar = { Enable = true, PerRow = 10, Size = 30, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true },
		PossessBar = { Enable = true, PerRow = 2, Size = 30, Space = 6, Alpha = 1, Mouseover = false, FadeCombat = false, HotKey = true },
		ExtraBar = { Enable = true, Size = 46 },
	},

	-- Unit frame geometry follows the original KkthnxUI. Health and power are two
	-- separate bordered bars stacked with a 6px gap, so a unit's outer height is
	-- Height + 6 + PowerHeight. Portraits are detached boxes beside the frame.
	Unitframe = {
		Enable = true,
		Texture = "KkthnxUI Forever",
		ClassHealth = false,
		ClassColorBorder = false,
		ThreatHealthColor = false, -- colour enemy health bars by your threat instead of reaction
		BarBackdrop = true,
		Portrait = true,
		PortraitStyle = "3D", -- 3D, 2D, Class
		Smooth = true,
		HealthPrediction = true,
		RangeFade = true, -- dim units that are out of range
		RangeAlpha = 0.4, -- how faded an out-of-range unit gets
		GroupDispelOnly = true, -- party/raid debuffs, what your raid can dispel, plus boss mechanics
		AuraWatch = true, -- corner dots on party/raid frames for your tracked heals
		QuestieTargetIcon = true, -- with Questie loaded, its objective icon beside the target frame

		-- Text formatting shared by the units below.
		HealthFormat = "Both", -- None, Current, Percent, Both
		PowerFormat = "Current", -- None, Current, Percent, Both
		NameColor = true,
		NameLength = 18,
		FirstNameOnly = false, -- drop the surname from player names (raid frames always do)

		-- Custom power bar colours, applied over the oUF defaults. Keyed by power
		-- token so both unit frames and nameplates use them.
		-- Blizzard's hues, with the pure primaries softened so they do not glare
		-- on the dark bars. Mana uses the lighter blue Blizzard gives its own
		-- nameplate mana bar, and stays apart from the accent and the mage colour.
		PowerColors = {
			MANA = { 0.18, 0.36, 0.95 },
			RAGE = { 0.89, 0.18, 0.18 },
			FOCUS = { 1.00, 0.55, 0.25 },
			ENERGY = { 1.00, 0.90, 0.25 },
		},
		-- Reaction colours, indexed 1 (hated) to 8 (exalted). Blizzard's red,
		-- orange, yellow and green, softened the same way. Like Blizzard, every
		-- friendly standing is the same green.
		ReactionColors = {
			[1] = { 0.84, 0.27, 0.22 },
			[2] = { 0.84, 0.27, 0.22 },
			[3] = { 0.86, 0.45, 0.12 },
			[4] = { 0.93, 0.76, 0.15 },
			[5] = { 0.25, 0.72, 0.30 },
			[6] = { 0.25, 0.72, 0.30 },
			[7] = { 0.25, 0.72, 0.30 },
			[8] = { 0.25, 0.72, 0.30 },
		},

		Player = { Enable = true, Width = 218, Height = 40, PowerHeight = 16, ShowPower = true, Buffs = false, Debuffs = true, ClassPower = true, AdditionalPower = true, ShowName = false, PowerTick = true, FiveSecondRule = true, Totems = true, PvPIcon = true },
		Target = { Enable = true, Width = 218, Height = 40, PowerHeight = 16, ShowPower = true, Buffs = true, Debuffs = true, PvPIcon = true, Threat = false },
		TargetOfTarget = { Enable = true, Width = 100, Height = 18, PowerHeight = 10, ShowPower = true },
		Pet = { Enable = true, Width = 100, Height = 18, PowerHeight = 10, ShowPower = true, Debuffs = false, Happiness = true, FeedMenu = true },
		Focus = { Enable = true, Width = 204, Height = 34, PowerHeight = 14, ShowPower = true, Debuffs = true },
		FocusTarget = { Enable = true, Width = 100, Height = 18, PowerHeight = 10, ShowPower = true },
		Party = { Enable = true, Width = 150, Height = 26, PowerHeight = 10, ShowPower = true, ShowSolo = false, ShowPlayer = true, Debuffs = true, DispelHighlight = true, Portrait = true, Castbar = true, RaidStyle = false, Spacing = 24, RoleIcon = true, HealthText = "Default", NameLength = 0 },
		-- Height is the health bar, the power bar (PowerHeight) sits below it with a
		-- PowerGap so the two read as separate bars. PowerMode: All, Mana, or None.
		Raid = { Enable = true, Width = 80, Height = 30, PowerHeight = 6, PowerGap = 6, PowerMode = "All", GroupsPerRow = 5, GroupBy = "GROUP", RaidWide = false, SortDirection = "ASC", Orientation = "DOWN_RIGHT", DispelHighlight = true, ShowGroupNumber = true, Debuffs = false, DebuffSize = 16, HealthText = "None", NameLength = 5, SortBy = "INDEX", Spacing = 6, RoleIcon = true },
		-- Spacing has to clear the frame plus its attached castbar, otherwise the
		-- bar for boss1 lands on top of boss2's name.
		Boss = { Enable = true, Width = 150, Height = 24, PowerHeight = 10, ShowPower = true, Spacing = 34, Debuffs = true, Castbar = true, Portrait = true },

		Auras = {
			-- Spacing is the UI's one 6 pixel gap. The frame widths are picked so a
			-- full row ends flush, since seven 26 pixel icons span the 218 pixel player and
			-- target, seven 24 pixel ones the 204 pixel focus.
			BuffSize = 26,
			DebuffSize = 26,
			PerRow = 7,
			NumBuffs = 12,
			NumDebuffs = 8,
			Spacing = 6,
			OnlyPlayerDebuffs = false,
		},

		ClassPower = {
			Height = 14,
			Spacing = 6,
		},

		-- Main hand, off hand and ranged swing bars, each on its own mover.
		Swing = {
			Enable = true,
			Spark = true,
			Icon = true, -- the equipped weapon's icon left of each bar
			Drain = false, -- empty the bar as the swing runs instead of filling it
			RangeCheck = true, -- dim a bar once its swing ends while the target is out of reach
			RangeAlpha = 0.4,
			HasteAdjust = true, -- stretch or shrink a running swing when attack speed changes
			MainHand = {
				Visibility = "swinging", -- always, combat, swinging or hidden
				Width = 242,
				Height = 22,
				Scale = 1,
				Alpha = 1,
				ShowTitle = true,
				ShowTime = true,
				Color = { 0.36, 0.55, 0.81 }, -- accent blue
			},
			OffHand = {
				Visibility = "swinging", -- always, combat, swinging or hidden
				Width = 242,
				Height = 22,
				Scale = 1,
				Alpha = 1,
				ShowTitle = true,
				ShowTime = true,
				Color = { 0.62, 0.48, 0.86 }, -- violet, so the two hands read apart. A chosen exception to the palette tokens.
			},
			Ranged = {
				Visibility = "swinging", -- always, combat, swinging or hidden
				Width = 242,
				Height = 22,
				Scale = 1,
				Alpha = 1,
				ShowTitle = true,
				ShowTime = true,
				Color = { 0.95, 0.69, 0.26 }, -- gold
			},
		},

		Castbar = {
			Enable = true,
			ShowIcon = true,
			ShowTimer = true,
			ShowSpark = true,
			ShowLatency = true,
			TimeToHold = 0.4,
			PlayerWidth = 242,
			PlayerHeight = 28,
			TargetWidth = 242,
			TargetHeight = 40,
			FocusWidth = 208,
			FocusHeight = 24,
		},
	},

	Minimap = {
		Enable = true,
		Size = 200,
		Square = true,
		ShowBorder = true, -- our border around the map
		ShowLocation = true, -- zone name, top of the map
		LocationFontSize = 12,
		ShowClock = true, -- time datatext, bottom of the map
		ClockFontSize = 12,
		ShowCoords = true, -- player coordinates, centered below the map
		ShowPerformance = true, -- framerate and latency datatext, movable
		PerformanceFontSize = 13,
		PerformanceSeparator = "-", -- what sits between the fps and ms readings
		PerformanceLabelColor = "White", -- White, Class, or Custom, for the fps and ms labels
		PerformanceCustomColor = { 1, 1, 1 }, -- used when the label colour is Custom
		ZoomResetDelay = 0, -- seconds of no wheel input before zoom snaps back out, 0 = off
		MouseoverFade = false, -- fade the map out until you hover it
		FadeAlpha = 0.25, -- alpha while faded
		CollectButtons = true,
		ButtonCorner = "BOTTOMLEFT", -- corner the button-collector bracket sits in
		CollectedButtonSize = 22, -- size of each addon button in the collector flyout
	},

	WorldMap = {
		Enable = true,
		SmallerMap = false, -- shrink the maximized map so it does not cover the screen, off because resizing the map from addon code taints its pin layout
		Scale = 0.9,
		Coordinates = true, -- player and cursor coordinates in a corner of the map
		CoordPosition = "BOTTOMLEFT",
		Reveal = false, -- draw unexplored map areas (toggle on the map itself)
		RevealDim = true, -- dim the revealed areas so explored ground still stands out
		Waypoints = true, -- /way and Alt+click on the map set the game's own super-tracked waypoint
	},

	Nameplate = {
		Enable = true,
		Width = 154, -- five 26 pixel debuffs with the 6 pixel gap span it exactly
		Height = 14,
		NameSize = 12,
		ClassColor = true,
		ShowHealthText = true,
		ShowQuestIcon = true,
		QuestShowParty = false, -- also mark NPCs on a party member's quest (greyed)
		QuestProgressFormat = "Completed", -- Completed (3/7) or Remaining (4)
		QuestProgressOnTarget = false, -- only show the progress text on your target
		QuestieIcons = true, -- with Questie loaded, show its objective icon in our marker and turn off its own plate icons

		ShowClassification = true,
		FriendlyNameOnly = true,
		ShowFriendlyNPCs = true, -- plates on friendly NPCs, drawn as a name only
		EnemyCombatOnly = false, -- enemy plates hidden out of combat
		FriendlyLevel = true, -- level in front of the name on name-only plates
		ShowGuildName = true,
		ShowCastbar = true,
		CastbarHeight = 14, -- matches the health bar so a cast does not outweigh it
		ShowDebuffs = true,
		OnlyMyDebuffs = true,
		TargetHighlight = true,
		TargetPower = true, -- your class resource on the target's nameplate
		ThreatColor = true,
		ThreatHealthColor = false, -- colour enemy health bars by your threat instead of reaction
		RoleColors = false, -- colour hostile plates by caster or melee so casters stand out
		-- Muted plum, kept clear of the accent, mana, the blue and purple classes and
		-- FocusColor, at the same brightness as MeleeColor so neither plate shouts.
		CasterColor = { 0.68, 0.34, 0.66 }, -- health colour for caster enemies
		MeleeColor = { 0.85, 0.4, 0.3 }, -- health colour for melee enemies
		ExecuteRange = 0, -- tint enemy health under this percent, 0 is off
		FocusHighlight = false, -- colour your focus's health bar
		FocusColor = { 0.85, 0.45, 1 },
		NonTargetAlpha = 1, -- alpha of the other plates while you have a target, 1 is off
		ExecuteColor = { 0.9, 0.2, 0.2 },
		MaxDistance = 60,
		MaxAuras = 5,
		AuraSize = 26,
		AuraSpacing = 6,
		PrivateAuras = true, -- Blizzard private auras (boss mechanics) on the plate
		PrivateAuraSize = 28,
		-- Custom health colours for priority mobs, keyed by npcID -> { r, g, b }.
		CustomColors = {},
	},

	Auras = {
		Enable = true,
		BuffSize = 30,
		DebuffSize = 38, -- kept two steps larger than the buffs so debuffs stand out
		PerRow = 14,
		Spacing = 6,
		WeaponEnchant = true,
	},

	Cooldown = {
		Enable = true, -- Blizzard's native countdown numbers (the only ones that
		-- can read the secret cooldown duration on 12.1)
	},

	-- Blizzard frame skins.
	Skins = {
		CharacterFrames = true, -- class background behind the model on the Character and Inspect windows
		CharacterFramesWide = true, -- give the paper doll tab and the inspect window more width for the model
		InspectItemLevel = true, -- the inspected player's average item level on the inspect window
		GearInfo = true, -- red marker for a missing enchant and the gems beside each slot
		CharacterSlots = true, -- our slot look, quality border and item level on the character and inspect frames
		SocialColors = true, -- class/difficulty colour the Friends and Who panels
		MirrorTimers = true, -- breath, fatigue and feign death bars in our style with the seconds left
		GameMenu = true, -- skin the pause menu and add a KkthnxUI options button
		ObjectiveTracker = false, -- tidy the quest tracker header/minimise and recolour its bars, off while the scenario tracker taint reports are open
		ObjectiveTrackerClassColor = true, -- class colour the tracker bars instead of the accent
		Details = true, -- offer a KkthnxUI skin in the damage meter's skin list, nothing changes until it is picked
	},

	-- Movable, reskinned micro menu.
	MicroMenu = {
		Enable = true,
		ButtonSize = 28,
		Spacing = 6,
		Orientation = "HORIZONTAL", -- HORIZONTAL or VERTICAL
		Order = "DEFAULT", -- DEFAULT or REVERSE
		HideStock = true, -- hide the game's own micro menu while ours is off
	},

	-- Movable, reskinned bag bar.
	BagBar = {
		Enable = true,
		ButtonSize = 30,
		Spacing = 6,
		Orientation = "HORIZONTAL", -- HORIZONTAL or VERTICAL
		Order = "DEFAULT", -- DEFAULT puts the backpack first, REVERSE puts it last
		ShowKeyring = true, -- the keyring button, when the client has one
		ShowFreeSlots = true, -- free bag slots on the backpack button
		HideStock = true, -- hide the game's own bag bar while ours is off
	},

	-- All-in-one bag and bank replacement, auto categorised.
	Bags = {
		Enable = true,
		ButtonSize = 34,
		Spacing = 6,
		BagsPerRow = 12,
		Categories = true, -- group items into New/Junk/Equipment/etc.
		MergeStacks = false, -- fold duplicate stackable items into one button
		GroupGearBySlot = false, -- split gear into per equipment slot shelves
		ShowItemLevel = true, -- item level on equippable gear
		PawnArrows = true, -- Pawn upgrade arrows on gear (only if Pawn is installed)
		QuestColor = true, -- quest-yellow border on quest items, ! bang on starters
		ReagentBagSection = true, -- group the reagent pouch into its own section
		DetachReagentBag = false, -- give the reagent pouch its own window
		ShowBagBar = true, -- bag slot strip state, set only by the bag window's toggle button
		ShowItemBind = true, -- BoE / BoA marker on bind-on-equip gear
		ShowNewItems = true, -- glow freshly looted items
		ShowCurrencies = true, -- tracked currency row along the bottom
		JunkIcon = true, -- coin marker on grey items
		ShowEquipmentSet = false, -- marker on items that belong to a saved equipment set
		DesaturateJunk = false, -- grey out the icon of vendor trash
		TintUnusable = true, -- red icon on weapons and armor you cannot use
		DeleteButton = true, -- show the delete-cheapest-junk button
		JunkList = {}, -- itemID -> true, items the player flagged as junk
		ReverseSort = false, -- newest items to the top-left instead
		AutoDepositReagents = false, -- push reagents to the bank on opening it
		Collapsed = {}, -- section key -> true when the player folded it away
		Favorites = {}, -- itemID -> true, pinned to their own section on top
		Groups = {}, -- group name -> order, categories folded under one header
		CategoryGroup = {}, -- category key -> group name it belongs to
		CustomCategories = {}, -- custom category key -> display name
		ItemAssignments = {}, -- itemID -> category key the player pinned it to
		SortOrder = {}, -- section or "group:" key -> position among its siblings, set from the bag sections panel
		DisabledCategories = {}, -- section key -> true when turned off, its items fall through to the next section
	},

	-- Movable experience / reputation / honor / house progress bar.
	ExpRep = {
		Enable = true,
		Width = 400,
		Height = 14,
		FontSize = 11,
		ShowText = true,
		ShowRested = true,
		Fade = false,
		FadeOpacity = 0,
		FadeCombat = true,
		FadeTarget = false,
	},

	-- Collect Blizzard's alert popups on one movable anchor.
	AlertFrames = {
		Enable = true,
		HideTalkingHead = false, -- suppress the Talking Head dialog frame
		StackSpacing = 0, -- gap between stacked alerts (negative overlaps art padding)
	},

	-- Group pull timer on /pull (alias /pc). Retail and Classic.
	PullCountdown = {
		Enable = true,
		Seconds = 10, -- used when /pull is typed with no number
	},

	-- The group tools panel, with ready check, role check, pull timer, world markers, and
	-- target icons, shown only while in a group.
	GroupTools = {
		Enable = true,
		PullTime = 8, -- default pull-timer countdown in seconds
	},

	-- Our own compact loot window, replacing the stock pick-up list.
	Loot = {
		Enable = true,
		IconSize = 32, -- height of each loot row and its icon
		Width = 232, -- minimum window width, grown to fit the longest item name
		UnderMouse = false, -- open the window at the cursor instead of the saved spot
		RollFrames = true, -- compact group loot roll bars in place of the game's roll frames
		RollWidth = 380, -- room for the name beside four buttons and the BoP tag
		RollHeight = 26,
	},

	-- Tint already-known collectibles green at vendors, AH, and guild bank.
	AlreadyKnown = {
		Enable = true,
	},

	-- Odds and ends that do not belong to a bigger system.
	Misc = {
		EnhancedMail = false, -- collect gold only, take all, and an attachment tooltip
		MoveFrames = false, -- drag Blizzard windows for the session, nothing saved

		FocusModifier = "None", -- None, Shift, Ctrl or Alt, sets focus on a modified click
		FocusButton = "Left", -- Left, Right or Middle

		GCDBar = false, -- a bar tracking the global cooldown
		GCDBarWidth = 220,
		GCDBarHeight = 10,
		GCDBarIcon = true, -- show the icon of the spell that started the cooldown
		GCDBarIconSize = 24,
		GCDBarDrain = true, -- drain the bar as the cooldown runs out, rather than fill it
		GCDBarAlpha = 1, -- opacity while in combat
		GCDBarRestAlpha = 0.5, -- opacity out of combat
		GCDBarClassColor = true,
		GCDBarColor = { 0.36, 0.55, 0.81 }, -- used when class colour is off

		CursorTrail = false, -- a trail behind the mouse pointer
		CursorTrailStyle = "Comet", -- Ribbon, Particles or Comet
		CursorTrailLength = 48, -- most trail points on screen at once
		CursorTrailSpacing = 8, -- pixels the pointer must travel before another point is dropped
		CursorTrailLifetime = 0.45, -- seconds a point takes to fade out
		CursorTrailShape = "IconGlow", -- particle and spark art, a key in C.Media.TrailGlows
		CursorTrailRibbon = "GlowLine", -- ribbon art, a key in C.Media.TrailRibbons
		CursorTrailSize = 18, -- particle size and ribbon width
		CursorTrailAlpha = 0.85,
		CursorTrailShrink = true, -- taper the ribbon and shrink particles as they fade
		CursorTrailDrift = true, -- particles drift apart as they fade
		CursorTrailTwinkle = true, -- particles flicker as they fade
		CursorTrailHead = true, -- a glow on the pointer itself
		CursorTrailHeadShape = "IconGlow",
		CursorTrailHeadSize = 34,
		CursorTrailCombat = false, -- only show the trail while in combat
		CursorTrailHideTurning = true, -- hide it while turning or looking with the mouse
		CursorTrailClassColor = true,
		CursorTrailColor = { 0.36, 0.55, 0.81 }, -- used when class colour is off
		CursorTrailFade = false, -- shift from the trail colour to the tail colour as it fades
		CursorTrailTailColor = { 0.95, 0.69, 0.26 },
	},

	-- Small quality-of-life automations.
	Automation = {
		Enable = true,
		DeclineDuels = true, -- decline player duel requests
		DeclinePetDuels = true, -- decline pet-battle duel requests
		SkipCinematics = false, -- skip cinematics and movies (off so story is not lost)
		AutoRepair = true, -- repair all gear at a repair-capable merchant
		RepairGuildFunds = false, -- spend guild bank money first when allowed
		SellJunk = false, -- sell grey items when a merchant opens, independent of the bags
		AutoSummon = false, -- accept a summon after a short delay, out of combat
		AutoResurrect = false, -- accept a resurrection request, out of combat
		AutoInvite = false, -- accept group invites from friends and guild members
		WhisperInvite = false, -- invite whoever whispers the keyword below
		WhisperInviteWord = "inv",
		BattlegroundRelease = false, -- release your spirit on death in a battleground
	},

	-- Small quality of life features, each off until switched on.
	QoL = {
		AlertSize = 24, -- text size shared by the centre screen alerts
		CombatAlert = false, -- +Combat and -Combat text
		LowDurability = false, -- pulsing warning when gear is badly worn
		DurabilityThreshold = 25, -- warn below this percentage
		GroupDeath = false, -- "name DIED" when a group member dies
		SecondaryStats = false, -- attack power, spell power, crit, hit and dodge readout, picked by class
		StatsSize = 13, -- text size of the stats readout
		RareAlert = false, -- announce rares that show on the minimap
		RareAlertSound = true, -- play a sound with the rare alert
		RareAlertChat = true, -- print a map link in chat with the rare alert
		BlockInvites = false, -- turn away group invites from strangers
		BlockRequests = false, -- also turn away requests to join your group
		BlockSharedQuests = false, -- also turn away quests a stranger in your group shares
		QuickDelete = false, -- fill in the typed word on the delete good item dialog
		LootSparkle = false, -- keep the sparkle on lootable quest items through graphics presets
		MaxCameraDistance = false, -- raise the camera distance setting to the top of the game's own slider
		EasyFishing = false, -- double right-click on the world to cast Fishing
		CancelBuffs = false, -- take off listed buffs such as costumes as soon as they land
		CancelBuffList = "16593, 16595, 44212", -- spell IDs, Noggenfogger slow fall and shrink, Weighted Jack-o'-Lantern
		FlightTimes = false, -- time flights, show them on the flight map and count down while flying
		FastLoot = false, -- take all loot at once when the game would auto loot
		Reminders = false, -- clickable icons for what your character is missing, out of combat
		ReminderSize = 36, -- icon size of the reminder row
		ReminderBuffs = true, -- class self-buffs such as armors and Intellect
		ReminderWeapons = true, -- poisons, oils, stones and shaman imbues
		ReminderPet = true, -- hunter pet and warlock demon
		ReminderTalents = true, -- unspent talent points and spells to train
		TrainAll = false, -- Train All button on class and profession trainers
		QuestLevels = false, -- quest levels in NPC quest lists and quest text titles
		TradeInfo = false, -- label a trade partner as friend, guild member or stranger
		HideErrors = false, -- hide the red error text except the useful ones
		HideTips = false, -- hide tutorial pop ups and help tips
		HideBossBanner = false, -- hide the boss kill banner
		Crosshair = false, -- crosshair in the middle of the screen
		CrosshairSize = 12,
		CrosshairColor = { 1, 1, 1 },
		CrosshairCombatOnly = false,
		CrosshairOffset = 0, -- vertical offset from the centre
		QuestAnnounce = false, -- tell the group about accepted and finished quests
		AchievementShot = false, -- screenshot when an achievement is earned
		LevelAnnouncer = false, -- say how long each level took when you ding
		LevelChannel = "LOCAL", -- LOCAL, SAY, PARTY or GUILD
		LevelMaxMessage = true, -- a special line at the maximum level
		AutoLog = false, -- switch combat logging on in logged content
		AutoLogRaidNormal = true,
		AutoLogRaidHeroic = true,
		AutoLogRaidFinder = false,
		AutoLogDungeon = true, -- Heroic dungeons
	},

	-- Hands-off questing, which covers accept, turn in and reward selection.
	AutoQuest = {
		Enable = true,
		Accept = true, -- accept offered quests
		TurnIn = true, -- hand in completed quests
		RewardMode = "TAKE", -- on a choice of rewards: OFF, HIGHLIGHT the best seller, or TAKE it
		SkipGossip = true, -- click through a single-option gossip
		IgnoreTrivial = false, -- leave low-level (grey) quests alone
		Repeatable = false, -- daily and repeatable quests, which usually eat materials
		SkipGoldCost = true, -- leave quests that cost gold to hand in
		SharedQuests = true, -- accept quests a party member shares
		Share = true, -- push accepted quests to the party
		BlockedNPCs = "", -- comma separated NPC IDs automation ignores
		PauseKey = "SHIFT", -- hold to pause automation (NONE disables the pause)
	},

	Chat = {
		Enable = true,
		Width = 420, -- Edit Mode also restores chat size, so we hold both
		Height = 180,
		Font = "Normal",
		FontSize = 13,
		FontOutline = false,
		Fade = false,
		FadeTime = 15,
		IdleFade = false, -- dim the whole chat to a resting alpha when idle, lift on hover
		IdleFadeAlpha = 0.25, -- resting alpha while idle
		MouseWheelScroll = true,
		StickyWhisper = false, -- writes a flag the chat edit box reads in its Enter handler, off by default
		WhisperSound = true, -- play a sound on an incoming whisper
		HistoryPersist = true, -- keep recent player chat across a reload or relog
		KeywordHighlight = true, -- highlight your name and custom keywords in chat
		KeywordList = "", -- extra keywords, comma separated (your name is always watched)
		KeywordColor = { 1, 0.82, 0 }, -- colour applied to a matched keyword
		KeywordSound = true, -- play a sound when a keyword is mentioned
		KeywordCount = true, -- show a badge counting unread keyword mentions
		Emojis = true, -- show :) and :shortcodes: as small icons in player chat
		SkinBubbles = true, -- give in-world chat bubbles our border and background
		BubbleName = true, -- start the bubble with who is speaking, class coloured
		BubbleChatColor = true, -- tint the bubble shadow by chat type (party, raid, yell)
		ShortenChannels = true,
		ClassColorNames = true,
		URLLinks = true,
		CharacterCount = true, -- characters left to type, on the right of the chat edit box
		HyperlinkTooltip = true,
		LootIcons = true, -- item icon in front of links in loot messages
		LinkItemLevel = true, -- item level inside the brackets of weapon and armor links
		ChatBar = true,
		SideButtons = true, -- vertical icon strip on the left of the chat
		SpamFilter = false,
		HideFleeEmotes = true, -- drop "attempts to run away in fear!" creature emotes
		LeaveChannelMenu = true, -- a Leave entry when right-clicking a channel name
		CopyButton = true,
		Timestamps = true,
		GradientBackdrop = true,
	},

	Tooltip = {
		Enable = true,
		CursorAnchor = false, -- follow the cursor instead of the default corner
		HideInCombat = false,
		ClassColorName = true,
		HealthValue = true,
		HealthBarPosition = "TOP", -- TOP or BOTTOM, outside the tooltip
		ShowTarget = true,
		ShowGuild = true, -- <Guild> line for players
		ShowItemLevel = true, -- inspect item level on players
		ItemLevelOnShift = false, -- only look it up while shift is held
		ShowIDs = true, -- spell / item / currency / mount ids
		ShowItemCount = true, -- how many of an item you hold in the bags and the bank
		QuestItemInfo = true, -- name and status of the quest a bag item starts
		ShowIcons = true, -- icon beside the tooltip title
		ShowMountSource = true, -- collection status/source on a player's mount buff (hold Shift)
		BorderColor = true, -- tint the tooltip border by item quality
		ShowMount = false, -- the mount a player is riding (off, since it clutters every player tooltip)
		ShowRole = true, -- tank/healer/dps icon for group members
		ShowFactionIcon = true, -- faction crest on the name, hides the faction line
		ShowRaidIcon = true, -- raid target marker ahead of the unit name
		ShowTargetedBy = true, -- who in your group is targeting this unit
		ShowTitle = true, -- swap in the player's title (PvP name)
		HidePvP = true, -- hide the big red PvP line
		UnitFrameHint = true, -- the "right click for frame settings" line on unit frame tooltips
	},
}
