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

	-- The window is a fixed size the player placed to taste; a five-wave round
	-- should use all of it rather than huddle at the left.
	it("spreads a run evenly across the whole staff", function()
		local ns = enc.setup()
		for _, q in ipairs({ "N", "E", "S", "W", "N" }) do ns.Seq.Press(q) end
		assert.equals(5, ns.Timeline.SlotCount())

		local pitch = ns.Timeline.SlotX(2) - ns.Timeline.SlotX(1)
		for i = 3, 5 do
			near(ns.Timeline.SlotX(i) - ns.Timeline.SlotX(i - 1), pitch, 0.01)
		end

		-- The first and last sit a half-icon in from each end of the staff.
		near(ns.Timeline.SlotX(1), ns.Timeline.SlotX(5) - 4 * pitch, 0.01)
		near(ns.Timeline.SlotX(5) + ns.Timeline.SlotX(1), ns.Timeline.TrackWidth(), 0.01)
	end)

	it("uses the same width for a short run as for a long one", function()
		local ns = enc.setup()
		for _, q in ipairs({ "N", "E", "S" }) do ns.Seq.Press(q) end
		local shortSpan = ns.Timeline.SlotX(3) - ns.Timeline.SlotX(1)

		ns.Seq.Reset()
		for i = 1, 7 do ns.Seq.Press(ns.QUADRANTS[(i % #ns.QUADRANTS) + 1]) end
		local longSpan = ns.Timeline.SlotX(7) - ns.Timeline.SlotX(1)

		near(shortSpan, longSpan, 0.01)
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
	-- The whole point of the sync: the call for a wave goes out at cast start, so
	-- the marker under the bar has to be the marker being said aloud.
	it("sits on the marker at the moment it is called", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E", "S" })

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1), 0.01)

		wow.advance(3)
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2), 0.01)

		wow.advance(3)
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(3), 0.01)
	end)

	it("spends the cast travelling to the marker called next", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E", "S" })

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		assert.equals(2, ns.Timeline.ScanTarget())

		-- Half way through the cast, half way between the two markers.
		wow.advance(1.5)
		near(ns.Timeline.BarX(), (ns.Timeline.SlotX(1) + ns.Timeline.SlotX(2)) / 2)

		wow.advance(1.5)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2))
	end)

	it("does not run past the next marker if the call is late", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E", "S" })

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		wow.advance(6)                      -- long past the cast, no new step
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2))
	end)

	-- The point of re-aiming every step. Hard sits on one of two cast lengths and
	-- switches part way through a round; a bar running at the first cast's speed
	-- would land early or late on every marker after the switch.
	it("re-aims when the cast length changes mid-round", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E", "S" })

		ns.Detector.SetCastEnd(wow.now() + enc.CAST.hardSlow)
		ns.Detector.Advance()
		wow.advance(enc.CAST.hardSlow)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2))

		-- The boss switches to the shorter cast.
		ns.Detector.SetCastEnd(wow.now() + enc.CAST.hardFast)
		ns.Detector.Advance()
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2), 0.01)
		wow.advance(enc.CAST.hardFast)
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(3))
	end)

	-- Nothing left to point at, so it finishes the staff instead -- and the
	-- replay closes as it gets there.
	it("runs off the end on the last call", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E" })

		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		wow.advance(3)
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2), 0.01)

		wow.advance(3)
		near(ns.Timeline.BarX(), ns.Timeline.TrackWidth())
	end)

	it("starts each replay on the first marker, not where the last one ended", function()
		local ns = enc.setup()
		enc.recordRun(ns, { "N", "E" })
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		wow.advance(3)
		ns.Detector.EndReplay()

		enc.recordRun(ns, { "S", "W" })
		ns.Detector.SetCastEnd(wow.now() + 3)
		ns.Detector.Advance()
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1), 0.01)
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
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1), 0.01)

		wow.advance(0.2)
		local moved = ns.Timeline.BarX()
		assert.is_true(moved > ns.Timeline.SlotX(1))
		assert.is_true(moved < ns.Timeline.SlotX(2))   -- moving, not teleported
	end)
end)

describe("a real pull drives the timeline", function()
	it("sweeps the run the boss actually called", function()
		local ns = enc.pull(enc.setup(), enc.HARD)
		enc.showRound(ns, { "N", "E", "S" }, { difficulty = enc.HARD })

		assert.equals(3, ns.Seq.Count())
		enc.callRound(ns, 1, { castTime = enc.CAST.hardSlow })

		-- One call in, and the cast it was announced over has run: the bar has
		-- left the first marker and is waiting on the second, which is what the
		-- next call will name.
		assert.equals(1, ns.Detector.EchoIndex())
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2))
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

	it("rests on each marker as its call goes out", function()
		local ns = outside(enc.setup())
		ns.Sim.StartDemo(3, { "W", "N", "S" })

		-- The reveal takes LEAD_IN + REVEAL_GAP*3 + 2; step 1 fires right after.
		wow.advance(7.4)
		assert.equals(1, ns.Detector.EchoIndex())
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(1), 0.01)

		wow.advance(3)                      -- one ECHO_GAP: the second call
		assert.equals(2, ns.Detector.EchoIndex())
		near(ns.Timeline.BarX(), ns.Timeline.SlotX(2), 0.01)
	end)

	it("clears its declared wave count when it finishes", function()
		local ns = outside(enc.setup())
		wow.slash("SNAKESAYS", "sim")
		wow.advance(60)
		assert.is_nil(ns.Detector.ExpectedWaves())
	end)

	-- The run borrows the windows for its duration. Everything it borrowed has to
	-- go back, or the only way out is a reload.
	it("puts the timeline away when it finishes on its own", function()
		local ns = outside(enc.setup({ locked = true }))
		wow.slash("SNAKESAYS", "sim")
		wow.advance(5)
		assert.is_true(ns.Timeline.IsVisible())

		wow.advance(60)
		assert.is_false(ns.Sim.IsRunning())
		assert.is_false(ns.Timeline.IsVisible())
	end)

	it("puts the timeline away when it is stopped early", function()
		local ns = outside(enc.setup({ locked = true }))
		wow.slash("SNAKESAYS", "sim")
		wow.advance(5)
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_false(ns.Timeline.IsVisible())
	end)

	-- The finished run stays on the board on purpose, to be looked at (see
	-- detection_spec). The timeline keeps it for the same reason -- it is the same
	-- run -- so the two windows agree about what is still on screen.
	it("keeps the finished run on show, exactly as the board does", function()
		local ns = enc.setup({ locked = true })       -- standing in the delve
		wow.slash("SNAKESAYS", "sim")
		wow.advance(60)

		assert.equals(5, ns.Seq.Count())
		assert.is_true(ns.HUD.IsVisible())
		assert.is_true(ns.Timeline.IsVisible())
	end)

	-- What it must not keep is the visibility it borrowed to run out in the world.
	it("hands the borrowed visibility back out in the world", function()
		local ns = outside(enc.setup({ locked = true }))
		wow.slash("SNAKESAYS", "sim")
		wow.advance(60)

		assert.is_false(ns.HUD.IsVisible())
		assert.is_false(ns.Timeline.IsVisible())
	end)
end)

describe("the timeline follows the location gates", function()
	it("re-checks itself when the map restriction is switched off", function()
		local ns = outside(enc.setup({ locked = true }))
		ns.Seq.Press("N")
		assert.is_false(ns.Timeline.IsVisible())

		ns.SetRestrictToMap(false)
		assert.is_true(ns.Timeline.IsVisible())
	end)

	it("re-checks itself when the map it watches for changes", function()
		local ns = enc.setup({ locked = true })
		ns.Seq.Press("N")
		assert.is_true(ns.Timeline.IsVisible())

		ns.SetMapID(99999)
		assert.is_false(ns.Timeline.IsVisible())
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
