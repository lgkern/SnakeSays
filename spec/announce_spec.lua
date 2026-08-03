-- Phase 4: what the player hears and reads during the silent replay --
-- the voice call, the bell that confirms they made it, and the on-screen popup.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

-- Default assignment: N = Circle (orange), E = Diamond (purple),
-- S = Square (blue), W = Cross (red).
local RUN = { "W", "N", "S" }          -- Red, Orange, Blue

describe("voice calls", function()
	it("speaks the safe colour at each step of the replay", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns); enc.echo(ns)
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("says nothing while the run is still being recorded", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		assert.equals(0, #wow.spoken)
	end)

	it("can announce marker names instead of colours", function()
		local ns = enc.setup("auto", { announceStyle = "marker" })
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns); enc.echo(ns)
		assert.same({ "Cross", "Circle", "Square" }, wow.spokenText())
	end)

	it("follows a reassigned marker", function()
		local ns = enc.setup("auto")
		ns.SetAssignment("W", 4)         -- West becomes Triangle (green)
		enc.recordRun(ns, { "W" , "N", "S" })
		enc.echo(ns)
		assert.equals("Green", wow.spokenText()[1])
	end)

	it("stays silent when text to speech is switched off", function()
		local ns = enc.setup("auto", { ttsEnabled = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns)
		assert.equals(0, #wow.spoken)
	end)

	-- Rate third, then volume, then overlap. Newer clients grew a `destination`
	-- argument in the rate's slot; this one did not, and speaking with that order
	-- is accepted without complaint and then says nothing -- silently, with the
	-- popup still working, which is exactly how it goes unnoticed.
	it("passes rate, volume and overlap the way the client expects", function()
		local ns = enc.setup("auto", { ttsVolume = 80, ttsOverlap = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		local call = wow.spoken[1]
		assert.equals(0, call.rate)
		assert.equals(80, call.volume)
		assert.equals(false, call.overlap)
	end)

	it("plays straight over the top when overlap is on", function()
		local ns = enc.setup("auto", { ttsOverlap = true })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals(true, wow.spoken[1].overlap)
	end)

	it("falls back to the default voice when the stored one is gone", function()
		local ns = enc.setup("auto", { ttsVoice = 77 })   -- not in GetTtsVoices()
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals(0, wow.spoken[1].voiceID)
	end)

	it("keeps a stored voice that still exists", function()
		local ns = enc.setup("auto", { ttsVoice = 1 })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals(1, wow.spoken[1].voiceID)
	end)

	-- Voice ids follow whatever language packs are installed, so there is no id
	-- that is safe to assume -- including zero. Handing the client one it does
	-- not know is answered with silence, which looks exactly like the feature
	-- being switched off.
	it("falls back to a voice the client really has, not to id zero", function()
		local ns = enc.setup("auto")          -- stored voice defaults to 0
		_G.C_VoiceChat.GetTtsVoices = function()
			return { { voiceID = 7, name = "Seven" }, { voiceID = 8, name = "Eight" } }
		end

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(1, #wow.spoken)
		assert.equals(7, wow.spoken[1].voiceID)
	end)

	it("says nothing at all rather than guessing when no voice is installed", function()
		local ns = enc.setup("auto")
		_G.C_VoiceChat.GetTtsVoices = function() return {} end

		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.equals(0, #wow.spoken)
	end)
end)


describe("next-up popup", function()
	it("shows the current colour large and the next one as a subtitle", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)

		assert.is_true(ns.Announce.IsPopupShown())
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("Orange", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("next", 1, true) ~= nil)
	end)

	it("includes the marker icon alongside the word", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("|T", 1, true) ~= nil)
	end)

	it("drops the subtitle on the final wave, where there is no next", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns); enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("Blue", 1, true) ~= nil)
		assert.equals("", ns.Announce.PopupSubtitle())
	end)

	it("hides the subtitle when that setting is off, keeping the main line", function()
		local ns = enc.setup("auto", { popupSubtitle = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
		assert.equals("", ns.Announce.PopupSubtitle())
	end)

	it("uses marker names when that style is selected", function()
		local ns = enc.setup("auto", { announceStyle = "marker" })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_true(ns.Announce.PopupText():find("Cross", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("Circle", 1, true) ~= nil)
	end)

	it("stays hidden when the popup is switched off", function()
		local ns = enc.setup("auto", { popupEnabled = false })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.is_false(ns.Announce.IsPopupShown())
	end)

	-- NOT YET WRITTEN: the timer that cleared the board a while after the last call
	-- went with the engine, so nothing ends a replay on its own any more. The
	-- popup still hides the moment something does.
	it("hides when the replay ends mid-run", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		ns.Detector.EndReplay()
		assert.is_false(ns.Announce.IsPopupShown())
	end)

	it("remembers a position the player dragged it to", function()
		local ns = enc.setup("auto")
		ns.Announce.SavePopupPosition("TOP", "TOP", 12, -300)
		assert.same({ point = "TOP", relPoint = "TOP", x = 12, y = -300 },
			_G.SnakeSaysDB.popupPosition)
	end)
end)

-- PlaySoundFile with a path into the game's own archive is refused for addons
-- now, and the numeric id the old fallback used was refused too -- so the bell
-- was silent through both of its paths at once.
describe("the bell", function()
	it("rings through a sound kit rather than a game file path", function()
		local ns = enc.ready("auto")          -- measured, so a quadrant can be read
		enc.recordRun(ns, RUN)
		enc.echo(ns)

		enc.standAt(ns, "W")                  -- the first call is West
		wow.advance(0.3)

		assert.equals(1, #wow.sounds)
		assert.is_number(wow.sounds[1].kit)
		assert.is_nil(wow.sounds[1].file)
	end)

	it("stays quiet when the cue is None", function()
		local ns = enc.ready("auto", { arrivalCue = "none" })
		enc.recordRun(ns, RUN)
		enc.echo(ns)

		-- The call itself is still spoken; it is only the arrival that is silent.
		local spokenSoFar = #wow.spoken
		enc.standAt(ns, "W")
		wow.advance(0.3)

		assert.equals(0, #wow.sounds)
		assert.equals(spokenSoFar, #wow.spoken)
	end)

	it("says Safe instead of ringing when that is the cue", function()
		local ns = enc.ready("auto", { arrivalCue = "say" })
		enc.recordRun(ns, RUN)
		enc.echo(ns)

		local spokenSoFar = #wow.spoken
		enc.standAt(ns, "W")
		wow.advance(0.3)

		assert.equals(0, #wow.sounds)
		assert.equals(spokenSoFar + 1, #wow.spoken)
		assert.equals("Safe", wow.spoken[#wow.spoken].text)
	end)

	-- "Safe" lands while the next call is already coming, and the two mean
	-- opposite things. In the same voice they are one more word to disentangle.
	it("says it in a different voice from the one calling the quadrants", function()
		local ns = enc.ready("auto", { arrivalCue = "say", ttsVoice = 0 })
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals(0, wow.spoken[#wow.spoken].voiceID)   -- the call

		enc.standAt(ns, "W")
		wow.advance(0.3)

		local arrival = wow.spoken[#wow.spoken]
		assert.equals("Safe", arrival.text)
		assert.equals(1, arrival.voiceID)
	end)

	it("falls back to the calling voice when only one is installed", function()
		local ns = enc.ready("auto", { arrivalCue = "say", ttsVoice = 0 })
		_G.C_VoiceChat.GetTtsVoices = function()
			return { { voiceID = 0, name = "Only" } }
		end

		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.standAt(ns, "W")
		wow.advance(0.3)

		local arrival = wow.spoken[#wow.spoken]
		assert.equals("Safe", arrival.text)
		assert.equals(0, arrival.voiceID)
	end)

	it("only confirms once per wave, however much they shuffle about", function()
		local ns = enc.ready("auto", { arrivalCue = "bell" })
		enc.recordRun(ns, RUN)
		enc.echo(ns)

		enc.standAt(ns, "W")
		wow.advance(0.3)
		enc.standAt(ns, "S")
		wow.advance(0.3)
		enc.standAt(ns, "W")
		wow.advance(0.3)

		assert.equals(1, #wow.sounds)
	end)

	-- An install that had the bell switched off keeps that answer rather than
	-- being handed a cue it never asked for.
	it("carries an existing bell setting over to the new choice", function()
		local off = enc.setup("auto", { bellEnabled = false })
		assert.equals("none", off.GetArrivalCue())

		local on = enc.setup("auto", { bellEnabled = true })
		assert.equals("bell", on.GetArrivalCue())

		local fresh = enc.setup("auto")
		assert.equals("bell", fresh.GetArrivalCue())
	end)

	it("refuses a cue it does not know", function()
		local ns = enc.setup("auto")
		assert.is_false(ns.SetArrivalCue("interpretive dance"))
		assert.equals("bell", ns.GetArrivalCue())
	end)
end)

describe("announce settings", function()
	it("defaults to speaking colours, with popup, subtitle and bell on", function()
		local ns = enc.setup("auto")
		assert.is_true(ns.GetTTSEnabled())
		assert.equals("color", ns.GetAnnounceStyle())
		assert.is_true(ns.GetPopupEnabled())
		assert.is_true(ns.GetPopupSubtitle())
		assert.is_true(ns.GetBellEnabled())
	end)

	it("round-trips every toggle through SavedVariables", function()
		local ns = enc.setup("auto")
		ns.SetTTSEnabled(false)
		ns.SetAnnounceStyle("marker")
		ns.SetPopupEnabled(false)
		ns.SetPopupSubtitle(false)
		ns.SetArrivalCue("say")

		assert.is_false(_G.SnakeSaysDB.ttsEnabled)
		assert.equals("marker", _G.SnakeSaysDB.announceStyle)
		assert.is_false(_G.SnakeSaysDB.popupEnabled)
		assert.is_false(_G.SnakeSaysDB.popupSubtitle)
		assert.equals("say", _G.SnakeSaysDB.arrivalCue)
	end)

	it("ignores an announce style it does not know", function()
		local ns = enc.setup("auto")
		ns.SetAnnounceStyle("interpretive dance")
		assert.equals("color", ns.GetAnnounceStyle())
	end)
end)
