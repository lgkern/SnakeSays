-- The boss runs the wave mechanic more than once per pull, and the run gets
-- longer each time -- on the hardest difficulty it is 5 waves, then 6, then 7.
-- Each one is recorded and replayed on its own; nothing may carry over.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local HARD = 2   -- index into ns.ENCOUNTERS

local function quadrantsFor(count)
	local cycle = { "N", "E", "S", "W" }
	local out = {}
	for i = 1, count do out[i] = cycle[(i - 1) % 4 + 1] end
	return out
end

describe("growing wave counts", function()
	it("records a five, six and seven wave run in one pull", function()
		local ns = enc.setup("auto")
		enc.pull(ns, ns.ENCOUNTERS[HARD].id)

		for _, count in ipairs({ 5, 6, 7 }) do
			local expected = quadrantsFor(count)
			enc.channel(ns, expected)
			assert.same(expected, ns.Seq.Get(),
				("phase of %d waves recorded wrong"):format(count))
			assert.equals(count, ns.Seq.Count())

			for _ = 1, count do enc.echo(ns) end
			assert.equals(count, ns.Detector.EchoIndex())
		end
	end)

	it("clears the previous phase when the next channel begins", function()
		local ns = enc.setup("auto")
		enc.pull(ns, ns.ENCOUNTERS[HARD].id)

		enc.channel(ns, quadrantsFor(5))
		assert.equals(5, ns.Seq.Count())

		enc.channel(ns, { "S", "S", "N", "E", "W", "N" })
		assert.same({ "S", "S", "N", "E", "W", "N" }, ns.Seq.Get())
		assert.equals(6, ns.Seq.Count())
	end)

	it("restarts the replay counter for each phase", function()
		local ns = enc.setup("auto")
		enc.pull(ns, ns.ENCOUNTERS[HARD].id)

		enc.channel(ns, quadrantsFor(5))
		enc.echo(ns); enc.echo(ns)
		assert.equals(2, ns.Detector.EchoIndex())

		enc.channel(ns, quadrantsFor(6))
		assert.equals(0, ns.Detector.EchoIndex())
		enc.echo(ns)
		assert.equals(1, ns.Detector.EchoIndex())
	end)

	it("announces the right run in the second phase", function()
		local ns = enc.setup("auto")
		enc.pull(ns, ns.ENCOUNTERS[HARD].id)

		enc.channel(ns, quadrantsFor(5))
		for _ = 1, 5 do enc.echo(ns) end
		local afterFirst = #wow.spoken

		enc.channel(ns, { "W", "W", "N", "N", "S", "E" })
		enc.echo(ns); enc.echo(ns)

		-- West is Cross (red), so the sixth-phase run opens on red twice.
		assert.equals("Red", wow.spoken[afterFirst + 1].text)
		assert.equals("Red", wow.spoken[afterFirst + 2].text)
	end)

	it("keeps fitting the grid as the channel gets longer", function()
		-- The channel length identifies the grid, and it changes every phase.
		-- A longer channel must read as more waves, not as a different grid.
		local ns = enc.setup("auto")
		enc.pull(ns, ns.ENCOUNTERS[HARD].id)
		local hardGrid = ns.ENCOUNTERS[HARD].grid

		for _, count in ipairs({ 5, 6, 7 }) do
			enc.channel(ns, quadrantsFor(count))
			assert.equals(hardGrid.spacing, ns.Detector.ActiveGrid().spacing,
				("grid drifted on the %d wave phase"):format(count))
			assert.equals(count, ns.Seq.Count())
		end
	end)

	it("handles the normal difficulty's longer runs too", function()
		local ns = enc.setup("auto")
		enc.pull(ns, ns.ENCOUNTERS[1].id)
		enc.channel(ns, quadrantsFor(7))
		assert.equals(7, ns.Seq.Count())
	end)
end)

describe("auto-reset and recorded runs", function()
	-- Auto-reset exists so a hand-recorded sequence can't go stale between
	-- pulls. A recorded run manages its own lifetime, and a seven wave phase
	-- plus its replay outlives the timer -- it must not be wiped mid-call.
	it("does not wipe a recorded run part way through its replay", function()
		local ns = enc.setup("auto", { autoReset = true, autoResetTime = 40 })
		enc.pull(ns, ns.ENCOUNTERS[HARD].id)
		enc.channel(ns, quadrantsFor(7))
		assert.equals(7, ns.Seq.Count())

		-- Real waves land about three seconds apart; well past 40 seconds from
		-- the first entry by the time the last call is made.
		for step = 1, 7 do
			enc.echo(ns, nil, 4)
			assert.equals(7, ns.Seq.Count(),
				("sequence lost before call %d"):format(step))
			assert.equals(step, ns.Detector.EchoIndex())
		end
	end)

	it("still auto-resets a sequence the player entered by hand", function()
		local ns = enc.setup("manual", { autoReset = true, autoResetTime = 40 })
		ns.Seq.Press("N")
		ns.Seq.Press("E")
		assert.equals(2, ns.Seq.Count())
		wow.advance(41)
		assert.equals(0, ns.Seq.Count())
	end)

	it("arms no timer for recorder entries", function()
		local ns = enc.setup("semi", { autoReset = true, autoResetTime = 40 })
		enc.placeIn(ns, "N")
		ns.Detector.Capture()
		assert.equals(1, ns.Seq.Count())
		wow.advance(41)
		assert.equals(1, ns.Seq.Count())
	end)
end)
