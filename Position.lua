local _, ns = ...

-- ===========================================================================
-- Position.lua  ·  where the player is standing, in room terms.
--
-- UnitPosition("player") returns world yards as (a, b, z, instanceID), where
-- axis `a` points NORTH and axis `b` points WEST. Everything here converts that
-- into the room's own frame -- x east, y north, origin at the room centre --
-- and buckets it into one of the four cardinal quadrants.
--
-- Secret values
-- -------------
-- Retail may hand back "secret" numbers from position and facing APIs. They can
-- be passed around freely but throw the instant you do arithmetic on them, so
-- every read AND every calculation on the result is wrapped. A guarded failure
-- returns nil; it never propagates an error into a combat event handler.
--
-- If reading position stops working altogether while we're in the delve, the
-- automatic modes have nothing to stand on. Rather than silently recording
-- garbage, Verify() says so in chat and drops the player back to manual.
-- ===========================================================================

local Position = {}
ns.Position = Position

-- Quadrants in compass order, offset so each cardinal name covers the 90
-- degrees centred on it (N spans 315-45, E spans 45-135, and so on).
local QUADRANT_BY_ARC = { "N", "E", "S", "W" }

local DEAD_ZONE = 0.5   -- yards; inside this the bearing is meaningless

local demoted = false   -- warned and dropped to manual already this session

-- ---------------------------------------------------------------------------
-- Room centre
-- ---------------------------------------------------------------------------

-- The measured centre if `/ss measure` has ever been run, else the shipped one.
function ns.GetRoomCenter()
	local stored = ns.db().roomCenter
	if stored and type(stored.a) == "number" and type(stored.b) == "number" then
		return stored
	end
	return { a = ns.ROOM.centerA, b = ns.ROOM.centerB }
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

-- Room-local offsets in yards: x east-positive, y north-positive.
function Position.Offset()
	local a, b = readWorld()
	if not a then return nil end
	local center = ns.GetRoomCenter()
	local ok, x, y = pcall(function()
		return center.b - b, a - center.a
	end)
	if not ok then return nil end
	return x, y
end

function Position.Distance()
	local x, y = Position.Offset()
	if not x then return nil end
	return math.sqrt(x * x + y * y)
end

-- Which cardinal quadrant the player occupies, or nil if that can't be told
-- (unreadable position, or standing too close to the centre to have a bearing).
function Position.Quadrant()
	local x, y = Position.Offset()
	if not x then return nil end
	if math.sqrt(x * x + y * y) < DEAD_ZONE then return nil end
	local angle = math.deg(math.atan2(x, y))   -- 0 = north, 90 = east
	if angle < 0 then angle = angle + 360 end
	return QUADRANT_BY_ARC[math.floor(((angle + 45) % 360) / 90) + 1]
end

-- Player facing in radians, or nil when the client withholds it (which happens
-- in combat). Callers draw a plain blip instead of a direction arrow.
function Position.Facing()
	local ok, facing = pcall(GetPlayerFacing)
	if not ok or type(facing) ~= "number" then return nil end
	local usable = pcall(function() return facing + 0 end)
	if not usable then return nil end
	return facing
end

function Position.IsAvailable()
	return Position.Offset() ~= nil
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
-- The shipped constants were measured in the middle of the room. If they ever
-- drift, standing in the middle and running `/ss measure` re-pins them.
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
