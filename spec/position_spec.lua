-- Phase 2: reading the player's quadrant from world coordinates, surviving
-- secret values, and demoting to manual if position ever stops being readable.

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

-- Place the player `dist` yards from the room centre on a compass bearing.
-- 0 = due north, 90 = due east. Axis a runs north, axis b runs west.
local function placeAt(ns, bearing, dist)
	local center = ns.GetRoomCenter()
	local rad = math.rad(bearing)
	local x = math.sin(rad) * dist   -- east component
	local y = math.cos(rad) * dist   -- north component
	wow.setPosition(center.a + y, center.b - x, 0, ns.ROOM.instanceMapID)
end

local function inDelve(ns)
	wow.instanceMapID = ns.ROOM.instanceMapID
	wow.zoneText = "Venomfall Deeps"
	wow.uiMapID = ns.ROOM.uiMapID
end

describe("quadrant from position", function()
	local ns
	before_each(function()
		ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
	end)

	it("reads the four cardinal directions", function()
		local cases = { [0] = "N", [90] = "E", [180] = "S", [270] = "W" }
		for bearing, expected in pairs(cases) do
			placeAt(ns, bearing, 20)
			assert.equals(expected, ns.Position.Quadrant(),
				("bearing %d should be %s"):format(bearing, expected))
		end
	end)

	it("keeps each cardinal wedge across its full 90 degree span", function()
		for bearing = -44, 44, 11 do
			placeAt(ns, bearing, 20)
			assert.equals("N", ns.Position.Quadrant(), "bearing " .. bearing)
		end
		for bearing = 46, 134, 11 do
			placeAt(ns, bearing, 20)
			assert.equals("E", ns.Position.Quadrant(), "bearing " .. bearing)
		end
	end)

	it("still resolves a quadrant when standing outside the room", function()
		placeAt(ns, 90, ns.ROOM.radius + 50)
		assert.equals("E", ns.Position.Quadrant())
	end)

	it("reports room-local offsets with east and north positive", function()
		placeAt(ns, 90, 12)         -- 12 yards due east
		local x, y = ns.Position.Offset()
		assert.is_true(math.abs(x - 12) < 0.001)
		assert.is_true(math.abs(y) < 0.001)

		placeAt(ns, 0, 7)           -- 7 yards due north
		x, y = ns.Position.Offset()
		assert.is_true(math.abs(x) < 0.001)
		assert.is_true(math.abs(y - 7) < 0.001)
	end)

	it("reports distance from the centre", function()
		placeAt(ns, 33, 25)
		assert.is_true(math.abs(ns.Position.Distance() - 25) < 0.001)
	end)

	it("returns nil at the exact centre rather than guessing a quadrant", function()
		local center = ns.GetRoomCenter()
		wow.setPosition(center.a, center.b, 0, ns.ROOM.instanceMapID)
		assert.is_nil(ns.Position.Quadrant())
	end)
end)

describe("secret value guard", function()
	local ns
	before_each(function()
		ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
	end)

	it("returns nil instead of erroring on secret coordinates", function()
		wow.setPosition(200, 10, 0, 3079, true)
		local quadrant
		assert.has_no.errors(function() quadrant = ns.Position.Quadrant() end)
		assert.is_nil(quadrant)
	end)

	it("survives position being unavailable entirely", function()
		wow.setPosition(nil)
		assert.has_no.errors(function() ns.Position.Quadrant() end)
		assert.is_nil(ns.Position.Quadrant())
		assert.is_nil(ns.Position.Offset())
		assert.is_nil(ns.Position.Distance())
	end)

	it("returns nil facing when facing is secret, without erroring", function()
		wow.setFacing(1.2, true)
		local facing
		assert.has_no.errors(function() facing = ns.Position.Facing() end)
		assert.is_nil(facing)
	end)

	it("reads facing normally when it is a plain number", function()
		wow.setFacing(1.25)
		assert.is_true(math.abs(ns.Position.Facing() - 1.25) < 0.001)
	end)

	it("reports availability honestly", function()
		placeAt(ns, 0, 5)
		assert.is_true(ns.Position.IsAvailable())
		wow.setPosition(200, 10, 0, 3079, true)
		assert.is_false(ns.Position.IsAvailable())
		wow.setPosition(nil)
		assert.is_false(ns.Position.IsAvailable())
	end)
end)

describe("fallback to manual", function()
	it("warns and switches to manual when position is unreadable in the delve", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
		wow.setPosition(nil)

		ns.Position.Verify()

		assert.equals("manual", ns.GetMode())
		assert.is_true(wow.chatContains("manual"))
	end)

	it("says why, so the player knows it is not their fault", function()
		local ns = addon.boot({ db = { mode = "semi" } })
		inDelve(ns)
		wow.setPosition(200, 10, 0, 3079, true)

		ns.Position.Verify()

		assert.equals("manual", ns.GetMode())
		assert.is_true(wow.chatContains("position"))
	end)

	it("re-enables manual input when it demotes", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
		assert.is_true(ns.GetBlockManualInput())

		wow.setPosition(nil)
		ns.Position.Verify()

		assert.is_false(ns.GetBlockManualInput())
		assert.is_true(ns.Seq.Press("N"))
	end)

	it("stays quiet while position works", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
		placeAt(ns, 0, 10)

		ns.Position.Verify()

		assert.equals("auto", ns.GetMode())
		assert.is_false(wow.chatContains("manual"))
	end)

	it("does not demote outside the delve, where position is irrelevant", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		wow.instanceMapID = 0
		wow.zoneText = "Stormwind City"
		wow.setPosition(nil)

		ns.Position.Verify()

		assert.equals("auto", ns.GetMode())
	end)

	it("does not demote a player who chose manual already", function()
		local ns = addon.boot({ db = { mode = "manual" } })
		inDelve(ns)
		wow.setPosition(nil)

		ns.Position.Verify()

		assert.equals("manual", ns.GetMode())
		assert.is_false(wow.chatContains("no longer"))
	end)

	it("only warns once, however often it is checked", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
		wow.setPosition(nil)

		ns.Position.Verify()
		ns.Position.Verify()
		ns.Position.Verify()

		local warnings = 0
		for _, line in ipairs(wow.chat) do
			if line:find("manual", 1, true) then warnings = warnings + 1 end
		end
		assert.equals(1, warnings)
	end)

	it("verifies automatically on entering the delve", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
		wow.setPosition(nil)

		wow.fire("ZONE_CHANGED_NEW_AREA")

		assert.equals("manual", ns.GetMode())
	end)
end)

describe("room centre measurement", function()
	it("defaults to the shipped constants", function()
		local ns = addon.boot()
		local center = ns.GetRoomCenter()
		assert.equals(ns.ROOM.centerA, center.a)
		assert.equals(ns.ROOM.centerB, center.b)
	end)

	it("stores a measured centre in SavedVariables", function()
		local ns = addon.boot()
		inDelve(ns)
		wow.setPosition(150.5, 12.25, 0, ns.ROOM.instanceMapID)

		assert.is_true(ns.Position.MeasureCenter())

		local center = ns.GetRoomCenter()
		assert.equals(150.5, center.a)
		assert.equals(12.25, center.b)
		assert.equals(150.5, _G.SnakeSaysDB.roomCenter.a)
	end)

	it("makes the measured centre the new origin for quadrants", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		inDelve(ns)
		wow.setPosition(500, 500, 0, ns.ROOM.instanceMapID)
		ns.Position.MeasureCenter()

		assert.is_nil(ns.Position.Quadrant())   -- we are the centre now
		placeAt(ns, 180, 15)
		assert.equals("S", ns.Position.Quadrant())
	end)

	it("refuses to measure when position is unreadable", function()
		local ns = addon.boot()
		inDelve(ns)
		wow.setPosition(nil)

		assert.is_false(ns.Position.MeasureCenter())
		assert.is_nil(_G.SnakeSaysDB.roomCenter)
	end)

	it("is reachable from chat and reports back", function()
		local ns = addon.boot()
		inDelve(ns)
		wow.setPosition(111.5, 22.5, 0, ns.ROOM.instanceMapID)

		wow.slash("SNAKESAYS", "measure")

		assert.equals(111.5, ns.GetRoomCenter().a)
		assert.is_true(wow.chatContains("centre"))
	end)

	it("can be reset back to the shipped constants", function()
		local ns = addon.boot()
		inDelve(ns)
		wow.setPosition(111.5, 22.5, 0, ns.ROOM.instanceMapID)
		ns.Position.MeasureCenter()

		wow.slash("SNAKESAYS", "measure reset")

		assert.equals(ns.ROOM.centerA, ns.GetRoomCenter().a)
		assert.is_nil(_G.SnakeSaysDB.roomCenter)
	end)
end)
