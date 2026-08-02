-- Phase 3: the encounter state machine -- arming, recording the wave channel
-- from the player's position, and stepping through the silent replay.

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

local BEARING = { N = 0, E = 90, S = 180, W = 270 }

local function placeIn(ns, quadrant)
	local center = ns.GetRoomCenter()
	local rad = math.rad(BEARING[quadrant])
	wow.setPosition(center.a + math.cos(rad) * 20, center.b - math.sin(rad) * 20, 0, ns.ROOM.instanceMapID)
end

local function inDelve(ns)
	wow.instanceMapID = ns.ROOM.instanceMapID
	wow.zoneText = "Venomfall Deeps"
	wow.uiMapID = ns.ROOM.uiMapID
end

local function setup(mode)
	local ns = addon.boot({ db = { mode = mode or "auto" } })
	inDelve(ns)
	placeIn(ns, "N")
	wow.hostile.boss1 = true
	wow.hostile.nameplate1 = true
	return ns
end

local function pull(ns, encounterID)
	wow.fire("ENCOUNTER_START", encounterID or ns.ENCOUNTERS[1].id, "Azta'rec", 2, 5)
	return ns
end

-- Drive a full wave channel: the player stands in each listed quadrant across
-- that wave's hit window, and the channel ends just after the last hit, the way
-- the real one does.
local function channel(ns, quadrants, unit, encounterID)
	unit = unit or "boss1"
	local grid = ns.Detector.ActiveGrid()
	local function hitAt(i) return grid.first + grid.spacing * (i - 1) end
	local last = hitAt(#quadrants) + 0.46

	wow.fire("UNIT_SPELLCAST_CHANNEL_START", unit)
	local now = 0
	for i, quadrant in ipairs(quadrants) do
		placeIn(ns, quadrant)
		local until_ = math.min(hitAt(i) + 0.75, last)
		if until_ > now then
			wow.advance(until_ - now)
			now = until_
		end
	end
	if last > now then wow.advance(last - now) end
	wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
	return encounterID
end

-- One echo cast from the boss, spaced past the advance throttle.
local function echo(ns, unit)
	wow.advance(1.2)
	wow.fire("UNIT_SPELLCAST_START", unit or "boss1")
end

describe("arming", function()
	it("arms on the encounter and disarms when it ends", function()
		local ns = setup()
		assert.is_false(ns.Detector.IsArmed())
		pull(ns)
		assert.is_true(ns.Detector.IsArmed())
		wow.fire("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
		assert.is_false(ns.Detector.IsArmed())
	end)

	it("ignores an unrelated encounter", function()
		local ns = setup()
		wow.fire("ENCOUNTER_START", 1234, "Some Other Boss", 2, 5)
		assert.is_false(ns.Detector.IsArmed())
	end)

	it("arms on the boss name if the encounter is renumbered", function()
		local ns = setup()
		wow.fire("ENCOUNTER_START", 99999, "Azta'rec the Whatever", 2, 5)
		assert.is_true(ns.Detector.IsArmed())
	end)

	it("picks the wave grid that matches the difficulty", function()
		local ns = setup()
		pull(ns, ns.ENCOUNTERS[1].id)
		local first = ns.Detector.ActiveGrid()
		pull(ns, ns.ENCOUNTERS[2].id)
		local second = ns.Detector.ActiveGrid()
		assert.is_not.equals(first.spacing, second.spacing)
	end)

	it("clears any stale sequence on the pull", function()
		local ns = setup("manual")
		ns.Seq.Press("N")
		ns.Seq.Press("E")
		pull(ns)
		assert.equals(0, ns.Seq.Count())
	end)

	it("does nothing with a channel while unarmed", function()
		local ns = setup()
		channel(ns, { "N", "E", "S" })
		assert.equals(0, ns.Seq.Count())
	end)
end)

describe("automatic recording", function()
	it("records one quadrant per wave, in order", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S", "W", "N" })
		assert.same({ "N", "E", "S", "W", "N" }, ns.Seq.Get())
	end)

	it("records a repeated quadrant rather than collapsing it", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "E", "E", "S" })
		assert.same({ "E", "E", "S" }, ns.Seq.Get())
	end)

	it("takes the majority quadrant across each wave window", function()
		-- Walking through a wedge on the way somewhere else must not be recorded:
		-- the player is in W for the first part of wave one's window, then settles
		-- in S for the rest of it and for the hit itself.
		local ns = setup("auto")
		pull(ns)
		local grid = ns.Detector.ActiveGrid()
		local function hitAt(i) return grid.first + grid.spacing * (i - 1) end

		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		placeIn(ns, "W")
		wow.advance(hitAt(1) - 0.44)          -- two samples inside the window, in W
		placeIn(ns, "S")
		wow.advance(0.44 + 0.75)              -- five more, in S: S wins the vote
		placeIn(ns, "N")
		wow.advance(hitAt(2) + 0.75 - (hitAt(1) + 0.75))
		placeIn(ns, "E")
		wow.advance(hitAt(3) + 0.46 - (hitAt(2) + 0.75))
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")

		assert.same({ "S", "N", "E" }, ns.Seq.Get())
	end)

	it("flashes the board as each wave is locked in", function()
		local ns = setup("auto")
		local flashes = {}
		ns.HUD.Flash = function(dir) flashes[#flashes + 1] = dir end
		pull(ns)
		channel(ns, { "N", "E", "S" })
		assert.same({ "N", "E", "S" }, flashes)
	end)

	it("discards a channel far too short to be the wave mechanic", function()
		local ns = setup("auto")
		pull(ns)
		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		wow.advance(2)
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")
		assert.equals(0, ns.Seq.Count())
		assert.is_false(ns.Detector.IsReplaying())
	end)

	it("does not record from a friendly unit's channel", function()
		local ns = setup("auto")
		wow.hostile.nameplate7 = false
		pull(ns)
		channel(ns, { "N", "E", "S" }, "nameplate7")
		assert.equals(0, ns.Seq.Count())
	end)

	it("ignores a second unit channelling while one is already recording", function()
		local ns = setup("auto")
		pull(ns)
		local grid = ns.Detector.ActiveGrid()
		local function hitAt(i) return grid.first + grid.spacing * (i - 1) end

		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		placeIn(ns, "N")
		wow.advance(hitAt(1) + 0.75)
		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "nameplate1")   -- must not wipe the run
		placeIn(ns, "E")
		wow.advance(hitAt(2) + 0.75 - (hitAt(1) + 0.75))
		placeIn(ns, "S")
		wow.advance(hitAt(3) + 0.46 - (hitAt(2) + 0.75))
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")

		assert.same({ "N", "E", "S" }, ns.Seq.Get())
	end)

	it("upgrades a nameplate token to the boss token mid-channel", function()
		local ns = setup("auto")
		pull(ns)
		local grid = ns.Detector.ActiveGrid()
		local function hitAt(i) return grid.first + grid.spacing * (i - 1) end

		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "nameplate1")
		placeIn(ns, "S")
		wow.advance(hitAt(1) + 0.75)
		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")        -- same channel, sturdier token
		placeIn(ns, "W")
		wow.advance(hitAt(2) + 0.75 - (hitAt(1) + 0.75))
		placeIn(ns, "N")
		wow.advance(hitAt(3) + 0.46 - (hitAt(2) + 0.75))
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")         -- must still finalise

		assert.same({ "S", "W", "N" }, ns.Seq.Get())
	end)

	it("skips unreadable samples instead of recording a wrong quadrant", function()
		-- Position blinks out across part of a wave's window. The samples that
		-- survive still agree, so the wave resolves.
		local ns = setup("auto")
		pull(ns)
		local grid = ns.Detector.ActiveGrid()
		local function hitAt(i) return grid.first + grid.spacing * (i - 1) end

		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		placeIn(ns, "E")
		wow.advance(hitAt(1) - 0.4)
		wow.setPosition(nil)
		wow.advance(0.6)
		placeIn(ns, "E")
		wow.advance(hitAt(1) + 0.75 - (hitAt(1) + 0.2))
		placeIn(ns, "S")
		wow.advance(hitAt(2) + 0.75 - (hitAt(1) + 0.75))
		placeIn(ns, "W")
		wow.advance(hitAt(3) + 0.46 - (hitAt(2) + 0.75))
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")

		assert.same({ "E", "S", "W" }, ns.Seq.Get())
	end)

	it("throws the run away if a wave cannot be resolved at all", function()
		-- A missing entry would shift every later call onto the wrong wave, so a
		-- partial recording is worse than none.
		local ns = setup("auto")
		pull(ns)
		local grid = ns.Detector.ActiveGrid()
		local function hitAt(i) return grid.first + grid.spacing * (i - 1) end

		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		placeIn(ns, "E")
		wow.advance(hitAt(1) + 0.75)
		wow.setPosition(nil)                    -- dead for the whole of wave two
		wow.advance(hitAt(2) + 1.0 - (hitAt(1) + 0.75))

		assert.equals(0, ns.Seq.Count())
		assert.is_false(ns.Detector.IsRecording())
		assert.is_true(wow.chatContains("position"))
	end)

	it("does not auto-record in manual mode", function()
		local ns = setup("manual")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		assert.equals(0, ns.Seq.Count())
	end)

	it("does not auto-record in semi-automatic mode", function()
		local ns = setup("semi")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		assert.equals(0, ns.Seq.Count())
	end)
end)

describe("semi-automatic capture", function()
	it("records the quadrant the player is standing in", function()
		local ns = setup("semi")
		pull(ns)
		placeIn(ns, "W")
		assert.is_true(ns.Detector.Capture())
		wow.advance(1)
		placeIn(ns, "N")
		ns.Detector.Capture()
		assert.same({ "W", "N" }, ns.Seq.Get())
	end)

	it("records repeats, since consecutive waves can share a quadrant", function()
		local ns = setup("semi")
		pull(ns)
		placeIn(ns, "E")
		ns.Detector.Capture()
		wow.advance(1)
		ns.Detector.Capture()
		assert.same({ "E", "E" }, ns.Seq.Get())
	end)

	it("throttles a double tap so one press is one wave", function()
		local ns = setup("semi")
		pull(ns)
		placeIn(ns, "E")
		ns.Detector.Capture()
		ns.Detector.Capture()          -- same instant: ignored
		assert.equals(1, ns.Seq.Count())
	end)

	it("flashes the board on capture", function()
		local ns = setup("semi")
		local flashes = {}
		ns.HUD.Flash = function(dir) flashes[#flashes + 1] = dir end
		pull(ns)
		placeIn(ns, "S")
		ns.Detector.Capture()
		assert.same({ "S" }, flashes)
	end)

	it("says so and records nothing when position is unreadable", function()
		local ns = setup("semi")
		pull(ns)
		wow.setPosition(nil)
		assert.is_false(ns.Detector.Capture())
		assert.equals(0, ns.Seq.Count())
	end)

	it("is exposed as a keybind global", function()
		local ns = setup("semi")
		pull(ns)
		placeIn(ns, "N")
		assert.is_function(_G.SnakeSays_Capture)
		_G.SnakeSays_Capture()
		assert.equals(1, ns.Seq.Count())
	end)
end)

describe("replay", function()
	it("starts replaying once the channel finishes", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		assert.is_true(ns.Detector.IsReplaying())
		assert.equals(0, ns.Detector.EchoIndex())
	end)

	it("advances one step per boss cast", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		echo(ns); assert.equals(1, ns.Detector.EchoIndex())
		echo(ns); assert.equals(2, ns.Detector.EchoIndex())
		echo(ns); assert.equals(3, ns.Detector.EchoIndex())
	end)

	it("reports the current and next safe quadrant at each step", function()
		local ns = setup("auto")
		local steps = {}
		ns.Detector.OnReplayStep(function(index, current, nextUp)
			steps[#steps + 1] = { index = index, current = current, nextUp = nextUp }
		end)
		pull(ns)
		channel(ns, { "N", "E", "S" })
		echo(ns); echo(ns); echo(ns)
		assert.same({
			{ index = 1, current = "N", nextUp = "E" },
			{ index = 2, current = "E", nextUp = "S" },
			{ index = 3, current = "S", nextUp = nil },
		}, steps)
	end)

	it("throttles casts that arrive within a second of each other", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		echo(ns)
		wow.fire("UNIT_SPELLCAST_START", "boss1")   -- same instant, must not count
		assert.equals(1, ns.Detector.EchoIndex())
	end)

	it("ignores casts from a unit that did not run the channel", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S" }, "boss1")
		wow.advance(1.2)
		wow.fire("UNIT_SPELLCAST_START", "nameplate1")
		assert.equals(0, ns.Detector.EchoIndex())
	end)

	it("stops advancing past the end of the recorded sequence", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		echo(ns); echo(ns); echo(ns); echo(ns); echo(ns)
		assert.equals(3, ns.Detector.EchoIndex())
	end)

	it("does not replay a sequence that was never recorded", function()
		local ns = setup("auto")
		pull(ns)
		echo(ns)
		assert.equals(0, ns.Detector.EchoIndex())
		assert.is_false(ns.Detector.IsReplaying())
	end)

	it("clears itself a while after the last echo", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		echo(ns); echo(ns); echo(ns)
		wow.advance(15)
		assert.is_false(ns.Detector.IsReplaying())
		assert.equals(0, ns.Seq.Count())
	end)

	-- The replay has to start by itself when the channel ends, whoever recorded
	-- the run. Calling BeginReplay by hand in a test proves only that the
	-- function works, not that the fight ever reaches it.
	it("starts by itself after a semi-automatically captured channel", function()
		local ns = setup("semi")
		pull(ns)
		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		for _, quadrant in ipairs({ "W", "N", "S" }) do
			placeIn(ns, quadrant)
			ns.Detector.Capture()
			wow.advance(3)
		end
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")

		assert.same({ "W", "N", "S" }, ns.Seq.Get())
		assert.is_true(ns.Detector.IsReplaying())

		echo(ns)
		assert.equals(1, ns.Detector.EchoIndex())
		assert.equals("Red", wow.spokenText()[1])
	end)

	it("starts by itself after a hand-pressed channel", function()
		local ns = setup("manual")
		pull(ns)
		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		ns.Seq.Press("N"); wow.advance(3)
		ns.Seq.Press("E"); wow.advance(3)
		ns.Seq.Press("S"); wow.advance(3)
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")

		assert.is_true(ns.Detector.IsReplaying())
		echo(ns)
		assert.equals(1, ns.Detector.EchoIndex())
	end)

	it("clears the previous phase at the start of a semi-mode channel", function()
		local ns = setup("semi")
		pull(ns)
		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		placeIn(ns, "W"); ns.Detector.Capture()
		wow.advance(3)
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")
		assert.equals(1, ns.Seq.Count())

		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		assert.equals(0, ns.Seq.Count())
	end)

	it("keeps a short hand-recorded channel, unlike an automatic one", function()
		-- The 8 second floor exists to reject channels the sampler shouldn't have
		-- recorded. A player pressing deliberately meant every press.
		local ns = setup("semi")
		pull(ns)
		wow.fire("UNIT_SPELLCAST_CHANNEL_START", "boss1")
		placeIn(ns, "E"); ns.Detector.Capture()
		wow.advance(2)
		wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "boss1")
		assert.same({ "E" }, ns.Seq.Get())
		assert.is_true(ns.Detector.IsReplaying())
	end)

	it("ends cleanly when the encounter ends mid-replay", function()
		local ns = setup("auto")
		pull(ns)
		channel(ns, { "N", "E", "S" })
		echo(ns)
		wow.fire("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
		assert.is_false(ns.Detector.IsReplaying())
		assert.is_false(ns.Detector.IsArmed())
	end)
end)

describe("event safety", function()
	it("never lets an error escape into the event handler", function()
		local ns = setup("auto")
		pull(ns)
		ns.HUD.Flash = function() error("boom") end
		assert.has_no.errors(function()
			channel(ns, { "N", "E" })
		end)
	end)

	it("survives a channel event with a junk unit token", function()
		local ns = setup("auto")
		pull(ns)
		assert.has_no.errors(function()
			wow.fire("UNIT_SPELLCAST_CHANNEL_START", nil)
			wow.fire("UNIT_SPELLCAST_CHANNEL_START", 42)
			wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", "player")
			wow.fire("UNIT_SPELLCAST_START", {})
		end)
	end)
end)
