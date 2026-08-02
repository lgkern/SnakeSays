-- The safe slice on the radar pulses until the player is standing in it.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local RUN = { "W", "N", "S" }

-- Sample the target alpha across a couple of blink cycles.
local function sample(ns, seconds, step)
	local seen = {}
	local elapsed = 0
	while elapsed < (seconds or 3) do
		wow.advance(step or 0.1)
		elapsed = elapsed + (step or 0.1)
		seen[#seen + 1] = ns.Radar.TargetAlpha()
	end
	return seen
end

local function spread(values)
	local lo, hi = values[1], values[1]
	for _, v in ipairs(values) do
		if v < lo then lo = v end
		if v > hi then hi = v end
	end
	return hi - lo
end

describe("target slice", function()
	it("marks the quadrant the current call points at", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals("W", ns.Radar.TargetQuadrant())
		enc.echo(ns)
		assert.equals("N", ns.Radar.TargetQuadrant())
	end)

	it("has no target outside a replay", function()
		local ns = enc.setup("auto")
		assert.is_nil(ns.Radar.TargetQuadrant())
		assert.equals(0, ns.Radar.TargetAlpha())

		enc.recordRun(ns, RUN)
		assert.is_nil(ns.Radar.TargetQuadrant())   -- recorded, but not called yet
	end)

	it("blinks while the player has not reached it", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")           -- wrong quadrant; W is safe
		enc.echo(ns)

		assert.is_false(ns.Radar.IsTargetReached())
		assert.is_true(spread(sample(ns, 3)) > 0.2, "slice did not pulse")
	end)

	it("holds steady once the player is standing in it", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")           -- the safe quadrant

		assert.is_true(ns.Radar.IsTargetReached())
		assert.equals(0, spread(sample(ns, 3)))
	end)

	it("settles the moment the player arrives, mid-pulse", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")
		enc.echo(ns)
		sample(ns, 1)                  -- let it pulse a while
		enc.placeIn(ns, "W")
		assert.equals(0, spread(sample(ns, 2)))
	end)

	it("starts pulsing again on the next call", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")           -- reached call one
		assert.equals(0, spread(sample(ns, 1)))

		enc.echo(ns)                   -- call two wants N, player is still in W
		assert.is_false(ns.Radar.IsTargetReached())
		assert.is_true(spread(sample(ns, 3)) > 0.2)
	end)

	it("stays lit rather than dark at its dimmest", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")
		enc.echo(ns)
		for _, alpha in ipairs(sample(ns, 3)) do
			assert.is_true(alpha > 0.05, "slice blinked all the way out")
			assert.is_true(alpha <= 0.6, "slice blinked brighter than solid")
		end
	end)

	it("does not pulse when position cannot be read", function()
		-- Nothing is known about where the player is, so nothing is claimed.
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		wow.setPosition(nil)
		assert.is_false(ns.Radar.IsTargetReached())
		assert.is_true(spread(sample(ns, 3)) > 0.2)
	end)

	it("clears when the replay ends", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		wow.fire("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
		assert.is_nil(ns.Radar.TargetQuadrant())
		assert.equals(0, ns.Radar.TargetAlpha())
	end)

	it("survives an update with a target set", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")
		enc.echo(ns)
		assert.has_no.errors(function() ns.Radar.Update() end)
	end)
end)

describe("next-up slice", function()
	it("stays dark while the player is still on their way", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")           -- not yet in W
		enc.echo(ns)
		assert.is_nil(ns.Radar.NextQuadrant())
		assert.equals(0, ns.Radar.NextAlpha())
	end)

	it("lights up once the player reaches the current slice", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)          -- W, N, S
		enc.placeIn(ns, "E")
		enc.echo(ns)
		assert.is_nil(ns.Radar.NextQuadrant())

		enc.placeIn(ns, "W")            -- arrived
		assert.equals("N", ns.Radar.NextQuadrant())
		assert.is_true(ns.Radar.NextAlpha() > 0)
	end)

	it("is dimmer than the slice being called now", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")
		assert.is_true(ns.Radar.NextAlpha() < ns.Radar.TargetAlpha())
	end)

	it("holds steady rather than pulsing", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")

		local seen = {}
		for _ = 1, 30 do
			wow.advance(0.1)
			seen[#seen + 1] = ns.Radar.NextAlpha()
		end
		assert.equals(0, spread(seen))
	end)

	it("becomes the green slice when the call moves on", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")
		assert.equals("N", ns.Radar.NextQuadrant())

		enc.echo(ns)                    -- time to move
		assert.equals("N", ns.Radar.TargetQuadrant())
		assert.is_nil(ns.Radar.NextQuadrant())   -- not there yet, so no preview
	end)

	it("shows nothing after the final wave", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns); enc.echo(ns); enc.echo(ns)
		enc.placeIn(ns, "S")            -- standing in the last safe slice
		assert.is_true(ns.Radar.IsTargetReached())
		assert.is_nil(ns.Radar.NextQuadrant())
	end)

	it("stays dark when the next call is for the same slice", function()
		-- Yellow over the green would read as "move" when the answer is "stay".
		local ns = enc.setup("auto")
		enc.recordRun(ns, { "W", "W", "N" })
		enc.echo(ns)
		enc.placeIn(ns, "W")
		assert.is_true(ns.Radar.IsTargetReached())
		assert.is_nil(ns.Radar.NextQuadrant())
	end)

	it("uses green for now and yellow for next", function()
		local ns = enc.setup("auto")
		local gr, gg, gb = ns.Radar.SliceColor("target")
		local yr, yg, yb = ns.Radar.SliceColor("next")

		assert.is_true(gg > gr and gg > gb, "target slice is not green")
		assert.is_true(yr > 0.6 and yg > 0.6 and yb < 0.3, "next slice is not yellow")
	end)

	it("clears with the replay", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")
		assert.is_not_nil(ns.Radar.NextQuadrant())

		wow.fire("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
		assert.is_nil(ns.Radar.NextQuadrant())
		assert.equals(0, ns.Radar.NextAlpha())
	end)

	it("survives an update with both slices lit", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")
		assert.has_no.errors(function() ns.Radar.Update() end)
	end)
end)

describe("danger slices", function()
	it("paints every quadrant that is not the call", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)          -- W, N, S
		enc.placeIn(ns, "E")
		enc.echo(ns)                    -- W is safe

		assert.equals("target", ns.Radar.SliceRole("W"))
		for _, dir in ipairs({ "N", "E", "S" }) do
			assert.equals("danger", ns.Radar.SliceRole(dir),
				dir .. " should be marked as danger")
		end
	end)

	it("keeps the next slice yellow rather than red once reached", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")            -- arrived, so N is previewed

		assert.equals("target", ns.Radar.SliceRole("W"))
		assert.equals("next", ns.Radar.SliceRole("N"))
		assert.equals("danger", ns.Radar.SliceRole("E"))
		assert.equals("danger", ns.Radar.SliceRole("S"))
	end)

	it("marks the coming slice as danger while the player is still travelling", function()
		-- It is not safe yet, whatever it becomes next wave.
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")
		enc.echo(ns)
		assert.equals("danger", ns.Radar.SliceRole("N"))
	end)

	it("says nothing about anywhere outside a live call", function()
		local ns = enc.setup("auto")
		for _, dir in ipairs(ns.QUADRANTS) do
			assert.is_nil(ns.Radar.SliceRole(dir))
			assert.equals(0, ns.Radar.SliceAlpha(ns.Radar.SliceRole(dir)))
		end

		enc.recordRun(ns, RUN)          -- recorded, not yet called
		for _, dir in ipairs(ns.QUADRANTS) do
			assert.is_nil(ns.Radar.SliceRole(dir))
		end
	end)

	it("uses a red that is clearly red", function()
		local ns = enc.setup("auto")
		local r, g, b = ns.Radar.SliceColor("danger")
		assert.is_true(r > 0.7, "danger slice is not red enough")
		assert.is_true(g < 0.3 and b < 0.3, "danger slice is not red")
	end)

	it("holds danger steady and below the called slice", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")

		local seen = {}
		for _ = 1, 20 do
			wow.advance(0.1)
			seen[#seen + 1] = ns.Radar.SliceAlpha("danger")
		end
		assert.equals(0, spread(seen))
		assert.is_true(ns.Radar.SliceAlpha("danger") < ns.Radar.TargetAlpha())
	end)

	it("stops painting when the replay ends", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		assert.equals("danger", ns.Radar.SliceRole("E"))

		wow.fire("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
		assert.is_nil(ns.Radar.SliceRole("E"))
	end)

	it("survives an update with all four slices painted", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")
		assert.has_no.errors(function() ns.Radar.Update() end)
	end)
end)

describe("blink setting", function()
	it("is on by default", function()
		local ns = enc.setup("auto")
		assert.is_true(ns.GetTargetBlink())
	end)

	it("round-trips through SavedVariables", function()
		local ns = enc.setup("auto")
		ns.SetTargetBlink(false)
		assert.is_false(_G.SnakeSaysDB.targetBlink)
		assert.is_false(ns.GetTargetBlink())
	end)

	it("holds the slice steady when switched off", function()
		local ns = enc.setup("auto", { targetBlink = false })
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")           -- not reached, but the pulse is off
		enc.echo(ns)

		assert.is_false(ns.Radar.IsTargetReached())
		assert.equals(0, spread(sample(ns, 3)))
	end)

	it("still marks the slice when the pulse is off", function()
		local ns = enc.setup("auto", { targetBlink = false })
		enc.recordRun(ns, RUN)
		enc.placeIn(ns, "E")
		enc.echo(ns)
		assert.equals("W", ns.Radar.TargetQuadrant())
		assert.is_true(ns.Radar.TargetAlpha() > 0)
	end)
end)
