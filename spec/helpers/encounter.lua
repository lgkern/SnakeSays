-- ===========================================================================
-- spec/helpers/encounter.lua  ·  drives a pull the way the client would.
--
-- Encapsulates the fiddly parts: placing the player on a compass bearing around
-- the room centre, and running a wave channel whose length actually matches the
-- grid (a channel too short is discarded by the detector on purpose, so tests
-- that hand-roll one get surprising results).
-- ===========================================================================

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

local M = {}

M.BEARING = { N = 0, E = 90, S = 180, W = 270 }

-- Stand the player in the middle of `quadrant`, 20 yards out.
function M.placeIn(ns, quadrant)
	local center = ns.GetRoomCenter()
	local rad = math.rad(M.BEARING[quadrant])
	wow.setPosition(
		center.a + math.cos(rad) * 20,
		center.b - math.sin(rad) * 20,
		0, ns.ROOM.instanceMapID)
end

function M.inDelve(ns)
	wow.instanceMapID = ns.ROOM.instanceMapID
	wow.zoneText = "Venomfall Deeps"
	wow.uiMapID = ns.ROOM.uiMapID
end

-- Boot the addon in `mode`, standing in the delve with the boss targetable.
function M.setup(mode, extraDB)
	local db = { mode = mode or "auto" }
	for k, v in pairs(extraDB or {}) do db[k] = v end
	local ns = addon.boot({ db = db })
	M.inDelve(ns)
	M.placeIn(ns, "N")
	wow.hostile.boss1 = true
	wow.hostile.nameplate1 = true
	return ns
end

function M.pull(ns, encounterID)
	wow.fire("ENCOUNTER_START", encounterID or ns.ENCOUNTERS[1].id, "Azta'rec", 2, 5)
	return ns
end

function M.hitAt(ns, i)
	local grid = ns.Detector.ActiveGrid()
	return grid.first + grid.spacing * (i - 1)
end

-- Run a full wave channel with the player standing in each listed quadrant
-- across that wave's hit window. Ends just after the final hit, as the real
-- channel does, so the measured length fits the grid exactly.
function M.channel(ns, quadrants, unit)
	unit = unit or "boss1"
	local last = M.hitAt(ns, #quadrants) + 0.46

	wow.fire("UNIT_SPELLCAST_CHANNEL_START", unit)
	local now = 0
	for i, quadrant in ipairs(quadrants) do
		M.placeIn(ns, quadrant)
		local until_ = math.min(M.hitAt(ns, i) + 0.75, last)
		if until_ > now then
			wow.advance(until_ - now)
			now = until_
		end
	end
	if last > now then wow.advance(last - now) end
	wow.fire("UNIT_SPELLCAST_CHANNEL_STOP", unit)
end

-- One silent repeat from the boss, spaced past the replay throttle. `gap` sets
-- how long to wait first, for tests that care about the real ~3s wave spacing.
function M.echo(ns, unit, gap)
	wow.advance(gap or 1.2)
	wow.fire("UNIT_SPELLCAST_START", unit or "boss1")
end

-- Record a run and leave the addon sitting at the start of the replay.
function M.recordRun(ns, quadrants)
	M.pull(ns)
	M.channel(ns, quadrants)
	return ns
end

return M
