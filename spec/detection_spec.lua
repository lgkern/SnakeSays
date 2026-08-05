-- Automatic detection: recognising the pull, reading the showing half off the
-- boss' aura, and calling it back off the boss' casts.
--
-- Everything here goes in through the client's events. Nothing calls the
-- recorder or the replay by hand -- a spec that does proves the function works,
-- not that the fight ever gets there.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local HARD_PATH = { "N", "E", "S", "W", "N" }            -- 5 waves

describe("recognising the encounter", function()
	it("arms on the normal encounter id", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		assert.is_true(ns.Detector.IsArmed())
	end)

	it("arms on the hard encounter id", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		assert.is_true(ns.Detector.IsArmed())
	end)

	it("ignores an encounter that is not this boss", function()
		local ns = enc.ready()
		enc.pull(ns, 1234, "Some Other Boss")
		assert.is_false(ns.Detector.IsArmed())
	end)

	it("arms on the name when the ids have been renumbered", function()
		local ns = enc.ready()
		enc.pull(ns, 9999, "Azta'rec")
		assert.is_true(ns.Detector.IsArmed())
	end)

	it("still reads a round when it only had the name to go on", function()
		local ns = enc.ready()
		enc.pull(ns, 9999, "Azta'rec")
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.same(HARD_PATH, ns.Seq.Get())
	end)

	it("disarms and forgets the pull when the encounter ends", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.equals(5, ns.Seq.Count())

		enc.kill(ns)
		assert.is_false(ns.Detector.IsArmed())
		assert.is_false(ns.Detector.IsShowingRound())
		assert.equals(0, ns.Seq.Count())
	end)

	-- A practice run leaves its made-up run on the board on purpose, so you can
	-- look at what you did. What must never happen is the next pull adopting it:
	-- the boss opens with ordinary abilities, and with a run already sitting
	-- there they were being called back as though the boss had shown them.
	it("starts a pull with an empty board, whatever was left on it", function()
		local ns = enc.ready()
		ns.Sim.StartDemo(5, { "N", "E", "S", "W", "N" })
		wow.advance(60)                             -- the run finishes on its own
		assert.is_false(ns.Sim.IsRunning())
		assert.equals(5, ns.Seq.Count())            -- left up to be looked at

		enc.pull(ns, enc.NORMAL)
		assert.equals(0, ns.Seq.Count())
	end)

	it("ignores the boss' opening casts, before any round has been shown", function()
		local ns = enc.ready()
		ns.Sim.StartDemo(3, { "N", "E", "S" })
		wow.advance(60)
		ns.Sim.Stop(true)

		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		-- Noxious Bile and Void Toxin, before the first Sermon. Nothing about
		-- them can be read, and there is no round for them to be calling.
		local spokenSoFar = #wow.spoken
		wow.startCast("boss1", 0, 3.30, { secret = true, nameless = true })
		wow.advance(4)
		wow.startCast("boss1", 0, 1.35, { secret = true, nameless = true })
		wow.advance(2)

		assert.equals(spokenSoFar, #wow.spoken)
		assert.is_false(ns.Detector.IsReplaying())
	end)

	it("does nothing with the boss' aura before the encounter starts", function()
		local ns = enc.ready()
		wow.applyAura("boss1", enc.SERMON, 15.015)
		wow.advance(16)
		assert.is_false(ns.Detector.IsShowingRound())
		assert.equals(0, ns.Seq.Count())
	end)
end)

-- Everything in here is a way the round's aura can reach the addon that the
-- happy path does not cover. Each one of them is silent when it goes wrong: the
-- fight runs, nothing is recorded, and there is nothing on screen to say why.
-- Retail refuses C_UnitAuras to a tainted caller in this content -- not "no
-- auras", but an error out of the call itself. The boss channels the Sermon for
-- exactly as long as it carries it, so the channel says the same two things the
-- aura would and says them through a door that is still open.
describe("the round as a channel", function()
	local RUN = { "N", "E", "S" }

	it("reads the round off the channel when auras are refused outright", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		assert.has_no.errors(function()
			enc.showRound(ns, RUN, { difficulty = enc.HARD })
		end)
		assert.same(RUN, ns.Seq.Get())
		assert.is_false(wow.chatContains("internal error"))
	end)

	it("calls it back with auras still refused", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		enc.round(ns, { "W", "N", "S" }, { difficulty = enc.HARD })
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("takes the round's length from the channel's own start and end", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		-- Four normal slots. Nothing tells the addon that but the channel.
		enc.showRound(ns, { "N", "E", "S", "W" }, { difficulty = enc.NORMAL })
		assert.equals(4, ns.Seq.Count())
	end)

	it("names the channel even when its spell id is secret", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		enc.showRound(ns, RUN, { difficulty = enc.HARD, secret = true })
		assert.same(RUN, ns.Seq.Get())
	end)

	it("takes an unnamed channel on the id the author's log recorded", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		enc.showRound(ns, RUN, { difficulty = enc.HARD, nameless = true })
		assert.same(RUN, ns.Seq.Get())
	end)

	it("leaves a channel alone that is neither named nor identified", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		wow.startChannel("boss1", 999, 9.009, { nameless = true, secret = true })
		wow.advance(9.009)
		wow.stopChannel("boss1")

		assert.is_false(ns.Detector.IsShowingRound())
		assert.equals(0, ns.Seq.Count())
	end)

	it("ends the round the moment the channel stops, not a poll later", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		local slot = enc.SLOT[enc.HARD]
		wow.startChannel("boss1", enc.SERMON_SPELL, slot * 3)
		for _, quadrant in ipairs(RUN) do
			ns.Seq.Press(quadrant)
			wow.advance(slot)
		end
		wow.stopChannel("boss1")

		assert.is_false(ns.Detector.IsShowingRound())
		assert.same(RUN, ns.Seq.Get())
	end)

	-- `/ss probe` is what is left to run in the field when nothing happens, and
	-- it has to survive the aura API being the thing that is refusing.
	it("reports the refusal rather than throwing on it", function()
		enc.ready()
		wow.aurasBlocked = true
		assert.has_no.errors(function() wow.slash("SNAKESAYS", "probe") end)
		assert.is_true(wow.chatContains("what this client will tell SnakeSays"))
	end)
end)

-- Replayed beat for beat from a logged normal pull, with that log's own
-- timings. The boss casts plenty either side of the calls, names nothing this
-- client will read, and hands over a secret spell id for every one of them --
-- so the only things separating the three calls from the four ordinary casts
-- are where they came from and how many the round said there would be.
describe("a logged pull, as the client actually delivered it", function()
	local function at(seconds, now)
		wow.advance(math.max(0, seconds - now))
		return seconds
	end

	it("records three waves and calls exactly those three back", function()
		local ns = enc.ready()
		ns.SetDebug(true)
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		local now = 0
		local function blindCast(t, duration)
			now = at(t, now)
			wow.startCast("boss1", 0, duration, { secret = true, nameless = true })
		end

		-- 8.26 Noxious Bile, 13.11 Void Toxin: ordinary abilities, before the round.
		blindCast(8.26, 3.30)
		blindCast(13.11, 1.35)

		-- 14.62 the Sermon channel goes up, and runs to 25.13. That is 10.51s,
		-- which is three of normal's 3.503s slots and nothing else.
		now = at(14.62, now)
		wow.startChannel("boss1", 1288103, 10.51, { secret = true, nameless = true })

		for _, quadrant in ipairs({ "N", "E", "S" }) do
			ns.Seq.Press(quadrant)
			now = at(now + 10.51 / 3, now)
		end

		now = at(25.13, now)
		wow.stopChannel("boss1")
		assert.same({ "N", "E", "S" }, ns.Seq.Get())

		-- 25.13, 28.68, 32.24: the three calls, back to back with the handover.
		blindCast(25.13, 3.34)
		blindCast(28.68, 3.31)
		blindCast(32.24, 3.31)
		assert.same({ "Orange", "Purple", "Blue" }, wow.spokenText())
		assert.equals(3, ns.Detector.EchoIndex())

		-- 36.13 Void Toxin, 38.56 Soul Extinction: ordinary again, and the round
		-- already said there were only three calls.
		blindCast(36.13, 1.65)
		blindCast(38.56, 2.76)

		assert.equals(3, #wow.spoken)
	end)

	-- A logged pull lost its second and third memory games to a counter that was
	-- reset when the encounter started but not when each round did: the first
	-- round spent the per-round budget for taking unidentifiable casts, and the
	-- second round's calls arrived to find it already gone.
	it("gives every round of a pull its own budget of unreadable calls", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		local rounds = {
			{ "N", "E", "S" },
			{ "N", "W", "N", "W" },
			{ "E", "S", "W", "N", "E" },
		}

		for index, path in ipairs(rounds) do
			local length = #path * enc.SLOT[enc.NORMAL]
			wow.startChannel("boss1", 1288103, length, { secret = true, nameless = true })
			for _, quadrant in ipairs(path) do
				ns.Seq.Press(quadrant)
				wow.advance(length / #path)
			end
			wow.stopChannel("boss1")
			assert.same(path, ns.Seq.Get())

			local spokenBefore = #wow.spoken
			for _ = 1, #path do
				wow.startCast("boss1", 0, 3.34, { secret = true, nameless = true })
				wow.advance(3.55)
			end

			assert.equals(#path, #wow.spoken - spokenBefore,
				("round %d called %d of %d"):format(index, #wow.spoken - spokenBefore, #path))
			wow.advance(2)
		end

		-- And with every round's calls accounted for, nothing ever looked like a
		-- disagreement worth "correcting" the slot length over.
		assert.is_false(wow.chatContains("wave timing corrected"))
		assert.is_false(wow.chatContains("cut short"))
	end)

	-- With the channel's own times unreadable, the round's length can only be
	-- measured end to end -- so the wave count is not known until it closes. What
	-- must not happen is the round being written off, which would take the
	-- player's presses down with it.
	it("still reads the round when the channel will not say how long it is", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		local slot = enc.SLOT[enc.NORMAL]
		wow.startChannel("boss1", 1288103, slot * 3, { secret = true, nameless = true, timeless = true })

		for _, quadrant in ipairs({ "N", "E", "S" }) do
			wow.advance(slot * 0.5)
			ns.Seq.Press(quadrant)
			wow.advance(slot * 0.5)
		end
		wow.stopChannel("boss1")

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
		assert.is_false(wow.chatContains("cut short"))

		-- And the calling half then runs off it.
		enc.callRound(ns, 3, { difficulty = enc.NORMAL })
		assert.same({ "Orange", "Purple", "Blue" }, wow.spokenText())
	end)

	it("re-reads the round when it turns out shorter than the pull's shape implied", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		-- Round one of a normal pull is three waves, so that is what gets filled
		-- in live. This one runs for two.
		local slot = enc.SLOT[enc.NORMAL]
		wow.startChannel("boss1", 1288103, slot * 2, { secret = true, nameless = true, timeless = true })
		ns.Seq.Press("N"); wow.advance(slot)
		ns.Seq.Press("E"); wow.advance(slot)
		wow.stopChannel("boss1")

		assert.same({ "N", "E" }, ns.Seq.Get())
	end)

	-- Hard puts a second boss in the room, and it is called "Echo of Azta'rec" --
	-- so DBM renders its ordinary abilities as "Echo of Azta'rec's Noxious Bile"
	-- and the like, interleaved with the real calls. With no readable spell id,
	-- no readable name and no readable GUID, "it came from a boss frame" lets
	-- every one of them through: a logged hard round spent two of its five calls
	-- on the wrong boss and ran through the whole run in half the time.
	it("ignores the second boss on hard when nothing about a cast can be read", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		local path = { "E", "W", "E", "N", "E" }
		wow.startChannel("boss1", enc.SERMON_SPELL, 15.015, { secret = true, nameless = true })
		for _, quadrant in ipairs(path) do
			ns.Seq.Press(quadrant)
			wow.advance(15.015 / #path)
		end
		wow.stopChannel("boss1")
		assert.same(path, ns.Seq.Get())

		-- One real call, then the other boss twice over, then the rest. Only the
		-- unit that carried the round is calling anything back.
		local function blind(unit)
			wow.startCast(unit, 0, 3.30, { secret = true, nameless = true })
			wow.advance(3.55)
		end

		blind("boss1")
		assert.equals(1, ns.Detector.EchoIndex())

		blind("boss2")
		blind("boss2")
		assert.equals(1, ns.Detector.EchoIndex())

		blind("boss1")
		blind("boss1")
		assert.equals(3, ns.Detector.EchoIndex())

		blind("boss1")
		blind("boss1")
		assert.same({ "Purple", "Red", "Purple", "Orange", "Purple" }, wow.spokenText())
	end)

	it("identifies the channel by the one id the log recorded", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		-- Named nothing, but the id is readable and is normal's.
		wow.startChannel("boss1", 1288103, 10.509, { nameless = true })
		for _, quadrant in ipairs({ "N", "E", "S" }) do
			ns.Seq.Press(quadrant)
			wow.advance(10.509 / 3)
		end
		wow.stopChannel("boss1")

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
	end)

	-- Normal changes the id every round, so an unrecognised one has to be able
	-- to get through on the shape of the round alone.
	it("takes a channel whose id it has never seen, on its length", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		wow.startChannel("boss1", 4242424, 14.012, { nameless = true })   -- 4 slots
		for _, quadrant in ipairs({ "N", "E", "S", "W" }) do
			ns.Seq.Press(quadrant)
			wow.advance(14.012 / 4)
		end
		wow.stopChannel("boss1")

		assert.same({ "N", "E", "S", "W" }, ns.Seq.Get())
	end)

	it("throws out a channel that is not a whole number of slots", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		wow.aurasBlocked = true

		-- Some other channel entirely: 5.2s is no whole count of 3.503s slots.
		wow.startChannel("boss1", 777, 5.2, { nameless = true })
		wow.advance(5.2)
		wow.stopChannel("boss1")

		assert.is_true(wow.chatContains("cut short"))

		-- Nothing was learned from it, so nothing gets called back off it either.
		enc.callRound(ns, 3, { difficulty = enc.NORMAL })
		assert.is_false(ns.Detector.IsReplaying())
	end)
end)

describe("finding the round's aura", function()
	local CURLY = "Sermon of Ula\226\128\153tek"     -- U+2019, not an ASCII quote

	it("does not care which apostrophe the client spells it with", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", CURLY, slot * 3)
		for _, quadrant in ipairs({ "N", "E", "S" }) do
			ns.Seq.Press(quadrant)
			wow.advance(slot)
		end
		wow.removeAura("boss1", CURLY)

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
	end)

	it("finds it on a unit that never gets a boss frame", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		wow.guids.boss1 = nil
		wow.hostile.target = true
		wow.guids.target = "Creature-0-0-3079-0-224001-0000AZTA"

		-- Silent: no UNIT_AURA at all, so only the poll can turn this up.
		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("target", enc.SERMON, slot * 3, { silent = true })
		for _, quadrant in ipairs({ "N", "E", "S" }) do
			wow.advance(slot * 0.5)
			ns.Seq.Press(quadrant)
			wow.advance(slot * 0.5)
		end
		wow.removeAura("target", enc.SERMON, { silent = true })
		wow.advance(0.4)                            -- let the poll notice

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
	end)

	it("dates the round from the aura's expiry, not from when it was noticed", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		-- A whole second of the round is already gone by the time anything looks.
		-- Timed from the moment of noticing, the round would come up a second
		-- short and be thrown away as cut off.
		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 3, { startedAgo = 1.0 })
		for _, quadrant in ipairs({ "N", "E", "S" }) do
			ns.Seq.Press(quadrant)
			wow.advance((slot * 3 - 1.0) / 3)
		end
		wow.removeAura("boss1", enc.SERMON)

		assert.is_false(wow.chatContains("cut short"))
		assert.same({ "N", "E", "S" }, ns.Seq.Get())
	end)

	it("survives the client making the boss' auras secret", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		assert.has_no.errors(function()
			wow.applyAura("boss1", enc.SERMON, slot * 3, { secret = true })
			wow.advance(slot * 3)
			wow.removeAura("boss1", enc.SERMON)
		end)

		-- Nothing readable means nothing recorded, but the addon is still alive:
		-- the next round, on ordinary values, works.
		assert.equals(0, ns.Seq.Count())
		wow.applyAura("boss1", enc.SERMON, slot * 3)
		for _, quadrant in ipairs({ "S", "W", "N" }) do
			ns.Seq.Press(quadrant)
			wow.advance(slot)
		end
		wow.removeAura("boss1", enc.SERMON)
		assert.same({ "S", "W", "N" }, ns.Seq.Get())
	end)

	-- The boss carries more than one aura, and only one of them is the round.
	it("picks the round's aura out from the others on the boss", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)

		wow.applyAura("boss1", "Something Else", 8)
		wow.applyAura("boss1", enc.SERMON, enc.SLOT[enc.NORMAL] * 3)
		wow.advance(0.3)

		local grid = ns.Detector.ActiveGrid()
		assert.is_not_nil(grid)
		assert.equals(3, grid.waves)          -- read off the Sermon, not the decoy
	end)
end)

-- The board is the player's. What the round is for is the wave count and the
-- slot length -- the timing the player cannot work out while playing.
describe("a round the player fills in by hand", function()
	it("keeps what was pressed, in order", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })
		assert.same(HARD_PATH, ns.Seq.Get())
	end)

	it("works out how many waves are coming from the aura's length alone", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)

		wow.applyAura("boss1", enc.SERMON, enc.SLOT[enc.NORMAL] * 3)
		wow.advance(0.3)

		local grid = ns.Detector.ActiveGrid()
		assert.is_not_nil(grid)
		assert.equals(3, grid.waves)          -- known before a single wave landed
		assert.equals(0, ns.Seq.Count())      -- and without anything on the board
	end)

	it("knows the wave count while the board is still empty", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "N", "E", "S", "W", "N" },
			{ difficulty = enc.HARD, silent = true })

		-- The player pressed nothing at all. The timing was still read.
		assert.equals(0, ns.Seq.Count())
		assert.is_true(ns.IsSlotLearned("hard") or ns.SlotLength("hard") > 0)
	end)

	it("starts each round from an empty board", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		enc.round(ns, { "N", "E", "S", "W", "N" }, { difficulty = enc.HARD })
		enc.showRound(ns, { "S", "W", "N" }, { difficulty = enc.HARD })
		assert.same({ "S", "W", "N" }, ns.Seq.Get())
	end)

	it("grows with the boss across three rounds in one pull", function()
		local ns = enc.ready()
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
end)

describe("a round that is cut short", function()
	it("says so when a wipe truncates the aura", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		-- Three whole slots in, then the raid dies and the aura goes with them.
		enc.showRoundCutShort(ns, HARD_PATH, enc.SLOT[enc.HARD] * 3.4, { difficulty = enc.HARD })

		assert.is_true(wow.chatContains("cut short"))
	end)

	-- The presses are the player's own work. A round the boss cut short says
	-- nothing about whether they typed it correctly, so binning it would be the
	-- addon throwing away something it did not put there.
	it("leaves the board alone, because the board is not ours to discard", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRoundCutShort(ns, { "N", "E", "S" }, enc.SLOT[enc.HARD] * 2.4,
			{ difficulty = enc.HARD })

		assert.same({ "N", "E" }, ns.Seq.Get())
	end)

	it("leaves nothing behind for the next pull", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRoundCutShort(ns, HARD_PATH, enc.SLOT[enc.HARD] * 2.5, { difficulty = enc.HARD })
		enc.wipe(ns)

		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "S", "W", "N" }, { difficulty = enc.HARD })
		assert.same({ "S", "W", "N" }, ns.Seq.Get())
	end)

	it("is over when the encounter ends before the aura does", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 5)
		ns.Seq.Press("N"); wow.advance(slot)
		ns.Seq.Press("E"); wow.advance(slot)

		enc.wipe(ns)                                -- ENCOUNTER_END lands first
		wow.removeAura("boss1", enc.SERMON)         -- the aura follows a tick later

		assert.equals(0, ns.Seq.Count())
		assert.is_false(ns.Detector.IsArmed())
	end)

	it("calls nothing back, because the round never proved its wave count", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRoundCutShort(ns, HARD_PATH, enc.SLOT[enc.HARD] * 3.4,
			{ difficulty = enc.HARD, silent = true })
		enc.callRound(ns, 5)
		assert.equals(0, #wow.spoken)
		assert.is_false(ns.Detector.IsReplaying())
	end)
end)

describe("calling the run back", function()
	it("announces one wave per cast, in the recorded order", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.round(ns, { "W", "N", "S" }, { difficulty = enc.HARD })
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("announces at the start of the cast, not when the wave lands", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		wow.startCast("boss1", enc.ECHO, 3.31)
		assert.equals(1, #wow.spoken)              -- spoken before a single tick
		assert.equals(1, ns.Detector.EchoIndex())
	end)

	it("gives the player the live cast time to move, not an assumed one", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N" }, { difficulty = enc.HARD })

		wow.startCast("boss1", enc.ECHO, 3.64)
		assert.is_near(wow.now() + 3.64, ns.Detector.CastEndsAt(), 0.001)

		wow.advance(3.64 + 0.4)
		wow.startCast("boss1", enc.ECHO, 3.31)     -- hard switches mid-round
		assert.is_near(wow.now() + 3.31, ns.Detector.CastEndsAt(), 0.001)
	end)

	it("ignores casts from the second boss", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		enc.callRound(ns, 3, { unit = "boss2" })
		assert.equals(0, #wow.spoken)
		assert.equals(0, ns.Detector.EchoIndex())
	end)

	it("counts one cast once however many unit tokens it arrives on", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		enc.callRound(ns, 3, { echoOn = { "nameplate1" } })
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("stops at the end of the run and ignores extra casts", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		enc.callRound(ns, 6)
		assert.equals(3, #wow.spoken)
	end)

	it("says which quarter is next while there is one", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "W", "N", "S" }, { difficulty = enc.HARD })

		wow.startCast("boss1", enc.ECHO, 3.31)
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
		assert.is_true(ns.Announce.PopupSubtitle():find("Orange", 1, true) ~= nil)
	end)

	it("closes the replay once the last wave has landed", function()
		local ns = enc.ready()
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

-- The client hands addons secret values for parts of a cast in this content. A
-- secret goes off on a comparison as readily as on arithmetic, and the throw
-- lands inside a combat event handler, where it takes the whole feature down
-- without a word on screen.
describe("a cast the client will not fully describe", function()
	local RUN = { "W", "N", "S" }

	it("never touches the spell id of a cast that is not the boss'", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		-- In an instance this is nearly every cast that happens.
		assert.has_no.errors(function()
			wow.startCast("party1", 12345, 2, { secret = true })
			wow.startCast("player", 12345, 2, { secret = true })
		end)
		assert.is_false(wow.chatContains("internal error"))
		assert.equals(0, ns.Detector.EchoIndex())
	end)

	it("calls the run back when the spell id is secret", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, RUN, { difficulty = enc.HARD })

		assert.has_no.errors(function()
			enc.callRound(ns, 3, { secret = true })
		end)
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
		assert.is_false(wow.chatContains("internal error"))
	end)

	it("calls it back when neither the id nor the name can be read", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, RUN, { difficulty = enc.HARD })

		assert.has_no.errors(function()
			enc.callRound(ns, 3, { secret = true, nameless = true })
		end)
		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	-- The fallback is "a cast we cannot name, during a calling half, is the
	-- wave". It must not reach back into the showing half, where a stray cast
	-- would shift the whole run onto the wrong quarters.
	it("does not treat an unreadable cast during the showing half as a wave", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		local slot = enc.SLOT[enc.HARD]
		wow.applyAura("boss1", enc.SERMON, slot * 3)
		ns.Seq.Press("N"); wow.advance(slot)
		wow.startCast("boss1", 999, 2, { secret = true, nameless = true })
		assert.equals(0, ns.Detector.EchoIndex())

		ns.Seq.Press("E"); wow.advance(slot)
		ns.Seq.Press("S"); wow.advance(slot)
		wow.removeAura("boss1", enc.SERMON)

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
	end)

	-- The mid-round guard is against the unit carrying the round shifting its own
	-- run. A second boss frame casting is a different thing, and refusing it
	-- would cost the calls outright if the round's channel outlasts them.
	it("never takes the round-carrier's own unreadable cast for a wave", function()
		local ns = enc.ready()
		ns.SetDebug(true)
		enc.pull(ns, enc.HARD)

		wow.startChannel("boss1", enc.SERMON_SPELL, 15.015)
		wow.advance(0.3)
		assert.is_true(ns.Detector.IsShowingRound())

		-- boss1 is carrying the round. Taking its own stray cast for a wave would
		-- shift the entire run onto the wrong quarters.
		wow.startCast("boss1", 999, 3.2, { secret = true, nameless = true })
		assert.is_false(wow.chatContains("echo from boss1"))
		assert.equals(0, ns.Detector.EchoIndex())
	end)

	it("still turns down a named cast that is not the wave", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, RUN, { difficulty = enc.HARD })

		wow.startCast("boss1", 555, 2, { secret = true, name = "Venomous Bile" })

		assert.equals(0, ns.Detector.EchoIndex())
		assert.equals(0, #wow.spoken)
	end)
end)

describe("learning the slot length", function()
	it("corrects itself when more waves are called than the length implied", function()
		local ns = enc.ready()
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
		local ns = enc.ready()
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
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		enc.showRound(ns, HARD_PATH, { difficulty = enc.HARD })   -- 15.015s, 5 waves, right
		enc.callRound(ns, 2)                                      -- the group dies after two
		enc.wipe(ns)

		assert.is_near(3.003, ns.SlotLength("hard"), 0.0001)
		assert.is_nil(_G.SnakeSaysDB.slotLength)
		assert.is_false(wow.chatContains("wave timing corrected"))
	end)

	it("reads the next pull the same way it would have before the wipe", function()
		local ns = enc.ready()
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
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		enc.showRound(ns, { "N", "E", "S", "W", "N", "E" }, { length = 18.2 })
		enc.callRound(ns, 7)
		enc.wipe(ns)

		assert.is_near(18.2 / 7, ns.SlotLength("hard"), 0.001)
	end)

	it("leaves the slot alone when the cast count agrees", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.round(ns, HARD_PATH, { difficulty = enc.HARD })
		enc.kill(ns)

		assert.is_near(3.003, ns.SlotLength("hard"), 0.0001)
		assert.is_false(wow.chatContains("wave timing corrected"))
	end)

	it("uses the correction on the very next round", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)

		enc.showRound(ns, { "N", "E", "S", "W", "N", "E" }, { length = 18.2 })
		enc.callRound(ns, 7)

		-- Same true slot of 2.6s, one more wave. Read on the seed this round is
		-- seven waves; read on what the last round taught it, it is eight.
		enc.showRound(ns, { "N", "E", "S", "W", "N", "E", "S", "W" }, { length = 20.8 })
		assert.equals(8, ns.Seq.Count())
	end)

	it("keeps the correction between sessions", function()
		local ns = enc.ready()
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, { "N", "E", "S", "W", "N", "E" }, { length = 18.2 })
		enc.callRound(ns, 7)
		enc.kill(ns)

		assert.is_near(18.2 / 7, _G.SnakeSaysDB.slotLength.hard, 0.001)
	end)

	-- A single miscounted round once wrote a 13.990s slot into SavedVariables --
	-- four times the real one. Every round after it, that session and the next,
	-- was thrown out for not being a whole number of something no round could be
	-- a whole number of. Nothing could recover, because a discarded round teaches
	-- nothing.
	it("refuses a correction that is nowhere near the measured seed", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)

		-- Four waves, one call: exactly the shape that produced 13.990.
		enc.showRound(ns, { "N", "E", "S", "W" }, { length = 14.012, difficulty = enc.NORMAL })
		enc.callRound(ns, 1)
		enc.showRound(ns, { "N", "E", "S" }, { length = 10.509, difficulty = enc.NORMAL })

		assert.is_near(3.503, ns.SlotLength("normal"), 0.0001)
		assert.is_nil(_G.SnakeSaysDB.slotLength and _G.SnakeSaysDB.slotLength.normal)
	end)

	it("ignores a stored slot that is already far past believing", function()
		local ns = enc.ready({ slotLength = { normal = 13.990 } })
		enc.pull(ns, enc.NORMAL)

		enc.showRound(ns, { "N", "E", "S" }, { length = 10.509, difficulty = enc.NORMAL })

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
		assert.is_false(wow.chatContains("cut short"))
	end)

	it("drops a believable stored slot that cannot explain a round", function()
		-- 4.5s is close enough to normal's 3.503 to have been a real correction,
		-- and it cannot make a whole number out of a 10.509s round.
		local ns = enc.ready({ slotLength = { normal = 4.5 } })
		enc.pull(ns, enc.NORMAL)

		enc.showRound(ns, { "N", "E", "S" }, { length = 10.509, difficulty = enc.NORMAL })

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
		assert.is_near(3.503, ns.SlotLength("normal"), 0.0001)
		assert.is_true(wow.chatContains("could not explain this round"))
	end)

	it("keeps normal and hard apart", function()
		local ns = enc.ready()
		enc.pull(ns, enc.NORMAL)
		enc.showRound(ns, { "N", "E", "S", "W" }, { length = 14.012 })
		enc.callRound(ns, 5)
		enc.kill(ns, enc.NORMAL)

		assert.is_near(14.012 / 5, ns.SlotLength("normal"), 0.001)
		assert.is_near(3.003, ns.SlotLength("hard"), 0.0001)
	end)
end)

describe("the delve check", function()
	it("knows the delve by its instance id", function()
		local ns = enc.setup()
		wow.zoneText = "Somewhere Else"
		assert.is_true(ns.InDelve())
	end)

	it("knows it by name when the instance id has moved", function()
		local ns = enc.setup()
		wow.instanceMapID = 4321
		wow.zoneText = "Venomfall Deeps"
		assert.is_true(ns.InDelve())
	end)

	it("says no everywhere else", function()
		local ns = enc.setup()
		wow.instanceMapID = 0
		wow.zoneText = "Valdrakken"
		assert.is_false(ns.InDelve())
	end)
end)
