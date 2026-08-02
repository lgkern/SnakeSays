-- Automatic detection: recognising the pull, reading the showing half off the
-- boss' aura, and calling it back off the boss' casts.
--
-- Everything here goes in through the client's events. Nothing calls the
-- recorder or the replay by hand -- a spec that does proves the function works,
-- not that the fight ever gets there.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local HARD_PATH   = { "N", "E", "S", "W", "N" }          -- 5 waves
local NORMAL_PATH = { "W", "N", "E" }                    -- 3 waves

describe("recognising the encounter", function()
	it("arms on the normal encounter id", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.NORMAL)
		assert.is_true(ns.Detector.IsArmed())
	end)

	it("arms on the hard encounter id", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		assert.is_true(ns.Detector.IsArmed())
	end)

	it("ignores an encounter that is not this boss", function()
		local ns = enc.ready("auto")
		enc.pull(ns, 1234, "Some Other Boss")
		assert.is_false(ns.Detector.IsArmed())
	end)

	it("arms on the name when the ids have been renumbered", function()
		local ns = enc.ready("auto")
		enc.pull(ns, 9999, "Azta'rec")
		assert.is_true(ns.Detector.IsArmed())
	end)

	it("still reads a round when it only had the name to go on", function()
		local ns = enc.ready("auto")
		enc.pull(ns, 9999, "Azta'rec")
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.same(HARD_PATH, ns.Seq.Get())
	end)

	it("disarms and forgets the pull when the encounter ends", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.equals(5, ns.Seq.Count())

		enc.kill(ns)
		assert.is_false(ns.Detector.IsArmed())
		assert.is_false(ns.Detector.IsRecording())
		assert.equals(0, ns.Seq.Count())
	end)

	it("does nothing with the boss' aura before the encounter starts", function()
		local ns = enc.ready("auto")
		wow.applyAura("boss1", enc.SERMON, 15.015)
		wow.advance(16)
		assert.is_false(ns.Detector.IsRecording())
		assert.equals(0, ns.Seq.Count())
	end)
end)

describe("reading a round", function()
	it("records one quarter per wave, in order", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.same(HARD_PATH, ns.Seq.Get())
	end)

	it("takes the wave count from the aura's length, not from a wave event", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.NORMAL)
		enc.showRound(ns, NORMAL_PATH, { difficulty = enc.NORMAL })
		assert.equals(3, ns.Seq.Count())
	end)

	it("fills the board as the round runs rather than all at once", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 3)

		-- Watch the board through the round rather than only at the end of it.
		local seen, held = {}, {}
		for _, quadrant in ipairs({ "N", "E", "S" }) do
			enc.standAt(ns, quadrant)
			for _ = 1, 6 do
				wow.advance(slot / 6)
				local count = ns.Seq.Count()
				if not held[count] then
					held[count] = true
					seen[#seen + 1] = count
				end
			end
		end
		wow.removeAura("boss1", enc.SERMON)

		-- It grew a wave at a time and was never seen jumping from nothing to
		-- everything at the close.
		assert.same({ 0, 1, 2 }, seen)
		assert.equals(3, ns.Seq.Count())
	end)

	it("takes where the player settled, not where they passed through", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		-- Set off from somewhere real, and cross into the answer only at the very
		-- end of each slot. An even weighting would call every one of these wrong.
		enc.standAt(ns, "S")
		enc.showRound(ns, { "N", "E", "S" }, { difficulty = enc.HARD, arriveAt = 0.7 })
		assert.same({ "N", "E", "S" }, ns.Seq.Get())
	end)

	it("will not call a slot the player spent the end of standing on the centre", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 2)
		enc.standAt(ns, "N"); wow.advance(slot)
		enc.standAt(ns, "E"); wow.advance(slot * 0.4)
		enc.standAt(ns, nil)                        -- back on top of the boss
		wow.advance(slot * 0.6)
		wow.removeAura("boss1", enc.SERMON)

		assert.equals(0, ns.Seq.Count())
	end)

	it("starts each round from an empty board", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		enc.round(ns, { "N", "E", "S", "W", "N" }, { difficulty = enc.HARD })
		enc.showRound(ns, { "S", "W", "N" }, { difficulty = enc.HARD })
		assert.same({ "S", "W", "N" }, ns.Seq.Get())
	end)

	it("grows with the boss across three rounds in one pull", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.NORMAL)

		local rounds = {
			{ "N", "E", "S" },
			{ "W", "N", "E", "S" },
			{ "E", "S", "W", "N", "E" },
		}
		local counts = {}
		for _, path in ipairs(rounds) do
			enc.round(ns, path, { difficulty = enc.NORMAL })
			counts[#counts + 1] = ns.Seq.Count()
		end

		assert.same({ 3, 4, 5 }, counts)
		assert.same(rounds[3], ns.Seq.Get())
	end)

	it("says so when two waves in a row read as the same quarter", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "N", "N", "E" }, { difficulty = enc.HARD })
		assert.is_true(wow.chatContains("never repeats"))
	end)

	it("keeps the run when that happens, rather than binning the good waves", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "N", "N", "E" }, { difficulty = enc.HARD })
		assert.same({ "N", "N", "E" }, ns.Seq.Get())
	end)
end)

describe("a round that is cut short", function()
	it("is discarded when a wipe truncates the aura", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		-- Three whole slots in, then the raid dies and the aura goes with them.
		enc.showRoundCutShort(ns, HARD_PATH, enc.SLOT[enc.HARD] * 3.4, { difficulty = enc.HARD })
		enc.wipe(ns)

		assert.equals(0, ns.Seq.Count())
		assert.is_true(wow.chatContains("cut short"))
	end)

	it("leaves nothing behind for the next pull", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRoundCutShort(ns, HARD_PATH, enc.SLOT[enc.HARD] * 2.5, { difficulty = enc.HARD })
		enc.wipe(ns)

		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "S", "W", "N" }, { difficulty = enc.HARD })
		assert.same({ "S", "W", "N" }, ns.Seq.Get())
	end)

	it("is discarded when the encounter ends before the aura does", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 5)
		enc.standAt(ns, "N"); wow.advance(slot)
		enc.standAt(ns, "E"); wow.advance(slot)

		enc.wipe(ns)                                -- ENCOUNTER_END lands first
		wow.removeAura("boss1", enc.SERMON)         -- the aura follows a tick later

		assert.equals(0, ns.Seq.Count())
		assert.is_false(ns.Detector.IsArmed())
	end)

	it("calls nothing back, because there is nothing to call", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRoundCutShort(ns, HARD_PATH, enc.SLOT[enc.HARD] * 3.4, { difficulty = enc.HARD })
		enc.callRound(ns, 5)
		assert.equals(0, #wow.spoken)
		assert.is_false(ns.Detector.IsReplaying())
	end)
end)

describe("a wave that cannot be read", function()
	it("takes the whole round with it", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 3)

		enc.standAt(ns, "N"); wow.advance(slot)
		enc.standAt(ns, "E"); wow.advance(slot * 0.6)
		wow.setPosition(nil)                       -- the client stops answering
		wow.advance(slot * 1.4)
		wow.removeAura("boss1", enc.SERMON)

		assert.equals(0, ns.Seq.Count())
	end)

	it("says which wave it lost", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 3)
		enc.standAt(ns, "N"); wow.advance(slot)
		enc.standAt(ns, "E"); wow.advance(slot)
		wow.setPosition(nil)
		wow.advance(slot)
		wow.removeAura("boss1", enc.SERMON)

		assert.is_true(wow.chatContains("Wave 3 could not be read"))
	end)

	it("is what a player standing on the centre point the whole slot gets", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 2)
		enc.standAt(ns, "N"); wow.advance(slot)
		enc.standAt(ns, nil)                       -- right on top of the boss
		wow.advance(slot)
		wow.removeAura("boss1", enc.SERMON)

		assert.equals(0, ns.Seq.Count())
		assert.is_true(wow.chatContains("Wave 2 could not be read"))
	end)
end)

describe("calling the run back", function()
	it("announces one wave per cast, in the recorded order", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.round(ns, { "W", "N", "S" }, { difficulty = enc.HARD })
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("announces at the start of the cast, not when the wave lands", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		wow.startCast("boss1", enc.ECHO, 3.31)
		assert.equals(1, #wow.spoken)              -- spoken before a single tick
		assert.equals(1, ns.Detector.EchoIndex())
	end)

	it("gives the player the live cast time to move, not an assumed one", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N" }, { difficulty = enc.HARD })

		wow.startCast("boss1", enc.ECHO, 3.64)
		assert.is_near(wow.now() + 3.64, ns.Detector.CastEndsAt(), 0.001)

		wow.advance(3.64 + 0.4)
		wow.startCast("boss1", enc.ECHO, 3.31)     -- hard switches mid-round
		assert.is_near(wow.now() + 3.31, ns.Detector.CastEndsAt(), 0.001)
	end)

	it("ignores casts from the second boss", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		enc.callRound(ns, 3, { unit = "boss2" })
		assert.equals(0, #wow.spoken)
		assert.equals(0, ns.Detector.EchoIndex())
	end)

	it("counts one cast once however many unit tokens it arrives on", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		enc.callRound(ns, 3, { echoOn = { "nameplate1" } })
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("stops at the end of the run and ignores extra casts", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		enc.callRound(ns, 6)
		assert.equals(3, #wow.spoken)
	end)

	it("says which quarter is next while there is one", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		wow.startCast("boss1", enc.ECHO, 3.31)
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("Orange", 1, true) ~= nil)
	end)

	-- The bell has been waiting on a quadrant reading to exist at all.
	it("rings once the player actually reaches the called quarter", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N" }, { difficulty = enc.HARD })

		enc.standAt(ns, "S")                        -- nowhere near the call
		wow.startCast("boss1", enc.ECHO, 3.31)
		wow.advance(1)
		assert.equals(0, #wow.sounds)

		enc.standAt(ns, "W")
		wow.advance(0.3)
		assert.equals(1, #wow.sounds)

		wow.advance(1)                              -- and does not ring again
		assert.equals(1, #wow.sounds)
	end)

	it("closes the replay once the last wave has landed", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N" }, { difficulty = enc.HARD })

		wow.startCast("boss1", enc.ECHO, 3.31)
		wow.advance(3.31 + 0.4)
		wow.startCast("boss1", enc.ECHO, 3.31)
		assert.is_true(ns.Detector.IsReplaying())   -- still up while the wave flies

		wow.advance(3.4)
		assert.is_false(ns.Detector.IsReplaying())
		assert.is_false(ns.Announce.IsPopupShown())
	end)
end)

describe("learning the slot length", function()
	it("corrects itself when more waves are called than the length implied", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		-- A round whose real slot is 2.6s: 7 waves in 18.2s. The seeded 3.003
		-- reads that as 6 waves, and the boss then casts 7 times.
		enc.showRound(ns, { "N", "E", "S", "W", "N", "E" }, { length = 18.2 })
		assert.equals(6, ns.Seq.Count())

		enc.callRound(ns, 7)
		enc.kill(ns)

		assert.is_near(18.2 / 7, ns.SlotLength("hard"), 0.001)
		assert.is_true(wow.chatContains("wave timing corrected"))
	end)

	it("corrects itself when fewer waves are called, once the round is provably over", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		-- 15.015s reads as exactly 5 slots on the seed, but the boss calls four.
		enc.showRound(ns, { "N", "E", "S", "W", "N" }, { length = 15.015 })
		enc.callRound(ns, 4)
		assert.is_near(3.003, ns.SlotLength("hard"), 0.0001)   -- not yet: a fifth call may be coming

		-- The next round's aura going up is what proves it was not.
		enc.showRound(ns, { "S", "W", "N" }, { length = 15.015 / 4 * 3 })
		assert.is_near(15.015 / 4, ns.SlotLength("hard"), 0.001)
		assert.equals(3, ns.Seq.Count())                       -- and is read on the new slot
	end)

	-- Four calls where five were expected has two causes the addon cannot tell
	-- apart: the estimate was too high, or the pull ended before the fifth call.
	-- Dying in the calling half is the likeliest way to wipe on this boss, so
	-- reading it as a measurement would poison the next pull as a matter of
	-- routine.
	it("learns nothing from a pull that died part way through the calling half", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })   -- 15.015s, 5 waves, right
		enc.callRound(ns, 2)                                      -- the group dies after two
		enc.wipe(ns)

		assert.is_near(3.003, ns.SlotLength("hard"), 0.0001)
		assert.is_nil(_G.SnakeSaysDB.slotLength)
		assert.is_false(wow.chatContains("wave timing corrected"))
	end)

	it("reads the next pull the same way it would have before the wipe", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		enc.callRound(ns, 2)
		enc.wipe(ns)

		enc.pull(ns, enc.HARD)
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.same(HARD_PATH, ns.Seq.Get())
	end)

	-- The other direction survives a wipe, because it is proof rather than an
	-- inference: the boss cast once per wave, so a seventh call happened.
	it("still learns from more calls than expected on a pull that died", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		enc.showRound(ns, { "N", "E", "S", "W", "N", "E" }, { length = 18.2 })
		enc.callRound(ns, 7)
		enc.wipe(ns)

		assert.is_near(18.2 / 7, ns.SlotLength("hard"), 0.001)
	end)

	it("leaves the slot alone when the cast count agrees", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.round(ns, HARD_PATH, { difficulty = enc.HARD })
		enc.kill(ns)

		assert.is_near(3.003, ns.SlotLength("hard"), 0.0001)
		assert.is_false(wow.chatContains("wave timing corrected"))
	end)

	it("uses the correction on the very next round", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		enc.showRound(ns, { "N", "E", "S", "W", "N", "E" }, { length = 18.2 })
		enc.callRound(ns, 7)

		-- Same true slot of 2.6s, one more wave. Read on the seed this round is
		-- seven waves; read on what the last round taught it, it is eight.
		enc.showRound(ns, { "N", "E", "S", "W", "N", "E", "S", "W" }, { length = 20.8 })
		assert.equals(8, ns.Seq.Count())
	end)

	it("keeps the correction between sessions", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "N", "E", "S", "W", "N", "E" }, { length = 18.2 })
		enc.callRound(ns, 7)
		enc.kill(ns)

		assert.is_near(18.2 / 7, _G.SnakeSaysDB.slotLength.hard, 0.001)
	end)

	it("keeps normal and hard apart", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.NORMAL)
		enc.showRound(ns, { "N", "E", "S", "W" }, { length = 14.012 })
		enc.callRound(ns, 5)
		enc.kill(ns, enc.NORMAL)

		assert.is_near(14.012 / 5, ns.SlotLength("normal"), 0.001)
		assert.is_near(3.003, ns.SlotLength("hard"), 0.0001)
	end)
end)

describe("every mode", function()
	local RUN = { "W", "N", "S" }

	it("records by itself in automatic", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, RUN, { difficulty = enc.HARD })
		assert.same(RUN, ns.Seq.Get())

		enc.callRound(ns, 3)
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("records nothing by itself in semi-automatic", function()
		local ns = enc.ready("semi")
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, RUN, { difficulty = enc.HARD })
		assert.equals(0, ns.Seq.Count())
	end)

	it("reads the quarter off the capture key in semi-automatic", function()
		local ns = enc.ready("semi")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 3)
		for _, quadrant in ipairs(RUN) do
			enc.standAt(ns, quadrant)
			wow.advance(slot * 0.9)
			_G.SnakeSays_Capture()
			wow.advance(slot * 0.1)
		end
		wow.removeAura("boss1", enc.SERMON)

		assert.same(RUN, ns.Seq.Get())

		enc.callRound(ns, 3)
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("calls back a run the player pressed in by hand in manual", function()
		local ns = enc.ready("manual")
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 3)
		for _, quadrant in ipairs(RUN) do
			_G.SnakeSays_Press(quadrant)
			wow.advance(slot)
		end
		wow.removeAura("boss1", enc.SERMON)

		assert.same(RUN, ns.Seq.Get())

		enc.callRound(ns, 3)
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("refuses the capture key in automatic, where it would corrupt the run", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		enc.standAt(ns, "E")
		assert.is_false(ns.Detector.Capture())
		assert.equals(0, ns.Seq.Count())
	end)

	it("refuses to capture a quarter it cannot read", function()
		local ns = enc.ready("semi")
		enc.pull(ns, enc.HARD)
		enc.standAt(ns, nil)                        -- on the centre point
		assert.is_false(ns.Detector.Capture())
		assert.is_true(wow.chatContains("too close to the centre"))
	end)
end)

describe("giving up honestly", function()
	it("drops to manual when the client stops handing out position", function()
		local ns = enc.ready("auto")
		wow.setPosition(nil)
		wow.fire("ZONE_CHANGED_NEW_AREA")

		assert.equals("manual", ns.GetMode())
		assert.is_false(ns.GetBlockManualInput())
		assert.is_true(wow.chatContains("no longer read your position"))
	end)

	it("says it once and only once", function()
		local ns = enc.ready("auto")
		wow.setPosition(nil)
		wow.fire("ZONE_CHANGED_NEW_AREA")
		wow.fire("ZONE_CHANGED_NEW_AREA")
		enc.pull(ns, enc.HARD)
		wow.fire("PLAYER_ENTERING_WORLD")

		local said = 0
		for _, line in ipairs(wow.chat) do
			if line:find("no longer read your position", 1, true) then said = said + 1 end
		end
		assert.equals(1, said)
	end)

	it("stays put out in the world, where position is nobody's business", function()
		local ns = enc.ready("auto")
		wow.instanceMapID = 0
		wow.zoneText = "Valdrakken"
		wow.setPosition(nil)
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.equals("auto", ns.GetMode())
	end)

	it("asks for a measurement rather than guessing at a centre", function()
		local ns = enc.setup("auto")           -- booted, never measured
		enc.pull(ns, enc.HARD)
		assert.is_true(wow.chatContains("/ss measure"))

		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.equals(0, ns.Seq.Count())
	end)
end)

describe("position", function()
	it("has no answer at all until the room has been measured", function()
		local ns = enc.setup("auto")
		enc.standAt(ns, "N")
		assert.is_nil(ns.Position.Quadrant())
		assert.is_nil(ns.Position.Distance())
		assert.is_nil(ns.Position.Offset())
	end)

	it("names each quarter once there is a centre", function()
		local ns = enc.ready("auto")
		for _, quadrant in ipairs(ns.QUADRANTS) do
			enc.standAt(ns, quadrant)
			assert.equals(quadrant, ns.Position.Quadrant())
		end
	end)

	it("puts the boundaries on the diagonals", function()
		local ns = enc.ready("auto")
		local center = ns.GetRoomCenter()

		-- A yard either side of the north-west diagonal, ten yards out.
		wow.setPosition(center.a + 10, center.b + 9, 0, ns.ROOM.instanceMapID)
		assert.equals("N", ns.Position.Quadrant())
		wow.setPosition(center.a + 9, center.b + 10, 0, ns.ROOM.instanceMapID)
		assert.equals("W", ns.Position.Quadrant())
	end)

	it("works just as well at melee range as out by the wall", function()
		local ns = enc.ready("auto")
		local center = ns.GetRoomCenter()
		for _, radius in ipairs({ 1.5, 5, 11, 38 }) do
			wow.setPosition(center.a - radius, center.b, 0, ns.ROOM.instanceMapID)
			assert.equals("S", ns.Position.Quadrant())
		end
	end)

	it("has no bearing for a player standing on the centre point", function()
		local ns = enc.ready("auto")
		local center = ns.GetRoomCenter()
		wow.setPosition(center.a + 0.4, center.b + 0.4, 0, ns.ROOM.instanceMapID)
		assert.is_nil(ns.Position.Quadrant())
		assert.is_near(0.566, ns.Position.Distance(), 0.01)   -- distance still known
	end)

	it("measures the distance from the centre", function()
		local ns = enc.ready("auto")
		enc.standAt(ns, "E")
		assert.is_near(8, ns.Position.Distance(), 0.001)
	end)

	it("says it does not know when the client withholds position", function()
		local ns = enc.ready("auto")
		wow.setPosition(nil)
		assert.is_nil(ns.Position.Quadrant())
		assert.is_nil(ns.Position.Distance())
		assert.is_false(ns.Position.IsAvailable())
	end)

	it("says it does not know when the client hands back a secret", function()
		local ns = enc.ready("auto")
		wow.setPosition(200, 20, 0, ns.ROOM.instanceMapID, true)
		assert.has_no.errors(function()
			assert.is_nil(ns.Position.Quadrant())
			assert.is_nil(ns.Position.Distance())
			assert.is_nil(ns.Position.Offset())
		end)
		assert.is_false(ns.Position.IsAvailable())
	end)

	it("reads facing, and declines a secret one", function()
		local ns = enc.ready("auto")
		wow.setFacing(1.25)
		assert.is_near(1.25, ns.Position.Facing(), 0.0001)

		wow.setFacing(1.25, true)
		assert.has_no.errors(function() assert.is_nil(ns.Position.Facing()) end)
	end)

	it("never lets a secret escape into a combat event handler", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		wow.setPosition(200, 20, 0, ns.ROOM.instanceMapID, true)
		wow.setFacing(0.5, true)

		-- A whole round with the client handing back landmines the entire way.
		assert.has_no.errors(function()
			wow.applyAura("boss1", enc.SERMON, enc.SLOT[enc.HARD] * 5)
			wow.advance(enc.SLOT[enc.HARD] * 5)
			wow.removeAura("boss1", enc.SERMON)
			enc.callRound(ns, 5)
		end)
		assert.equals(0, ns.Seq.Count())
	end)
end)

describe("the delve check", function()
	it("knows the delve by its instance id", function()
		local ns = enc.setup("auto")
		wow.zoneText = "Somewhere Else"
		assert.is_true(ns.InDelve())
	end)

	it("knows it by name when the instance id has moved", function()
		local ns = enc.setup("auto")
		wow.instanceMapID = 4321
		wow.zoneText = "Venomfall Deeps"
		assert.is_true(ns.InDelve())
	end)

	it("says no everywhere else", function()
		local ns = enc.setup("auto")
		wow.instanceMapID = 0
		wow.zoneText = "Valdrakken"
		assert.is_false(ns.InDelve())
	end)
end)
