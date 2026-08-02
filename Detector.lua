local _, ns = ...

-- ===========================================================================
-- Detector.lua  ·  the encounter state machine.
--
-- The fight has two halves. First the boss channels a run of waves, each
-- leaving exactly one quadrant safe -- that half is visible, so the addon (or
-- the player) records where they stood. Then the boss repeats the same run
-- silently, one cast per wave, and the recording is read back.
--
--   ENCOUNTER_START            arm, pick the wave grid, clear any stale run
--   UNIT_SPELLCAST_CHANNEL_START   the visible half begins -> start sampling
--   UNIT_SPELLCAST_CHANNEL_STOP    the visible half ends   -> lock the run
--   UNIT_SPELLCAST_START           one silent repeat       -> advance a step
--   ENCOUNTER_END              disarm and forget everything
--
-- Wave timing
-- -----------
-- Waves land on a fixed grid measured from the channel's start: the first at
-- `first` seconds, the rest every `spacing` after it. The channel then trails
-- off ~0.46s past the final wave. That trail makes the channel's own length
-- identify the grid, which is the fallback when the encounter id is unfamiliar.
--
-- Rather than reading the player's position once per wave, the sampler runs
-- continuously and each wave takes the *majority* quadrant across a window
-- around its hit. Sampling once would record whichever wedge the player happened
-- to be crossing at that instant; the vote records where they actually stood.
-- ===========================================================================

local Detector = {}
ns.Detector = Detector

-- Encounter ids per difficulty. The name check in ENCOUNTER_START covers the
-- case where these are renumbered out from under us.
ns.ENCOUNTERS = {
	{ id = 3508, label = "normal", grid = { first = 3.04, spacing = 3.50 } },
	{ id = 3525, label = "hard",   grid = { first = 2.50, spacing = 3.01 } },
}

local BOSS_NAME_PATTERN = "Azta"

local SAMPLE_INTERVAL = 0.2    -- how often the player's quadrant is read
local VOTE_HALF       = 0.7    -- majority window each side of a wave's hit
local LOCK_DELAY      = 0.7    -- lock a wave this long after its hit lands
local CHANNEL_TRAIL   = 0.46   -- channel keeps going this long past the last wave
local MIN_CHANNEL     = 8      -- shorter than this was never the wave mechanic
local MAX_WAVES       = 20     -- matches the sequence cap
local GRID_TOLERANCE  = 0.3    -- how far a channel may sit off a grid and still fit
local ECHO_THROTTLE   = 1      -- ignore repeat casts closer together than this
local REPLAY_LINGER   = 10     -- clear the board this long after the last echo

local grid = ns.ENCOUNTERS[1].grid

local armed      = false
local channelUnit                -- the unit token running the wave channel
local sampler                    -- the position ticker, while recording
local channelStart = 0
local waveIndex    = 0           -- next wave awaiting a lock
local samples      = {}          -- { { t = seconds into the channel, q = quadrant } }
local locked       = {}          -- waveIndex -> quadrant

local replaying    = false
local echoIndex    = 0
local lastEchoAt   = 0
local replayTimer
local lastCaptureAt = 0

local replayListeners = {}
local replayEndListeners = {}

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function hitTime(i)
	return grid.first + grid.spacing * (i - 1)
end

function Detector.ActiveGrid() return grid end
function Detector.IsArmed() return armed end
function Detector.IsRecording() return sampler ~= nil end
function Detector.IsReplaying() return replaying end
function Detector.EchoIndex() return echoIndex end

function Detector.OnReplayStep(fn)
	replayListeners[#replayListeners + 1] = fn
end

local function notifyReplay(index, current, nextUp)
	for _, fn in ipairs(replayListeners) do
		pcall(fn, index, current, nextUp)
	end
end

-- Fired once when a replay stops, however it stopped: the run finished and
-- lingered out, the encounter ended, or a fresh channel started over the top.
function Detector.OnReplayEnd(fn)
	replayEndListeners[#replayEndListeners + 1] = fn
end

local function notifyReplayEnd()
	for _, fn in ipairs(replayEndListeners) do
		pcall(fn)
	end
end

-- Boss casts arrive on nameplate units only when enemy nameplates are switched
-- on; boss frames fire either way. Accept both, and let the channel-unit filter
-- drop the duplicate when a cast shows up on two tokens at once.
local function isHostileUnit(unit)
	if type(unit) ~= "string" then return false end
	if unit:match("^boss%d$") then return true end
	if not unit:match("^nameplate%d+$") then return false end
	local ok, hostile = pcall(UnitCanAttack, "player", unit)
	if not ok or issecretvalue(hostile) then return false end
	return hostile and true or false
end

local function stopSampler()
	if sampler then
		sampler:Cancel()
		sampler = nil
	end
end

local function cancelReplayTimer()
	if replayTimer then
		replayTimer:Cancel()
		replayTimer = nil
	end
end

-- ---------------------------------------------------------------------------
-- Recording
-- ---------------------------------------------------------------------------

-- The quadrant the player spent most of a wave's window in. Ties go to whichever
-- they were in most recently, since that is where they ended up standing.
local function voteQuadrant(hitAt)
	local from, to = hitAt - VOTE_HALF, hitAt + VOTE_HALF
	local counts, latest = {}, {}
	for _, sample in ipairs(samples) do
		if sample.q and sample.t >= from and sample.t <= to then
			counts[sample.q] = (counts[sample.q] or 0) + 1
			latest[sample.q] = sample.t
		end
	end
	local best
	for quadrant, count in pairs(counts) do
		if not best or count > counts[best]
			or (count == counts[best] and latest[quadrant] > latest[best]) then
			best = quadrant
		end
	end
	return best
end

local function lockWave(i)
	local quadrant = voteQuadrant(hitTime(i)) or ns.Position.Quadrant()
	if not quadrant then return false end
	locked[i] = quadrant
	ns.Seq.Record(quadrant)
	if ns.HUD then pcall(ns.HUD.Flash, quadrant) end
	return true
end

local function clearRun()
	local wasReplaying = replaying
	stopSampler()
	cancelReplayTimer()
	channelUnit = nil
	waveIndex = 0
	replaying = false
	echoIndex = 0
	lastEchoAt = 0
	wipe(samples)
	wipe(locked)
	if wasReplaying then notifyReplayEnd() end
end

-- A wave we can't resolve makes everything after it a lie: the replay reads the
-- sequence by index, so a missing entry shifts every later call onto the wrong
-- wave. Throw the whole run away and say so rather than call the fight wrong.
local function abortRecording()
	clearRun()
	ns.Seq.Reset()
	ns.Print("|cffff5555lost your position during a wave|r - nothing recorded for this pull.")
end

-- A channel has begun. Every mode clears the previous phase and remembers which
-- unit is channelling; only automatic mode also samples position, since in the
-- other two the player supplies the quadrants themselves.
local function beginChannel(unit)
	clearRun()
	ns.Seq.Reset()
	channelUnit = unit
	channelStart = GetTime()
	waveIndex = 1

	if ns.GetMode() ~= "auto" then return end

	-- The wave count isn't known up front -- the run grows with the pull -- so
	-- the sampler simply keeps going until the channel actually stops.
	sampler = C_Timer.NewTicker(SAMPLE_INTERVAL, function()
		if waveIndex > MAX_WAVES then return end
		local elapsed = GetTime() - channelStart
		samples[#samples + 1] = { t = elapsed, q = ns.Position.Quadrant() }
		if elapsed >= hitTime(waveIndex) + LOCK_DELAY then
			if not lockWave(waveIndex) then
				abortRecording()
				return
			end
			waveIndex = waveIndex + 1
		end
	end)
end

-- How far `elapsed` sits from this grid's nearest whole-wave channel length.
local function gridFitError(candidate, elapsed)
	local waves = math.floor((elapsed - CHANNEL_TRAIL - candidate.first) / candidate.spacing + 0.5) + 1
	if waves < 1 then waves = 1 end
	return math.abs(candidate.first + (waves - 1) * candidate.spacing + CHANNEL_TRAIL - elapsed)
end

-- If the channel we just measured doesn't fit the grid the encounter id chose,
-- try the others and re-vote from the stored samples. The samples span the whole
-- channel, so nothing is lost by re-deciding the wave times after the fact.
local function refitGrid(elapsed)
	if gridFitError(grid, elapsed) <= GRID_TOLERANCE then return false end
	local best, bestError
	for _, encounter in ipairs(ns.ENCOUNTERS) do
		local err = gridFitError(encounter.grid, elapsed)
		if not bestError or err < bestError then best, bestError = encounter.grid, err end
	end
	if best == grid or bestError > GRID_TOLERANCE then return false end
	grid = best
	return true
end

-- The sampled half of finishing a channel. Returns false if the run was thrown
-- away and there is nothing to replay.
local function finishSampledChannel(elapsed)
	stopSampler()

	if elapsed < MIN_CHANNEL then
		-- Something other than the wave mechanic slipped through the filters, or
		-- the boss died mid-channel. Discard rather than replay a partial run.
		-- Only the sampler is held to this: a player pressing deliberately meant
		-- every press, however short the channel turned out to be.
		clearRun()
		ns.Seq.Reset()
		return false
	end

	if refitGrid(elapsed) then
		ns.Seq.Reset()
		wipe(locked)
		waveIndex = 1
	end

	-- Lock every wave whose hit already landed: the last one arrives just before
	-- the channel stops, too late for the sampler's lock delay to have fired.
	-- The cutoff sits inside the trail, so a wave that never happened can't be
	-- mistaken for one that did (the next hit is a full spacing away).
	while waveIndex <= MAX_WAVES and hitTime(waveIndex) <= elapsed - (CHANNEL_TRAIL - 0.16) do
		if not locked[waveIndex] then
			if not lockWave(waveIndex) then
				abortRecording()
				return false
			end
		end
		waveIndex = waveIndex + 1
	end

	return true
end

-- The channel is over, so whatever was recorded during it is the run. This is
-- the only path into the replay, and it must work in every mode -- the boss
-- repeats the waves whether the addon recorded them or the player did.
local function finishChannel()
	if not channelUnit then return end
	local elapsed = GetTime() - channelStart

	if sampler and not finishSampledChannel(elapsed) then return end

	if ns.Seq.Count() > 0 then
		Detector.BeginReplay()
	else
		clearRun()
	end
end

-- ---------------------------------------------------------------------------
-- Replay
-- ---------------------------------------------------------------------------

function Detector.BeginReplay()
	if ns.Seq.Count() == 0 then return false end
	cancelReplayTimer()
	replaying = true
	echoIndex = 0
	lastEchoAt = 0
	return true
end

local function advanceReplay()
	local list = ns.Seq.Get()
	if not replaying or echoIndex >= #list then return end

	local now = GetTime()
	if now - lastEchoAt < ECHO_THROTTLE then return end
	lastEchoAt = now

	echoIndex = echoIndex + 1
	notifyReplay(echoIndex, list[echoIndex], list[echoIndex + 1])

	if echoIndex >= #list then
		-- Last repeat resolved: leave it on screen a moment, then clear.
		cancelReplayTimer()
		replayTimer = C_Timer.NewTimer(REPLAY_LINGER, function()
			replayTimer = nil
			clearRun()
			ns.Seq.Reset()
		end)
	end
end

-- ---------------------------------------------------------------------------
-- Semi-automatic capture
-- ---------------------------------------------------------------------------

-- The player says when; the addon says where. Throttled so a double tap can't
-- write two waves.
function Detector.Capture()
	local now = GetTime()
	if now - lastCaptureAt < 0.5 then return false end

	local quadrant = ns.Position.Quadrant()
	if not quadrant then
		ns.Print("|cffff5555could not read your position|r - nothing captured.")
		return false
	end

	lastCaptureAt = now
	if not ns.Seq.Record(quadrant) then return false end
	if ns.HUD then pcall(ns.HUD.Flash, quadrant) end
	return true
end

function Detector.Reset()
	clearRun()
	ns.Seq.Reset()
end

-- ---------------------------------------------------------------------------
-- Events
--
-- Every branch runs inside a pcall: these fire in combat, and an error escaping
-- here would break the handler for the rest of the pull.
-- ---------------------------------------------------------------------------

local function onEncounterStart(id, name)
	local match
	for _, encounter in ipairs(ns.ENCOUNTERS) do
		if encounter.id == id then match = encounter break end
	end
	if not match and not (type(name) == "string" and name:find(BOSS_NAME_PATTERN)) then
		return
	end
	armed = true
	grid = match and match.grid or ns.ENCOUNTERS[1].grid
	Detector.Reset()
	ns.Position.Verify()
end

local function onChannelStart(unit)
	if not armed or not isHostileUnit(unit) then return end

	if channelUnit and unit ~= channelUnit then
		-- Only the boss channels this, so the same channel arriving on a second
		-- token is the same unit. Adopt the boss token if that is the new one --
		-- boss frames survive the whole fight, nameplates can drop out -- and
		-- otherwise leave the recording in progress alone.
		if unit:match("^boss%d$") and not channelUnit:match("^boss%d$") then
			channelUnit = unit
		end
		return
	end
	beginChannel(unit)
end

local function onChannelStop(unit)
	if not armed or not isHostileUnit(unit) then return end
	if channelUnit and unit ~= channelUnit then return end
	finishChannel()
end

local function onCastStart(unit)
	if not armed or not isHostileUnit(unit) then return end
	if channelUnit and unit ~= channelUnit then return end
	advanceReplay()
end

-- Public so the practice simulator can drive the same state machine the client
-- drives, rather than a parallel one that could drift out of step with it.
function Detector.HandleEvent(event, ...)
	pcall(function(...)
		if event == "ENCOUNTER_START" then
			onEncounterStart(...)
		elseif event == "ENCOUNTER_END" then
			armed = false
			clearRun()
		elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
			onChannelStart(...)
		elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
			onChannelStop(...)
		elseif event == "UNIT_SPELLCAST_START" then
			onCastStart(...)
		end
	end, ...)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ENCOUNTER_START")
events:RegisterEvent("ENCOUNTER_END")
events:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
events:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
events:RegisterEvent("UNIT_SPELLCAST_START")
events:SetScript("OnEvent", function(_, event, ...)
	Detector.HandleEvent(event, ...)
end)
