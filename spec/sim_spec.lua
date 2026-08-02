-- The practice run drives the shipped detector through a scripted pull, so it
-- has to leave no trace: no stray encounter state, and the real room centre back
-- exactly as it was.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

-- The demo run is what `/ss sim` does by default: it makes up a sequence and
-- calls it back, so the announcements can be checked standing still.
describe("demo practice run", function()
	local function outside(ns)
		wow.instanceMapID = 0
		wow.zoneText = "Valdrakken"
		wow.uiMapID = 2112
		wow.fire("ZONE_CHANGED_NEW_AREA")
		return ns
	end

	it("puts a run on the board without the player moving", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")

		wow.slash("SNAKESAYS", "sim")
		assert.is_true(ns.Sim.IsRunning())
		assert.equals(0, ns.Seq.Count())    -- nothing until the lead-in is over

		wow.advance(10)
		assert.equals(5, ns.Seq.Count())
	end)

	it("calls the run back out loud", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")

		wow.slash("SNAKESAYS", "sim")
		wow.advance(25)                     -- through the last call, before it clears

		assert.equals(5, #wow.spoken)
		assert.equals(5, ns.Detector.EchoIndex())
	end)

	it("announces exactly the run it said it would", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")

		-- Pin the run so the assertion doesn't depend on the dice.
		ns.Sim.StartDemo(3, { "W", "N", "S" })
		wow.advance(40)

		assert.same({ "Red", "Orange", "Blue" }, wow.spokenText())
	end)

	it("shows the run in chat before playing it", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")
		ns.Sim.StartDemo(3, { "W", "N", "S" })
		assert.is_true(wow.chatContains("Red > Orange > Blue"))
	end)

	it("flashes the board as each wave is revealed", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")
		local flashes = {}
		ns.HUD.Flash = function(dir) flashes[#flashes + 1] = dir end

		ns.Sim.StartDemo(3, { "E", "S", "W" })
		wow.advance(10)
		assert.same({ "E", "S", "W" }, flashes)
	end)

	it("drives the popup and the radar tint", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")
		ns.Sim.StartDemo(3, { "W", "N", "S" })

		wow.advance(8)                      -- through the reveal, past the first call
		assert.is_true(ns.Announce.IsPopupShown())
		assert.is_true(ns.Announce.PopupText():find("Red", 1, true) ~= nil)

		enc.placeIn(ns, "W")                -- stand where it says
		wow.advance(0.5)
		assert.equals("safe", ns.Radar.SafetyState())
		assert.is_true(#wow.sounds > 0)     -- and the bell rings
	end)

	it("works in manual mode, where the player records nothing themselves", function()
		local ns = outside(enc.setup("manual"))
		enc.placeIn(ns, "N")
		ns.Sim.StartDemo(3, { "W", "N", "S" })
		wow.advance(40)
		assert.equals(3, #wow.spoken)
	end)

	-- A doubled call means the right move is to stand still, which is the one
	-- thing a drill can't usefully rehearse -- and looks like a missed call.
	it("never calls the same quadrant twice in a row", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")

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
		enc.placeIn(ns, "N")

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

	it("honours a longer phase", function()
		local ns = outside(enc.setup("auto"))
		enc.placeIn(ns, "N")
		wow.slash("SNAKESAYS", "sim 7")
		wow.advance(50)
		assert.equals(7, #wow.spoken)
	end)
end)

describe("recorded practice run", function()
	it("records from the player's own position and replays it", function()
		local ns = enc.setup("auto")
		wow.instanceMapID = 0             -- explicitly not in the delve
		wow.zoneText = "Valdrakken"
		enc.placeIn(ns, "N")

		wow.slash("SNAKESAYS", "sim record")
		assert.is_true(ns.Sim.IsRunning())

		wow.advance(4)                    -- lead-in, then the channel opens
		assert.is_true(ns.Detector.IsRecording())

		-- Stand somewhere for each wave, as a player would.
		for _, quadrant in ipairs({ "N", "E", "S", "W", "N" }) do
			enc.placeIn(ns, quadrant)
			wow.advance(3.5)
		end
		wow.advance(2)

		assert.is_true(ns.Seq.Count() > 0)
		wow.advance(4)
		assert.is_true(ns.Detector.EchoIndex() > 0)
		assert.is_true(#wow.spoken > 0)
	end)

	it("says so when the player never left the centre", function()
		local ns = enc.setup("auto")
		wow.slash("SNAKESAYS", "sim record")
		wow.advance(30)                   -- never moves: every wave unresolvable
		assert.equals(0, ns.Seq.Count())
		assert.is_true(wow.chatContains("centre") or wow.chatContains("position"))
		assert.is_false(ns.Sim.IsRunning())
	end)

	it("restores a room centre that was never measured", function()
		local ns = enc.setup("auto")
		assert.is_nil(_G.SnakeSaysDB.roomCenter)

		wow.slash("SNAKESAYS", "sim")
		assert.is_not_nil(_G.SnakeSaysDB.roomCenter)   -- re-pinned while running

		wow.slash("SNAKESAYS", "sim stop")
		assert.is_nil(_G.SnakeSaysDB.roomCenter)
		assert.equals(ns.ROOM.centerA, ns.GetRoomCenter().a)
	end)

	it("restores a room centre the player had measured themselves", function()
		local ns = enc.setup("auto")
		wow.setPosition(300.5, 44.25, 0, ns.ROOM.instanceMapID)
		ns.Position.MeasureCenter()

		wow.slash("SNAKESAYS", "sim")
		enc.placeIn(ns, "E")
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

	it("leaves no encounter state behind", function()
		local ns = enc.setup("auto")
		wow.slash("SNAKESAYS", "sim")
		wow.advance(5)
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_false(ns.Detector.IsArmed())
		assert.is_false(ns.Detector.IsRecording())
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

	it("can practise a longer phase", function()
		local ns = enc.setup("auto")
		enc.placeIn(ns, "N")
		wow.slash("SNAKESAYS", "sim record 7")
		wow.advance(4)

		for _, quadrant in ipairs({ "N", "E", "S", "W", "N", "E", "S" }) do
			enc.placeIn(ns, quadrant)
			wow.advance(3.5)
		end
		wow.advance(3)
		assert.equals(7, ns.Seq.Count())
	end)

	it("says so when asked to stop nothing", function()
		enc.setup("auto")
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_true(wow.chatContains("no practice run"))
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

	it("reports the quadrant it can currently see", function()
		local ns = enc.setup("auto")
		enc.placeIn(ns, "E")
		wow.slash("SNAKESAYS", "status")
		assert.is_true(wow.chatContains("position readable"))
		assert.is_true(wow.chatContains("(E,"))
	end)
end)

-- A practice run happens out in the world, where both windows are normally
-- hidden by the map restriction. Showing nothing would defeat the point of it.
describe("practice run visibility", function()
	local function outside(ns)
		wow.instanceMapID = 0
		wow.zoneText = "Valdrakken"
		wow.uiMapID = 2112
		wow.fire("ZONE_CHANGED_NEW_AREA")
		return ns
	end

	it("hides both windows out in the world to begin with", function()
		local ns = outside(enc.setup("auto"))
		assert.is_false(ns.HUD.IsVisible())
		assert.is_false(ns.Radar.IsShown())
	end)

	it("brings the board and the radar up for the run", function()
		local ns = outside(enc.setup("auto"))
		wow.slash("SNAKESAYS", "sim")
		assert.is_true(ns.HUD.IsVisible())
		assert.is_true(ns.Radar.IsShown())
	end)

	it("puts them away again when the run is stopped", function()
		local ns = outside(enc.setup("auto"))
		wow.slash("SNAKESAYS", "sim")
		wow.advance(5)
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_false(ns.HUD.IsVisible())
		assert.is_false(ns.Radar.IsShown())
	end)

	it("puts them away when the run finishes on its own", function()
		local ns = outside(enc.setup("auto"))
		wow.slash("SNAKESAYS", "sim")
		wow.advance(60)
		assert.is_false(ns.Sim.IsRunning())
		assert.is_false(ns.HUD.IsVisible())
		assert.is_false(ns.Radar.IsShown())
	end)

	it("leaves them alone inside the delve, where they already show", function()
		local ns = enc.setup("auto")
		wow.fire("ZONE_CHANGED_NEW_AREA")
		wow.slash("SNAKESAYS", "sim")
		assert.is_true(ns.HUD.IsVisible())
		wow.slash("SNAKESAYS", "sim stop")
		assert.is_true(ns.HUD.IsVisible())   -- still in the delve
	end)

	-- The override lifts the *location* gate only. Switching a feature off is a
	-- statement about wanting it at all, and a practice run shouldn't argue.
	it("respects a board the player has hidden", function()
		local ns = outside(enc.setup("auto"))
		ns.SetShown(false)
		wow.slash("SNAKESAYS", "sim")
		assert.is_false(ns.HUD.IsVisible())
	end)

	it("respects a radar the player has switched off", function()
		local ns = outside(enc.setup("auto", { radarEnabled = false }))
		wow.slash("SNAKESAYS", "sim")
		assert.is_false(ns.Radar.IsShown())
	end)

	it("does not leave the override set if the run never starts", function()
		local ns = outside(enc.setup("auto"))
		wow.setPosition(nil)
		wow.slash("SNAKESAYS", "sim")
		assert.is_false(ns.Sim.IsRunning())
		assert.is_false(ns.HUD.IsVisible())
	end)
end)
