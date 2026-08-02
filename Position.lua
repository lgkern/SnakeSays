local _, ns = ...

-- ===========================================================================
-- Position.lua  ·  where the player is standing, in room terms.
--
-- UnitPosition("player") returns world yards as (a, b, z, instanceID), where
-- `a` runs north and `b` runs west. Everything here is expressed in those two
-- axes rather than in an angle, because the room's quarters are cut on the
-- diagonals: which quarter you are in is "is |north| bigger than |west|", a
-- comparison that is exactly as true five yards from the boss as it is at the
-- wall. An arctangent would be a lot of precision spent on a number that swings
-- a quarter-turn per step at melee range.
--
-- Secret values
-- -------------
-- Retail may hand back "secret" numbers from position and facing APIs. They can
-- be passed around freely but throw the instant you do arithmetic on them, so
-- every read AND every calculation on the result is wrapped. A guarded failure
-- returns nil; it never propagates an error into a combat event handler.
--
-- Offset() is the one place a reading is turned into numbers we own. Everything
-- downstream works off its result, so the guard has a single edge to sit on.
--
-- If reading position stops working altogether while we're in the delve, the
-- automatic modes have nothing to stand on. Rather than silently recording
-- garbage, Verify() says so in chat and drops the player back to manual.
-- ===========================================================================

local Position = {}
ns.Position = Position

local abs, sqrt = math.abs, math.sqrt

-- Inside this many yards of the centre there is no bearing worth having: a
-- single step swings it clean across a boundary, so the honest answer is that
-- we do not know (R6.7). Every reading in a logged round sat 5 to 11 yards out,
-- and the one that had no bearing at all was 0.61 yards, so this sits clear of
-- both.
local DEAD_ZONE = 1.0

local demoted = false   -- warned and dropped to manual already this session

-- ---------------------------------------------------------------------------
-- Room centre
-- ---------------------------------------------------------------------------

-- The centre `/ss measure` recorded, or nil if it has never been run. There is
-- no shipped fallback: an unmeasured room is a room we cannot reason about, and
-- saying so beats guessing. ns.ROOM carries the author's own measurement as
-- reference geometry, but a centre is only trusted once this client has stood
-- in the room and taken it.
function ns.GetRoomCenter()
	local stored = ns.db().roomCenter
	if stored and type(stored.a) == "number" and type(stored.b) == "number" then
		return stored
	end
	return nil
end

function ns.HasRoomCenter()
	return ns.GetRoomCenter() ~= nil
end

-- ---------------------------------------------------------------------------
-- Reading
-- ---------------------------------------------------------------------------

-- Raw world coordinates, or nil if unreadable/secret. Both the call and a
-- trivial arithmetic probe are guarded: a secret value survives the call and
-- only detonates when used, so the probe is what actually proves it is safe.
local function readWorld()
	local ok, a, b = pcall(UnitPosition, "player")
	if not ok or type(a) ~= "number" or type(b) ~= "number" then return nil end
	local usable = pcall(function() return a + b end)
	if not usable then return nil end
	return a, b
end

-- Run `fn` and insist on a real number coming back: not an error, not a secret,
-- not a NaN.
local function number(fn)
	local ok, v = pcall(fn)
	if not ok or type(v) ~= "number" or v ~= v then return nil end
	return v
end

-- How far north and how far west of the room centre the player is, in yards.
-- nil when the room has never been measured or the client is withholding the
-- reading -- both of which are answers, not failures.
--
-- This is the guarded edge. Past it the two numbers are ours: they came out of
-- arithmetic that has already been proved to run, so the rest of the file does
-- plain maths on them.
function Position.Offset()
	local center = ns.GetRoomCenter()
	if not center then return nil end

	local a, b = readWorld()
	if a == nil then return nil end

	local ok, north, west = pcall(function()
		return a - center.a, b - center.b
	end)
	if not ok then return nil end
	if type(north) ~= "number" or type(west) ~= "number" then return nil end
	if north ~= north or west ~= west then return nil end
	return north, west
end

-- Yards from the room centre, or nil.
function Position.Distance()
	local north, west = Position.Offset()
	if north == nil then return nil end
	return number(function() return sqrt(north * north + west * west) end)
end

-- Which quarter of the room the player is in ("N"/"E"/"S"/"W"), or nil.
--
-- The quarters are centred on the cardinals with their boundaries on the
-- diagonals, so the whole question is which offset is larger. A player sitting
-- on top of the centre gets nil rather than whichever way the last decimal
-- happened to fall.
function Position.Quadrant()
	local north, west = Position.Offset()
	if north == nil then return nil end
	if sqrt(north * north + west * west) < DEAD_ZONE then return nil end
	if abs(north) >= abs(west) then
		return north >= 0 and "N" or "S"
	end
	return west >= 0 and "W" or "E"
end

-- Which way the player is facing, in radians counter-clockwise from north, or
-- nil. Guarded the same way as position: the type check catches a withheld
-- value and the arithmetic probe catches a secret one.
function Position.Facing()
	if type(GetPlayerFacing) ~= "function" then return nil end
	local ok, facing = pcall(GetPlayerFacing)
	if not ok or type(facing) ~= "number" then return nil end
	if not pcall(function() return facing * 1 end) then return nil end
	if facing ~= facing then return nil end
	return facing
end

-- Whether the client is handing out coordinates at all. Deliberately *not*
-- routed through Offset(): this asks about the client, not about whether we can
-- currently turn a reading into a room position.
function Position.IsAvailable()
	return readWorld() ~= nil
end

-- ---------------------------------------------------------------------------
-- Safety net
-- ---------------------------------------------------------------------------

-- Drop to manual and explain. Called when the automatic modes lose the one
-- thing they depend on -- most likely because the client stopped handing out
-- player position to addons, which is not something the player can fix.
function Position.DemoteToManual(reason)
	if demoted then return end
	demoted = true
	ns.Print("|cffff5555" .. reason .. "|r")
	ns.Print("switched to |cffffd200manual|r mode - press the quadrants yourself.")
	ns.SetBlockManualInput(false)   -- manual is all that's left; let it through
	ns.SetMode("manual")
end

-- Check that automatic detection can actually work here, and demote if not.
-- Cheap enough to call on zone changes and at the start of every encounter.
function Position.Verify()
	if ns.GetMode() == "manual" or not ns.IsModeChosen() then return true end
	if not ns.InDelve() then return true end
	if Position.IsAvailable() then return true end
	Position.DemoteToManual("SnakeSays can no longer read your position.")
	return false
end

-- Test seam: forget that we already demoted this session.
function Position.ResetDemotion()
	demoted = false
end

-- ---------------------------------------------------------------------------
-- Measuring the centre
--
-- Nothing ships with a centre. Stand in the middle of the room and run
-- `/ss measure` to record one; it is kept in SavedVariables.
-- ---------------------------------------------------------------------------

function Position.MeasureCenter()
	local a, b = readWorld()
	if not a then return false end
	ns.db().roomCenter = { a = a, b = b }
	return true
end

function Position.ClearMeasuredCenter()
	ns.db().roomCenter = nil
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:SetScript("OnEvent", function()
	Position.Verify()
end)
