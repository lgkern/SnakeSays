local _, ns = ...

-- ===========================================================================
-- Announce.lua  ·  what the player hears and reads during the silent replay.
--
-- Three channels, each independently switchable:
--
--   voice   one word per wave -- the safe colour ("Red"), or the marker's name
--           ("Cross") for players who read the board by shape. Short on purpose:
--           waves are about three seconds apart, so anything longer arrives
--           after the thing it was warning about.
--   bell    rings the moment the player actually reaches the safe quadrant, so
--           they can confirm the move without looking away from the fight.
--   popup   the call on screen: the current quadrant large, and the one after it
--           as a smaller line so the next move can be started early.
--
-- The voice goes through C_VoiceChat.SpeakText with the argument order and
-- voice-validation the community's raid addons settled on: an unknown stored
-- voice id silently falls back to 0 rather than failing to speak at all.
-- ===========================================================================

local Announce = {}
ns.Announce = Announce

local BELL_SOUND = "Sound\\Doodad\\BellTollNightElf.ogg"
local BELL_POLL  = 0.1     -- how often we check whether the player made it
local ICON_SIZE  = 22

local popup                -- the on-screen call
local bellTicker
local safeQuadrant         -- where the player should be standing right now
local bellRung             -- already rung for this wave

-- ---------------------------------------------------------------------------
-- Voice
-- ---------------------------------------------------------------------------

-- Is `voiceID` one the client actually has? Voices depend on the player's
-- installed language packs, so a stored id can vanish between sessions.
local function voiceExists(voiceID)
	if not C_VoiceChat or not C_VoiceChat.GetTtsVoices then return false end
	local ok, voices = pcall(C_VoiceChat.GetTtsVoices)
	if not ok or type(voices) ~= "table" then return false end
	for _, voice in ipairs(voices) do
		if voice.voiceID == voiceID then return true end
	end
	return false
end

function Announce.Say(text)
	if not ns.GetTTSEnabled() then return false end
	if type(text) ~= "string" or text == "" then return false end
	if issecretvalue and issecretvalue(text) then return false end
	if not C_VoiceChat or not C_VoiceChat.SpeakText then return false end

	local voiceID = ns.GetTTSVoice()
	if not voiceExists(voiceID) then voiceID = 0 end

	local rate = 0
	if C_TTSSettings and C_TTSSettings.GetSpeechRate then
		local ok, stored = pcall(C_TTSSettings.GetSpeechRate)
		if ok and type(stored) == "number" then rate = stored end
	end

	return pcall(C_VoiceChat.SpeakText, voiceID, text, rate,
		ns.GetTTSVolume(), ns.GetTTSOverlap())
end

-- ---------------------------------------------------------------------------
-- Bell
-- ---------------------------------------------------------------------------

local function ring()
	if not ns.GetBellEnabled() then return end
	local ok, willPlay = pcall(PlaySoundFile, BELL_SOUND, "Master")
	if not ok or not willPlay then
		-- The file is missing on this client; any audible confirmation beats none.
		pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE or 878, "Master")
	end
end

local function stopBellWatch()
	if bellTicker then
		bellTicker:Cancel()
		bellTicker = nil
	end
	safeQuadrant = nil
	bellRung = false
end

-- Watch for the player arriving in the wave's safe quadrant. Edge-triggered per
-- wave: shuffling in and out afterwards doesn't ring again, but the next wave
-- re-arms it.
local function startBellWatch()
	if bellTicker then return end
	bellTicker = C_Timer.NewTicker(BELL_POLL, function()
		if not safeQuadrant or bellRung then return end
		if ns.Position.Quadrant() == safeQuadrant then
			bellRung = true
			ring()
		end
	end)
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
function Announce.IsPopupShown() return popup ~= nil and popup:IsShown() end
function Announce.PopupText() return popup and popup.main:GetText() or "" end
function Announce.PopupSubtitle() return popup and popup.subtitle:GetText() or "" end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function Announce.OnStep(index, current, nextUp)
	safeQuadrant = current
	bellRung = false
	startBellWatch()
	Announce.Say(ns.QuadrantLabel(current))
	showCall(current, nextUp)
end

function Announce.OnEnd()
	stopBellWatch()
	hideCall()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
	buildPopup()
end)

ns.Detector.OnReplayStep(Announce.OnStep)
ns.Detector.OnReplayEnd(Announce.OnEnd)
