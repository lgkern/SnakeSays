local _, ns = ...

-- ===========================================================================
-- Sim.lua  ·  practice run, anywhere.
--
-- `/ss sim` makes up a run, shows it going onto the board one wave at a time,
-- then calls it back with the real voice and popup. Nothing to move to and
-- nothing to press -- this is for checking that the announcements work and for
-- placing the windows.
--
-- It drives the shipped detector through the same replay seam the boss does, so
-- what is heard and seen here is what happens in the delve.
-- ===========================================================================

local Sim = {}
ns.Sim = Sim

local DEFAULT_WAVES = 5  -- the opening phase; it grows to 6 and 7 as the boss drops
local MAX_WAVES = 12
local LEAD_IN = 3        -- seconds of warning before anything happens
local REVEAL_GAP = 0.8   -- seconds between waves while the run is shown
local ECHO_GAP = 3       -- seconds between silent repeats

local running = false
local timers = {}

local function cancelTimers()
	for _, timer in ipairs(timers) do
		if timer and timer.Cancel then timer:Cancel() end
	end
	wipe(timers)
end

local function at(delay, fn)
	timers[#timers + 1] = C_Timer.NewTimer(delay, fn)
end

-- The single way out. Every ending -- stopped by hand, run to completion, or
-- abandoned before it started -- goes through here, so nothing the run borrowed
-- can be left behind: the window visibility and the declared wave count.
--
-- The made-up run itself stays on the board on purpose, to be looked at after
-- the fact; the next pull clears it (see arm()). Only what was *borrowed* is
-- handed back here.
local function tearDown()
	running = false
	cancelTimers()
	ns.SetVisibilityOverride(false)
	ns.Detector.SetExpectedWaves(nil)
end

function Sim.IsRunning() return running end

function Sim.Stop(quiet)
	if not running then return false end
	tearDown()
	ns.Detector.EndReplay()
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

	running = true
	cancelTimers()

	-- The run happens out in the world, where the map restriction normally keeps
	-- the board hidden. Lift it for the duration.
	ns.SetVisibilityOverride(true)

	ns.Detector.Reset()
	return waves
end

-- Queue one silent repeat per wave, then tidy up after the last call has had
-- time to land.
--
-- Each call says when its wave lands before stepping, which during a real pull
-- is read off the boss' cast. Nothing downstream can tell the difference, and
-- the timeline's scanning bar has a span to travel -- without it the drill would
-- show a bar that never moves, which is the one thing the drill is for.
local function queueReplay(startAt, waves)
	for wave = 1, waves do
		at(startAt + ECHO_GAP * (wave - 1), function()
			ns.Detector.SetCastEnd(GetTime() + ECHO_GAP)
			ns.Detector.Advance()
		end)
	end
	at(startAt + ECHO_GAP * waves + 4, function()
		if running then
			tearDown()
			ns.Detector.EndReplay()
			ns.Print("practice run finished.")
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Demo run: made-up sequence, no running about required
-- ---------------------------------------------------------------------------

-- No wave repeats the one before it. A doubled call is the one case where
-- following the addon correctly means standing still, which is both the least
-- useful thing to rehearse and the easiest to misread as a missed call. The
-- recorder still handles a real doubled wave; this is only about what makes a
-- worthwhile drill.
local function makeRun(waves)
	local run = {}
	local previous
	for i = 1, waves do
		local choices = {}
		for _, quadrant in ipairs(ns.QUADRANTS) do
			if quadrant ~= previous then choices[#choices + 1] = quadrant end
		end
		previous = choices[math.random(#choices)]
		run[i] = previous
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


	-- Declare the length up front, the way a real round's aura does, so the
	-- timeline lays out its rests and the practice run rehearses the whole thing
	-- rather than a staff that grows a slot at a time.
	ns.Detector.SetExpectedWaves(#run)

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

-- `/ss sim`, `/ss sim 7`, `/ss sim stop`.
function Sim.Start(arg)
	arg = tostring(arg or ""):lower()
	return Sim.StartDemo(arg ~= "" and tonumber(arg) or nil)
end
