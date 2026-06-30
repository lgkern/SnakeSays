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

local MAX = 20            -- generous cap; the boss does 5 casts per cycle
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

-- Append a quadrant press. Returns true if it was recorded.
-- Rejected (returns false) when at the cap, or when it repeats the immediately
-- preceding press -- that consecutive duplicate is double-click noise, never a
-- real input (a genuine sequence only ever changes quadrant between casts).
function Seq.Press(quadrant)
	if not ns.QUADRANT_NAME[quadrant] then return false end
	if #list >= MAX then return false end
	if list[#list] == quadrant then return false end
	local wasEmpty = (#list == 0)
	list[#list + 1] = quadrant
	changed()
	-- Auto-reset is anchored to the FIRST press of a sequence (it does not slide
	-- forward on later presses), so we only arm it on the empty -> first press.
	if wasEmpty and ns.GetAutoReset() and C_Timer then
		cancelAutoReset()
		autoTimer = C_Timer.NewTimer(ns.GetAutoResetTime(), function()
			autoTimer = nil
			if ns.GetAutoReset() then Seq.Reset() end   -- re-check: may be off now
		end)
	end
	return true
end

function Seq.Reset()
	cancelAutoReset()
	if #list == 0 then return end
	wipe(list)
	changed()
end

function Seq.Get() return list end
function Seq.Count() return #list end
