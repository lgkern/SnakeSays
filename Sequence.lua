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
local listener           -- single change callback (the HUD)
local autoTimer          -- pending auto-reset timer, if any

function Seq.OnChange(fn) listener = fn end

local function changed()
	if listener then listener(list) end
end

local function cancelAutoReset()
	if autoTimer then
		autoTimer:Cancel()
		autoTimer = nil
	end
end

local function append(quadrant, armAutoReset)
	if not ns.QUADRANT_NAME[quadrant] then return false end
	if #list >= MAX then return false end
	local wasEmpty = (#list == 0)
	list[#list + 1] = quadrant
	changed()
	-- Auto-reset is anchored to the FIRST press of a sequence (it does not slide
	-- forward on later presses), so we only arm it on the empty -> first press.
	if armAutoReset and wasEmpty and ns.GetAutoReset() and C_Timer then
		cancelAutoReset()
		autoTimer = C_Timer.NewTimer(ns.GetAutoResetTime(), function()
			autoTimer = nil
			if ns.GetAutoReset() then Seq.Reset() end   -- re-check: may be off now
		end)
	end
	return true
end

-- A quadrant the player picked, by wedge click or quadrant keybind. This is how
-- the board gets filled. Returns true if it was recorded.
--
-- Rejected at the cap, or when it repeats the immediately preceding press --
-- that consecutive duplicate is double-click noise rather than a real input,
-- since the player only presses when they see the quadrant change.
function Seq.Press(quadrant)
	if list[#list] == quadrant then return false end
	return append(quadrant, true)
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
	if #list == 0 then return end
	wipe(list)
	changed()
end

function Seq.Get() return list end
function Seq.Count() return #list end
