-- Phase 4: what the player hears and reads during the silent replay --
-- the voice call, the bell that confirms they made it, and the on-screen popup.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

-- Default assignment: N = Circle (orange), E = Diamond (purple),
-- S = Square (blue), W = Cross (red).
local RUN = { "W", "N", "S" }          -- Red, Orange, Blue

describe("voice calls", function()
	it("speaks the safe colour at each step of the replay", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns); enc.echo(ns)
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("says nothing while the run is still being recorded", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)
		assert.equals(0, #wow.spoken)
	end)

	it("can announce marker names instead of colours", function()
		local ns = enc.setup({ announceStyle = "marker" })
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns); enc.echo(ns)
		assert.same({ "Cross", "Circle", "Square" }, wow.spokenText())
	end)

	it("follows a reassigned marker", function()
		local ns = enc.setup()
		ns.SetAssignment("W", 4)         -- West becomes Triangle (green)
		enc.recordRun(ns, { "W" , "N", "S" })
		enc.echo(ns)
		assert.equals("Green", wow.spokenText()[1])
	end)

	it("stays silent when text to speech is switched off", function()
		local ns = enc.setup({ ttsEnabled = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns)
		assert.equals(0, #wow.spoken)
	end)

	-- Rate third, then volume, then overlap. Newer clients grew a `destination`
	-- argument in the rate's slot; this one did not, and speaking with that order
	-- is accepted without complaint and then says nothing -- silently, with the
	-- popup still working, which is exactly how it goes unnoticed.
	it("passes rate, volume and overlap the way the client expects", function()
		local ns = enc.setup({ ttsVolume = 80, ttsOverlap = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		local call = wow.spoken[1]
		assert.equals(0, call.rate)
		assert.equals(80, call.volume)
		assert.equals(false, call.overlap)
	end)

	it("plays straight over the top when overlap is on", function()
		local ns = enc.setup({ ttsOverlap = true })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals(true, wow.spoken[1].overlap)
	end)

	it("falls back to the default voice when the stored one is gone", function()
		local ns = enc.setup({ ttsVoice = 77 })   -- not in GetTtsVoices()
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals(0, wow.spoken[1].voiceID)
	end)

	it("keeps a stored voice that still exists", function()
		local ns = enc.setup({ ttsVoice = 1 })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals(1, wow.spoken[1].voiceID)
	end)

	-- Voice ids follow whatever language packs are installed, so there is no id
	-- that is safe to assume -- including zero. Handing the client one it does
	-- not know is answered with silence, which looks exactly like the feature
	-- being switched off.
	it("falls back to a voice the client really has, not to id zero", function()
		local ns = enc.setup()          -- stored voice defaults to 0
		_G.C_VoiceChat.GetTtsVoices = function()
			return { { voiceID = 7, name = "Seven" }, { voiceID = 8, name = "Eight" } }
		end

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(1, #wow.spoken)
		assert.equals(7, wow.spoken[1].voiceID)
	end)

	it("says nothing at all rather than guessing when no voice is installed", function()
		local ns = enc.setup()
		_G.C_VoiceChat.GetTtsVoices = function() return {} end

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(0, #wow.spoken)
	end)
end)


-- The client going quiet part way through a round.
--
-- GetTtsVoices belongs to the voice chat subsystem, and that subsystem
-- re-initialises while a pull is running -- somebody joins the group, a voice
-- session drops -- and lists nothing at all while it does. The voice used to go
-- with it: the wave resolved to no voice and was never spoken, the popup carried
-- on updating beside it, and nothing anywhere said why. It was reported from the
-- field as the voice cutting out at random, mid-readback.
describe("the client listing no voices mid-round", function()
	local function installVoices(list)
		_G.C_VoiceChat.GetTtsVoices = function() return list end
	end

	it("keeps calling in the voice that last worked", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)

		enc.echo(ns)                    -- spoken normally: voice 0 proves itself
		installVoices({})               -- the subsystem goes away mid-round
		enc.echo(ns); enc.echo(ns)

		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
		assert.equals(0, wow.spoken[3].voiceID)
	end)

	it("picks the list back up when the client answers again", function()
		local ns = enc.setup({ ttsVoice = 1 })
		enc.recordRun(ns, RUN)

		enc.echo(ns)
		installVoices({})
		enc.echo(ns)
		installVoices({ { voiceID = 0, name = "Default" }, { voiceID = 1, name = "Alt" } })
		enc.echo(ns)

		assert.same({ 1, 1, 1 }, {
			wow.spoken[1].voiceID, wow.spoken[2].voiceID, wow.spoken[3].voiceID,
		})
	end)

	-- The remembered id covers an empty list and nothing else. A list that comes
	-- back populated is the truth of the moment, so a voice that really has been
	-- uninstalled must still be picked over rather than remembered past its life.
	it("does not remember a voice the client has since dropped", function()
		local ns = enc.setup({ ttsVoice = 1 })
		enc.recordRun(ns, RUN)

		enc.echo(ns)                                        -- voice 1 works
		installVoices({ { voiceID = 4, name = "Karen" } })  -- 1 uninstalled
		enc.echo(ns)

		assert.equals(1, wow.spoken[1].voiceID)
		assert.equals(4, wow.spoken[2].voiceID)
	end)

	-- Only speech proves a voice speaks. An id that resolved and was then refused
	-- has proved nothing, and falling back to it later would be falling back to
	-- the thing that was already failing.
	it("never falls back to a voice that was refused rather than spoken", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)

		wow.speakError = "voice chat is not connected"
		enc.echo(ns)
		wow.speakError = nil
		installVoices({})
		enc.echo(ns)

		assert.equals(0, #wow.spoken)
	end)
end)


-- Which voice says it.
--
-- Voice ids number whatever the operating system installed, in whatever order it
-- lists them, so an id is a position and not a voice. The addon shipped storing
-- id 0 and calling that a default; on macOS position 0 lands in the novelty
-- voices, and the author of Deadly Boss Mods reported it laughing at him once
-- per wave instead of calling the colours.
describe("choosing a voice", function()
	local function installVoices(list)
		_G.C_VoiceChat.GetTtsVoices = function() return list end
	end

	it("passes over a novelty voice for one that can say a word", function()
		local ns = enc.setup()
		installVoices({
			{ voiceID = 0, name = "Hysterical" },
			{ voiceID = 1, name = "Samantha" },
		})

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(1, wow.spoken[1].voiceID)
	end)

	it("prefers a voice known to read clearly over merely the first that is not a joke",
		function()
			local ns = enc.setup()
			installVoices({
				{ voiceID = 0, name = "Bahh" },
				{ voiceID = 1, name = "Ralph" },
				{ voiceID = 2, name = "Alex" },
			})

			enc.recordRun(ns, RUN)
			enc.echo(ns)

			assert.equals(2, wow.spoken[1].voiceID)
		end)

	-- The client decorates the name differently per platform, so the joke voices
	-- have to be recognised through it -- this is exactly how they arrive.
	it("recognises a novelty voice through the decoration around its name", function()
		local ns = enc.setup()
		installVoices({
			{ voiceID = 0, name = "Hysterical (English (United States))" },
			{ voiceID = 1, name = "Microsoft David Desktop - English (United States)" },
		})

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(1, wow.spoken[1].voiceID)
	end)

	-- Matched whole, not as a substring: "Organ" is a joke voice and "Morgan" is
	-- not, and the second must not be thrown away with the first.
	it("does not mistake a real voice for a joke one it happens to contain", function()
		local ns = enc.setup()
		installVoices({ { voiceID = 4, name = "Morgan" } })

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(4, wow.spoken[1].voiceID)
	end)

	it("speaks in a novelty voice rather than not at all, when that is all there is",
		function()
			local ns = enc.setup()
			installVoices({ { voiceID = 3, name = "Zarvox" } })

			enc.recordRun(ns, RUN)
			enc.echo(ns)

			assert.equals(3, wow.spoken[1].voiceID)
		end)

	-- A choice is a choice. The list the addon avoids is for picking on the
	-- player's behalf, never for overruling them.
	it("keeps a novelty voice the player picked on purpose", function()
		local ns = enc.setup()
		installVoices({
			{ voiceID = 0, name = "Hysterical" },
			{ voiceID = 1, name = "Samantha" },
		})
		ns.SetTTSVoice(0)

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(0, wow.spoken[1].voiceID)
	end)

	it("reports the voice it settled on, which is not the one stored", function()
		local ns = enc.setup()
		installVoices({
			{ voiceID = 0, name = "Hysterical" },
			{ voiceID = 6, name = "Samantha" },
		})

		assert.is_nil(ns.GetTTSVoice())
		assert.equals(6, ns.Announce.ActiveVoice())
		assert.equals("Samantha", ns.Announce.VoiceName(6))
	end)

	it("hands the whole list to the picker", function()
		local ns = enc.setup()
		assert.equals(2, #ns.Announce.Voices())
	end)

	it("round-trips a picked voice, and going back to automatic", function()
		local ns = enc.setup()

		ns.SetTTSVoice(1)
		assert.equals(1, _G.SnakeSaysDB.ttsVoice)

		ns.SetTTSVoice(nil)
		assert.is_nil(_G.SnakeSaysDB.ttsVoice)
		assert.is_nil(ns.GetTTSVoice())
	end)

	-- Every install before the picker existed was seeded with id 0, and there was
	-- no way in the interface to have chosen it. Left alone it keeps whatever
	-- position 0 happens to be, which is the bug.
	it("clears a seeded id zero back to automatic on an old install", function()
		local ns = enc.setup({ ttsVoice = 0 })
		assert.is_nil(ns.GetTTSVoice())
	end)

	it("leaves a voice the player really did pick alone", function()
		local ns = enc.setup({ ttsVoice = 1 })
		assert.equals(1, ns.GetTTSVoice())
	end)
end)

-- Deadly Boss Mods ships eight recordings, mm1 to mm8, one per raid target, that
-- say "move to square" in the voice the rest of the pull is already called in.
-- Borrowed rather than reimplemented, and only ever as an alternative to the
-- client's text to speech.
describe("Deadly Boss Mods' voice", function()
	-- Default assignment: West is Cross, marker 7.
	local WEST_CALL = "Interface\\AddOns\\DBM-VPVEM\\mm7.ogg"

	it("plays the marker's call instead of speaking", function()
		local ns = enc.setup({ dbmVoice = true })
		wow.installDBM()

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.same({ WEST_CALL }, wow.soundFiles())
		assert.equals(0, #wow.spoken)
	end)

	it("follows a reassigned marker, since the file is the marker", function()
		local ns = enc.setup({ dbmVoice = true })
		wow.installDBM()
		ns.SetAssignment("W", 4)          -- West becomes Triangle, marker 4

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.same({ "Interface\\AddOns\\DBM-VPVEM\\mm4.ogg" }, wow.soundFiles())
	end)

	it("uses whichever voice pack DBM is set to", function()
		local ns = enc.setup({ dbmVoice = true })
		wow.installDBM({ pack = "Corsica" })

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.same({ "Interface\\AddOns\\DBM-VPCorsica\\mm7.ogg" }, wow.soundFiles())
	end)

	it("is off unless asked for, even with DBM sitting right there", function()
		local ns = enc.setup()
		wow.installDBM()

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(0, #wow.sounds)
		assert.same({ "Red" }, wow.spokenText())
	end)

	-- Ticking the box must never be a way to end up with silence. Every reason
	-- DBM cannot answer falls back to the voice that was there before.
	it("falls back to speaking when DBM is not installed at all", function()
		local ns = enc.setup({ dbmVoice = true })

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.same({ "Red" }, wow.spokenText())
	end)

	it("falls back to speaking when DBM has no voice pack chosen", function()
		local ns = enc.setup({ dbmVoice = true })
		wow.installDBM({ pack = "None" })

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(0, #wow.sounds)
		assert.same({ "Red" }, wow.spokenText())
	end)

	-- A pack named in DBM's settings that has since been uninstalled builds a
	-- path to a file that is not there. DBM lists what it really found; that list
	-- is the check.
	it("falls back to speaking when the chosen pack is no longer installed", function()
		local ns = enc.setup({ dbmVoice = true })
		wow.installDBM({ pack = "VEM", versions = {} })

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(0, #wow.sounds)
		assert.same({ "Red" }, wow.spokenText())
	end)

	-- Which voice does the calling is a preference; whether anything calls at all
	-- is the feature, and it has one switch.
	it("stays silent when the voice is switched off altogether", function()
		local ns = enc.setup({ dbmVoice = true, ttsEnabled = false })
		wow.installDBM()

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(0, #wow.sounds)
		assert.equals(0, #wow.spoken)
	end)

	it("says whether it can answer, which is what the options page reports", function()
		local ns = enc.setup({ dbmVoice = true })
		assert.is_false(ns.Announce.DBMVoiceAvailable())

		wow.installDBM()
		assert.is_true(ns.Announce.DBMVoiceAvailable())
	end)

	it("round-trips the setting through SavedVariables", function()
		local ns = enc.setup()
		assert.is_false(ns.GetDBMVoice())

		ns.SetDBMVoice(true)
		assert.is_true(_G.SnakeSaysDB.dbmVoice)
	end)

	-- The on-screen call still follows the announce style; the recording cannot.
	it("keeps naming the marker even when the style says colours", function()
		local ns = enc.setup({ dbmVoice = true, announceStyle = "color" })
		wow.installDBM()

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.same({ WEST_CALL }, wow.soundFiles())
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
	end)
end)

describe("next-up popup", function()
	it("shows the current colour large and the next one as a subtitle", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.is_true(ns.Announce.IsPopupShown())
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("Orange", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("next", 1, true) ~= nil)
	end)

	it("includes the marker icon alongside the word", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("|T", 1, true) ~= nil)
	end)

	it("drops the subtitle on the final wave, where there is no next", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns); enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("Blue", 1, true) ~= nil)
		assert.equals("", ns.Announce.PopupSubtitle())
	end)

	it("hides the subtitle when that setting is off, keeping the main line", function()
		local ns = enc.setup({ popupSubtitle = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
		assert.equals("", ns.Announce.PopupSubtitle())
	end)

	it("uses marker names when that style is selected", function()
		local ns = enc.setup({ announceStyle = "marker" })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("Cross", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("Circle", 1, true) ~= nil)
	end)

	it("stays hidden when the popup is switched off", function()
		local ns = enc.setup({ popupEnabled = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_false(ns.Announce.IsPopupShown())
	end)

	-- NOT YET WRITTEN: the timer that cleared the board a while after the last call
	-- went with the engine, so nothing ends a replay on its own any more. The
	-- popup still hides the moment something does.
	it("hides when the replay ends mid-run", function()
		local ns = enc.setup()
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		ns.Detector.EndReplay()
		assert.is_false(ns.Announce.IsPopupShown())
	end)

	it("remembers a position the player dragged it to", function()
		local ns = enc.setup()
		ns.Announce.SavePopupPosition("TOP", "TOP", 12, -300)
		assert.same({ point = "TOP", relPoint = "TOP", x = 12, y = -300 },
			_G.SnakeSaysDB.popupPosition)
	end)
end)

describe("announce settings", function()
	it("defaults to speaking colours, with the popup and its subtitle on", function()
		local ns = enc.setup()
		assert.is_true(ns.GetTTSEnabled())
		assert.equals("color", ns.GetAnnounceStyle())
		assert.is_true(ns.GetPopupEnabled())
		assert.is_true(ns.GetPopupSubtitle())
	end)

	it("round-trips every toggle through SavedVariables", function()
		local ns = enc.setup()
		ns.SetTTSEnabled(false)
		ns.SetAnnounceStyle("marker")
		ns.SetPopupEnabled(false)
		ns.SetPopupSubtitle(false)

		assert.is_false(_G.SnakeSaysDB.ttsEnabled)
		assert.equals("marker", _G.SnakeSaysDB.announceStyle)
		assert.is_false(_G.SnakeSaysDB.popupEnabled)
		assert.is_false(_G.SnakeSaysDB.popupSubtitle)
	end)

	it("ignores an announce style it does not know", function()
		local ns = enc.setup()
		ns.SetAnnounceStyle("interpretive dance")
		assert.equals("color", ns.GetAnnounceStyle())
	end)
end)
