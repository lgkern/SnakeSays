local _, ns = ...

-- ===========================================================================
-- Sim.lua  ·  practice run, anywhere.
--
-- Two shapes, because there are two different things worth rehearsing:
--
--   /ss sim          makes up a run, shows it going onto the board, then calls
--                    it back with the real voice, bell, radar and popup. You
--                    don't have to move -- this is for checking that the
--                    announcements work and for placing the windows.
--   /ss sim record   records the run from where you actually stand, the way a
--                    real pull does. You become the centre of the room, so walk
--                    around during the wave phase.
--
-- Both drive the shipped detector through the same events the client fires, so
-- what happens here is what happens in the delve.
--
-- Two concessions to running outside the room: the room centre is temporarily
-- re-pinned to wherever the player is standing (so "north of centre" means north
-- of them, and the radar and bell have something to measure against), and the
-- boss unit token is faked. The original centre is put back when the run ends,
-- however it ends.
-- ===========================================================================

local Sim = {}
ns.Sim = Sim

local UNIT = "boss1"
local DEFAULT_WAVES = 5  -- the opening phase; it grows to 6 and 7 as the boss drops
local MAX_WAVES = 12
local LEAD_IN = 3        -- seconds of warning before anything happens
local REVEAL_GAP = 0.8   -- seconds between waves while the run is shown
local ECHO_GAP = 3       -- seconds between silent repeats

local running = false
local timers = {}
local savedCenter
local centerWasStored

local function cancelTimers()
	for _, timer in ipairs(timers) do
		if timer and timer.Cancel then timer:Cancel() end
	end
	wipe(timers)
end

local function at(delay, fn)
	timers[#timers + 1] = C_Timer.NewTimer(delay, fn)
end

-- Put the real room centre back exactly as it was: absent if the player had
-- never measured one, otherwise the value they measured.
local function restoreCenter()
	if centerWasStored then
		ns.db().roomCenter = savedCenter
	else
		ns.db().roomCenter = nil
	end
	savedCenter, centerWasStored = nil, nil
end

-- The single way out. Every ending -- stopped by hand, run to completion, or
-- abandoned before it started -- goes through here, so the borrowed room centre
-- and the borrowed window visibility can't be left behind.
local function tearDown()
	running = false
	cancelTimers()
	restoreCenter()
	ns.SetVisibilityOverride(false)
end

function Sim.IsRunning() return running end

function Sim.Stop(quiet)
	if not running then return false end
	tearDown()
	ns.Detector.HandleEvent("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
	if not quiet then ns.Print("practice run stopped.") end
	return true
end

-- ---------------------------------------------------------------------------
-- Shared setup
-- ---------------------------------------------------------------------------

local function begin(waves)
	if running then
		ns.Print("a practice run is already going - /ss sim stop to end it.")
		return nil
	end

	waves = tonumber(waves) or DEFAULT_WAVES
	if waves < 1 then waves = 1 elseif waves > MAX_WAVES then waves = MAX_WAVES end

	-- Re-pin the centre to the player's feet so quadrants mean something here.
	if not ns.Position.IsAvailable() then
		ns.Print("|cffff5555could not read your position|r - cannot start a practice run.")
		return nil
	end
	savedCenter = ns.db().roomCenter
	centerWasStored = savedCenter ~= nil
	ns.Position.MeasureCenter()

	running = true
	cancelTimers()

	-- The run happens out in the world, where the map restriction normally keeps
	-- the board and the radar hidden. Lift it for the duration.
	ns.SetVisibilityOverride(true)

	ns.Detector.HandleEvent("ENCOUNTER_START", ns.ENCOUNTERS[1].id, "Azta'rec (practice)")
	return waves
end

-- Queue one silent repeat per wave, then tidy up after the last call has had
-- time to land.
local function queueReplay(startAt, waves)
	for wave = 1, waves do
		at(startAt + ECHO_GAP * (wave - 1), function()
			ns.Detector.HandleEvent("UNIT_SPELLCAST_START", UNIT)
		end)
	end
	at(startAt + ECHO_GAP * waves + 4, function()
		if running then
			tearDown()
			ns.Print("practice run finished.")
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Demo run: made-up sequence, no running about required
-- ---------------------------------------------------------------------------

local function makeRun(waves)
	local run = {}
	for i = 1, waves do
		run[i] = ns.QUADRANTS[math.random(#ns.QUADRANTS)]
	end
	return run
end

local function describeRun(run)
	local parts = {}
	for i, quadrant in ipairs(run) do
		parts[i] = ns.QuadrantLabel(quadrant)
	end
	return table.concat(parts, " > ")
end

function Sim.StartDemo(waves, forcedRun)
	waves = begin(waves)
	if not waves then return false end

	local run = forcedRun or makeRun(waves)
	Sim.lastRun = run

	ns.Print(("practice run: |cffffd200%d waves|r. Watch them go onto the board, "):format(#run)
		.. "then follow the calls.")
	ns.Print("the run will be: |cffffd200" .. describeRun(run) .. "|r")
	ns.Print("/ss sim stop ends it early.")

	-- Reveal the run one wave at a time, so the board fills the way it does
	-- during a real channel rather than appearing all at once.
	for i, quadrant in ipairs(run) do
		at(LEAD_IN + REVEAL_GAP * (i - 1), function()
			ns.Seq.Record(quadrant)
			if ns.HUD then pcall(ns.HUD.Flash, quadrant) end
		end)
	end

	local replayAt = LEAD_IN + REVEAL_GAP * #run + 2
	at(replayAt - 1, function()
		ns.Print("|cffffd200repeat phase|r - move to each colour as it is called.")
		ns.Detector.BeginReplay()
	end)
	queueReplay(replayAt, #run)
	return true
end

-- ---------------------------------------------------------------------------
-- Recorded run: the real thing, driven by where the player stands
-- ---------------------------------------------------------------------------

function Sim.StartRecorded(waves)
	waves = begin(waves)
	if not waves then return false end

	local grid = ns.Detector.ActiveGrid()
	local channelLength = grid.first + grid.spacing * (waves - 1) + 0.46

	ns.Print(("practice run: |cffffd200%d waves|r starting in %ds. "):format(waves, LEAD_IN)
		.. "You are the centre of the room - walk around during the wave phase.")
	if ns.GetMode() == "semi" then
		ns.Print("press your |cffffd200Quadrant detection|r key once per wave.")
	elseif ns.GetMode() == "manual" then
		ns.Print("press a quadrant on the board once per wave.")
	end
	ns.Print("/ss sim stop ends it early.")

	at(LEAD_IN, function()
		ns.Print("|cff33ff99waves incoming|r - stand where you want to be for each one.")
		ns.Detector.HandleEvent("UNIT_SPELLCAST_CHANNEL_START", UNIT)
	end)

	at(LEAD_IN + channelLength, function()
		ns.Detector.HandleEvent("UNIT_SPELLCAST_CHANNEL_STOP", UNIT)
		if ns.Seq.Count() == 0 then
			ns.Print("|cffff5555nothing was recorded|r - you may not have moved off the centre.")
			tearDown()
			ns.Detector.HandleEvent("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
			return
		end
		ns.Print("|cffffd200repeat phase|r - follow the calls.")
	end)

	queueReplay(LEAD_IN + channelLength + 1.5, waves)
	return true
end

-- `/ss sim`, `/ss sim 7`, `/ss sim record`, `/ss sim record 7`, `/ss sim stop`.
function Sim.Start(arg)
	arg = tostring(arg or ""):lower()
	local mode, count = arg:match("^(%a*)%s*(%d*)$")
	if mode == "record" or mode == "live" then
		return Sim.StartRecorded(count ~= "" and count or nil)
	end
	return Sim.StartDemo(arg ~= "" and tonumber(arg) or nil)
end
