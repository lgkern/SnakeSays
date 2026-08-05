-- The timeline writes the run out left to right and sweeps a bar across it
-- during the silent repeat. Two claims are worth holding onto: the bar reaches
-- each marker exactly as that wave lands, and it re-aims every step rather than
-- running at one tempo -- because on hard the boss' cast length changes part way
-- through a round, and a bar with a tempo baked in drifts off the markers.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

-- Where the bar should be, allowing for the mock's 0.05s animation slices.
local function near(actual, expected, tolerance)
	assert.is_not_nil(actual)
	assert.is_true(math.abs(actual - expected) <= (tolerance or 4),
		("expected ~%.1f, got %.1f"):format(expected, actual))
end

local function outside(ns)
	wow.instanceMapID = 0
	wow.zoneText = "Valdrakken"
	wow.uiMapID = 2112
	wow.fire("ZONE_CHANGED_NEW_AREA")
	return ns
end

describe("timeline layout", function()
	it("draws one slot per press", function()
		local ns = enc.setup()
		assert.equals(0, ns.Timeline.SlotCount())

		ns.Seq.Press("N")
		ns.Seq.Press("E")
		assert.equals(2, ns.Timeline.SlotCount())
	end)

	it("still lets the board draw its own row", function()
		-- Both windows subscribe to the sequence. A single-listener Seq silently
		-- unhooked whichever registered first, which was the board.
		local ns = enc.setup()
		local seen = {}
		ns.Seq.OnChange(function(list) seen[#seen + 1] = #list end)

		ns.Seq.Press("N")
		assert.same({ 1 }, seen)
		assert.equals(1, ns.Timeline.SlotCount())
	end)

	it("keeps a short run at the same pitch as a long one", function()
		-- The markers must not slide sideways as the board fills.
		local ns = enc.setup()
		ns.Seq.Press("N")
		local firstOfOne = ns.Timeline.SlotX(1)
		local secondOfTwo
		ns.Seq.Press("E")
		secondOfTwo = ns.Timeline.SlotX(2)

		assert.equals(firstOfOne, ns.Timeline.SlotX(1))
		assert.is_true(secondOfTwo > firstOfOne)
	end)

	it("squeezes a run longer than the fight can produce", function()
		local ns = enc.setup()
		local nominal = ns.Detector.MaxWaves()
		for i = 1, nominal do
			ns.Seq.Press(ns.QUADRANTS[(i % #ns.QUADRANTS) + 1])
		end
		local roomyPitch = ns.Timeline.SlotX(2) - ns.Timeline.SlotX(1)

		for i = 1, 8 do
			ns.Seq.Press(ns.QUADRANTS[(i % #ns.QUADRANTS) + 1])
		end
		assert.is_true(ns.Seq.Count() > nominal)

		-- The slots close up rather than the run running off the end.
		local tightPitch = ns.Timeline.SlotX(2) - ns.Timeline.SlotX(1)
		assert.is_true(tightPitch < roomyPitch)
		assert.is_true(ns.Timeline.SlotX(ns.Seq.Count()) <= ns.Timeline.TrackWidth())
	end)

	-- The nominal width follows the detector's wave table rather than a literal,
	-- so a fight that grows an eighth wave only needs that table corrected.
	it("sizes itself from the detector's wave counts", function()
		local ns = enc.setup()
		assert.equals(7, ns.Detector.MaxWaves())
	end)
end)

describe("timeline rests", function()
	it("shows an empty slot for a wave not pressed yet", function()
		local ns = enc.pull(enc.setup(), enc.HARD)
		enc.beginSermon("boss1", enc.SLOT[enc.HARD] * 5, {})
		wow.advance(0.4)

		-- The round says five waves are coming; nobody has pressed anything.
		assert.equals(5, ns.Detector.ExpectedWaves())
		assert.equals(5, ns.Timeline.SlotCount())
		assert.equals(0, ns.Seq.Count())
	end)

	it("fills the rests as the player presses", function()
		local ns = enc.pull(enc.setup(), enc.HARD)
		enc.beginSermon("boss1", enc.SLOT[enc.HARD] * 5, {})
		wow.advance(0.4)

		ns.Seq.Press("N")
		ns.Seq.Press("E")
		assert.equals(5, ns.Timeline.SlotCount())   -- still five slots
		assert.equals(2, ns.Seq.Count())            -- two of them filled
	end)

	it("never hides a press behind a short round", function()
		-- More presses than the round declared: the slots follow the presses.
		local ns = enc.pull(enc.setup(), enc.HARD)
		enc.beginSermon("boss1", enc.SLOT[enc.HARD] * 2, {})
		wow.advance(0.4)
		for _, q in ipairs({ "N", "E", "S", "W" }) do ns.Seq.Press(q) end
		assert.equals(4, ns.Timeline.SlotCount())
	end)
end)

describe("the scanning bar", function()
	it("aims at the wave being called", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E", "S" })

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		assert.equals(1, ns.Timeline.ScanTarget())

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		assert.equals(2, ns.Timeline.ScanTarget())
	end)

	it("reaches the marker as the cast ends", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E", "S" })

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()

		-- Half way through the cast, half way to the marker.
		wow.advance(1.5)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1) * 0.5)

		wow.advance(1.5)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1))
	end)

	it("does not run past the marker while the wave has not landed", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E" })

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		wow.advance(6)                      -- long past the cast, no new step
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1))
	end)

	-- The point of re-aiming every step. Hard sits on one of two cast lengths and
	-- switches part way through a round; a bar running at the first cast's speed
	-- would arrive early or late on every marker after the switch.
	it("re-aims when the cast length changes mid-round", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E", "S" })

		ns.Detector.SetCastEnd(wow.now() + enc.CAST.hardSlow)
		ns.Detector.Advance()
		wow.advance(enc.CAST.hardSlow)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1))

		-- The boss switches to the shorter cast.
		ns.Detector.SetCastEnd(wow.now() + enc.CAST.hardFast)
		ns.Detector.Advance()
		wow.advance(enc.CAST.hardFast)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2))

		ns.Detector.SetCastEnd(wow.now() + enc.CAST.hardSlow)
		ns.Detector.Advance()
		wow.advance(enc.CAST.hardSlow)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(3))
	end)

	it("starts from the left edge rather than from wherever it stopped", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E" })
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		wow.advance(3)
		ns.Detector.EndReplay()

		enc.recordRun(ns, { "S", "W" })
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		near(ns.Timeline.BarX(), 0, 6)
	end)

	it("is put away when the replay ends", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E" })
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		assert.is_not_nil(ns.Timeline.ScanTarget())

		ns.Detector.EndReplay()
		assert.is_nil(ns.Timeline.ScanTarget())
	end)

	-- The client often refuses to say how long a cast is in here. A bar that
	-- teleports to the marker is worse than one moving at roughly the right speed.
	it("falls back to a slot's length when the cast will not say", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E" })

		ns.Detector.SetCastEnd(nil)
		ns.Detector.Advance()
		wow.advance(0.2)
		local moved = ns.Timeline.BarX()
		assert.is_true(moved > 0)
		assert.is_true(moved < ns.Timeline.SlotX(1))   -- moving, not teleported
	end)
end)

describe("a real pull drives the timeline", function()
	it("sweeps the run the boss actually called", function()
		local ns = enc.pull(enc.setup(), enc.HARD)
		enc.showRound(ns, { "N", "E", "S" }, { difficulty = enc.HARD })

		assert.equals(3, ns.Seq.Count())
		enc.callRound(ns, 1, { castTime = enc.CAST.hardSlow })
		-- One call in, one marker struck.
		assert.equals(1, ns.Detector.EchoIndex())
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1))
	end)
end)

describe("timeline visibility", function()
	-- It is read, never clicked, so it earns its place on screen rather than
	-- holding one. A locked, idle addon shows nothing.
	it("stays out of the way when there is nothing to show", function()
		local ns = enc.setup({ locked = true })
		assert.is_false(ns.Timeline.IsVisible())
	end)

	-- The addon ships unlocked, and a window nobody can see is a window nobody
	-- can place: a fresh install finds it up, ready to be dragged.
	it("is up on a fresh install, before anything is locked", function()
		local ns = enc.setup()
		assert.is_false(ns.IsLocked())
		assert.is_true(ns.Timeline.IsVisible())
	end)

	it("appears once there is a run on the board", function()
		local ns = enc.setup()
		ns.Seq.Press("N")
		assert.is_true(ns.Timeline.IsVisible())
	end)

	it("appears while a round is being shown, before any press", function()
		local ns = enc.pull(enc.setup(), enc.HARD)
		enc.beginSermon("boss1", enc.SLOT[enc.HARD] * 5, {})
		wow.advance(0.4)
		assert.is_true(ns.Timeline.IsVisible())
	end)

	it("comes up when the windows are unlocked, so it can be placed", function()
		local ns = enc.setup({ locked = true })
		assert.is_false(ns.Timeline.IsVisible())
		ns.SetLocked(false)
		assert.is_true(ns.Timeline.IsVisible())
	end)

	it("goes away again when the windows are locked", function()
		local ns = enc.setup()
		assert.is_true(ns.Timeline.IsVisible())
		ns.SetLocked(true)
		assert.is_false(ns.Timeline.IsVisible())
	end)

	it("stays away when the player has switched it off", function()
		local ns = enc.setup({ locked = true })
		ns.SetTimelineEnabled(false)
		ns.Seq.Press("N")
		assert.is_false(ns.Timeline.IsVisible())
	end)

	it("respects the map restriction", function()
		local ns = outside(enc.setup())
		ns.Seq.Press("N")
		assert.is_false(ns.Timeline.IsVisible())
	end)

	it("is lifted out of the map restriction for a practice run", function()
		local ns = outside(enc.setup())
		wow.slash("SNAKESAYS", "sim")
		wow.advance(5)
		assert.is_true(ns.Timeline.IsVisible())
	end)
end)

describe("the practice run previews the timeline", function()
	it("lays out the whole run's slots before a wave is revealed", function()
		local ns = outside(enc.setup())
		ns.Sim.StartDemo(5)
		assert.equals(5, ns.Timeline.SlotCount())
		assert.equals(0, ns.Seq.Count())
	end)

	it("sweeps the bar the same way a pull does", function()
		local ns = outside(enc.setup())
		ns.Sim.StartDemo(3, { "W", "N", "S" })

		wow.advance(8)                      -- through the reveal, into the first call
		assert.is_true(ns.Detector.IsReplaying())
		assert.is_not_nil(ns.Timeline.ScanTarget())
		assert.is_not_nil(ns.Timeline.BarX())
	end)

	it("reaches each marker as its call lands", function()
		local ns = outside(enc.setup())
		ns.Sim.StartDemo(3, { "W", "N", "S" })

		-- The reveal takes LEAD_IN + REVEAL_GAP*3 + 2; step 1 fires right after.
		wow.advance(7.4)
		assert.equals(1, ns.Detector.EchoIndex())
		wow.advance(3)                      -- one ECHO_GAP: wave one lands
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1))
	end)

	it("clears its declared wave count when it finishes", function()
		local ns = outside(enc.setup())
		wow.slash("SNAKESAYS", "sim")
		wow.advance(60)
		assert.is_nil(ns.Detector.ExpectedWaves())
	end)
end)

describe("timeline window", function()
	it("ships on, at 100%, at the top of the screen", function()
		local ns = enc.setup()
		assert.is_true(ns.GetTimelineEnabled())
		assert.equals(1, ns.GetTimelineScale())
		local point = ns.Timeline.GetFrame():GetPoint(1)
		assert.equals("TOP", point)
	end)

	it("carries its own size", function()
		local ns = enc.setup()
		ns.SetTimelineScale(1.6)
		assert.equals(1.6, ns.Timeline.GetFrame():GetScale())
		assert.equals(1, ns.HUD.GetFrame():GetScale())   -- independent of the board
	end)

	it("survives a reload", function()
		local ns = enc.setup({ timelineScale = 1.35, timelineEnabled = false })
		assert.equals(1.35, ns.Timeline.GetFrame():GetScale())
		assert.is_false(ns.GetTimelineEnabled())
	end)

	it("remembers where it was dragged to", function()
		local ns = enc.setup()
		ns.Timeline.SavePosition("TOPLEFT", "TOPLEFT", 40, -12)
		local point, _, relPoint, x, y = ns.Timeline.GetFrame():GetPoint(1)
		assert.equals("TOPLEFT", point)
		assert.equals("TOPLEFT", relPoint)
		assert.equals(40, x)
		assert.equals(-12, y)
	end)

	it("goes back to the top on /ss recenter", function()
		local ns = enc.setup()
		ns.Timeline.SavePosition("BOTTOMRIGHT", "BOTTOMRIGHT", -300, 200)
		wow.slash("SNAKESAYS", "recenter")
		local point = ns.Timeline.GetFrame():GetPoint(1)
		assert.equals("TOP", point)
	end)

	it("is toggled by /ss timeline", function()
		local ns = enc.setup()
		wow.slash("SNAKESAYS", "timeline off")
		assert.is_false(ns.GetTimelineEnabled())
		wow.slash("SNAKESAYS", "timeline on")
		assert.is_true(ns.GetTimelineEnabled())
		wow.slash("SNAKESAYS", "timeline")
		assert.is_false(ns.GetTimelineEnabled())
	end)

	it("is written back by the options page", function()
		local ns = enc.setup()
		ns.SetTimelineScale(1.2)
		assert.has_no.errors(function() ns.Options.Refresh() end)
		assert.equals(1.2, ns.GetTimelineScale())
	end)
end)

-- One unlock has to reach every window, or the player can only place some of
-- what they were told they could place.
describe("unlocking", function()
	it("makes the call and the timeline grabbable too", function()
		local ns = enc.setup()
		ns.SetLocked(false)
		assert.is_true(ns.Announce.IsPopupShown())
		assert.is_true(ns.Timeline.IsVisible())
	end)
end)
