local addonName, ns = ...

-- ===========================================================================
-- Radar.lua  ·  a top-down view of the room, in its own window.
--
-- The room from above, turned so the way the player faces is up. The window
-- itself hangs off the left edge of the board and rides along with it until
-- dragged, at which point it pins to the screen and stays there.
--
-- What it has to say, and how it says it
-- --------------------------------------
-- Four things share this small square, so each gets a channel of its own rather
-- than competing for brightness:
--
--   which quarter is which   the wedge's marker colour and its raid icon, always
--                            on, so the view reads the same as the board does
--   be here now              that wedge lit; dim while the player is still on
--                            their way, solid the instant they arrive, so
--                            "made it" is a step in brightness and not a caption
--   be here next             that wedge half lit, and only once the player has
--                            reached the current one -- two lit wedges while
--                            they are still moving is one thing too many
--   about to be hit          a red wash over every quarter that is not the safe
--                            one, deepening as the boss' cast runs down
--
-- The wash is a separate layer from the wedge, so the quarter the player is
-- being sent to next can be both "go here" and "hot right now" at the same time,
-- which is exactly what it is.
--
-- Turning the view
-- ----------------
-- The player is drawn where they stand and the room turns around them. Facing is
-- often unavailable, and a view that guessed would point people the wrong way,
-- so when it is missing the room simply sits north-up and the facing arrow goes
-- away rather than being drawn pointing somewhere invented.
-- ===========================================================================

local Radar = {}
ns.Radar = Radar

local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"

-- The player arrow the map and the minimap both use, so the view reads as a map
-- rather than as a diagram. One constant: if this path ever stops resolving,
-- this is the only line that changes.
local PLAYER_ARROW = "Interface\\Minimap\\MinimapArrow"

local SIZE   = 190     -- canvas px
local UPDATE = 0.05    -- redraw interval while shown
local DOT    = 8       -- facing-less player blip px
local ARROW  = 26      -- player arrow px
local ICON   = 18      -- per-quarter marker icon px
local ICON_AT = 0.60   -- how far out that icon sits, as a fraction of the room

local sin, cos, sqrt, pi = math.sin, math.cos, math.sqrt, math.pi

-- Bearing of each quarter's centre, radians counter-clockwise from north --
-- the same convention GetPlayerFacing uses.
local BEARING = { N = 0, W = pi / 2, S = pi, E = -pi / 2 }

local WEDGE_ART = { N = "wedge-n", E = "wedge-e", S = "wedge-s", W = "wedge-w" }

-- While the waves are being shown, each quarter wears its own marker's colour,
-- so the view reads the same as the board does and the player can match one to
-- the other. The moment the calling half starts there is only one question worth
-- answering -- where do I stand -- so the quarters drop their identities and go
-- to a traffic light:
--
--   green   stand here now, breathing until the player is actually in it
--   yellow  stand here next, and only once they have got to the green one
--   red     everything else, deepening as the wave comes in
--
-- Which makes it three red while they are still moving and two once they have
-- arrived. The raid icons stay on top throughout, so which quarter is which is
-- never lost -- it just stops being the thing the colour is saying.
local CALL_COLOR = {
	now    = { 0.16, 0.82, 0.26 },
	nextUp = { 1.00, 0.80, 0.10 },
	danger = { 0.90, 0.15, 0.12 },
}

-- Alpha per wedge state. "Reached" is a jump in brightness rather than only a
-- change in movement, so R7.6 still reads for a player who has the pulse off.
local ALPHA = {
	idle    = 0.20,
	next    = 0.80,
	pending = 0.55,   -- this wave's quarter, not stood in yet
	reached = 1.00,
}

local PULSE_PERIOD = 0.8    -- seconds per breath of the unreached safe quarter
local PULSE_DEPTH  = 0.28

local DANGER_BASE = 0.40    -- red the moment the call goes out
local DANGER_MAX  = 0.85    -- red at the moment the wave lands

local frame
local wedges, icons = {}, {}
local dot, arrow

-- What the replay is currently saying. Set from the subscription at the bottom,
-- which is the same seam the practice run drives.
local current, nextUp, stepAt

-- Last drawn state, for the readers at the end of the file.
local drawn = { state = {}, alpha = {}, color = {}, wash = {}, rotation = 0 }

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function ns.GetRadarEnabled()
	local v = ns.db().radarEnabled
	if v == nil then return true end
	return v
end

function ns.SetRadarEnabled(v)
	ns.db().radarEnabled = not not v
	Radar.ApplyShown()
end

function Radar.IsShown() return frame ~= nil and frame:IsShown() end
function Radar.GetFrame() return frame end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

-- Yards of floor the view covers from the centre out: the room's modelled
-- radius plus the margin of floor shown past the wall.
local function viewYards()
	return ns.ROOM.radius + ns.ROOM.drawMargin
end

local function pxPerYard()
	return (SIZE / 2) / viewYards()
end

-- Texture rotation is counter-clockwise for a positive angle. The player is
-- fixed and the room turns under them, so the room rotates by minus their
-- facing. Kept in one function: if it ever reads mirrored in game, this is the
-- only line that has to change, and the player dot follows from the same maths.
local function viewRotation(facing)
	return -(facing or 0)
end

-- Screen offset in px for a point `yards` out on world bearing `bearing`, with
-- the view turned so `facing` is up.
local function project(yards, bearing, facing)
	local a = bearing - (facing or 0)
	local px = pxPerYard()
	return -yards * sin(a) * px, yards * cos(a) * px
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build()
	if frame then return end

	frame = CreateFrame("Frame", "SnakeSaysRadar", UIParent)
	frame:SetSize(SIZE + 16, SIZE + 16)
	frame:SetFrameStrata("MEDIUM")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:Hide()

	local backdrop = frame:CreateTexture(nil, "BACKGROUND")
	backdrop:SetAllPoints(frame)
	backdrop:SetColorTexture(0, 0, 0, 0.45)

	-- The canvas covers the room plus the margin of floor past the wall. The
	-- four wedges only cover the room itself, so the edge of the coloured disc
	-- *is* the wall and standing past it is something you can see rather than
	-- something you have to be told.
	local canvas = CreateFrame("Frame", nil, frame)
	canvas:SetSize(SIZE, SIZE)
	canvas:SetPoint("CENTER", frame, "CENTER", 0, 0)
	frame.canvas = canvas

	local roomPx = SIZE * (ns.ROOM.radius / viewYards())

	for _, dir in ipairs(ns.QUADRANTS) do
		local wedge = canvas:CreateTexture(nil, "ARTWORK")
		wedge:SetTexture(MEDIA .. WEDGE_ART[dir] .. ".tga")
		wedge:SetSize(roomPx, roomPx)
		wedge:SetPoint("CENTER", canvas, "CENTER", 0, 0)
		wedges[dir] = wedge

		local icon = canvas:CreateTexture(nil, "OVERLAY")
		icon:SetSize(ICON, ICON)
		icon:SetTexture(ns.MARKER_TEXTURE)
		icons[dir] = icon
	end

	-- The player reads as the player: the same arrow the map puts them under.
	-- The view is already turned so their facing is up, so the arrow points up
	-- and never has to be rotated on its own.
	arrow = canvas:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(ARROW, ARROW)
	arrow:SetTexture(PLAYER_ARROW)
	arrow:Hide()

	-- Standing in for it when there is no facing to point with. An arrow with
	-- nothing behind it would be a claim about which way they are looking.
	dot = canvas:CreateTexture(nil, "OVERLAY")
	dot:SetSize(DOT, DOT)
	dot:SetColorTexture(1, 1, 1, 1)
	dot:Hide()

	frame:SetScript("OnDragStart", function(self)
		if not ns.IsLocked() then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		Radar.SavePosition(point, relPoint, x, y)
	end)

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	title:SetPoint("BOTTOM", frame, "BOTTOM", 0, 3)
	title:SetText("SnakeSays radar")
	frame.title = title

	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < UPDATE then return end
		elapsed = 0
		Radar.Update()
	end)

	Radar.ApplyPosition()
	Radar.ApplyScale()
	Radar.Update()
end

-- ---------------------------------------------------------------------------
-- Position
-- ---------------------------------------------------------------------------

-- Where the radar sits when the player hasn't placed it: hung off the left edge
-- of the board, so the two read as one unit and dragging the board carries the
-- radar with it. Once the player drags the radar itself it gets its own saved
-- position against the screen and stops following.
function Radar.ApplyPosition()
	if not frame then return end
	frame:ClearAllPoints()

	local stored = ns.db().radarPosition
	if stored and stored.point then
		frame:SetPoint(stored.point, UIParent, stored.relPoint or stored.point, stored.x or 0, stored.y or 0)
		return
	end

	local board = ns.HUD and ns.HUD.GetFrame and ns.HUD.GetFrame()
	if board then
		frame:SetPoint("TOPRIGHT", board, "TOPLEFT", -6, 0)
	else
		frame:SetPoint("RIGHT", UIParent, "RIGHT", -80, 0)
	end
end

-- True while the radar is riding along with the board rather than pinned to the
-- screen on its own.
function Radar.IsAttachedToBoard()
	local stored = ns.db().radarPosition
	return not (stored and stored.point)
end

function Radar.SavePosition(point, relPoint, x, y)
	ns.db().radarPosition = { point = point, relPoint = relPoint, x = x, y = y }
	Radar.ApplyPosition()
end

function Radar.ClearPosition()
	ns.db().radarPosition = nil
	Radar.ApplyPosition()
end

function Radar.ApplyScale()
	if not frame then return end
	frame:SetScale(ns.GetRadarScale())
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

-- How far through the current call we are, 0 at the announcement and 1 when the
-- wave lands. The end time is read off the live cast, which is the only honest
-- source: on hard the cast runs at one of two lengths and swaps part way
-- through a round.
local function callProgress()
	if not current or not stepAt then return 0 end
	local endsAt = ns.Detector.CastEndsAt()
	if not endsAt then return 0 end
	local span = endsAt - stepAt
	if span <= 0 then return 1 end
	local p = (GetTime() - stepAt) / span
	if p < 0 then return 0 end
	if p > 1 then return 1 end
	return p
end

local function pulse()
	if not ns.GetTargetBlink() then return 0 end
	return PULSE_DEPTH * (0.5 + 0.5 * sin(2 * pi * GetTime() / PULSE_PERIOD))
end

-- Where the player sits on the canvas, and whether they had to be pulled in to
-- fit. The room is far longer north-south than the modelled circle, so standing
-- off the drawn floor is ordinary rather than exceptional: the dot goes to the
-- rim in the right direction and changes colour, which still answers "which way
-- am I from the middle" (R7.7).
local function placePlayer(facing)
	local north, west = ns.Position.Offset()
	if north == nil then
		arrow:Hide()
		dot:Hide()
		return nil
	end

	local f = facing or 0
	local px = pxPerYard()
	local x = (north * sin(f) - west * cos(f)) * px
	local y = (north * cos(f) + west * sin(f)) * px

	local limit = SIZE / 2 - DOT
	local r = sqrt(x * x + y * y)
	local clamped = false
	if r > limit and r > 0 then
		x, y, clamped = x * limit / r, y * limit / r, true
	end

	-- Amber says "off the drawn floor, that way"; white says "here". The two have
	-- to look different, because at the rim they sit in the same place.
	local marker = facing and arrow or dot
	local spare  = facing and dot or arrow
	spare:Hide()

	marker:ClearAllPoints()
	marker:SetPoint("CENTER", frame.canvas, "CENTER", x, y)
	if clamped then
		marker:SetVertexColor(1, 0.75, 0.2, 1)
	else
		marker:SetVertexColor(1, 1, 1, 1)
	end
	marker:Show()

	return x, y, clamped
end

function Radar.Update()
	if not frame or not frame:IsShown() then return false end

	local facing = ns.Position.Facing()
	local rotation = viewRotation(facing)
	local standing = ns.Position.Quadrant()

	-- R7.4 / R7.5: the next-up hint waits until the player has arrived, is never
	-- shown for the quarter they are already being sent to, and does not exist on
	-- the last wave (the replay hands over no next at all there).
	local reached  = current ~= nil and standing == current
	local showNext = current ~= nil and nextUp ~= nil and nextUp ~= current and reached

	local progress = callProgress()
	local lit = reached and ALPHA.reached or (ALPHA.pending + pulse())

	for _, dir in ipairs(ns.QUADRANTS) do
		local marker = ns.GetMarker(ns.GetAssignment(dir))

		local state, color, alpha
		if current == nil then
			-- Nothing being called: the quarters wear their own markers.
			state = "idle"
			color = marker and marker.color or { 1, 1, 1 }
			alpha = ALPHA.idle
		elseif dir == current then
			state, color, alpha = "now", CALL_COLOR.now, lit
		elseif showNext and dir == nextUp then
			state, color, alpha = "next", CALL_COLOR.nextUp, ALPHA.next
		else
			state, color = "danger", CALL_COLOR.danger
			alpha = DANGER_BASE + (DANGER_MAX - DANGER_BASE) * progress
		end

		local wedge = wedges[dir]
		wedge:SetRotation(rotation)
		wedge:SetVertexColor(color[1], color[2], color[3], alpha)

		local icon = icons[dir]
		if marker then
			icon:SetTexCoord(unpack(marker.coords))
			local ix, iy = project(ns.ROOM.radius * ICON_AT, BEARING[dir], facing)
			icon:ClearAllPoints()
			icon:SetPoint("CENTER", frame.canvas, "CENTER", ix, iy)
			icon:SetVertexColor(1, 1, 1, state == "idle" and 0.65 or 1)
			icon:Show()
		else
			icon:Hide()
		end

		drawn.state[dir] = state
		drawn.alpha[dir] = alpha
		drawn.color[dir] = color
		drawn.wash[dir] = state == "danger" and alpha or 0
	end

	local x, y, clamped = placePlayer(facing)
	drawn.rotation = rotation
	drawn.x, drawn.y, drawn.clamped = x, y, clamped
	drawn.reached = reached
	drawn.showNext = showNext
	drawn.progress = progress

	return true
end

-- ---------------------------------------------------------------------------
-- Readers
-- ---------------------------------------------------------------------------

-- What the view is saying about a quarter as of the last draw:
--   idle    nothing is being called
--   now     be here for the wave in the air
--   next    be here for the one after it
--   danger  not the safe quarter this wave
function Radar.QuadrantState(dir) return drawn.state[dir] end

-- How brightly a quarter was last drawn. The step between "on your way" and
-- "you are there" lives here rather than only in the pulse, so it survives a
-- player who has the pulse switched off.
function Radar.QuadrantAlpha(dir) return drawn.alpha[dir] end

-- The colour a quarter was last drawn in, as r, g, b.
function Radar.QuadrantColor(dir)
	local c = drawn.color[dir]
	if not c then return nil end
	return c[1], c[2], c[3]
end

-- How hard the "about to be hit" wash is being pushed on a quarter, 0 to
-- DANGER_MAX. Rises as the boss' cast runs down.
function Radar.DangerAlpha(dir) return drawn.wash[dir] or 0 end

-- The player marker's offset from the middle of the canvas, in px, and whether
-- it had to be pulled in to the rim to fit.
function Radar.PlayerPoint() return drawn.x, drawn.y, drawn.clamped end

-- How far the room is turned, in radians. Zero when facing is unreadable, which
-- is the north-up fallback.
function Radar.Rotation() return drawn.rotation end

-- Whether the player is standing in the quarter being called right now.
function Radar.HasReached() return drawn.reached == true end

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------

-- Follows the same map restriction as the board.
function Radar.ApplyShown()
	-- Build on demand as well as at login: something may want the radar before
	-- PLAYER_LOGIN has come round, and a radar that silently never exists is
	-- much harder to diagnose than one that builds late.
	if not frame then build() end
	if not frame then return end
	if not ns.GetRadarEnabled() then
		frame:Hide()
		return
	end
	frame:SetShown(ns.HasVisibilityOverride() or not ns.GetRestrictToMap() or ns.InDelve())
end

-- ---------------------------------------------------------------------------
-- Wiring
-- ---------------------------------------------------------------------------

function Radar.OnStep(_, safe, upNext)
	current, nextUp = safe, upNext
	stepAt = GetTime()
	Radar.Update()
end

function Radar.OnEnd()
	current, nextUp, stepAt = nil, nil, nil
	Radar.Update()
end

ns.Detector.OnReplayStep(Radar.OnStep)
ns.Detector.OnReplayEnd(Radar.OnEnd)

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:RegisterEvent("ZONE_CHANGED")
boot:RegisterEvent("ZONE_CHANGED_INDOORS")
boot:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then build() end
	Radar.ApplyShown()
end)
