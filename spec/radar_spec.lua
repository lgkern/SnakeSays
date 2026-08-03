-- The room view: what it says about where the player is and where the wave is
-- going, and what it deliberately refuses to say.
--
-- Every replay here is started by the boss casting, not by hand.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local RUN = { "W", "N", "S" }          -- Red, Orange, Blue

-- Walk a pull as far as the first call of the calling half, and stop there so
-- the view can be read mid-wave.
local function intoTheCall(mode, path, castTime)
	local ns = enc.ready(mode or "auto")
	enc.pull(ns, enc.HARD)
	enc.showRound(ns, path or RUN, { difficulty = enc.HARD })
	wow.startCast("boss1", enc.ECHO, castTime or 3.31)
	return ns
end

describe("the room", function()
	it("shows a marker for every quarter", function()
		local ns = enc.ready("auto")
		wow.advance(0.2)
		for _, dir in ipairs(ns.QUADRANTS) do
			assert.equals("idle", ns.Radar.QuadrantState(dir))
		end
	end)

	it("says nothing about danger while no wave is being called", function()
		local ns = enc.ready("auto")
		wow.advance(0.2)
		for _, dir in ipairs(ns.QUADRANTS) do
			assert.equals(0, ns.Radar.DangerAlpha(dir))
		end
	end)

	it("puts the player where they are standing", function()
		local ns = enc.ready("auto")
		wow.setFacing(0)                       -- north-up
		enc.standAt(ns, "N")
		wow.advance(0.2)

		local x, y = ns.Radar.PlayerPoint()
		assert.is_near(0, x, 0.001)
		assert.is_true(y > 0)                  -- north of centre is up the screen

		enc.standAt(ns, "W")
		wow.advance(0.2)
		x, y = ns.Radar.PlayerPoint()
		assert.is_true(x < 0)                  -- west of centre is left
		assert.is_near(0, y, 0.001)
	end)

	it("turns the room so the way the player faces is up", function()
		local ns = enc.ready("auto")
		enc.standAt(ns, "N")

		wow.setFacing(0)
		wow.advance(0.2)
		assert.is_near(0, ns.Radar.Rotation(), 0.001)
		local _, northUp = ns.Radar.PlayerPoint()

		-- Face west. The player is still north of the centre, so north now has to
		-- read as being off to the player's right.
		wow.setFacing(math.pi / 2)
		wow.advance(0.2)
		assert.is_near(-math.pi / 2, ns.Radar.Rotation(), 0.001)

		local x, y = ns.Radar.PlayerPoint()
		assert.is_true(x > 0)
		assert.is_near(0, y, 0.001)
		assert.is_true(northUp > 0)
	end)

	it("sits north-up rather than guessing when facing is unreadable", function()
		local ns = enc.ready("auto")
		enc.standAt(ns, "N")
		wow.setFacing(1.2, true)               -- secret
		wow.advance(0.2)

		assert.equals(0, ns.Radar.Rotation())
		local _, y = ns.Radar.PlayerPoint()
		assert.is_true(y > 0)
	end)

	it("still shows a player standing well outside the modelled circle", function()
		local ns = enc.ready("auto")
		wow.setFacing(0)
		local center = ns.GetRoomCenter()

		-- 54 yards north: inside the room, well past the 38.5 yd circle.
		wow.setPosition(center.a + 54, center.b, 0, ns.ROOM.instanceMapID)
		wow.advance(0.2)

		local x, y, clamped = ns.Radar.PlayerPoint()
		assert.is_true(clamped)
		assert.is_true(y > 0)                  -- pulled to the rim, still northward
		assert.is_near(0, x, 0.001)
	end)

	it("does not clamp a player who is merely at the wall", function()
		local ns = enc.ready("auto")
		wow.setFacing(0)
		local center = ns.GetRoomCenter()
		wow.setPosition(center.a, center.b - 38, 0, ns.ROOM.instanceMapID)
		wow.advance(0.2)

		local _, _, clamped = ns.Radar.PlayerPoint()
		assert.is_falsy(clamped)
	end)

	it("hides the player when the room has never been measured", function()
		local ns = enc.setup("auto")
		enc.standAt(ns, "N")
		wow.advance(0.2)
		assert.is_nil(ns.Radar.PlayerPoint())
	end)
end)

-- While the waves are being shown each quarter wears its marker's colour. The
-- moment the calling half starts there is only one question worth answering, so
-- they go to a traffic light instead.
describe("the traffic light", function()
	local function isGreen(ns, dir)
		local r, g, b = ns.Radar.QuadrantColor(dir)
		return g > 0.5 and r < 0.5 and b < 0.5
	end
	local function isYellow(ns, dir)
		local r, g, b = ns.Radar.QuadrantColor(dir)
		return r > 0.7 and g > 0.6 and b < 0.4
	end
	local function isRed(ns, dir)
		local r, g, b = ns.Radar.QuadrantColor(dir)
		return r > 0.7 and g < 0.4 and b < 0.4
	end

	it("keeps the marker colours while the waves are still being shown", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true

		local slot = enc.SLOT[enc.HARD]
		wow.startChannel("boss1", enc.SERMON_SPELL, slot * 3)
		enc.standAt(ns, "N")
		wow.advance(slot)

		assert.is_true(ns.Detector.IsRecording())
		for _, dir in ipairs(ns.QUADRANTS) do
			local marker = ns.GetMarker(ns.GetAssignment(dir))
			local r, g, b = ns.Radar.QuadrantColor(dir)
			assert.is_near(marker.color[1], r, 0.001)
			assert.is_near(marker.color[2], g, 0.001)
			assert.is_near(marker.color[3], b, 0.001)
		end
	end)

	it("is one green and three red while the player is still moving", function()
		local ns = intoTheCall("auto", RUN)     -- called to W, standing in S
		wow.advance(0.1)

		assert.is_true(isGreen(ns, "W"))
		local red = 0
		for _, dir in ipairs({ "N", "E", "S" }) do
			if isRed(ns, dir) then red = red + 1 end
		end
		assert.equals(3, red)
	end)

	it("is one green, one yellow and two red once they arrive", function()
		local ns = intoTheCall("auto", RUN)     -- W now, N next
		enc.standAt(ns, "W")
		wow.advance(0.1)

		assert.is_true(isGreen(ns, "W"))
		assert.is_true(isYellow(ns, "N"))
		assert.is_true(isRed(ns, "E"))
		assert.is_true(isRed(ns, "S"))
	end)

	it("stays one green and three red on the last wave, where there is no next", function()
		local ns = intoTheCall("auto", { "W", "N" })
		wow.advance(3.31 + 0.4)
		wow.startCast("boss1", enc.ECHO, 3.31)   -- the final call, for N
		enc.standAt(ns, "N")
		wow.advance(0.1)

		assert.is_true(isGreen(ns, "N"))
		local red = 0
		for _, dir in ipairs({ "W", "E", "S" }) do
			if isRed(ns, dir) then red = red + 1 end
		end
		assert.equals(3, red)
	end)

	it("goes back to the marker colours when the replay ends", function()
		local ns = intoTheCall("auto", { "W", "N" })
		wow.advance(3.31 + 0.4)
		wow.startCast("boss1", enc.ECHO, 3.31)
		wow.advance(4)

		assert.is_false(ns.Detector.IsReplaying())
		local marker = ns.GetMarker(ns.GetAssignment("W"))
		local r = ns.Radar.QuadrantColor("W")
		assert.is_near(marker.color[1], r, 0.001)
	end)
end)

describe("the call in the room view", function()
	it("lights the quarter to be in now", function()
		local ns = intoTheCall()
		wow.advance(0.1)
		assert.equals("now", ns.Radar.QuadrantState("W"))
	end)

	it("marks everything else as about to be hit", function()
		local ns = intoTheCall()
		wow.advance(0.1)
		for _, dir in ipairs({ "N", "E", "S" }) do
			assert.is_true(ns.Radar.DangerAlpha(dir) > 0)
		end
		assert.equals(0, ns.Radar.DangerAlpha("W"))
	end)

	it("presses the danger harder the closer the wave gets", function()
		local ns = intoTheCall()
		wow.advance(0.3)
		local early = ns.Radar.DangerAlpha("N")
		wow.advance(2.5)
		local late = ns.Radar.DangerAlpha("N")

		assert.is_true(early > 0)
		assert.is_true(late > early)
	end)

	it("reads the danger off the live cast, not off an assumed one", function()
		local slow = intoTheCall("auto", RUN, 3.64)
		wow.advance(1.8)
		local slowAlpha = slow.Radar.DangerAlpha("N")

		local fast = intoTheCall("auto", RUN, 3.31)
		wow.advance(1.8)
		local fastAlpha = fast.Radar.DangerAlpha("N")

		-- Same moment into the cast, but the short cast is further along it.
		assert.is_true(fastAlpha > slowAlpha)
	end)

	-- The client will not say when the cast finishes in this content, and with
	-- no landing time the danger never builds -- the warning the wash exists to
	-- give never arrives. A slot's worth is the estimate that keeps it moving.
	it("still counts the danger down when the cast time cannot be read", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)
		wow.aurasBlocked = true
		enc.showRound(ns, RUN, { difficulty = enc.HARD })

		wow.startCast("boss1", 0, 3.31, { secret = true, nameless = true, timeless = true })
		wow.advance(0.3)
		local early = ns.Radar.DangerAlpha("N")

		wow.advance(2.0)
		local late = ns.Radar.DangerAlpha("N")

		assert.is_true(early > 0)
		assert.is_true(late > early)
	end)

	it("clears everything when the replay ends", function()
		local ns = intoTheCall("auto", { "W", "N" })
		wow.advance(3.31 + 0.4)
		wow.startCast("boss1", enc.ECHO, 3.31)
		wow.advance(4)                          -- the last wave lands

		assert.is_false(ns.Detector.IsReplaying())
		for _, dir in ipairs(ns.QUADRANTS) do
			assert.equals("idle", ns.Radar.QuadrantState(dir))
			assert.equals(0, ns.Radar.DangerAlpha(dir))
		end
	end)
end)

describe("reached and not reached", function()
	it("shows the current quarter dimmer until the player is standing in it", function()
		local ns = intoTheCall("auto", RUN)
		enc.standAt(ns, "S")                    -- called to W, still over in S
		wow.advance(0.1)
		assert.is_false(ns.Radar.HasReached())

		enc.standAt(ns, "W")
		wow.advance(0.1)
		assert.is_true(ns.Radar.HasReached())
	end)

	it("draws it brighter once they are there", function()
		local ns = intoTheCall("auto", RUN)
		enc.standAt(ns, "S")
		wow.advance(0.1)
		local onTheWay = ns.Radar.QuadrantAlpha("W")

		enc.standAt(ns, "W")
		wow.advance(0.1)
		assert.is_true(ns.Radar.QuadrantAlpha("W") > onTheWay)
	end)

	-- The pulse is a setting. The brightness step is not, so turning the pulse
	-- off must not leave the two states looking the same.
	it("still tells them apart with the pulse switched off", function()
		local ns = enc.ready("auto", { targetBlink = false })
		enc.pull(ns, enc.HARD)
		enc.showRound(ns, RUN, { difficulty = enc.HARD })
		enc.standAt(ns, "S")
		wow.startCast("boss1", enc.ECHO, 3.31)

		wow.advance(0.1)
		local onTheWay = ns.Radar.QuadrantAlpha("W")
		wow.advance(0.4)
		assert.equals(onTheWay, ns.Radar.QuadrantAlpha("W"))   -- and it holds still

		enc.standAt(ns, "W")
		wow.advance(0.1)
		assert.is_true(ns.Radar.QuadrantAlpha("W") > onTheWay)
	end)

	it("breathes the unreached quarter when the pulse is on", function()
		local ns = intoTheCall("auto", RUN)
		enc.standAt(ns, "S")

		local seen = {}
		for _ = 1, 8 do
			wow.advance(0.1)
			seen[#seen + 1] = ns.Radar.QuadrantAlpha("W")
		end

		local moved = false
		for i = 2, #seen do
			if math.abs(seen[i] - seen[1]) > 0.01 then moved = true end
		end
		assert.is_true(moved)
	end)

	it("knows the player has not arrived when the quarter cannot be read", function()
		local ns = intoTheCall("auto", RUN)
		enc.standAt(ns, nil)                    -- on the centre point, no bearing
		wow.advance(0.1)
		assert.is_false(ns.Radar.HasReached())
	end)
end)

describe("the next-up hint", function()
	it("stays away while the player is still on their way to the current one", function()
		local ns = intoTheCall("auto", RUN)
		enc.standAt(ns, "S")
		wow.advance(0.1)

		assert.equals("now", ns.Radar.QuadrantState("W"))
		assert.are_not.equals("next", ns.Radar.QuadrantState("N"))
	end)

	it("appears the moment they arrive", function()
		local ns = intoTheCall("auto", RUN)
		enc.standAt(ns, "S")
		wow.advance(0.1)
		assert.are_not.equals("next", ns.Radar.QuadrantState("N"))

		enc.standAt(ns, "W")
		wow.advance(0.1)
		assert.equals("next", ns.Radar.QuadrantState("N"))
	end)

	it("never appears on the last wave", function()
		local ns = intoTheCall("auto", { "W", "N" })
		wow.advance(3.31 + 0.4)
		wow.startCast("boss1", enc.ECHO, 3.31)  -- the second and final call
		enc.standAt(ns, "N")
		wow.advance(0.1)

		assert.is_true(ns.Radar.HasReached())
		for _, dir in ipairs(ns.QUADRANTS) do
			assert.are_not.equals("next", ns.Radar.QuadrantState(dir))
		end
	end)

	it("never appears when the next call is for the quarter already stood in", function()
		local ns = enc.ready("auto")
		enc.pull(ns, enc.HARD)

		-- A doubled call: the right move is to stand still, and pointing at the
		-- quarter they are already in would read as being sent somewhere.
		enc.showRound(ns, { "W", "W", "S" }, { difficulty = enc.HARD })
		wow.startCast("boss1", enc.ECHO, 3.31)
		enc.standAt(ns, "W")
		wow.advance(0.1)

		assert.is_true(ns.Radar.HasReached())
		assert.equals("now", ns.Radar.QuadrantState("W"))
		for _, dir in ipairs(ns.QUADRANTS) do
			assert.are_not.equals("next", ns.Radar.QuadrantState(dir))
		end
	end)

	it("takes the next quarter out of the danger once it is being pointed at", function()
		local ns = intoTheCall("auto", RUN)
		enc.standAt(ns, "W")
		wow.advance(0.5)

		assert.equals("next", ns.Radar.QuadrantState("N"))
		assert.equals(0, ns.Radar.DangerAlpha("N"))
	end)
end)

describe("the room view window", function()
	it("follows the practice run out into the world", function()
		local ns = enc.ready("auto")
		wow.instanceMapID = 0
		wow.zoneText = "Valdrakken"
		wow.uiMapID = 2112
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.is_false(ns.Radar.IsShown())

		wow.slash("SNAKESAYS", "sim")
		assert.is_true(ns.Radar.IsShown())
	end)

	it("is driven by the practice run the same way a pull drives it", function()
		local ns = enc.ready("auto")
		ns.Sim.StartDemo(3, RUN)
		wow.advance(8)                          -- through the reveal, into the calls
		assert.equals("now", ns.Radar.QuadrantState("W"))
	end)
end)
