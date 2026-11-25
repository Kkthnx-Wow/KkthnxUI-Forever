--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Core/Media.lua
	Purpose:
		Central media registry. Stored on C.Media (never a saved profile) so it
		survives config rebuilds. Accessors fall back to LibSharedMedia when a
		requested name is not one of ours.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local ipairs = ipairs
local pairs = pairs
local media = K.MediaFolder

-- Two copies of the library can be in play. Ours is embedded under a suffixed
-- name so it can never fight another addon's, but a private copy shares nothing:
-- every other addon publishes into and reads from the real LibSharedMedia-3.0. So
-- prefer the real one whenever some addon has brought it along, and fall back to
-- our own when we are running alone, which at least keeps Fetch working.
K.LibSharedMedia = LibStub and (LibStub("LibSharedMedia-3.0", true) or LibStub("LibSharedMedia-3.0-KkthnxUI", true))

C.Media = {
	Fonts = {
		Normal = STANDARD_TEXT_FONT,
		Combat = _G.DAMAGE_TEXT_FONT or STANDARD_TEXT_FONT,
		Blank = media .. "Fonts\\Invisible.ttf",
	},
	-- Every bar texture we actually ship. Most of these sat in Media/Statusbars
	-- unlisted, so they were on disk but could never be picked.
	Statusbars = {
		KkthnxUI = media .. "Statusbars\\Statusbar",
		-- The default. The name stays as it was when this was an atlas, since the
		-- defaults and saved profiles refer to it by that name.
		["KkthnxUI Forever"] = media .. "Statusbars\\KkthnxUI_Forever.tga",
		AltzUI = media .. "Statusbars\\AltzUI.tga",
		AsphyxiaUI = media .. "Statusbars\\AsphyxiaUI.tga",
		AzeriteUI = media .. "Statusbars\\AzeriteUI.tga",
		Blank = media .. "Statusbars\\Blank.tga",
		Clean = media .. "Statusbars\\Clean.tga",
		Flat = media .. "Statusbars\\Flat.tga",
		Glamour7 = media .. "Statusbars\\Glamour7.tga",
		GoldpawUI = media .. "Statusbars\\GoldpawUI.tga",
		Kui = media .. "Statusbars\\KuiStatusbar.tga",
		KuiBright = media .. "Statusbars\\KuiStatusbarBright.tga",
		Ohi_Dragon = media .. "Statusbars\\Ohi_Dragon.tga",
		Palooza = media .. "Statusbars\\Palooza.tga",
		PinkGradient = media .. "Statusbars\\PinkGradient.tga",
		Rain = media .. "Statusbars\\Rain.tga",
		SkullFlowerUI = media .. "Statusbars\\SkullFlowerUI.tga",
		Tukui = media .. "Statusbars\\ElvTukui.tga",
		Water = media .. "Statusbars\\Water.tga",
		Wglass = media .. "Statusbars\\Wglass.tga",
		ZorkUI = media .. "Statusbars\\ZorkUI.tga",
	},
	Textures = {
		White8x8 = "Interface\\BUTTONS\\WHITE8X8",
		Glow = media .. "Textures\\GlowTex.tga",
		-- White, so every spark can take its own colour, a 2px core with a soft
		-- halo, drawn 16px wide so the core lands on whole pixels.
		Spark = media .. "Textures\\Spark_Glow.tga",
	},
	Sounds = {},
}

-- Cursor trail art, in the order the options list it. Every atlas here is on
-- the Forever client. White and soft art takes the trail colour cleanly, gold or
-- orange art blends with it. The first four keep their old keys, so a saved
-- shape still resolves.
C.Media.TrailGlows = {
	{ key = "Glow", text = "Soft Glow", file = [[Interface\GLUES\Models\UI_Draenei\GenericGlow64]] },
	{ key = "Spark", text = "Star", file = [[Interface\Cooldown\star4]] },
	{ key = "Ping", text = "Ping", file = [[Interface\Cooldown\ping4]] },
	{ key = "Streak", text = "Streak", file = [[Interface\CastingBar\UI-CastingBar-Spark]] },
	{ key = "IconGlow", text = "Halo", atlas = "AftLevelup-WhiteIconGlow" },
	{ key = "Orb", text = "Orb", atlas = "Artifacts-Anim-Orb" },
	{ key = "SpikeyGlow", text = "Spiky Glow", atlas = "ChallengeMode-WhiteSpikeyGlow" },
	{ key = "StarBurst", text = "Star Burst", atlas = "AftLevelup-WhiteStarBurst" },
	{ key = "NodeGlow", text = "Node Glow", atlas = "heartofazeroth-node-glow" },
	{ key = "Dot", text = "Dot", atlas = "common-radiobutton-dot" },
	{ key = "Ember", text = "Ember", atlas = "XPBarAnim-OrangeSpark" },
}
C.Media.TrailRibbons = {
	{ key = "GlowLine", text = "Glow Line", atlas = "Cast_Standard_LineGlow" },
	{ key = "LevelLine", text = "Level Up Line", atlas = "AftLevelup-GlowLine" },
	{ key = "XPTrail", text = "Comet Tail", atlas = "XPBarAnim-OrangeTrail" },
	{ key = "XPGlow", text = "Soft Band", atlas = "XPBarAnim-OrangeGlow" },
	{ key = "Channel", text = "Channel Spark", atlas = "Azerite-SmallChannel-Spark" },
	{ key = "Solid", text = "Solid", file = [[Interface\Buttons\WHITE8X8]] },
}

-- Look an entry up by key in one of the lists above.
function K.FindTrailArt(list, key)
	for _, entry in ipairs(list) do
		if entry.key == key then
			return entry
		end
	end
	return list[1]
end

-- Put a trail entry on a texture or line, atlas or file.
function K.SetTrailArt(region, entry)
	if entry.atlas then
		region:SetAtlas(entry.atlas, false)
	else
		region:SetTexture(entry.file)
	end
end

local statusbars = C.Media.Statusbars
local fonts = C.Media.Fonts

-- Bar textures that are atlas names rather than files. A StatusBar takes either
-- through SetStatusBarTexture, but a plain Texture needs SetAtlas for these, and
-- they are never handed to other addons as a file path.
K.StatusbarAtlases = {
}

-- Put a bar texture from the list above on a plain Texture region.
function K.SetTextureAsset(texture, asset)
	if K.StatusbarAtlases[asset] then
		texture:SetAtlas(asset, false)
	else
		texture:SetTexture(asset)
	end
end

-- Resolve a statusbar texture by name, falling back to LSM then our default.
function K.GetTexture(name)
	if statusbars[name] then
		return statusbars[name]
	end
	if K.LibSharedMedia then
		local hit = K.LibSharedMedia:Fetch("statusbar", name, true)
		if hit then
			return hit
		end
	end
	return statusbars.KkthnxUI
end

-- Resolve a font by name, falling back to LSM then the game font.
function K.GetFont(name)
	if not name then
		return fonts.Normal
	end
	if fonts[name] then
		return fonts[name]
	end
	if K.LibSharedMedia then
		local hit = K.LibSharedMedia:Fetch("font", name, true)
		if hit then
			return hit
		end
	end
	return fonts.Normal
end

-- Borders are deliberately absent from both directions below. Ours are a single
-- strip holding all eight edge pieces, cropped by K.CreateBorder, not the edgeFile
-- a shared border is. Publishing ours would hand other addons a texture they would
-- draw wrong, and pulling theirs in would fill our border dropdown with entries
-- that cannot render in our frames.
local SHARED_TYPES = {
	{ "statusbar", statusbars },
	{ "font", fonts },
	{ "sound", C.Media.Sounds },
}

-- Publish our media so other addons can pick it, then pull in everything they have
-- registered so it shows up in our own dropdowns. Ours win a name clash, since a
-- name in C.Media is what our defaults refer to.
function K.SyncSharedMedia()
	local LSM = K.LibSharedMedia
	if not LSM then
		return
	end

	for _, entry in pairs(SHARED_TYPES) do
		local mediatype, tbl = entry[1], entry[2]
		for name, path in pairs(tbl) do
			-- An atlas name is not a file, and another addon would draw it blank.
			if not (mediatype == "statusbar" and K.StatusbarAtlases[path]) then
				LSM:Register(mediatype, name, path)
			end
		end
	end

	for _, entry in pairs(SHARED_TYPES) do
		local mediatype, tbl = entry[1], entry[2]
		local shared = LSM:HashTable(mediatype)
		if shared then
			for name, path in pairs(shared) do
				if tbl[name] == nil then
					tbl[name] = path
				end
			end
		end
	end
end

K.SyncSharedMedia()

-- Addons that load after us register their media later, so pick those up as they
-- arrive rather than only taking a snapshot at login. The callback names the one
-- entry just added, so only that is copied. A full sync per entry made a media
-- pack of a few hundred files rescan every table a few hundred times at load.
local SHARED_BY_TYPE = {}
for _, entry in pairs(SHARED_TYPES) do
	SHARED_BY_TYPE[entry[1]] = entry[2]
end

if K.LibSharedMedia and K.LibSharedMedia.RegisterCallback then
	K.LibSharedMedia.RegisterCallback(K, "LibSharedMedia_Registered", function(_, mediatype, key)
		local tbl = SHARED_BY_TYPE[mediatype]
		if tbl and key and tbl[key] == nil then
			tbl[key] = K.LibSharedMedia:Fetch(mediatype, key, true)
		end
	end)
end
