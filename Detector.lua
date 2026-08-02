local _, ns = ...

-- ===========================================================================
-- Detector.lua  ·  the encounter state machine.
--
-- The fight runs a memory game three times per pull. Each round has a showing
-- half, where waves cross the room and the player's quarter is the answer, and
-- a calling half, where the boss repeats the same run with no visual warning.
--
-- The showing half is invisible: no cast, no damage, no unit event per wave.
-- What it does have is an aura on the boss that lasts exactly one slot per
-- wave, so the round announces its own length the moment it starts. That is the
-- whole trick -- the round is cut into equal slots, and the player's quarter is
-- read at the end of each one.
--
-- The calling half is the opposite: one cast per wave, fully observable, and
-- the wave lands when the cast completes. So the showing half is driven by a
-- clock and the calling half is driven by events, and the two halves of this
-- file look nothing like each other on purpose.
--
--   ENCOUNTER_START ─ arm
--     UNIT_AURA (Sermon applied)   ─ round starts, length known, slots begin
--       ... sampled ...            ─ one board entry per slot as it closes
--     UNIT_AURA (Sermon removed)   ─ round ends; whole? keep it. short? bin it
--     UNIT_SPELLCAST_START (Echo)  ─ one call per cast, announced at cast start
--   ENCOUNTER_END   ─ disarm, forget the pull
--
-- The replay at the bottom is the seam the rest of the addon hangs off: Announce
-- and the room view subscribe to it at load, and the practice run drives it
-- directly. Nothing downstream knows or cares whether a step came from the boss
-- or from `/ss sim`.
-- ===========================================================================

local Detector = {}
ns.Detector = Detector

-- Encounter ids per difficulty. These are facts the client hands over in
-- ENCOUNTER_START, not measurements: the label is only used for reporting.
ns.ENCOUNTERS = {
	{ id = 3508, label = "normal" },
	{ id = 3525, label = "hard" },
}

-- The boss carries this while the waves are being shown, and drops it in the
-- same millisecond the first repeat begins. Matched by name deliberately: the
-- spell id changes between rounds on normal and stays put on hard, so it says
-- nothing at all about how long the round is. The duration does.
local SERMON_AURA = "Sermon of Ula'tek"

-- One cast per wave during the calling half. The wave lands when it completes,
-- which is what gives the player their warning window.
local ECHO_SPELL = 1288125

-- Seconds per wave slot: round length / slot = wave count. Starting points
-- only. The calling half reveals the true wave count, and learnSlot() overwrites
-- these from it (R3.4), so a wrong seed costs one round rather than the feature.
local SEED_SLOT = { normal = 3.503, hard = 3.003 }

-- How far a round's length may sit from a whole number of slots and still count
-- as a whole round. A wipe cuts the aura mid-slot; this is what catches it.
local SLOT_TOLERANCE = 0.20   -- in slots

-- How often the player's quarter is read while a round is being shown. Around
-- thirty readings per slot: enough to weight meaningfully, cheap enough to run
-- through a whole pull.
local SAMPLE_INTERVAL = 0.1

local MAX_WAVES = 12   -- the longest real round is seven; this is a sanity rail

local BOSS_UNIT = {}
for i = 1, 8 do BOSS_UNIT["boss" .. i] = true end

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local armed      = false
local difficulty            -- "normal" / "hard", or nil when armed by name only
local bossGUID              -- whichever boss is running our encounter

local showing               -- the round being shown, while its aura is up
local lastRound             -- the round whose calls are still coming in
local calls      = 0        -- Echo casts counted since the round started
local seenCasts  = {}       -- cast keys already handled (R5.5)

local castEndsAt            -- GetTime() at which the current call's wave lands
local sampler               -- position-sampling ticker
local endTimer              -- closes the replay when the last wave lands

local replaying  = false
local echoIndex  = 0

local replayListeners = {}
local replayEndListeners = {}

-- ---------------------------------------------------------------------------
-- Replay subscription
-- ---------------------------------------------------------------------------

function Detector.OnReplayStep(fn)
	replayListeners[#replayListeners + 1] = fn
end

local function notifyReplay(index, current, nextUp)
	for _, fn in ipairs(replayListeners) do
		pcall(fn, index, current, nextUp)
	end
end

-- Fired once when a replay stops, however it stopped.
function Detector.OnReplayEnd(fn)
	replayEndListeners[#replayEndListeners + 1] = fn
end

local function notifyReplayEnd()
	for _, fn in ipairs(replayEndListeners) do
		pcall(fn)
	end
end

-- ---------------------------------------------------------------------------
-- Replay state
-- ---------------------------------------------------------------------------

local function cancelEndTimer()
	if endTimer then
		endTimer:Cancel()
		endTimer = nil
	end
end

function Detector.BeginReplay()
	if ns.Seq.Count() == 0 then return false end
	replaying = true
	echoIndex = 0
	return true
end

-- Step to the next call. Whatever decides *when* a step happens lives outside
-- this function: the boss' casts during a pull, timers during a practice run.
function Detector.Advance()
	local list = ns.Seq.Get()
	if not replaying or echoIndex >= #list then return false end
	echoIndex = echoIndex + 1
	notifyReplay(echoIndex, list[echoIndex], list[echoIndex + 1])
	return true
end

function Detector.EndReplay()
	cancelEndTimer()
	castEndsAt = nil
	if not replaying then return false end
	replaying = false
	echoIndex = 0
	notifyReplayEnd()
	return true
end

function Detector.IsReplaying() return replaying end
function Detector.EchoIndex() return echoIndex end

-- When the wave being called right now lands, on the GetTime() clock. Read from
-- the live cast rather than assumed: on hard the cast runs at one of two lengths
-- and switches part way through a round, so anything with a number baked into it
-- is wrong by the last call.
function Detector.CastEndsAt() return castEndsAt end

-- ---------------------------------------------------------------------------
-- Slot length, and learning it
-- ---------------------------------------------------------------------------

local function slotLength(diff)
	local store = ns.db().slotLength
	local learned = store and store[diff]
	if type(learned) == "number" and learned > 0 then return learned end
	return SEED_SLOT[diff]
end

ns.SlotLength = slotLength

local function learnSlot(diff, value)
	if not diff or type(value) ~= "number" or value ~= value or value <= 0 then
		return false
	end
	local d = ns.db()
	d.slotLength = d.slotLength or {}
	d.slotLength[diff] = value
	return true
end

-- Wave count for a round of `length` seconds at `diff`'s slot length, plus the
-- slot used and how far off a whole number it landed. nil when the length is not
-- a whole number of slots, which is R2.4's cut-short case.
local function derive(length, diff)
	local slot = slotLength(diff)
	if not slot or slot <= 0 or not length or length <= 0 then return nil end
	local exact = length / slot
	local waves = math.floor(exact + 0.5)
	if waves < 1 or waves > MAX_WAVES then return nil end
	local err = math.abs(exact - waves)
	if err > SLOT_TOLERANCE then return nil end
	return waves, slot, err
end

-- The same, for a pull we armed on the encounter *name* and so cannot label.
-- Both slot lengths are tried and the cleaner fit wins; R3.4 corrects it from
-- the cast count either way, so a wrong guess here costs one round.
local function resolveRound(length)
	if difficulty then
		local waves, slot = derive(length, difficulty)
		return waves, slot, difficulty
	end

	local bestWaves, bestSlot, bestDiff, bestErr
	for _, encounter in ipairs(ns.ENCOUNTERS) do
		local waves, slot, err = derive(length, encounter.label)
		if waves and (not bestErr or err < bestErr) then
			bestWaves, bestSlot, bestDiff, bestErr = waves, slot, encounter.label, err
		end
	end
	return bestWaves, bestSlot, bestDiff
end

-- The calling half counts the waves for us, one cast each. Where that disagrees
-- with what the round length said, the slot length was wrong and can be fixed
-- from the two numbers we now both know (R3.4).
--
-- The two directions of disagreement are not worth the same, though:
--
--   more calls than expected   Proof. The boss casts once per wave, so a sixth
--                              call means there were at least six waves, whether
--                              or not the pull lived to see a seventh. Acting on
--                              it can only move the slot the right way.
--   fewer calls than expected  Ambiguous. Either the estimate was too high, or
--                              the group died before the rest of the calls
--                              arrived -- and dying in the calling half is the
--                              likeliest way to wipe on this boss. Treating that
--                              as a measurement writes a badly wrong slot into
--                              SavedVariables and costs the next pull a round.
--
-- So the second one only counts when something has proved the calling half is
-- over, which in practice means the next round's aura going up.
local function settleWaveCount(callingHalfEnded)
	local round = lastRound
	lastRound = nil
	if not round or calls <= 0 or calls == round.waves then return false end
	if calls < round.waves and not callingHalfEnded then return false end

	local corrected = round.length / calls
	if not learnSlot(round.difficulty, corrected) then return false end

	ns.Print(("wave timing corrected: %d waves called, %d expected. "):format(calls, round.waves)
		.. ("Slot is now |cffffd200%.3fs|r on %s."):format(corrected, round.difficulty))
	return true
end

-- ---------------------------------------------------------------------------
-- Reading the round
-- ---------------------------------------------------------------------------

local function stopSampler()
	if sampler then
		sampler:Cancel()
		sampler = nil
	end
end

-- Which quarter slot `index` belongs to, out of the readings taken during it.
--
-- Weighted towards the end of the slot, because that is where the wave lands
-- (R4.2.1). A reading counts as the square of how far through the slot it was
-- taken, so the second half of a slot outweighs the first half seven to one and
-- a player who only just makes it still reads as having made it. That is what
-- separates "walking through the north quarter" from "standing in it"; an even
-- weighting would call a player who crossed at half time by a coin toss, and a
-- flat ramp would call one who crossed late by a whisker.
--
-- Readings the client would not answer weigh in too, on their own side. The
-- winner has to have been seen for more of the slot than we were blind for,
-- which is what stops one stray reading on a slot boundary from deciding a slot
-- nobody could see -- and it puts the burden at the end of the slot, where the
-- weights are biggest and the wave actually lands.
local function resolveSlot(round, index)
	local from = (index - 1) * round.slot
	local span = round.slot
	local weight, blind = {}, 0
	local best, bestWeight = nil, 0

	for _, sample in ipairs(round.samples) do
		if sample.t > from and sample.t <= from + span then
			local through = (sample.t - from) / span
			local w = through * through
			if sample.q then
				local total = (weight[sample.q] or 0) + w
				weight[sample.q] = total
				if total > bestWeight then
					best, bestWeight = sample.q, total
				end
			else
				blind = blind + w
			end
		end
	end

	if bestWeight <= blind then return nil end
	return best
end

-- Give up on the round and say why. A run with a hole in it is worse than no
-- run: every later call would be shifted onto the wrong wave (R4.3).
local function abandonRound(round, reason)
	round.dead = true
	stopSampler()
	ns.Seq.Reset()
	ns.Print("|cffff5555" .. reason .. "|r Nothing recorded for this round.")
	-- Position going away entirely is the likeliest cause, and it is not
	-- something the player can fix by trying again.
	ns.Position.Verify()
end

-- Put every slot up to `upTo` on the board. Called as the round runs so the
-- board fills wave by wave (R4.4) rather than appearing all at once.
local function recordUpTo(round, upTo)
	if round.dead or not round.recording then return end
	if upTo > round.waves then upTo = round.waves end

	while round.recorded < upTo do
		local index = round.recorded + 1
		local quadrant = resolveSlot(round, index)
		if not quadrant then
			abandonRound(round, ("Wave %d could not be read."):format(index))
			return
		end

		-- Consecutive waves never use the same quarter, so this means the reading
		-- is wrong rather than that the boss repeated itself (R4.5). Said out loud
		-- and left on the board: the run is still the best evidence there is, and
		-- binning it would take the good waves with the bad one.
		if round.previous == quadrant then
			ns.Print(("|cffffd200waves %d and %d both read as %s|r - the boss never repeats a "):format(
				index - 1, index, ns.QUADRANT_NAME[quadrant])
				.. "quarter, so check the board against what you saw.")
		end

		round.recorded = index
		round.previous = quadrant
		ns.Seq.Record(quadrant)
	end
end

local function sample()
	local round = showing
	if not round or round.dead then return end

	local elapsed = GetTime() - round.startedAt
	round.samples[#round.samples + 1] = { t = elapsed, q = ns.Position.Quadrant() }

	if round.waves then
		recordUpTo(round, math.floor(elapsed / round.slot))
	end
end

-- ---------------------------------------------------------------------------
-- The showing half
-- ---------------------------------------------------------------------------

local function beginRound(aura, unit)
	-- A new round starting is the one thing that proves the previous round's
	-- calling half ran to its end, so this is where a disagreement in either
	-- direction can be trusted.
	settleWaveCount(true)
	Detector.EndReplay()
	stopSampler()

	-- Each round stands alone (R2.5).
	ns.Seq.Reset()
	calls = 0
	seenCasts = {}

	local declared = tonumber(aura and aura.duration)
	if declared and declared <= 0 then declared = nil end

	local round = {
		startedAt = GetTime(),
		unit      = unit,
		length    = declared,
		samples   = {},
		recorded  = 0,
		-- Only automatic mode reads the player's quarter for them. In the other
		-- two the round still runs -- it is what tells us the wave count and
		-- drives the calling half -- but the board is the player's to fill.
		recording = ns.GetMode() == "auto",
	}

	-- A declared duration lets the slots start closing while the round is still
	-- running. Without one -- or with one that is not a whole number of slots --
	-- the round is measured end to end and resolved in one go when the aura drops,
	-- which still works, just with a board that fills late.
	if declared then
		round.waves, round.slot, round.difficulty = resolveRound(declared)
	end

	showing = round
	sampler = C_Timer.NewTicker(SAMPLE_INTERVAL, sample)
	return round
end

local function endRound(cutShort)
	local round = showing
	if not round then return false end
	showing = nil
	stopSampler()

	local elapsed = GetTime() - round.startedAt
	local length = round.length or elapsed

	-- A whole round runs for exactly as long as its aura said it would. A wipe
	-- or a kill cuts the aura mid-slot, which shows up either as a length that
	-- is not a whole number of slots or as the aura going early (R2.4).
	if round.length and math.abs(elapsed - round.length) > (round.slot or SEED_SLOT.hard) * SLOT_TOLERANCE then
		cutShort = true
	end

	local waves, slot, diff = round.waves, round.slot, round.difficulty
	if not waves then
		waves, slot, diff = resolveRound(length)
	end
	if not waves then cutShort = true end

	if cutShort then
		if round.recording then ns.Seq.Reset() end
		lastRound = nil
		ns.Print("|cffff5555round cut short|r - discarding it.")
		return false
	end

	round.waves, round.slot, round.difficulty = waves, slot, diff
	recordUpTo(round, waves)

	-- Kept even when the recording failed: the calling half still counts the
	-- waves for us, and that is what corrects the slot length (R3.4).
	lastRound = { length = length, waves = waves, slot = slot, difficulty = diff }
	return true
end

-- ---------------------------------------------------------------------------
-- The calling half
-- ---------------------------------------------------------------------------

local function guidOf(unit)
	if type(UnitGUID) ~= "function" then return nil end
	local ok, guid = pcall(UnitGUID, unit)
	if not ok or type(guid) ~= "string" then return nil end
	return guid
end

-- The unit running our encounter. Once the Sermon has told us which boss that
-- is, everything else is filtered out by identity -- which is how the second
-- boss on hard is ignored (R5.3) rather than by hoping it never casts.
local function isOurBoss(unit)
	if bossGUID then return guidOf(unit) == bossGUID end
	return BOSS_UNIT[unit] == true
end

-- When the cast in progress on `unit` finishes, on the GetTime() clock.
local function readCastEnd(unit)
	if type(UnitCastingInfo) ~= "function" then return nil end
	local ok, _, _, _, _, endMS = pcall(UnitCastingInfo, unit)
	if not ok or type(endMS) ~= "number" then return nil end
	local usable, seconds = pcall(function() return endMS / 1000 end)
	if not usable or type(seconds) ~= "number" or seconds ~= seconds then return nil end
	return seconds
end

local function onCall(unit, castGUID)
	-- The same cast surfaces on more than one unit token, so a call is counted
	-- once by its cast id (R5.5).
	local key = castGUID
	if not key then
		local ok, _, _, _, startMS = pcall(UnitCastingInfo, unit)
		key = ok and type(startMS) == "number" and ("t" .. startMS) or nil
	end
	if key then
		if seenCasts[key] then return false end
		seenCasts[key] = true
	end

	calls = calls + 1
	castEndsAt = readCastEnd(unit)

	if calls == 1 then Detector.BeginReplay() end

	-- Announced at cast start, so the player has the whole cast to move (R5.2).
	-- Past the end of the recorded run this does nothing, which is the answer to
	-- extra casts (R5.4).
	if not Detector.Advance() then return false end

	-- Close the replay when the last wave actually lands, not the moment it is
	-- called: the call is a warning, and the popup has to outlive the walk.
	if echoIndex >= ns.Seq.Count() then
		local landsIn = castEndsAt and (castEndsAt - GetTime())
		if not landsIn or landsIn <= 0 then
			landsIn = lastRound and lastRound.slot or SEED_SLOT.hard
		end
		cancelEndTimer()
		endTimer = C_Timer.NewTimer(landsIn, function()
			endTimer = nil
			Detector.EndReplay()
		end)
	end

	return true
end

-- ---------------------------------------------------------------------------
-- Arming
-- ---------------------------------------------------------------------------

local function labelFor(id, name)
	for _, encounter in ipairs(ns.ENCOUNTERS) do
		if encounter.id == id then return encounter.label, true end
	end
	-- Armed on the name in case the ids are renumbered under us (R1.2). We are
	-- then in the fight but do not know which of the two it is; resolveRound()
	-- works it out from the first round's length.
	if type(name) == "string" and name:find("Azta", 1, true) then return nil, true end
	return nil, false
end

local function arm(id, name)
	local label, ours = labelFor(id, name)
	if not ours then return false end

	-- A pull that never got its ENCOUNTER_END may still have something to teach
	-- us, but nothing here proves its last calling half finished.
	settleWaveCount(false)

	armed = true
	difficulty = label
	bossGUID = nil
	showing, lastRound = nil, nil
	calls, seenCasts = 0, {}
	stopSampler()
	Detector.EndReplay()

	-- The automatic modes stand on two things: the client handing out position,
	-- and this client having measured the room. Say which one is missing now,
	-- while there is still time to do something about it.
	ns.Position.Verify()
	if ns.GetMode() ~= "manual" and ns.IsModeChosen() and not ns.HasRoomCenter() then
		ns.Print("|cffff5555no room centre measured|r - stand in the middle of the room and "
			.. "run |cffffd200/ss measure|r, or the quadrants cannot be read.")
	end

	return true
end

local function disarm()
	if not armed then return false end

	-- Settle the wave count before forgetting the pull: the correction it makes
	-- is the one thing here worth keeping (R3.4), and it lives in SavedVariables.
	-- The encounter ending says nothing about whether the calling half finished
	-- or the group died half way through it, so only the provable direction
	-- counts here.
	if showing then endRound(true) end
	settleWaveCount(false)

	armed = false
	difficulty = nil
	bossGUID = nil
	showing, lastRound = nil, nil
	calls, seenCasts = 0, {}
	stopSampler()
	Detector.EndReplay()
	ns.Seq.Reset()
	return true
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- The Sermon on `unit`, or nil. Scanned by name across both filters rather than
-- looked up by id, for the reason SERMON_AURA gives.
local function findSermon(unit)
	if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return nil end
	for _, filter in ipairs({ "HELPFUL", "HARMFUL" }) do
		for index = 1, 40 do
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
			if not ok or type(aura) ~= "table" then break end
			if aura.name == SERMON_AURA then return aura end
		end
	end
	return nil
end

local function onAura(unit)
	if not armed then return false end

	local sermon = findSermon(unit)

	if sermon then
		if showing then return false end
		if not BOSS_UNIT[unit] then return false end
		bossGUID = guidOf(unit) or bossGUID
		beginRound(sermon, unit)
		return true
	end

	-- Only the unit carrying the round can end it. Without this, the second boss
	-- ticking its own auras would close a round it has nothing to do with.
	if showing and (unit == showing.unit or (bossGUID and guidOf(unit) == bossGUID)) then
		endRound(false)
		return true
	end

	return false
end

-- Single entry point for everything the client tells us. Kept public so a test
-- (or the practice run) can push an event through the same door the game does.
function Detector.HandleEvent(event, ...)
	if event == "ENCOUNTER_START" then
		local id, name = ...
		return arm(id, name)
	elseif event == "ENCOUNTER_END" then
		return disarm()
	elseif event == "UNIT_AURA" then
		local unit = ...
		return onAura(unit)
	elseif event == "UNIT_SPELLCAST_START" then
		local unit, castGUID, spellID = ...
		if not armed or spellID ~= ECHO_SPELL then return false end
		if not isOurBoss(unit) then return false end
		return onCall(unit, castGUID)
	elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
		if not armed or showing then return false end
		for unit in pairs(BOSS_UNIT) do onAura(unit) end
		return true
	end
	return false
end

-- ---------------------------------------------------------------------------
-- Readers
-- ---------------------------------------------------------------------------

function Detector.IsArmed() return armed end

-- True while a round is being shown and has not been given up on.
function Detector.IsRecording()
	return showing ~= nil and not showing.dead
end

-- The round in progress, for anything that wants to draw or report it: how many
-- waves, how long a slot is, when it started, and which slot is running.
function Detector.ActiveGrid()
	local round = showing
	if not round or not round.waves then return nil end
	local elapsed = GetTime() - round.startedAt
	local wave = math.floor(elapsed / round.slot) + 1
	if wave > round.waves then wave = round.waves end
	return {
		waves      = round.waves,
		slot       = round.slot,
		difficulty = round.difficulty,
		startedAt  = round.startedAt,
		length     = round.length or (round.waves * round.slot),
		wave       = wave,
		recorded   = round.recorded,
	}
end

-- Semi-automatic capture: the player picks the moment, the addon reads which
-- quadrant they are standing in.
--
-- Refused in automatic mode for the same reason board presses are (R8.5): the
-- addon is managing that recording and a stray press would shift it.
function Detector.Capture()
	if ns.GetMode() == "auto" then
		ns.Print("automatic mode records by itself - the capture key is for |cffffd200semi-automatic|r.")
		return false
	end

	local quadrant = ns.Position.Quadrant()
	if not quadrant then
		if not ns.HasRoomCenter() then
			ns.Print("|cffff5555no room centre measured|r - stand in the middle and run |cffffd200/ss measure|r.")
		elseif not ns.Position.IsAvailable() then
			ns.Print("|cffff5555cannot read your position|r - use the board.")
		else
			ns.Print("|cffff5555too close to the centre to tell|r - step out and try again.")
		end
		return false
	end

	if not ns.Seq.Record(quadrant) then return false end
	if ns.HUD then pcall(ns.HUD.Flash, quadrant) end
	return true
end

-- Clear everything about the run in progress without disarming. The practice
-- run calls this before staging its own.
function Detector.Reset()
	Detector.EndReplay()
	stopSampler()
	showing, lastRound = nil, nil
	calls, seenCasts = 0, {}
	ns.Seq.Reset()
end

local boot = CreateFrame("Frame")
for _, event in ipairs({
	"ENCOUNTER_START", "ENCOUNTER_END",
	"UNIT_AURA", "UNIT_SPELLCAST_START",
	"INSTANCE_ENCOUNTER_ENGAGE_UNIT",
}) do
	boot:RegisterEvent(event)
end
boot:SetScript("OnEvent", function(_, event, ...)
	Detector.HandleEvent(event, ...)
end)
