local _, ns = ...

-- ===========================================================================
-- Announce.lua  ·  what the player hears and reads during the silent replay.
--
-- Two channels, each independently switchable:
--
--   voice   one word per wave -- the safe colour ("Red"), or the marker's name
--           ("Cross") for players who read the board by shape. Short on purpose:
--           waves are about three seconds apart, so anything longer arrives
--           after the thing it was warning about.
--   popup   the call on screen: the current quadrant large, and the one after it
--           as a smaller line so the next move can be started early.
--
-- There used to be a third: a bell that rang the moment the player reached the
-- safe quarter. It needed to know where they were standing, which the client no
-- longer says in here, so it is gone rather than left to fail silently.
--
-- The voice goes through C_VoiceChat.SpeakText. An id is a position in whatever
-- language packs the player installed, so nothing here assumes one: a stored id
-- the client no longer lists is picked over rather than handed on (AutoVoice),
-- and a client that has stopped listing anything at all is answered from memory
-- rather than with silence (resolveVoice).
-- ===========================================================================

local Announce = {}
ns.Announce = Announce

local ICON_SIZE = 22

local popup                -- the on-screen call

-- ---------------------------------------------------------------------------
-- Voice
-- ---------------------------------------------------------------------------

local function installedVoices()
	if not C_VoiceChat or not C_VoiceChat.GetTtsVoices then return {} end
	local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
	if not ok or type(voices) ~= "table" then return {} end
	return voices
end

-- Every voice the client has, for the picker in the options.
function Announce.Voices() return installedVoices() end

-- The name as the operating system spells it, cut back to the voice's own name:
-- the client hands these over decorated in ways that differ per platform
-- ("Microsoft David Desktop - English (United States)", "Samantha (Enhanced)").
-- Comparing the whole string would match nothing on one platform and everything
-- on the other.
local function plainName(voice)
	local name = voice and voice.name
	if type(name) ~= "string" then return "" end
	name = name:gsub("%b()", ""):gsub("%s+%-.*$", "")
	return (name:lower():gsub("^%s*(.-)%s*$", "%1"))
end

-- macOS ships a set of joke voices alongside the real ones, and they are not
-- degraded speech -- they do not say the word at all. This was reported from the
-- field by the author of Deadly Boss Mods: the addon had picked "Hysterical",
-- so instead of calling the colours it laughed at the player, once per wave, for
-- a whole pull.
--
-- Matched against the trimmed name whole rather than as a substring, so a real
-- voice is never blocked for containing one of these by accident ("Organ" would
-- otherwise take "Morgan" with it).
local NOVELTY_VOICES = {
	["albert"] = true, ["bad news"] = true, ["bahh"] = true, ["bells"] = true,
	["boing"] = true, ["bubbles"] = true, ["cellos"] = true, ["deranged"] = true,
	["good news"] = true, ["hysterical"] = true, ["jester"] = true,
	["organ"] = true, ["pipe organ"] = true, ["superstar"] = true,
	["trinoids"] = true, ["whisper"] = true, ["wobble"] = true, ["zarvox"] = true,
}

-- Voices known to read a single word cleanly, best first. A wave call is one
-- word arriving three seconds before it matters, so clarity is the only thing
-- being judged here. Substring matched, since these arrive decorated.
local PREFERRED_VOICES = {
	"samantha", "alex", "david", "zira", "mark",
	"daniel", "karen", "moira", "tessa", "fiona", "serena", "hazel",
}

-- Is `voiceID` one the client actually has? Voices depend on the player's
-- installed language packs, so a stored id can vanish between sessions.
--
-- `voices` is the list to check against, for callers that already asked the
-- client for one. Asking again is not free of consequence: the answer changes
-- between one call and the next (see resolveVoice), so a function that looks the
-- list up twice can be told two different things inside one wave call.
local function voiceExists(voiceID, voices)
	if type(voiceID) ~= "number" then return false end
	for _, voice in ipairs(voices or installedVoices()) do
		if voice.voiceID == voiceID then return true end
	end
	return false
end

-- The voice to use when the player has not picked one.
--
-- Not "the first one". There is no id that is safe to assume -- including zero:
-- the numbering follows whatever language packs are installed, in whatever order
-- the system lists them, so an id is a position and not a voice. Handing the
-- client an id it does not know is answered with silence, which is
-- indistinguishable from the feature being switched off; handing it the wrong
-- position is worse, because it answers.
--
-- So: a voice known to speak clearly, else any voice that is not a joke, else
-- the first one there is. Only the last of those three can still be a novelty
-- voice, and by then it is that or nothing.
function Announce.AutoVoice(voices)
	voices = voices or installedVoices()
	local firstSpeaking, firstAny

	for _, voice in ipairs(voices) do
		if type(voice.voiceID) == "number" then
			firstAny = firstAny or voice.voiceID
			if not NOVELTY_VOICES[plainName(voice)] then
				firstSpeaking = firstSpeaking or voice.voiceID
			end
		end
	end

	for _, wanted in ipairs(PREFERRED_VOICES) do
		for _, voice in ipairs(voices) do
			if type(voice.voiceID) == "number" and not NOVELTY_VOICES[plainName(voice)]
				and plainName(voice):find(wanted, 1, true) then
				return voice.voiceID
			end
		end
	end

	return firstSpeaking or firstAny
end

-- The voice a call would come out in right now: the player's, while the client
-- still has it, and the addon's own choice otherwise. The options page and
-- `/ss sound` both report this rather than the stored value, because a stored
-- voice that has gone away is exactly the case worth being able to see.
function Announce.ActiveVoice(voices)
	voices = voices or installedVoices()
	local chosen = ns.GetTTSVoice()
	if voiceExists(chosen, voices) then return chosen end
	return Announce.AutoVoice(voices)
end

-- The name to show for `voiceID`, or nil if the client does not have it.
function Announce.VoiceName(voiceID)
	for _, voice in ipairs(installedVoices()) do
		if voice.voiceID == voiceID then return tostring(voice.name) end
	end
	return nil
end

-- The last id that actually spoke. See resolveVoice.
local lastGoodVoice

-- The voice this call comes out in: the id, and whether it had to be remembered
-- rather than looked up.
--
-- Announce.ActiveVoice asks the client afresh every time, which is right for the
-- options page and `/ss sound` -- those report the truth of this moment. It is
-- wrong for a wave call. GetTtsVoices belongs to the voice chat subsystem, and
-- that subsystem re-initialises: on a group change, on zoning, on a voice
-- session dropping. While it does, it lists nothing at all.
--
-- A wave call landing in one of those frames used to resolve to nil and never be
-- spoken. From the chair that is the voice cutting out for a wave or three in
-- the middle of a round, with the popup still updating beside it -- and it left
-- nothing behind to find, which is how it outlived several reports of it.
--
-- An empty list is the only thing the remembered id covers. A list that comes
-- back populated is the truth of the moment, so a stored voice missing from a
-- populated list really has gone away and AutoVoice should pick over it as
-- before.
local function resolveVoice(voiceID)
	local voices = installedVoices()
	if #voices == 0 then return lastGoodVoice, true end
	if voiceExists(voiceID, voices) then return voiceID, false end
	return Announce.ActiveVoice(voices), false
end

-- `voiceID` overrides the one the player picked, for anything that has to be
-- told apart from a wave call by ear alone.
--
-- Every road out of here that ends in silence says so under `/ss debug`. It used
-- to have six of them and no voice: a wave that was never spoken looked, from
-- the chair and from the log alike, exactly like a wave the detector never saw.
function Announce.Say(text, voiceID)
	if not ns.GetTTSEnabled() then return false end
	if type(text) ~= "string" or text == "" then
		ns.Trace("|cffff5555said nothing:|r there was no word to say (%s)", tostring(text))
		return false
	end
	if issecretvalue and issecretvalue(text) then
		ns.Trace("|cffff5555said nothing:|r the word came back secret")
		return false
	end
	if not C_VoiceChat or not C_VoiceChat.SpeakText then
		ns.Trace("|cffff5555said nothing:|r this client has no C_VoiceChat.SpeakText")
		return false
	end

	local resolved, remembered = resolveVoice(voiceID)
	if not resolved then
		ns.Trace("|cffff5555said nothing:|r the client listed no voice to say \"%s\" in",
			tostring(text))
		return false
	end
	if remembered then
		ns.Trace("the client listed no voices - saying \"%s\" in %s, the last one that worked",
			tostring(text), tostring(resolved))
	end

	local rate = 0
	if C_TTSSettings and C_TTSSettings.GetSpeechRate then
		local ok, stored = pcall(C_TTSSettings.GetSpeechRate)
		if ok and type(stored) == "number" then rate = stored end
	end

	-- Rate third, then volume, then overlap. Later clients grew a `destination`
	-- argument in the rate's place, and this one has not: it has no
	-- Enum.VoiceTtsDestination at all, and speaking with the newer order is
	-- accepted without complaint and then silently says nothing. Both orders were
	-- put to the ear side by side; this is the one that was audible.
	local ok, err = pcall(C_VoiceChat.SpeakText, resolved, text, rate,
		ns.GetTTSVolume(), ns.GetTTSOverlap())
	if not ok then
		ns.Trace("|cffff5555the client refused to say \"%s\":|r %s", tostring(text), tostring(err))
		return false
	end

	-- Proof this id speaks, and so the only thing worth falling back on when the
	-- client stops listing voices part way through a round.
	lastGoodVoice = resolved
	return true
end

-- ---------------------------------------------------------------------------
-- Deadly Boss Mods' voice
--
-- DBM's voice packs carry eight files, mm1 to mm8, one per raid target marker,
-- and they say the whole instruction: "move to square". They are the same voice
-- the rest of the pull is already being called in, recorded by a person, and on
-- macOS they sidestep the text-to-speech voice list entirely.
--
-- Nothing here calls into DBM's internals. The path is the one its own warnings
-- build (SpecialWarning.lua: "Interface\AddOns\DBM-VP<pack>\<name>.ogg"), and it
-- is played through DBM:PlaySoundFile so the sound lands on whichever channel
-- the player set DBM to use and obeys its silent mode.
--
-- Marker ids line up with no mapping at all: mm1..mm8 are Blizzard's eight raid
-- targets in Blizzard's order, which is the order ns.MARKERS is written in.
-- ---------------------------------------------------------------------------

local DBM_MARKER_SOUND = "Interface\\AddOns\\DBM-VP%s\\mm%d.ogg"

-- The voice pack DBM is set to use, or nil if there is nothing to play from.
-- Every step is guarded: DBM may be absent, may be an old build without these
-- fields, and may be installed with no voice pack at all -- and "the player has
-- DBM" is not the question, "will this file exist" is.
local function dbmVoicePack()
	local dbm = _G.DBM
	if type(dbm) ~= "table" or type(dbm.PlaySoundFile) ~= "function" then return nil end

	local options = rawget(dbm, "Options")
	local pack = type(options) == "table" and options.ChosenVoicePack2 or nil
	if type(pack) ~= "string" or pack == "" or pack:lower() == "none" then return nil end

	-- DBM lists the packs it actually found at login. A name left in the settings
	-- by a pack that has since been uninstalled would build a path to nothing.
	local versions = rawget(dbm, "VoiceVersions")
	if type(versions) == "table" and versions[pack] == nil then return nil end

	return pack
end

-- Whether a wave call would come out in DBM's voice right now. The options page
-- reports this, because "I ticked the box and it still sounds the same" is
-- answered by DBM having no voice pack far more often than by anything here.
function Announce.DBMVoiceAvailable() return dbmVoicePack() ~= nil end

-- Say a quadrant the DBM way. Returns true only if something was played, so the
-- caller can fall back to text to speech -- a player who ticked the box and then
-- uninstalled their voice pack gets the colours read out, not silence.
function Announce.SayWithDBM(quadrant)
	if not ns.GetDBMVoice() then return false end
	local pack = dbmVoicePack()
	if not pack then return false end
	local marker = ns.GetMarker(ns.GetAssignment(quadrant))
	if not marker then return false end

	local ok = pcall(_G.DBM.PlaySoundFile, _G.DBM, DBM_MARKER_SOUND:format(pack, marker.id))
	if not ok then
		ns.Trace("DBM refused to play the call for %s", tostring(quadrant))
		return false
	end
	return true
end

-- One wave, spoken. DBM's voice when it can, the client's own otherwise.
--
-- Both are behind the one "speak the safe quadrant" switch: which voice says it
-- is a preference, whether anything says it at all is the feature.
--
-- Note that DBM names the marker whichever way the announce style is set --
-- "move to square" is a recording, not a sentence being built here. The on-screen
-- call still follows the style, so a player reading colours and hearing marks is
-- a combination they can reach; it is theirs to choose.
function Announce.Call(quadrant)
	if not ns.GetTTSEnabled() then
		ns.Trace("said nothing for %s: the voice is switched off", tostring(quadrant))
		return false
	end
	if Announce.SayWithDBM(quadrant) then return true end
	return Announce.Say(ns.QuadrantLabel(quadrant))
end

-- ---------------------------------------------------------------------------
-- Sound self-test
--
-- The voice fails the same way it succeeds from the outside -- nothing happens
-- -- so "no sound" on its own says nothing about why. This fires it and reports
-- what the client made of it.
-- ---------------------------------------------------------------------------

function Announce.SelfTest()
	local voices = installedVoices()
	local active = Announce.ActiveVoice()

	ns.Print(("voice: enabled=%s, %d installed"):format(
		ns.GetTTSEnabled() and "yes" or "|cffff5555no|r", #voices))
	for _, voice in ipairs(voices) do
		ns.Print(("    id %s  %s%s%s"):format(tostring(voice.voiceID), tostring(voice.name),
			voice.voiceID == active and "  |cff44ff44<- in use|r" or "",
			NOVELTY_VOICES[plainName(voice)] and "  |cff888888(novelty - never chosen for you)|r" or ""))
	end

	local stored = ns.GetTTSVoice()
	if stored == nil then
		ns.Print(("    no voice picked, so the addon chose |cffffd200%s|r. Pick one in the "
			.. "options if it reads badly."):format(tostring(Announce.VoiceName(active) or active)))
	elseif not voiceExists(stored) then
		ns.Print(("    |cffffd200your chosen voice (%s) is not installed|r - using %s instead."):format(
			tostring(stored), tostring(Announce.VoiceName(active) or active)))
	end

	-- Reported whether or not it is switched on: "I have DBM and it still uses the
	-- robot" is the question this answers, and half the time the reason is that
	-- DBM itself has no voice pack selected.
	local pack = dbmVoicePack()
	ns.Print(("    Deadly Boss Mods voice: wanted=%s available=%s"):format(
		ns.GetDBMVoice() and "yes" or "no",
		pack and ("|cff44ff44" .. pack .. "|r") or "|cffff5555no voice pack|r"))

	local label = ns.QuadrantLabel(ns.QUADRANTS[1])
	if ns.GetDBMVoice() and pack then
		ns.Print("    playing the DBM call for " .. label .. " now.")
		Announce.Call(ns.QUADRANTS[1])
	elseif #voices == 0 then
		ns.Print("    |cffff5555no voices at all|r - text to speech is off in the game's own "
			.. "Sound settings, or no voice pack is installed.")
	else
		ns.Print("    saying \"" .. label .. "\" now.")
		Announce.Call(ns.QUADRANTS[1])
	end
end

-- ---------------------------------------------------------------------------
-- Popup
-- ---------------------------------------------------------------------------

local function buildPopup()
	if popup then return end

	popup = CreateFrame("Frame", "SnakeSaysCallout", UIParent)
	popup:SetSize(340, 76)
	popup:SetFrameStrata("HIGH")
	popup:SetMovable(true)
	popup:SetClampedToScreen(true)
	popup:EnableMouse(false)      -- click-through until the player unlocks the HUD
	popup:Hide()

	local main = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	main:SetPoint("TOP", popup, "TOP", 0, -6)
	popup.main = main

	local subtitle = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	subtitle:SetPoint("TOP", main, "BOTTOM", 0, -6)
	subtitle:SetTextColor(0.75, 0.75, 0.75)
	popup.subtitle = subtitle

	-- Dragging follows the same rule as the board: only while the HUD is
	-- unlocked, so it can't be nudged mid-pull.
	popup:RegisterForDrag("LeftButton")
	popup:SetScript("OnDragStart", function(self)
		if not ns.IsLocked() then self:StartMoving() end
	end)
	popup:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		Announce.SavePopupPosition(point, relPoint, x, y)
	end)

	Announce.ApplyPopupPosition()
	Announce.ApplyScale()
end

-- The player's chosen size for the call. Scaling the frame takes the icons with
-- the words, so "{cross} Red" stays legible as one thing at any size.
function Announce.ApplyScale()
	if not popup then return end
	popup:SetScale(ns.GetPopupScale())
end

function Announce.ApplyPopupPosition()
	if not popup then return end
	popup:ClearAllPoints()
	local stored = ns.db().popupPosition
	if stored and stored.point then
		popup:SetPoint(stored.point, UIParent, stored.relPoint or stored.point, stored.x or 0, stored.y or 0)
	else
		popup:SetPoint("TOP", UIParent, "TOP", 0, -160)
	end
end

function Announce.SavePopupPosition(point, relPoint, x, y)
	ns.db().popupPosition = { point = point, relPoint = relPoint, x = x, y = y }
	Announce.ApplyPopupPosition()
end

function Announce.ClearPopupPosition()
	ns.db().popupPosition = nil
	Announce.ApplyPopupPosition()
end

-- Unlocked HUD means the popup is grabbable, and shows itself so there is
-- something to grab even when no fight is running.
function Announce.ApplyLock()
	if not popup then return end
	local locked = ns.IsLocked()
	popup:EnableMouse(not locked)
	if not locked then
		popup.main:SetText(ns.QuadrantMarkup(ns.QUADRANTS[1], ICON_SIZE))
		popup.subtitle:SetText("drag to move")
		popup:Show()
	elseif not ns.Detector.IsReplaying() then
		popup:Hide()
	end
end

local function showCall(current, nextUp)
	if not ns.GetPopupEnabled() then return end
	buildPopup()

	local marker = ns.GetMarker(ns.GetAssignment(current))
	popup.main:SetText(ns.QuadrantMarkup(current, ICON_SIZE))
	if marker then
		popup.main:SetTextColor(unpack(marker.color))
	end

	if nextUp and ns.GetPopupSubtitle() then
		popup.subtitle:SetText(ns.QuadrantMarkup(nextUp, ICON_SIZE - 4) .. " next")
	else
		popup.subtitle:SetText("")
	end

	popup:Show()
end

local function hideCall()
	if not popup then return end
	popup:Hide()
	popup.main:SetText("")
	popup.subtitle:SetText("")
end

-- Test seams / external readers.
function Announce.GetPopup() return popup end
function Announce.IsPopupShown() return popup ~= nil and popup:IsShown() end
function Announce.PopupText() return popup and popup.main:GetText() or "" end
function Announce.PopupSubtitle() return popup and popup.subtitle:GetText() or "" end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

-- No quadrant means a run this client only heard called in party chat: the boss
-- is calling the waves and the timeline can follow them, but which quadrant each
-- one is arrived as a secret value and cannot be known. Nothing to say, and
-- nothing to put on screen -- guessing aloud is worse than silence.
function Announce.OnStep(index, current, nextUp)
	if not current then return end
	Announce.Call(current)
	showCall(current, nextUp)
end

function Announce.OnEnd()
	hideCall()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
	buildPopup()
end)

ns.Detector.OnReplayStep(Announce.OnStep)
ns.Detector.OnReplayEnd(Announce.OnEnd)
