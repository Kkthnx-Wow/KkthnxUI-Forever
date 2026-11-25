--[[-----------------------------------------------------------------------------
	Addon: KkthnxUI
	File: Modules/Chat/Emojis.lua
	Purpose:
		Swap :shortcodes: and classic emoticons like :) or <3 for small inline
		icons in player chat. Built on a message filter like the keyword
		highlighter, so links are never reached into and nothing secure is touched.
		Copy Chat turns the icons back into text through RestoreEmojis.
-----------------------------------------------------------------------------]]

local K, C = KkthnxUI[1], KkthnxUI[2]

local Module = K:GetModule("Chat")
if not Module then
	return
end

local ipairs = ipairs
local next = next
local type = type
local gsub = string.gsub
local match = string.match
local find = string.find

local IsSecret = K.IsSecret

local FOLDER = K.MediaFolder .. "Chat\\Emojis\\"

-- { text, texture file }. Matched as whole words only, so "xD" inside a longer
-- word or ":p" inside a URL is left alone. A word may end in . , ! or ? and
-- still match, so "nice :)." works.
local DEFINITIONS = {
	-- Shortcodes
	{ ":smile:", "Grinning_Face_with_Big_Eyes" },
	{ ":joy:", "Face_with_Tears_of_Joy" },
	{ ":laughing:", "Grinning_Squinting_Face" },
	{ ":wink:", "Winking_Face" },
	{ ":blush:", "Smiling_Face_with_Smiling_Eyes" },
	{ ":heart_eyes:", "Smiling_Face_with_Heart_Eyes" },
	{ ":kissing_heart:", "Face_Blowing_a_Kiss" },
	{ ":kissing:", "Kissing_Face" },
	{ ":yum:", "Face_Savoring_Food" },
	{ ":relieved:", "Relieved_Face" },
	{ ":sweat_smile:", "Smiling_Face_with_Sweat" },
	{ ":heart:", "Red_Heart" },
	{ ":broken_heart:", "Broken_Heart" },
	{ ":thumbsup:", "Thumbs_Up" },
	{ ":+1:", "Thumbs_Up" },
	{ ":thumbsdown:", "Thumbs_Down" },
	{ ":-1:", "Thumbs_Down" },
	{ ":wave:", "Waving_Hand" },
	{ ":ok_hand:", "OK_Hand" },
	{ ":sparkles:", "Sparkles" },
	{ ":warning:", "Warning" },
	{ ":eyes:", "Eyes" },
	{ ":slightly_smiling_face:", "Slightly_Smiling_Face" },
	{ ":slightly_frowning_face:", "Slightly_Frowning_Face" },
	{ ":cry:", "Crying_Face" },
	{ ":angry:", "Angry_Face" },
	{ ":rage:", "Face_with_Symbols_on_Mouth" },
	{ ":open_mouth:", "Face_with_Open_Mouth" },
	{ ":expressionless:", "Expressionless_Face" },
	{ ":confused:", "Confused_Face" },
	{ ":stuck_out_tongue:", "Face_with_Tongue" },
	{ ":stuck_out_tongue_winking_eye:", "Winking_Face_with_Tongue" },
	-- The first KkthnxUI set, for the faces the set above lacks
	{ ":kappa:", "Kappa" },
	{ ":murloc:", "Murloc" },
	{ ":facepalm:", "Facepalm" },
	{ ":poop:", "Poop" },
	{ ":thinking:", "Thinking" },
	{ ":sunglasses:", "Sunglasses" },
	{ ":smirk:", "Smirk" },
	{ ":scream:", "Scream" },
	{ ":zzz:", "ZZZ" },
	{ ":call_me:", "CallMe" },
	-- Classes
	{ ":death_knight:", "Death_knight" },
	{ ":dk:", "Death_knight" },
	{ ":demon_hunter:", "Demon_hunter" },
	{ ":dh:", "Demon_hunter" },
	{ ":druid:", "Druid" },
	{ ":evoker:", "Evoker" },
	{ ":hunter:", "Hunter" },
	{ ":mage:", "Mage" },
	{ ":monk:", "Monk" },
	{ ":paladin:", "Paladin" },
	{ ":pally:", "Paladin" },
	{ ":priest:", "Priest" },
	{ ":rogue:", "Rogue" },
	{ ":shaman:", "Shaman" },
	{ ":shammy:", "Shaman" },
	{ ":warlock:", "Warlock" },
	{ ":lock:", "Warlock" },
	{ ":warrior:", "Warrior" },
	{ ":warr:", "Warrior" },
	-- Happy
	{ ":)", "Slightly_Smiling_Face" },
	{ ":-)", "Slightly_Smiling_Face" },
	{ "=)", "Slightly_Smiling_Face" },
	{ ":D", "Grinning_Face_with_Big_Eyes" },
	{ ":-D", "Grinning_Face_with_Big_Eyes" },
	{ "=D", "Grinning_Face_with_Big_Eyes" },
	{ "xD", "Face_with_Tears_of_Joy" },
	{ "XD", "Face_with_Tears_of_Joy" },
	{ ":')", "Face_with_Tears_of_Joy" },
	{ ";)", "Winking_Face" },
	{ ";-)", "Winking_Face" },
	{ ";P", "Winking_Face_with_Tongue" },
	{ ";p", "Winking_Face_with_Tongue" },
	{ ":P", "Face_with_Tongue" },
	{ ":-P", "Face_with_Tongue" },
	{ ":p", "Face_with_Tongue" },
	{ ":-p", "Face_with_Tongue" },
	{ "=P", "Face_with_Tongue" },
	{ ":*", "Face_Blowing_a_Kiss" },
	{ ":-*", "Face_Blowing_a_Kiss" },
	{ "<3", "Red_Heart" },
	{ "</3", "Broken_Heart" },
	-- Sad and angry
	{ ":(", "Slightly_Frowning_Face" },
	{ ":-(", "Slightly_Frowning_Face" },
	{ "=(", "Slightly_Frowning_Face" },
	{ ":'(", "Crying_Face" },
	{ ":'-(", "Crying_Face" },
	{ ">:(", "Angry_Face" },
	{ ">:-(", "Angry_Face" },
	{ ":@", "Face_with_Symbols_on_Mouth" },
	{ ":-@", "Face_with_Symbols_on_Mouth" },
	-- Shocked and neutral
	{ ":O", "Face_with_Open_Mouth" },
	{ ":-O", "Face_with_Open_Mouth" },
	{ ":o", "Face_with_Open_Mouth" },
	{ ":-o", "Face_with_Open_Mouth" },
	{ "-_-", "Expressionless_Face" },
	{ "o_O", "Confused_Face" },
	{ "O_o", "Confused_Face" },
}

local EVENTS = {
	"CHAT_MSG_SAY", "CHAT_MSG_YELL", "CHAT_MSG_EMOTE",
	"CHAT_MSG_GUILD", "CHAT_MSG_OFFICER",
	"CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER",
	"CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER", "CHAT_MSG_RAID_WARNING",
	"CHAT_MSG_INSTANCE_CHAT", "CHAT_MSG_INSTANCE_CHAT_LEADER",
	"CHAT_MSG_CHANNEL", "CHAT_MSG_COMMUNITIES_CHANNEL",
	"CHAT_MSG_WHISPER", "CHAT_MSG_WHISPER_INFORM",
	"CHAT_MSG_BN_WHISPER", "CHAT_MSG_BN_WHISPER_INFORM",
	"CHAT_MSG_AFK", "CHAT_MSG_DND",
}

-- Word -> finished replacement string, built once. A hash lookup per word keeps
-- the cost flat however many emoticons there are.
local replacements = {}
-- Texture file -> the shortest text that makes it, for Copy Chat.
local textByFile = {}

local function Build()
	for _, def in ipairs(DEFINITIONS) do
		local text, file = def[1], def[2]
		-- Height 0 sizes the icon to the chat font, so it follows the font size option.
		replacements[text] = "|T" .. FOLDER .. file .. ".tga:0|t"
		local known = textByFile[file]
		if not known or #text < #known then
			textByFile[file] = text
		end
	end
end

local function ReplaceWord(word)
	local hit = replacements[word]
	if hit then
		return hit
	end
	-- Allow trailing sentence punctuation after the emoticon.
	local core, tail = match(word, "^(.-)([%.,!%?]+)$")
	hit = core and replacements[core]
	if hit then
		return hit .. tail
	end
end

local function Replace(segment)
	return (gsub(segment, "%S+", ReplaceWord))
end

-- Every emoticon above has one of these characters, or is xD. A line with none
-- of them, most of Trade, skips the word by word pass. The filter runs once per
-- chat window showing the line, so this check pays off several times over.
local function MayHaveEmoji(message)
	return find(message, "[:;=<>_]") or find(message, "[xX]D")
end

local function Filter(_, _, message, ...)
	if not C.Chat.Emojis or type(message) ~= "string" or IsSecret(message) or not MayHaveEmoji(message) then
		return false, message, ...
	end
	return false, Module.OutsideLinks(message, Replace), ...
end

-- Emoji icons for text shown outside the chat frame, such as our chat bubbles.
function Module.Emojify(text)
	if not C.Chat.Emojis or not next(replacements) then
		return text
	end
	return Module.OutsideLinks(text, Replace)
end

-- Turn each icon back into text for Copy Chat. Forever prints an empty hyperlink
-- as raw code, so the icon carries no hidden copy of what was typed. Several
-- emoticons share one icon, so this gives the shortest form, :) for :-).
function Module.RestoreEmojis(text)
	return (gsub(text, "|T[^|]-Chat\\Emojis\\([^|]-)%.tga:0|t", function(file)
		return textByFile[file]
	end))
end

function Module:SetupEmojis()
	Build()
	for _, event in ipairs(EVENTS) do
		ChatFrameUtil.AddMessageEventFilter(event, Filter)
	end
end
