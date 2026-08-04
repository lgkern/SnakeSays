-- The practice run is the addon's own, and it survives the quarantine: it makes
-- up a run, puts it on the board and calls it back, which exercises everything
-- downstream of the recorder.
--
-- `/ss sim record` recorded from the player's real position, which needs the
-- recording engine -- not written yet, so its tests are gone until it is.
-- See SPEC-detection.md.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local function outside(ns)
	wow.instanceMapID = 0
	wow.zoneText = "Valdrakken"
	wow.uiMapID = 2112
	wow.fire("ZONE_CHANGED_NEW_AREA")
	return ns
end

describe("demo practice run", function()
	it("puts a run on the board without the player moving", function()
		local ns = outside(enc.setup("auto"))

		wow.slash("SNAKESAYS", "sim")
		assert.is_true(ns.Sim.IsRunning())
		assert.equals(0, ns.Seq.Count())    -- nothing until the lead-in is over

		wow.advance(10)
		assert.equals(5, ns.Seq.Count())
	end)

	it("calls the run back out loud", function()
		local ns = outside(enc.setup("auto"))

		wow.slash("SNAKESAYS", "sim")
		wow.advance(25)                     -- through the last call, before it clears

		assert.equals(5, #wow.spoken)
		assert.equals(5, ns.Detector.EchoIndex())
	end)

	it("announces exactly the run it said it would", function()
		local ns = outside(enc.setup("auto"))

		-- Pin the run so the assertion doesn't depend on the dice.
		ns.Sim.StartDemo(3, { "W", "N", "S" })
		wow.advance(40)

		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("shows the run in chat before playing it", function()
		local ns = outside(enc.setup("auto"))
		ns.Sim.StartDemo(3, { "W", "N", "S" })
		assert.is_true(wow.chatContains("Red > Orange > Blue"))
	end)

	it("flashes the board as each wave is revealed", function()
		local ns = outside(enc.setup("auto"))
		local flashes = {}
		ns.HUD.Flash = function(dir) flashes[#flashes + 1] = dir end

		ns.Sim.StartDemo(3, { "E", "S", "W" })
		wow.advance(10)
		assert.same({ "E", "S", "W" }, flashes)
	end)

	it("drives the on-screen call", function()
		local ns = outside(enc.setup("auto"))
		ns.Sim.StartDemo(3, { "W", "N", "S" })

		wow.advance(8)                      -- through the reveal, past the first call
		assert.is_true(ns.Announce.IsPopupShown())
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)
	end)

	it("works in manual mode, where the player records nothing themselves", function()
		local ns = outside(enc.setup("manual"))
		ns.Sim.StartDemo(3, { "W", "N", "S" })
		wow.advance(40)
		assert.equals(3, #wow.spoken)
	end)

	it("honours a longer phase", function()
		outside(enc.setup("auto"))
		wow.slash("SNAKESAYS", "sim 7")
		wow.advance(50)
		assert.equals(7, #wow.spoken)
	end)

	-- A doubled call means the right move is to stand still, which is the one
	-- thing a drill can't usefully rehearse -- and looks like a missed call.
	it("never calls the same quadrant twice in a row", function()
		local ns = outside(enc.setup("auto"))

		for _ = 1, 50 do
			ns.Sim.StartDemo(7)
			local run = ns.Sim.lastRun
			assert.equals(7, #run)
			for i = 2, #run do
				assert.are_not.equals(run[i - 1], run[i])
			end
			ns.Sim.Stop(true)
		end
	end)

	it("still uses every quadrant across a long enough run", function()
		local ns = outside(enc.setup("auto"))

		local seen = {}
		for _ = 1, 50 do
			ns.Sim.StartDemo(7)
			for _, quadrant in ipairs(ns.Sim.lastRun) do seen[quadrant] = true end
			ns.Sim.Stop(true)
		end
		for _, quadrant in ipairs(ns.QUADRANTS) do
			assert.is_true(seen[quadrant] == true)
		end
	end)
end)

describe("practice run lifecycle", function()
	it("restores a room centre that was never measured", function()
		enc.setup("auto")
		assert.is_nil(_G.SnakeSaysDB.roomCenter)

		wow.slash("SNAKESAYS", "sim")
		assert.is_not_nil(_G.SnakeSaysDB.roomCenter)   -- re-pinned while running

		wow.slash("SNAKESAYS", "sim stop")
		assert.is_nil(_G.SnakeSaysDB.roomCenter)
	end)

	it("restores a room centre the player had measured themselves", function()
		local ns = enc.setup("auto")
		wow.setPosition(300.5, 44.25, 0, ns.ROOM.instanceMapID)
		ns.Position.MeasureCenter()

		wow.slash("SNAKESAYS", "sim")
		wow.advance(2)
		wow.slash("SNAKESAYS", "sim stop")

		assert.equals(300.5, ns.GetRoomCenter().a)
		assert.equals(44.25, ns.GetRoomCenter().b)
	end)

	it("restores the centre when it finishes on its own", function()
		local ns = enc.setup("auto")
		wow.slash("SNAKESAYS", "sim")
		wow.advance(60)
		assert.is_false(ns.Sim.IsRunning())
		assert.is_nil(_G.SnakeSaysDB.roomCenter)
	end)

	it("leaves no replay state behind", function()
		local ns = enc.setup("auto")
		wow.slash("SNAKESAYS", "sim")
		wow.advance(5)
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_false(ns.Detector.IsReplaying())
	end)

	it("refuses to start twice over", function()
		local ns = enc.setup("auto")
		wow.slash("SNAKESAYS", "sim")
		wow.slash("SNAKESAYS", "sim")
		assert.is_true(wow.chatContains("already"))
		assert.is_true(ns.Sim.IsRunning())
	end)

	it("refuses to start when position is unreadable", function()
		local ns = enc.setup("auto")
		wow.setPosition(nil)
		wow.slash("SNAKESAYS", "sim")
		assert.is_false(ns.Sim.IsRunning())
		assert.is_true(wow.chatContains("position"))
	end)

	it("says so when asked to stop nothing", function()
		enc.setup("auto")
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_true(wow.chatContains("no practice run"))
	end)

	-- NOT YET WRITTEN: recorded runs need the engine that was removed.
	it("says the recorded run is unavailable rather than starting one", function()
		local ns = enc.setup("auto")
		wow.slash("SNAKESAYS", "sim record")
		assert.is_false(ns.Sim.IsRunning())
		assert.is_true(wow.chatContains("rebuilt"))
	end)
end)

describe("status report", function()
	it("runs in every state without erroring", function()
		local ns = enc.setup("auto")
		assert.has_no.errors(function() wow.slash("SNAKESAYS", "status") end)

		enc.recordRun(ns, { "N", "E", "S" })
		enc.echo(ns)
		assert.has_no.errors(function() wow.slash("SNAKESAYS", "status") end)
	end)

	it("survives no mode, no position and no facing", function()
		enc.setup("auto")
		_G.SnakeSaysDB.mode = nil
		wow.setPosition(nil)
		wow.setFacing(0, true)
		assert.has_no.errors(function() wow.slash("SNAKESAYS", "status") end)
		assert.is_true(wow.chatContains("not chosen"))
	end)

	it("says the room centre has not been measured", function()
		enc.setup("auto")
		wow.slash("SNAKESAYS", "status")
		assert.is_true(wow.chatContains("not measured"))
	end)

	it("says whether we are in the delve", function()
		enc.setup("auto")
		wow.slash("SNAKESAYS", "status")
		assert.is_true(wow.chatContains("in the delve: |cff44ff44yes|r"))
	end)
end)

-- A practice run happens out in the world, where both windows are normally
-- hidden by the map restriction. Showing nothing would defeat the point of it.
describe("practice run visibility", function()
	it("brings the board up for the run", function()
		local ns = outside(enc.setup("auto"))
		wow.slash("SNAKESAYS", "sim")
		assert.is_true(ns.HUD.IsVisible())
	end)

	it("puts it away again when the run is stopped", function()
		local ns = outside(enc.setup("auto"))
		wow.slash("SNAKESAYS", "sim")
		wow.advance(5)
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_false(ns.HUD.IsVisible())
	end)

	it("puts it away when the run finishes on its own", function()
		local ns = outside(enc.setup("auto"))
		wow.slash("SNAKESAYS", "sim")
		wow.advance(60)
		assert.is_false(ns.Sim.IsRunning())
		assert.is_false(ns.HUD.IsVisible())
	end)

	-- The override lifts the *location* gate only. Switching a feature off is a
	-- statement about wanting it at all, and a practice run shouldn't argue.
	it("respects a board the player has hidden", function()
		local ns = outside(enc.setup("auto"))
		ns.SetShown(false)
		wow.slash("SNAKESAYS", "sim")
		assert.is_false(ns.HUD.IsVisible())
	end)

	it("does not leave the override set if the run never starts", function()
		local ns = outside(enc.setup("auto"))
		wow.setPosition(nil)
		wow.slash("SNAKESAYS", "sim")
		assert.is_false(ns.Sim.IsRunning())
		assert.is_false(ns.HUD.IsVisible())
	end)
end)
