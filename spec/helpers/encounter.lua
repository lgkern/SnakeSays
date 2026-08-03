-- ===========================================================================
-- spec/helpers/encounter.lua  ·  drives a pull the way the client does.
--
-- Nothing here reaches into the addon to set up an outcome. It fires the events
-- a real fight fires -- ENCOUNTER_START, the boss' aura going on and coming off,
-- one cast per wave -- moves the player around between them, and leaves the
-- addon to work out for itself what happened. A test that stages the answer
-- proves the function works; this proves the fight reaches it.
-- ===========================================================================

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

local M = {}

M.NORMAL = 3508
M.HARD   = 3525

M.SERMON       = "Sermon of Ula'tek"
M.SERMON_SPELL = 1306239
M.ECHO         = 1288125

-- Slot length per difficulty, from the recorded aura durations.
M.SLOT = { [M.NORMAL] = 3.503, [M.HARD] = 3.003 }

-- Observed cast lengths. Normal held one value across every logged cast; hard
-- sits on one of two and switches part way through a round.
M.CAST = { normal = 3.005, hardSlow = 3.64, hardFast = 3.31 }

-- The room, as the addon's author measured it.
M.CENTER = { a = 181.80, b = 0.60 }

-- How far out the player stands. Every sample in a logged hard round sat
-- between 5 and 11 yards from the centre, so this is the middle of that.
local STAND = 8

local OFFSET = {
	N = {  STAND, 0 },
	S = { -STAND, 0 },
	W = { 0,  STAND },
	E = { 0, -STAND },
}

local BOSS_GUID = "Creature-0-0-3079-0-224001-0000AZTA"
local ADD_GUID  = "Creature-0-0-3079-0-224002-0000ADD1"

-- ---------------------------------------------------------------------------
-- Standing somewhere
-- ---------------------------------------------------------------------------

-- Walk into the delve, zone event and all -- which is what the windows and the
-- mode prompt actually watch for.
function M.inDelve(ns)
	wow.instanceMapID = ns.ROOM.instanceMapID
	wow.zoneText = "Venomfall Deeps"
	wow.uiMapID = ns.ROOM.uiMapID
	wow.fire("ZONE_CHANGED_NEW_AREA")
end

-- Move the player into `quadrant`, or to the middle of the room when nil.
-- Offsets are taken from whatever centre the addon is currently working with, so
-- an unmeasured room puts the player where the real one is.
function M.standAt(ns, quadrant)
	local center = ns.GetRoomCenter() or M.CENTER
	local offset = quadrant and OFFSET[quadrant] or { 0, 0 }
	wow.setPosition(center.a + offset[1], center.b + offset[2], 0, ns.ROOM.instanceMapID)
end

-- Stand in the middle of the room and run `/ss measure`, which is the only way
-- the addon ever gets a room centre.
function M.measure(ns)
	M.standAt(ns, nil)
	wow.slash("SNAKESAYS", "measure")
	return ns
end

-- Boot the addon in `mode`, standing in the middle of the delve.
function M.setup(mode, extraDB)
	local db = { mode = mode or "auto" }
	for k, v in pairs(extraDB or {}) do db[k] = v end
	local ns = addon.boot({ db = db })
	M.inDelve(ns)
	wow.setPosition(M.CENTER.a, M.CENTER.b, 0, ns.ROOM.instanceMapID)
	wow.hostile.boss1 = true
	wow.hostile.nameplate1 = true
	wow.guids.boss1 = BOSS_GUID
	wow.guids.boss2 = ADD_GUID
	wow.guids.nameplate1 = BOSS_GUID
	return ns
end

-- Boot, measure the room, and walk in. The usual starting point for a test that
-- cares about what the addon reads rather than about it having nothing to read.
function M.ready(mode, extraDB)
	local ns = M.setup(mode, extraDB)
	M.measure(ns)
	return ns
end

-- ---------------------------------------------------------------------------
-- A pull
-- ---------------------------------------------------------------------------

function M.pull(ns, encounterID, name)
	wow.fire("ENCOUNTER_START", encounterID or M.HARD, name or "Azta'rec", 152, 5)
	return ns
end

function M.wipe(ns, encounterID)
	wow.fire("ENCOUNTER_END", encounterID or M.HARD, "Azta'rec", 152, 5, 0)
	return ns
end

function M.kill(ns, encounterID)
	wow.fire("ENCOUNTER_END", encounterID or M.HARD, "Azta'rec", 152, 5, 1)
	return ns
end

-- ---------------------------------------------------------------------------
-- The showing half
-- ---------------------------------------------------------------------------

-- Walk the player through one round. `path` is the quarter they settle in for
-- each wave, one entry per wave.
--
-- They arrive part way through each slot rather than teleporting at its start,
-- which is what a player actually does and what the end-weighting exists for:
-- at the default they spend the first half of the slot still in the quarter they
-- came from. `opts.arriveAt` moves that crossing point (0 = there from the off,
-- 0.9 = only just made it).
--
-- opts:
--   difficulty  M.NORMAL or M.HARD, which picks the slot length (default hard)
--   slot        seconds per slot, overriding the difficulty's
--   length      override the aura duration, for rounds that are not whole
--   arriveAt    fraction of the slot spent still in the previous quarter
--   unit        which boss carries the aura (default boss1)
-- `opts.via` picks how the boss carries the round:
--   "channel"  what retail actually does, and the default
--   "aura"     the aura the spec describes, for the client that will answer it
function M.beginSermon(unit, length, opts)
	if (opts.via or "channel") == "aura" then
		wow.applyAura(unit, M.SERMON, length, opts)
	else
		wow.startChannel(unit, M.SERMON_SPELL, length, opts)
	end
end

function M.endSermon(unit, opts)
	if (opts.via or "channel") == "aura" then
		wow.removeAura(unit, M.SERMON, opts)
	else
		wow.stopChannel(unit, opts)
	end
end

function M.showRound(ns, path, opts)
	opts = opts or {}
	local unit = opts.unit or "boss1"
	local slot = opts.slot or M.SLOT[opts.difficulty or M.HARD]
	local arriveAt = opts.arriveAt or 0.5
	local length = opts.length or slot * #path
	local step = length / #path      -- the walk always covers the whole round

	M.beginSermon(unit, length, opts)

	for _, quadrant in ipairs(path) do
		wow.advance(step * arriveAt)
		M.standAt(ns, quadrant)
		wow.advance(step * (1 - arriveAt))
	end

	M.endSermon(unit, opts)
	return ns
end

-- A round the boss starts and something cuts off part way through -- a wipe, a
-- kill, anything. The aura goes away mid-slot, which is the tell.
function M.showRoundCutShort(ns, path, after, opts)
	opts = opts or {}
	local unit = opts.unit or "boss1"
	local slot = opts.slot or M.SLOT[opts.difficulty or M.HARD]

	M.beginSermon(unit, opts.length or slot * #path, opts)
	local spent = 0
	for _, quadrant in ipairs(path) do
		if spent + slot > after then break end
		wow.advance(slot * 0.5)
		M.standAt(ns, quadrant)
		wow.advance(slot * 0.5)
		spent = spent + slot
	end
	wow.advance(math.max(0, after - spent))
	M.endSermon(unit, opts)
	return ns
end

-- ---------------------------------------------------------------------------
-- The calling half
-- ---------------------------------------------------------------------------

-- One Echo cast per wave. `opts.castTime` may be a single number or a list, for
-- the hard rounds where the cast length changes part way through.
--
-- `opts.echoOn` sends the same cast out on extra unit tokens as well, which is
-- what the client does when the boss is also the player's target.
function M.callRound(ns, count, opts)
	opts = opts or {}
	local unit = opts.unit or "boss1"
	for wave = 1, count do
		local castTime = opts.castTime
		if type(castTime) == "table" then castTime = castTime[wave] or castTime[#castTime] end
		castTime = castTime or M.CAST.normal

		local guid = wow.startCast(unit, M.ECHO, castTime, {
			castGUID = opts.castGUID,
			secret   = opts.secret,
			nameless = opts.nameless,
		})
		for _, extra in ipairs(opts.echoOn or {}) do
			wow.casts[extra] = wow.casts[unit]
			wow.fire("UNIT_SPELLCAST_START", extra, guid, M.ECHO)
		end

		wow.advance(castTime)
		if opts.moveTo then M.standAt(ns, ns.Seq.Get()[wave]) end
		wow.advance(opts.gap or 0.4)
	end
	return ns
end

-- A whole round, both halves, the way the fight runs it: the aura comes off in
-- the same instant the first call begins.
function M.round(ns, path, opts)
	opts = opts or {}
	M.showRound(ns, path, opts)
	M.callRound(ns, opts.calls or #path, opts)
	return ns
end

-- ---------------------------------------------------------------------------
-- Staging a replay without a fight
--
-- For the tests downstream of the recorder -- the voice, the popup, the board --
-- which care about what a replay does, not about how it got started.
-- ---------------------------------------------------------------------------

function M.recordRun(ns, quadrants)
	ns.Seq.Reset()
	for _, quadrant in ipairs(quadrants) do
		ns.Seq.Record(quadrant)
	end
	ns.Detector.BeginReplay()
	return ns
end

-- One step of the replay. `gap` waits first, for tests that care about waves
-- arriving a few seconds apart.
function M.echo(ns, gap)
	wow.advance(gap or 1.2)
	ns.Detector.Advance()
end

return M
