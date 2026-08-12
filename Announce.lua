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
-- The voice goes through C_VoiceChat.SpeakText with the argument order and
-- voice-validation the community's raid addons settled on: an unknown stored
-- voice id silently falls back to 0 rather than failing to speak at all.
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

-- Is `voiceID` one the client actually has? Voices depend on the player's
-- installed language packs, so a stored id can vanish between sessions.
local function voiceExists(voiceID)
	for _, voice in ipairs(installedVoices()) do
		if voice.voiceID == voiceID then return true end
	end
	return false
end

-- The first voice this client really has, or nil if it has none.
--
-- Falling back to zero is only a fallback if zero is one of them, and there is
-- no id that is safe to assume: the numbering follows whatever language packs
-- are installed. Handing the client an id it does not know is answered with
-- silence, which is indistinguishable from the feature being switched off.
local function defaultVoice()
	for _, voice in ipairs(installedVoices()) do
		if type(voice.voiceID) == "number" then return voice.voiceID end
	end
	return nil
end

-- `voiceID` overrides the one the player picked, for anything that has to be
-- told apart from a wave call by ear alone.
function Announce.Say(text, voiceID)
	if not ns.GetTTSEnabled() then return false end
	if type(text) ~= "string" or text == "" then return false end
	if issecretvalue and issecretvalue(text) then return false end
	if not C_VoiceChat or not C_VoiceChat.SpeakText then return false end

	voiceID = voiceID or ns.GetTTSVoice()
	if not voiceExists(voiceID) then voiceID = defaultVoice() end
	if not voiceID then return false end

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
	return pcall(C_VoiceChat.SpeakText, voiceID, text, rate,
		ns.GetTTSVolume(), ns.GetTTSOverlap())
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
	ns.Print(("voice: enabled=%s, %d installed"):format(
		ns.GetTTSEnabled() and "yes" or "|cffff5555no|r", #voices))
	for _, voice in ipairs(voices) do
		ns.Print(("    id %s  %s%s"):format(tostring(voice.voiceID), tostring(voice.name),
			voice.voiceID == ns.GetTTSVoice() and "  |cff44ff44<- yours|r" or ""))
	end

	local stored = ns.GetTTSVoice()
	if not voiceExists(stored) then
		ns.Print(("    |cffffd200your stored voice (%s) is not installed|r - using %s instead."):format(
			tostring(stored), tostring(defaultVoice())))
	end

	if #voices == 0 then
		ns.Print("    |cffff5555no voices at all|r - text to speech is off in the game's own "
			.. "Sound settings, or no voice pack is installed.")
	else
		ns.Print("    saying \"" .. ns.QuadrantLabel(ns.QUADRANTS[1]) .. "\" now.")
		Announce.Say(ns.QuadrantLabel(ns.QUADRANTS[1]))
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
	Announce.Say(ns.QuadrantLabel(current))
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
