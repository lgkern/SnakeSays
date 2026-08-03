local _, ns = ...

-- ===========================================================================
-- Detector.lua  ·  the encounter state machine.
--
-- The fight runs a memory game three times per pull. Each round has a showing
-- half, where waves cross the room and the player's quarter is the answer, and
-- a calling half, where the boss repeats the same run with no visual warning.
--
-- The showing half is invisible: no cast, no damage, no unit event per wave.
-- What it does have is the boss channelling Sermon of Ula'tek for exactly one
-- slot per wave, so the round announces its own length the moment it starts.
-- That is the whole trick -- the round is cut into equal slots, and the player's
-- quarter is read at the end of each one.
--
-- The calling half is the opposite: one cast per wave, and the wave lands when
-- the cast completes. So the showing half is driven by a clock and the calling
-- half is driven by events, and the two halves of this file look nothing like
-- each other on purpose.
--
--   ENCOUNTER_START ─ arm
--     CHANNEL_START (Sermon)       ─ round starts, length known, slots begin
--       ... sampled ...            ─ one board entry per slot as it closes
--     CHANNEL_STOP  (Sermon)       ─ round ends; whole? keep it. short? bin it
--     UNIT_SPELLCAST_START (Echo)  ─ one call per cast, announced at cast start
--   ENCOUNTER_END   ─ disarm, forget the pull
--
-- The handover between the halves is exact: a logged pull stopped the channel
-- and started the first call in the same hundredth of a second.
--
-- How much of that the client will actually say varies. Spell ids arrive
-- secret, names arrive unreadable, and the aura API is refused outright, so
-- nearly everything below is written to work from less than it would like --
-- and to say which way it got there when `/ss debug` is on.
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
--
-- Compared with the punctuation and the case stripped out, because an
-- apostrophe is the single worst character to hang an exact match on -- the
-- client may hand back a typographic one where a log had a plain one, and the
-- failure is completely silent.
local SERMON_AURA = "Sermon of Ula'tek"

-- The boss channels the same spell for as long as it carries it, so the channel
-- says everything the aura would have -- and unlike the aura, a channel is
-- reachable. Retail refuses C_UnitAuras to a tainted caller outright:
--
--   GetAuraDataByIndex(): Auras cannot be accessed when secret while tainted
--
-- so the aura is the fallback now and the channel is the road in.
--
-- The ids below are the ones the author's own event traces recorded -- 1288103
-- on normal, 1306239 on hard. They are a shortcut, never a requirement: normal
-- uses a different id per round, so this list is expected to be incomplete, and
-- an unrecognised channel is checked by its length instead (see findSermon).
local SERMON_SPELLS = { [1288103] = true, [1306239] = true }

local AURA_FILTERS = { "HELPFUL", "HARMFUL" }

-- Where the aura is looked for. Boss frames are the obvious place, but a delve
-- is not a raid and there is no promise the client hands the nemesis a boss
-- token -- so the units the player has to hand are checked too, and the poll
-- below means none of this depends on the event arriving on a token we guessed.
local CANDIDATE_UNITS = {
	"boss1", "boss2", "boss3", "boss4", "boss5",
	"target", "focus", "nameplate1", "nameplate2", "nameplate3",
}

-- How often the boss is checked for the aura while the encounter is up. The
-- round's start time comes from the aura's own expiry rather than from when we
-- noticed it, so this interval costs accuracy nothing.
local POLL_INTERVAL = 0.2

-- One cast per wave during the calling half. The wave lands when it completes,
-- which is what gives the player their warning window.
local ECHO_SPELL = 1288125

-- Seconds per wave slot: round length / slot = wave count. Starting points
-- only. The calling half reveals the true wave count, and learnSlot() overwrites
-- these from it (R3.4), so a wrong seed costs one round rather than the feature.
local SEED_SLOT = { normal = 3.503, hard = 3.003 }

-- How many waves each round of a pull runs, in order. Used only when the client
-- will not say how long the channel is -- which is the usual case, since the
-- channel's start and end times come back secret. Without it the wave count is
-- not known until the round is already over, and the board lands all at once at
-- the end instead of filling as the player watches (R4.4).
--
-- Provisional, always: the round's measured length has the final say, and a
-- round that disagrees is re-read from the samples before anything is called
-- back. So a wrong guess here costs a redraw, not a run.
local WAVES_BY_ROUND = {
	normal = { 3, 4, 5 },
	hard   = { 5, 6, 7 },
}

-- How far a round's length may sit from a whole number of slots and still count
-- as a whole round. A wipe cuts the aura mid-slot; this is what catches it.
local SLOT_TOLERANCE = 0.20   -- in slots

-- How often the player's quarter is read while a round is being shown. Around
-- thirty readings per slot: enough to weight meaningfully, cheap enough to run
-- through a whole pull.
local SAMPLE_INTERVAL = 0.1

local MAX_WAVES = 12   -- the longest real round is seven; this is a sanity rail

local WATCHED_UNIT = {}
for _, unit in ipairs(CANDIDATE_UNITS) do WATCHED_UNIT[unit] = true end

-- ---------------------------------------------------------------------------
-- Reading the client safely
--
-- Everything the client says about a hostile unit -- aura names, aura
-- durations, cast times -- can come back as a secret value, and a secret
-- detonates on a comparison every bit as readily as on arithmetic. Guarding the
-- call is not enough: `aura.name == "..."` is where it goes off, and an error
-- thrown there escapes into a UNIT_AURA handler and takes the whole feature
-- down without a word. So every field is proved usable before it is used.
-- ---------------------------------------------------------------------------

-- The client's own "is this a landmine" test, wrapped in case a build does not
-- have it. A secret value is not detectable by `type`: it reports as the number
-- or string it is standing in for and only goes off when you use it.
local function isSecret(v)
	if type(issecretvalue) ~= "function" then return false end
	local ok, secret = pcall(issecretvalue, v)
	return ok and secret == true
end

-- Compare two values the client may have handed over in any state at all.
-- Returns nil when the comparison could not be made -- which is a different
-- answer from "they are not equal", and the whole reason this exists.
local function equals(a, b)
	if isSecret(a) or isSecret(b) then return nil end
	local ok, same = pcall(function() return a == b end)
	if not ok then return nil end
	return same
end

local function usableNumber(v)
	if type(v) ~= "number" or isSecret(v) then return nil end
	local ok, out = pcall(function() return v + 0 end)
	if not ok or type(out) ~= "number" or out ~= out then return nil end
	return out
end

-- A value rendered for a diagnostic line, whatever state it is in. Never
-- tostring()s anything unproven: that is itself a use, and a secret throws on it.
local function describe(v)
	if isSecret(v) then return "|cffff8800<secret>|r" end
	if type(v) == "string" then return v end
	if type(v) == "number" then
		local n = usableNumber(v)
		return n and tostring(n) or "<number?>"
	end
	return "<" .. type(v) .. ">"
end

-- An aura name reduced to letters and digits: case, spaces and punctuation all
-- taken out, so "Sermon of Ula'tek" and "Sermon of Ula<curly>tek" are the same
-- string by the time they are compared.
local function auraKey(name)
	if type(name) ~= "string" or isSecret(name) then return nil end
	local ok, out = pcall(function() return (name:lower():gsub("[^%w]", "")) end)
	if not ok or type(out) ~= "string" then return nil end
	return out
end

local SERMON_KEY = auraKey(SERMON_AURA)
local ECHO_KEY   = auraKey("Echo of Ula'tek")

-- ---------------------------------------------------------------------------
-- Tracing
--
-- Detection either works or is invisible, and "nothing happened" is the one
-- report that says nothing about which step failed. `/ss debug` turns each step
-- into a line so a pull in the field comes back as evidence.
-- ---------------------------------------------------------------------------

local function trace(fmt, ...)
	if not ns.GetDebug() then return end
	local ok, line = pcall(string.format, fmt, ...)
	ns.Print("|cff888888[ss]|r " .. (ok and line or fmt))
end

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
local lastCallAt            -- GetTime() of the last counted call, for deduping
local unreadableCalls = 0   -- calls taken on where-and-when alone, this round
local roundIndex = 0        -- which memory game of this pull is running

local castEndsAt            -- GetTime() at which the current call's wave lands
local sampler               -- position-sampling ticker
local roundPoll             -- looks for the round's aura while the encounter is up
local endTimer              -- closes the replay when the last wave lands

local replaying  = false
local echoIndex  = 0

-- Defined down in the events section; armed from up here, so it needs a name
-- before it has a body.
local scanForRound

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
	trace("step %d of %d: now %s, next %s", echoIndex, #list,
		tostring(list[echoIndex]), tostring(list[echoIndex + 1]))
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

-- How far a learned slot may sit either side of the shipped seed and still be
-- believable. The seeds came off measured rounds, so a real correction is a
-- nudge; anything near this bound is a symptom rather than a measurement.
local SLOT_DRIFT = 2.0

local function believable(diff, value)
	local seed = SEED_SLOT[diff]
	if not seed then return false end
	if type(value) ~= "number" or value ~= value or value <= 0 then return false end
	return value >= seed / SLOT_DRIFT and value <= seed * SLOT_DRIFT
end

local function forgetSlot(diff)
	local store = ns.db().slotLength
	if store then store[diff] = nil end
end

local function slotLength(diff)
	local store = ns.db().slotLength
	local learned = store and store[diff]
	if believable(diff, learned) then return learned end
	return SEED_SLOT[diff]
end

ns.SlotLength = slotLength

-- Whether the slot in use for `diff` is something this client worked out rather
-- than what shipped. A stored value that is being ignored does not count.
function ns.IsSlotLearned(diff)
	return slotLength(diff) ~= SEED_SLOT[diff]
end

-- Throw away stored timings that are past believing, rather than leaving them
-- sitting in SavedVariables being quietly ignored for ever.
local function purgeSlots()
	local store = ns.db().slotLength
	if not store then return end
	for diff, value in pairs(store) do
		if not believable(diff, value) then
			store[diff] = nil
			trace("dropped an unbelievable stored slot of %s for %s", tostring(value), diff)
		end
	end
	if not next(store) then ns.db().slotLength = nil end
end

-- A correction has to be believable before it is kept. A logged session wrote a
-- 13.990s slot -- four times the real one -- off a single miscounted round, and
-- from then on no round in that session or the next could be a whole number of
-- anything. One bad number must not be able to do that.
local function learnSlot(diff, value)
	if not diff then return false end
	if not believable(diff, value) then
		trace("refusing a slot of %s for %s - too far from %.3fs to be a measurement",
			tostring(value), diff, SEED_SLOT[diff] or 0)
		return false
	end
	local d = ns.db()
	d.slotLength = d.slotLength or {}
	d.slotLength[diff] = value
	return true
end

-- Wave count for a round of `length` seconds cut into `slot`-second slots, plus
-- how far off a whole number it landed. nil when the length is not a whole
-- number of slots, which is R2.4's cut-short case.
local function derive(length, slot)
	if not slot or slot <= 0 or not length or length <= 0 then return nil end
	local exact = length / slot
	local waves = math.floor(exact + 0.5)
	if waves < 1 or waves > MAX_WAVES then return nil end
	local err = math.abs(exact - waves)
	if err > SLOT_TOLERANCE then return nil end
	return waves, err
end

-- The same for a difficulty, using whatever slot length actually explains the
-- round. The learned value gets first refusal, but it does not get to be wrong
-- for ever: if it cannot explain a round and the shipped seed can, then the
-- learning was wrong and the seed goes back. Nothing else can recover from a bad
-- correction, because every later round gets thrown out before it can teach us
-- anything.
local function deriveFor(length, diff)
	local learned = slotLength(diff)
	local waves, err = derive(length, learned)
	if waves then return waves, learned, err end

	local seed = SEED_SLOT[diff]
	if not seed or learned == seed then return nil end

	waves, err = derive(length, seed)
	if not waves then return nil end

	forgetSlot(diff)
	ns.Print(("|cffffd200the stored wave timing for %s could not explain this round|r - "):format(diff)
		.. ("back to %.3fs a wave."):format(seed))
	return waves, seed, err
end

-- The same, for a pull we armed on the encounter *name* and so cannot label.
-- Both slot lengths are tried and the cleaner fit wins; R3.4 corrects it from
-- the cast count either way, so a wrong guess here costs one round.
local function resolveRound(length)
	if difficulty then
		local waves, slot = deriveFor(length, difficulty)
		return waves, slot, difficulty
	end

	local bestWaves, bestSlot, bestDiff, bestErr
	for _, encounter in ipairs(ns.ENCOUNTERS) do
		local waves, slot, err = deriveFor(length, encounter.label)
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
		trace("wave %d read as %s", index, quadrant)
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

	-- Each round stands alone (R2.5). Every counter that belongs to a round has
	-- to be in this list: one left behind cost a logged pull its second and
	-- third memory games, because the fallback's per-round call budget was
	-- already spent by the time the second round's calls arrived.
	ns.Seq.Reset()
	calls, seenCasts, lastCallAt, unreadableCalls = 0, {}, nil, 0
	roundIndex = roundIndex + 1

	local declared = aura and usableNumber(aura.duration)
	if declared and declared <= 0 then declared = nil end

	-- When the round started, not when we noticed it. The aura knows its own
	-- expiry, so working backwards from that keeps the slot boundaries exact
	-- however late the poll got to it.
	local now = GetTime()
	local startedAt = now
	local expires = aura and usableNumber(aura.expires)
	if expires and declared then
		startedAt = expires - declared
		if startedAt > now then startedAt = now end
		if now - startedAt > declared then startedAt = now - declared end
	end

	local round = {
		startedAt = startedAt,
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
	-- running. Failing that, the round's place in the pull says how many waves to
	-- expect, which does the same job -- and failing that too, the round is
	-- measured end to end and resolved in one go when it finishes, which still
	-- works, just with a board that lands all at once.
	if declared then
		round.waves, round.slot, round.difficulty = resolveRound(declared)
	end
	if not round.waves and difficulty then
		local expected = WAVES_BY_ROUND[difficulty]
		local waves = expected and (expected[roundIndex] or expected[#expected])
		if waves then
			round.waves, round.slot, round.difficulty = waves, slotLength(difficulty), difficulty
			round.provisional = true
		end
	end

	showing = round
	sampler = C_Timer.NewTicker(SAMPLE_INTERVAL, sample)

	trace("round: %s waves at %ss (%s), recording=%s, late by %.2fs",
		tostring(round.waves), round.slot and ("%.3f"):format(round.slot) or "?",
		round.difficulty or "difficulty unknown", tostring(round.recording), now - startedAt)
	if round.recording and not ns.HasRoomCenter() then
		trace("no room centre - every wave of this round will fail to read")
	end
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
	if not waves or round.provisional then
		-- However the round was read on the way in, how long it actually ran is
		-- the authority on the way out.
		local measured, measuredSlot, measuredDiff = resolveRound(length)
		if measured then
			waves, slot, diff = measured, measuredSlot, measuredDiff
		elseif round.provisional then
			waves = nil   -- the measurement says this was never a whole round
		end
	end
	if not waves then cutShort = true end

	trace("round over: ran %.3fs, aura said %s, %s waves",
		elapsed, round.length and ("%.3f"):format(round.length) or "?", tostring(waves))

	if cutShort then
		if round.recording then ns.Seq.Reset() end
		lastRound = nil
		ns.Print("|cffff5555round cut short|r - discarding it.")
		return false
	end

	round.waves, round.slot, round.difficulty = waves, slot, diff

	-- The board was filled against a guess and the guess ran long. The samples
	-- are all still here, so the honest fix is to read the round again from the
	-- start rather than leave a wave on the board that never happened.
	if round.recording and round.recorded > waves then
		trace("round was shorter than expected - re-reading it as %d waves", waves)
		ns.Seq.Reset()
		round.recorded, round.previous = 0, nil
	end
	recordUpTo(round, waves)

	-- Kept even when the recording failed: the calling half still counts the
	-- waves for us, and that is what corrects the slot length (R3.4). The unit is
	-- kept too -- it is what says which of the bosses is allowed to call.
	lastRound = {
		length = length, waves = waves, slot = slot,
		difficulty = diff, unit = round.unit,
	}
	return true
end

-- ---------------------------------------------------------------------------
-- The calling half
-- ---------------------------------------------------------------------------

local function guidOf(unit)
	if type(UnitGUID) ~= "function" then return nil end
	local ok, guid = pcall(UnitGUID, unit)
	if not ok or type(guid) ~= "string" or isSecret(guid) then return nil end
	return guid
end

-- The unit running our encounter, so everything else is filtered out by
-- identity rather than by hoping it never casts (R5.3).
--
-- By GUID where the client will hand one over. Where it will not -- and in this
-- content it will not -- by which unit carried the round: the boss that shows
-- the waves is the boss that calls them back, in both of the author's logs.
--
-- That distinction is the whole of R5.3 on hard, where the second boss is a
-- unit named "Echo of Azta'rec" whose ordinary abilities all read as "Echo of
-- ..." too. With no GUID and no name, "it came from a boss frame" lets every one
-- of them through, and a logged hard round spent two of its five calls on them.
local function isOurBoss(unit)
	if bossGUID then return equals(guidOf(unit), bossGUID) == true end

	local carrier = (showing and showing.unit) or (lastRound and lastRound.unit)
	if carrier then return unit == carrier end

	return WATCHED_UNIT[unit] == true
end

-- When the cast in progress on `unit` finishes, on the GetTime() clock.
local function readCastEnd(unit)
	if type(UnitCastingInfo) ~= "function" then return nil end
	local ok, _, _, _, _, endMS = pcall(UnitCastingInfo, unit)
	if not ok then return nil end
	local ms = usableNumber(endMS)
	if not ms then return nil end
	return ms / 1000
end

-- Is this the wave call? Three ways of asking, because the client may refuse
-- to answer the first two.
--
--   by id     what the event carries, when it carries a number we may look at
--   by name   what the cast bar says, when that is readable instead
--   by place  neither could be read. Falling back on where the cast came from
--             is the last resort, and it is fenced in hard: a boss frame only,
--             never a target or a nameplate, and never while a round is still
--             being shown, where a stray cast would shift the whole run onto
--             the wrong quarters. The spec's own guarantee is what makes the
--             boss frame enough -- the second boss on hard casts nothing this
--             feature cares about.
--
-- Returns the verdict and which way it was reached, so `/ss debug` says which.
local function identifyEcho(unit, spellID)
	local byID = equals(spellID, ECHO_SPELL)
	if byID ~= nil then return byID, "id" end

	if type(UnitCastingInfo) == "function" then
		local ok, name = pcall(UnitCastingInfo, unit)
		local key = ok and auraKey(name)
		if key then return key == ECHO_KEY, "name" end
	end

	-- The guard is against the unit *carrying* the round shifting its own run
	-- with a stray cast. A different boss frame casting is not that, and under
	-- the spec's model this never comes up at all, because the round is over
	-- before the calls begin.
	if showing and unit == showing.unit then return false, "mid-round" end

	-- Nothing about the cast could be read, so all that is left is where and
	-- when it happened -- and the boss casts plenty of ordinary things either
	-- side of the calls. A logged normal pull had seven boss casts and only
	-- three of them were calls, so an unfenced fallback takes all seven.
	--
	-- Two fences, both from the round itself. There has to have been a round --
	-- before the first one there is no calling half to be in, and the boss opens
	-- with ordinary abilities. And there is one call per wave and not one more,
	-- so past that count the calls are over and this belongs to the rest of the
	-- fight.
	if not lastRound then return false, "no round shown yet" end
	if unreadableCalls >= lastRound.waves then return false, "past the last call" end
	return true, "unreadable"
end

-- One cast surfaces on several unit tokens at once, and must be counted once
-- (R5.5). By its own id where that can be used -- but a secret value cannot even
-- be a table key, let alone be compared, so that is not something to lean on.
--
-- The fallback needs nothing from the client: duplicates of one cast all arrive
-- in the same frame, GetTime() does not move within a frame, and two real calls
-- are a whole cast apart. So "same instant" means "same cast", exactly, with no
-- tolerance to pick out of the air.
local function alreadyCounted(unit, castGUID)
	local key
	if type(castGUID) == "string" and not isSecret(castGUID) then
		key = castGUID
	else
		local ok, _, _, _, startMS = pcall(UnitCastingInfo, unit)
		local usable = ok and usableNumber(startMS)
		key = usable and ("t" .. usable) or nil
	end

	local now = GetTime()
	local seen = (key and seenCasts[key] == true) or lastCallAt == now

	if key then seenCasts[key] = true end
	lastCallAt = now
	return seen
end

local function onCall(unit, castGUID)
	if alreadyCounted(unit, castGUID) then return false end

	calls = calls + 1

	-- When the wave lands. Read off the live cast where the client allows it --
	-- on hard the cast runs at one of two lengths and swaps part way through a
	-- round, so a baked-in number is wrong by the last call. Where it does not,
	-- a slot's worth is the best estimate available and a great deal better than
	-- nothing: the room view counts down the danger against this, and with no
	-- number at all the danger never builds and the warning it exists to give
	-- never arrives.
	castEndsAt = readCastEnd(unit)
	local measured = castEndsAt ~= nil
	if not castEndsAt then
		castEndsAt = GetTime() + ((lastRound and lastRound.slot) or SEED_SLOT.hard)
	end

	trace("call %d from %s, wave lands in %.2fs (%s), board has %d",
		calls, tostring(unit), castEndsAt - GetTime(),
		measured and "read from the cast" or "estimated from the slot", ns.Seq.Count())

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

local function stopPoll()
	if roundPoll then
		roundPoll:Cancel()
		roundPoll = nil
	end
end

local function arm(id, name)
	local label, ours = labelFor(id, name)
	trace("ENCOUNTER_START %s '%s' -> %s", tostring(id), tostring(name),
		ours and (label or "ours, difficulty unknown") or "not ours")
	if not ours then return false end

	-- A pull that never got its ENCOUNTER_END may still have something to teach
	-- us, but nothing here proves its last calling half finished.
	settleWaveCount(false)
	purgeSlots()

	armed = true
	difficulty = label
	bossGUID = nil
	showing, lastRound = nil, nil
	calls, seenCasts, lastCallAt, unreadableCalls = 0, {}, nil, 0
	roundIndex = 0
	stopSampler()
	Detector.EndReplay()

	-- A pull starts with an empty board. Whatever is on it came from somewhere
	-- else -- a practice run, an earlier pull, a stray press -- and calling it
	-- back as though the boss had just shown it is worse than calling nothing.
	ns.Seq.Reset()

	-- Watch for the round's aura on a timer as well as on UNIT_AURA. Which unit
	-- token a delve nemesis turns up on is not something worth staking the whole
	-- feature on, and a poll costs nothing the aura's own expiry does not give
	-- back.
	stopPoll()
	roundPoll = C_Timer.NewTicker(POLL_INTERVAL, scanForRound)

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

	trace("ENCOUNTER_END after %d call(s)", calls)

	armed = false
	difficulty = nil
	bossGUID = nil
	showing, lastRound = nil, nil
	calls, seenCasts, lastCallAt, unreadableCalls = 0, {}, nil, 0
	roundIndex = 0
	stopSampler()
	stopPoll()
	Detector.EndReplay()
	ns.Seq.Reset()
	return true
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

-- Walk every aura on `unit`, handing each one to `visit` as plain values. The
-- whole walk sits inside one pcall, so a secret field anywhere in it costs us
-- this unit rather than the event handler we are standing in.
-- Returns what `visit` found, how many auras were walked, and the error if the
-- walk itself blew up. The last two matter only to the diagnostics, but they
-- are the difference between "this unit has no auras" and "this unit's auras
-- cannot be looked at", which is not a distinction to be guessing at.
local function forEachAura(unit, visit)
	if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then
		return nil, 0, "C_UnitAuras.GetAuraDataByIndex is missing"
	end

	local seen = 0
	local ok, found = pcall(function()
		for _, filter in ipairs(AURA_FILTERS) do
			for index = 1, 40 do
				local aura = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
				if type(aura) ~= "table" then break end
				seen = seen + 1
				local hit = visit(
					auraKey(aura.name),
					usableNumber(aura.duration),
					usableNumber(aura.expirationTime),
					aura.name)
				if hit then return hit end
			end
		end
		return nil
	end)

	if not ok then return nil, seen, tostring(found) end
	return found, seen, nil
end

-- The Sermon channelling on `unit`, as { duration, expires }, or nil.
--
-- This is the primary way in. UnitChannelInfo hands back the same two facts the
-- aura would have -- when it ends and how long it runs -- and does it through a
-- door the client has not closed.
-- Identified three ways, in descending order of how much the client is willing
-- to say:
--
--   by name   what the channel calls itself, when that can be read
--   by id     one of the ids the author's traces recorded, when it can be read
--   by shape  neither. A channel on the boss during our encounter is taken as a
--             candidate and left to prove itself: a round has to run for a whole
--             number of slots (R3.3), and a channel that is not the Sermon will
--             not, so it is thrown out at the end by the check that is already
--             there. Accepting here costs a round at worst; refusing costs the
--             feature on a client that names nothing.
local function findSermonChannel(unit)
	if type(UnitChannelInfo) ~= "function" then return nil end
	local ok, name, _, _, startMS, endMS, _, _, spellID = pcall(UnitChannelInfo, unit)
	if not ok then return nil end

	-- Nothing at all came back, so the unit is not channelling. This has to be
	-- told apart from "channelling something the client will not describe",
	-- which looks identical field by field and means the opposite.
	if name == nil and startMS == nil and endMS == nil and spellID == nil then
		return nil
	end

	local key = auraKey(name)
	if key and key ~= SERMON_KEY then return nil, "named something else" end

	local id = usableNumber(spellID)
	if not key and id and not SERMON_SPELLS[id] then
		-- The id was readable and is not one we know. On normal that is expected
		-- -- the id changes per round -- so this still falls through to shape.
		id = nil
	end

	local how = key and "name" or (id and "id" or "shape")
	local from, to = usableNumber(startMS), usableNumber(endMS)

	-- Times unreadable: the channel is still the round, its length just has to
	-- be measured from the two events instead of read off the client. The board
	-- then fills at the end rather than as it goes, which is a worse experience
	-- than R4.4 asks for but a great deal better than no recording at all.
	if not from or not to or to <= from then
		return { duration = nil, expires = nil }, how
	end

	return { duration = (to - from) / 1000, expires = to / 1000 }, how
end

-- The Sermon as an aura on `unit`, as { duration, expires }, or nil. Kept for
-- the client that will answer it; see SERMON_SPELL for the one that will not.
local function findSermonAura(unit)
	return forEachAura(unit, function(key, duration, expires)
		if key ~= SERMON_KEY then return nil end
		return { duration = duration, expires = expires }
	end)
end

local function findSermon(unit)
	local channel, how = findSermonChannel(unit)
	if channel then return channel, how end
	local aura = findSermonAura(unit)
	if aura then return aura, "aura" end
	return nil
end

-- Look at everything we can see for the round's aura. Runs on UNIT_AURA and on
-- a timer, because which unit token the boss turns up on is not something to
-- stake the feature on.
function scanForRound()
	if not armed then return false end

	if not showing then
		for _, unit in ipairs(CANDIDATE_UNITS) do
			local sermon = findSermon(unit)
			if sermon then
				bossGUID = guidOf(unit) or bossGUID
				trace("sermon up on %s: %.3fs", unit, sermon.duration or 0)
				beginRound(sermon, unit)
				return true
			end
		end
		return false
	end

	-- Only the unit carrying the round can end it: the second boss on hard
	-- ticking its own auras must not close a round it has nothing to do with.
	if not findSermon(showing.unit) then
		trace("sermon gone from %s", tostring(showing.unit))
		endRound(false)
		return true
	end

	return false
end

local function onAura(unit)
	if not armed then return false end
	if not WATCHED_UNIT[unit] and unit ~= (showing and showing.unit) then return false end
	return scanForRound()
end

-- The channel ending is the round ending, and it is the exact moment the calling
-- half begins -- so it is worth acting on directly rather than waiting up to a
-- poll for the absence to be noticed.
local function onChannelStop(unit)
	if not armed or not showing then return false end
	if unit ~= showing.unit then return false end
	if findSermon(unit) then return false end   -- a different channel ended
	trace("sermon channel ended on %s", tostring(unit))
	endRound(false)
	return true
end

-- Every aura the addon can see on the boss, printed. This exists because the
-- one thing that cannot be worked out from "nothing happened" is what the aura
-- is actually called on this client -- run it during the showing half and the
-- answer is on screen.
function Detector.ScanAuras()
	local total = 0

	for _, unit in ipairs(CANDIDATE_UNITS) do
		local exists = false
		if type(UnitExists) == "function" then
			local ok, result = pcall(UnitExists, unit)
			exists = ok and result == true
		end

		-- Scanned whether or not the unit claims to exist. A unit token that
		-- answers "no" and still has auras on it is exactly the kind of thing
		-- worth finding out about, and gating on it is how the last scan came
		-- back empty and said nothing.
		local lines = {}
		local _, seen, fault = forEachAura(unit, function(key, duration, _, name)
			lines[#lines + 1] = ("      |cffffd200%s|r  %ss%s"):format(
				describe(name),
				duration and ("%.3f"):format(duration) or describe(nil),
				key == SERMON_KEY and "  |cff44ff44<- this is the one|r" or "")
			return nil
		end)
		total = total + seen

		if seen > 0 or fault or exists then
			ns.Print(("  %s: exists=%s auras=%d%s"):format(
				unit, exists and "yes" or "no", seen,
				fault and (" |cffff5555failed: " .. fault .. "|r") or ""))
			for _, line in ipairs(lines) do ns.Print(line) end
		end
	end

	if total == 0 then
		ns.Print("|cffff5555no auras readable on any boss, target or nameplate unit.|r")
		ns.Print("If the boss visibly has a buff right now, the client is not letting "
			.. "addons see it - which is a different problem from a wrong name.")
	end
	return total
end

-- What this client is willing to tell the addon, measured rather than assumed.
--
-- The whole feature is built on reading things about the boss, and in this
-- content some of those reads come back blocked or secret. Before anything gets
-- redesigned around that, this says exactly which reads survive -- and it says
-- it from inside the addon, which is the only place the answer counts, since
-- the restriction is on tainted execution rather than on the API.
function Detector.Probe()
	local function line(label, ok, ...)
		if not ok then
			ns.Print(("  %s: |cffff5555blocked|r - %s"):format(label, tostring((...))))
			return
		end
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = describe((select(i, ...))) end
		if #parts == 0 then parts[1] = "<nothing>" end
		ns.Print(("  %s: %s"):format(label, table.concat(parts, "  ")))
	end

	ns.Print("what this client will tell SnakeSays:")
	line("UnitPosition(player)", pcall(UnitPosition, "player"))
	line("GetPlayerFacing()", pcall(GetPlayerFacing))

	for _, unit in ipairs({ "boss1", "target" }) do
		local exists = select(2, pcall(UnitExists, unit)) == true
		ns.Print(("  -- %s (exists=%s)"):format(unit, exists and "yes" or "no"))
		line("    UnitGUID", pcall(UnitGUID, unit))
		line("    UnitName", pcall(UnitName, unit))
		line("    UnitHealth", pcall(UnitHealth, unit))
		line("    UnitHealthMax", pcall(UnitHealthMax, unit))
		line("    UnitCastingInfo", pcall(UnitCastingInfo, unit))
		line("    UnitChannelInfo", pcall(UnitChannelInfo, unit))
		if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			local ok, err = pcall(C_UnitAuras.GetAuraDataByIndex, unit, 1, "HELPFUL")
			line("    GetAuraDataByIndex", ok, ok and "<readable>" or err)
		end
	end
end

local function dispatch(event, ...)
	if event == "ENCOUNTER_START" then
		local id, name = ...
		return arm(id, name)
	elseif event == "ENCOUNTER_END" then
		return disarm()
	elseif event == "UNIT_AURA" then
		local unit = ...
		return onAura(unit)
	elseif event == "UNIT_SPELLCAST_CHANNEL_START"
		or event == "UNIT_SPELLCAST_CHANNEL_UPDATE" then
		if not armed then return false end
		return scanForRound()
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		local unit = ...
		return onChannelStop(unit)
	elseif event == "UNIT_SPELLCAST_START" then
		local unit, castGUID, spellID = ...
		-- The unit is checked first and the spell second, on purpose. The spell
		-- id is a value the client may have made secret, and touching one is
		-- what threw; there is no reason to touch it for a cast that is not our
		-- boss', which in an instance is nearly all of them.
		if not armed or not isOurBoss(unit) then return false end
		local isEcho, how = identifyEcho(unit, spellID)
		if not isEcho then return false end
		trace("echo from %s, identified by %s", tostring(unit), how)

		local counted = onCall(unit, castGUID)
		if counted and how == "unreadable" then
			unreadableCalls = unreadableCalls + 1
		end
		return counted
	elseif event == "INSTANCE_ENCOUNTER_ENGAGE_UNIT" then
		if not armed then return false end
		return scanForRound()
	end
	return false
end

local reportedFault = false

-- Single entry point for everything the client tells us. Kept public so a test
-- (or the practice run) can push an event through the same door the game does.
--
-- Nothing is allowed out of here. These run inside combat event handlers, where
-- an error is either swallowed or turned into a wall of spam, and in both cases
-- the feature dies quietly. If one ever does throw, it is said once and the
-- addon carries on.
function Detector.HandleEvent(event, ...)
	local ok, result = pcall(dispatch, event, ...)
	if ok then return result end
	if not reportedFault then
		reportedFault = true
		ns.Print("|cffff5555internal error handling " .. tostring(event) .. "|r: " .. tostring(result))
		ns.Print("please report this; detection may be unreliable for the rest of this session.")
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
	calls, seenCasts, lastCallAt, unreadableCalls = 0, {}, nil, 0
	roundIndex = 0
	ns.Seq.Reset()
end

local boot = CreateFrame("Frame")
for _, event in ipairs({
	"ENCOUNTER_START", "ENCOUNTER_END",
	"UNIT_AURA", "UNIT_SPELLCAST_START",
	"UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_CHANNEL_UPDATE",
	"UNIT_SPELLCAST_CHANNEL_STOP",
	"INSTANCE_ENCOUNTER_ENGAGE_UNIT",
}) do
	boot:RegisterEvent(event)
end
boot:SetScript("OnEvent", function(_, event, ...)
	Detector.HandleEvent(event, ...)
end)
