-- ===========================================================================
-- spec/helpers/encounter.lua  ·  drives a pull the way the client does.
--
-- Nothing here reaches into the addon to set up an outcome. It fires the events
-- a real fight fires -- ENCOUNTER_START, the boss' aura going on and coming off,
-- one cast per wave -- presses the board the way the player does between them,
-- and leaves the addon to work out for itself what happened. A test that stages
-- the answer proves the function works; this proves the fight reaches it.
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

local BOSS_GUID = "Creature-0-0-3079-0-224001-0000AZTA"
local ADD_GUID  = "Creature-0-0-3079-0-224002-0000ADD1"

-- ---------------------------------------------------------------------------
-- Being there
-- ---------------------------------------------------------------------------

-- Walk into the delve, zone event and all -- which is what the windows watch
-- for.
function M.inDelve(ns)
	wow.instanceMapID = ns.ROOM.instanceMapID
	wow.zoneText = "Venomfall Deeps"
	wow.uiMapID = ns.ROOM.uiMapID
	wow.fire("ZONE_CHANGED_NEW_AREA")
end

-- Walk back out, to somewhere the addon has no business in.
function M.leaveDelve()
	wow.instanceMapID = 0
	wow.zoneText = "Dornogal"
	wow.uiMapID = 0
	wow.fire("ZONE_CHANGED_NEW_AREA")
end

-- Boot the addon, standing in the delve with the boss units to hand.
function M.setup(extraDB)
	local db = {}
	for k, v in pairs(extraDB or {}) do db[k] = v end
	local ns = addon.boot({ db = db })
	M.inDelve(ns)
	wow.hostile.boss1 = true
	wow.hostile.nameplate1 = true
	wow.guids.boss1 = BOSS_GUID
	wow.guids.boss2 = ADD_GUID
	wow.guids.nameplate1 = BOSS_GUID
	return ns
end

-- Nothing to measure any more, so this is `setup` -- kept because most of the
-- suite reads better saying it is ready than saying it is set up.
M.ready = M.setup

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

-- Run one round. `path` is the quarter the player presses for each wave, one
-- entry per wave, pressed half way through its slot the way somebody watching
-- the wave actually would.
--
-- opts:
--   difficulty  M.NORMAL or M.HARD, which picks the slot length (default hard)
--   slot        seconds per slot, overriding the difficulty's
--   length      override the aura duration, for rounds that are not whole
--   silent      run the round without the player pressing anything
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
	local length = opts.length or slot * #path
	local step = length / #path      -- the presses always cover the whole round

	M.beginSermon(unit, length, opts)

	for _, quadrant in ipairs(path) do
		wow.advance(step * 0.5)
		if not opts.silent then ns.Seq.Press(quadrant) end
		wow.advance(step * 0.5)
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
		if not opts.silent then ns.Seq.Press(quadrant) end
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
