local _, ns = ...

-- ===========================================================================
-- Sequence.lua  ·  the recorded list of pressed quadrants.
--
-- Pure state + a change listener; no frames here. The HUD registers a listener
-- and re-renders whenever the sequence changes. Lives on `ns` so the keybind
-- and slash-command globals (Commands.lua) can drive it the same way the mouse
-- does. Recording is plain Lua state, so it works fine in combat.
-- ===========================================================================

local Seq = {}
ns.Seq = Seq

-- The run grows as the boss loses health -- on the hardest difficulty it is 5
-- waves, then 6, then 7 -- so the cap has to sit well clear of the longest one.
local MAX = 20
local list = {}          -- array of quadrant keys ("N"/"E"/"S"/"W")
local listeners = {}     -- change callbacks, in registration order
local autoTimer          -- pending auto-reset timer, if any
local firstAt            -- GetTime() of the press that started this board

-- When the board stopped being empty, or nil while it still is. The detector
-- asks: an unreadable channel spends a couple of seconds proving it is a round
-- (CONFIRM_CHANNEL), the player is already pressing during those seconds, and
-- the round must not open by wiping the presses that belong to it.
function Seq.FirstPressAt() return firstAt end

-- More than one thing draws the board now (the HUD row and the timeline), so a
-- second subscriber has to be added rather than replace the first -- a single
-- slot here silently unhooked whichever registered earlier.
function Seq.OnChange(fn)
	listeners[#listeners + 1] = fn
end

-- Wrapped, because a listener that throws must not stop the ones after it from
-- being told, nor leave the press that triggered it half-applied.
--
-- But a swallowed error is its own bug report going missing: a press that
-- records perfectly and then fails to draw looks, from the chair, exactly like a
-- press that never happened. The pcall stays; what it caught now says so.
local function changed()
	for i, fn in ipairs(listeners) do
		local ok, err = pcall(fn, list)
		if not ok then
			ns.Trace("|cffff5555listener %d threw:|r %s", i, tostring(err))
		end
	end
end

local function cancelAutoReset()
	if autoTimer then
		autoTimer:Cancel()
		autoTimer = nil
	end
end

-- The safety net: a board the player filled in and then walked away from clears
-- itself, so the next pull does not start on top of the last one's run.
--
-- Declared ahead of itself because it re-arms itself; see below.
local armAutoReset

armAutoReset = function()
	if not ns.GetAutoReset() or not C_Timer then return end
	cancelAutoReset()
	autoTimer = C_Timer.NewTimer(ns.GetAutoResetTime(), function()
		autoTimer = nil
		if not ns.GetAutoReset() then return end   -- re-check: may be off now

		-- Never while the run is being called back. The net is for a board left
		-- lying around between pulls; a board being read back is the opposite of
		-- that, and the one moment the run is actually being used.
		--
		-- Forty seconds sounds like room to spare and is not. It is anchored to
		-- the first press and never slides forward, and a seven-wave hard round
		-- spends twenty-one seconds showing the run and twenty-five more calling
		-- it. So the net closed over the last wave or two of the longest rounds
		-- -- the ones worth having -- and the voice and the popup stopped dead
		-- mid-readback while the detector carried on stepping past an empty
		-- board. It was reported from the field as the voice cutting out at
		-- random, and it read that way in the log too: the only sign of it was
		-- `board has 0` on the call that went unannounced.
		--
		-- Deferred rather than cancelled. A board still wants clearing once
		-- nobody is reading it, so the net re-arms and comes back around.
		if ns.Detector and ns.Detector.IsReplaying() then
			armAutoReset()
			return
		end

		Seq.Reset()
	end)
end

local function append(quadrant, withAutoReset)
	if not ns.QUADRANT_NAME[quadrant] then return false end
	if #list >= MAX then return false end
	local wasEmpty = (#list == 0)
	if wasEmpty then firstAt = GetTime and GetTime() or nil end
	list[#list + 1] = quadrant
	changed()
	-- Auto-reset is anchored to the FIRST press of a sequence (it does not slide
	-- forward on later presses), so we only arm it on the empty -> first press.
	if withAutoReset and wasEmpty then armAutoReset() end
	return true
end

-- A quadrant the player picked, by wedge click or quadrant keybind. This is how
-- the board gets filled. Returns true if it was recorded.
--
-- Rejected at the cap, or when it repeats the immediately preceding press --
-- that consecutive duplicate is double-click noise rather than a real input,
-- since the player only presses when they see the quadrant change.
function Seq.Press(quadrant)
	-- Every way a press can come to nothing says so under `/ss debug`. "I pressed
	-- it and the board did not change" is three different bugs wearing the same
	-- coat, and in the field they are not tellable apart without this.
	if not ns.QUADRANT_NAME[quadrant] then
		ns.Trace("press %s refused: not a quadrant", tostring(quadrant))
		return false
	end
	if list[#list] == quadrant then
		ns.Trace("press %s refused: same as the last one", tostring(quadrant))
		return false
	end
	if #list >= MAX then
		ns.Trace("press %s refused: board is full at %d", tostring(quadrant), MAX)
		return false
	end
	if not append(quadrant, true) then return false end
	ns.Trace("press %s recorded, board is now %d long%s", tostring(quadrant), #list,
		InCombatLockdown and InCombatLockdown() and " (in combat)" or "")
	-- A press is what makes this client the one filling the board, so the group
	-- hears about it here rather than anywhere the addon fills the board itself.
	if ns.Comms then ns.Comms.OnLocalPress() end
	return true
end

-- Replace the whole board with somebody else's, wholesale. Only group sync uses
-- this: it sends the run entire every time rather than one press at a time, so
-- a dropped message or a late arrival costs nothing -- the next press puts the
-- receiver right again.
--
-- Listeners are told once, at the end, rather than once per entry: this is one
-- change to the board, and a flash per wave would make a silent correction look
-- like five waves arriving at once.
function Seq.Adopt(quadrants)
	if type(quadrants) ~= "table" then return false end
	if #quadrants > MAX then return false end
	for _, quadrant in ipairs(quadrants) do
		if not ns.QUADRANT_NAME[quadrant] then return false end
	end

	cancelAutoReset()
	wipe(list)
	for i, quadrant in ipairs(quadrants) do list[i] = quadrant end
	firstAt = (#list > 0) and (GetTime and GetTime() or nil) or nil
	changed()
	return true
end

-- Take the last press back off the board.
--
-- A misclick used to cost the whole run: Reset was the only way to change what
-- was recorded, and by then the waves it had swallowed were gone from memory
-- too. One wrong marker at the end is worth taking off; nine right ones are not
-- worth throwing away with it.
--
-- Only the board's own end is reachable, deliberately. Editing the middle would
-- need a cursor, and there is no time to place one between waves.
function Seq.Undo()
	if #list == 0 then
		ns.Trace("undo refused: the board is already empty")
		return false
	end
	local dropped = list[#list]
	list[#list] = nil
	if #list == 0 then
		-- Emptied by hand is emptied: the auto-reset was armed for a board that no
		-- longer exists, and an empty board stops this client driving, which is what
		-- lets the group's run back onto the timeline. Seq.Reset does both too.
		cancelAutoReset()
		firstAt = nil
		if ns.Comms then ns.Comms.OnBoardCleared() end
	end
	changed()
	ns.Trace("undo took %s back, board is now %d long", tostring(dropped), #list)
	return true
end

-- A quadrant staged by the addon itself rather than pressed. Only the practice
-- run uses this: it puts a made-up sequence on the board to call back.
--
-- Never deduplicated, since a made-up run is allowed to repeat, and never
-- auto-reset -- that timer is a safety net for a hand-typed run left lying
-- around between pulls, and the practice run clears up after itself.
function Seq.Record(quadrant)
	return append(quadrant, false)
end

function Seq.Reset()
	cancelAutoReset()
	-- Before the early return: an empty board still stops this client driving,
	-- and that is what lets the group's run back onto the timeline.
	if ns.Comms then ns.Comms.OnBoardCleared() end
	if #list == 0 then return end
	wipe(list)
	firstAt = nil
	changed()
end

function Seq.Get() return list end
function Seq.Count() return #list end
