local _, ns = ...

-- ===========================================================================
-- Radar.lua  ·  a top-down view of the room, in its own window.
--
-- Shows the room as a circle split into the same four quadrants as the board,
-- with the player drawn live inside it. The view turns with the player, so "up"
-- on the radar is always the way they are facing and a call of "go left" reads
-- as left. When the boss is repeating the run, the whole thing is tinted: green
-- while the player stands in the safe quadrant, red while they don't.
--
-- Deliberately a separate frame from the board rather than an overlay on it, so
-- the radar can sit where the player is already looking while the board stays
-- wherever they put it.
--
-- Nothing here is protected, and every position read is guarded, so the radar
-- keeps drawing in combat and simply stops moving the arrow if the client stops
-- handing out coordinates.
-- ===========================================================================

local Radar = {}
ns.Radar = Radar

local SIZE       = 190     -- canvas px
local UPDATE     = 0.05    -- redraw interval while shown
local ARROW      = 26
local BLIP       = 9
local LABEL_ICON = 24      -- marker icons on the rim; big enough to read at a glance

-- Each cardinal quadrant spans the 90 degrees centred on its own marker, so the
-- boundaries between them lie on the diagonals -- a quarter turn off the marker
-- positions. Drawing the dividers on the marker axes would put a line straight
-- through every marker and, worse, show boundaries where there aren't any.
local BOUNDARY_OFFSET = math.pi / 4

-- Tints for the three states. Green and red are the whole point of the window,
-- so they are strong; neutral is barely there.
local STATE_COLOR = {
	safe    = { 0.15, 0.85, 0.25, 0.34 },
	danger  = { 0.90, 0.15, 0.12, 0.34 },
	neutral = { 0.45, 0.55, 0.70, 0.12 },
}

local WEDGES = {
	{ dir = "N", dx =  0, dy =  1 },
	{ dir = "E", dx =  1, dy =  0 },
	{ dir = "S", dx =  0, dy = -1 },
	{ dir = "W", dx = -1, dy =  0 },
}

-- Quarter-circle slices, cut from the corners of a round alpha mask. Unrotated
-- these are the NE/SE/SW/NW quarters; the whole set is turned by BOUNDARY_OFFSET
-- so each one ends up centred on a cardinal marker, matching how the quadrants
-- are actually bucketed. `dx, dy` is the direction from the circle's centre to
-- the slice's own bounding-box centre -- rotating a slice about its own centre
-- while moving that centre along the same rotation turns it about the circle.
local SLICES = {
	{ dir = "N", dx =  1, dy =  1, coords = { 0.5, 1.0, 0.0, 0.5 } },
	{ dir = "E", dx =  1, dy = -1, coords = { 0.5, 1.0, 0.5, 1.0 } },
	{ dir = "S", dx = -1, dy = -1, coords = { 0.0, 0.5, 0.5, 1.0 } },
	{ dir = "W", dx = -1, dy =  1, coords = { 0.0, 0.5, 0.0, 0.5 } },
}

-- The safe slice pulses until the player is standing in it, then holds steady.
-- Slow on purpose: a fast flash in the corner of the eye reads as an alarm, and
-- the point is to draw the eye once, not to nag.
local BLINK_PERIOD = 1.4
local BLINK_DIM, BLINK_BRIGHT = 0.13, 0.46
local REACHED_ALPHA = 0.55

-- Once the player is safe, the slice they'll be sent to next is previewed in
-- yellow. It only appears after they've arrived: while they're still travelling,
-- a second lit slice is just something else to misread under pressure.
local NEXT_ALPHA = 0.30

-- Every quadrant that isn't the call and isn't the preview is somewhere the wave
-- lands. Painting those red rather than leaving them clear means the radar reads
-- the same way round as the fight: one green slice to be in, the rest to avoid.
local DANGER_ALPHA = 0.26

local SLICE_COLOR = {
	target = { 0.15, 0.90, 0.30 },   -- green: stand here now
	next   = { 1.00, 0.82, 0.10 },   -- yellow: here after this one
	danger = { 0.90, 0.13, 0.10 },   -- red: this one gets hit
}

local frame
local mapRotation = 0
local markerKind = "none"   -- "arrow" | "blip" | "none"

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

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

function Radar.StateColor(state)
	local c = STATE_COLOR[state] or STATE_COLOR.neutral
	return c[1], c[2], c[3], c[4]
end

-- Green when the player is where the current call says to be, red when they are
-- anywhere else, neutral whenever there is no live call to judge them against
-- (or no readable position -- silence beats a confident wrong answer).
function Radar.SafetyState()
	if not ns.Detector.IsReplaying() then return "neutral" end
	local index = ns.Detector.EchoIndex()
	if index < 1 then return "neutral" end

	local safe = ns.Seq.Get()[index]
	if not safe then return "neutral" end

	local standing = ns.Position.Quadrant()
	if not standing then return "neutral" end

	return standing == safe and "safe" or "danger"
end

function Radar.MapRotation() return mapRotation end
function Radar.DividerRotation() return mapRotation + BOUNDARY_OFFSET end

-- The quadrant the current call is telling the player to stand in, or nil when
-- there is no live call.
function Radar.TargetQuadrant()
	if not ns.Detector.IsReplaying() then return nil end
	local index = ns.Detector.EchoIndex()
	if index < 1 then return nil end
	return ns.Seq.Get()[index]
end

function Radar.IsTargetReached()
	local target = Radar.TargetQuadrant()
	return target ~= nil and ns.Position.Quadrant() == target
end

-- How strongly to paint the safe slice right now. Zero when nothing is being
-- called; steady once the player has arrived (or if they've turned the pulse
-- off); a slow sine otherwise.
function Radar.TargetAlpha()
	if not Radar.TargetQuadrant() then return 0 end
	if Radar.IsTargetReached() or not ns.GetTargetBlink() then return REACHED_ALPHA end
	local phase = (GetTime() % BLINK_PERIOD) / BLINK_PERIOD
	local wave = 0.5 + 0.5 * math.cos(phase * 2 * math.pi)
	return BLINK_DIM + (BLINK_BRIGHT - BLINK_DIM) * wave
end

-- The slice after this one, previewed only once the player is standing safe.
-- Nil on the last wave, and nil when the next call is for the quadrant they're
-- already in -- painting yellow over the green would say "move" when the answer
-- is "stay", and the on-screen call already spells that case out in words.
function Radar.NextQuadrant()
	if not Radar.IsTargetReached() then return nil end
	local nextUp = ns.Seq.Get()[ns.Detector.EchoIndex() + 1]
	if not nextUp or nextUp == Radar.TargetQuadrant() then return nil end
	return nextUp
end

-- Steady, and dimmer than the target: it's information for later, not now.
function Radar.NextAlpha()
	return Radar.NextQuadrant() and NEXT_ALPHA or 0
end

function Radar.SliceColor(role)
	local c = SLICE_COLOR[role]
	if not c then return nil end
	return c[1], c[2], c[3]
end

-- What a given quadrant means right now: "target", "next", "danger", or nil when
-- there is no live call and the radar is saying nothing about anywhere.
function Radar.SliceRole(dir)
	local target = Radar.TargetQuadrant()
	if not target then return nil end
	if dir == target then return "target" end
	if dir == Radar.NextQuadrant() then return "next" end
	return "danger"
end

function Radar.SliceAlpha(role)
	if role == "target" then return Radar.TargetAlpha() end
	if role == "next" then return NEXT_ALPHA end
	if role == "danger" then return DANGER_ALPHA end
	return 0
end
function Radar.MarkerKind() return markerKind end
function Radar.IsShown() return frame ~= nil and frame:IsShown() end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function build()
	if frame then return end

	local radius = SIZE / 2 - 12
	local yardsAcross = 2 * (ns.ROOM.radius + ns.ROOM.pad)
	local pixelsPerYard = SIZE / yardsAcross

	frame = CreateFrame("Frame", "SnakeSaysRadar", UIParent)
	frame:SetSize(SIZE + 16, SIZE + 16)
	frame:SetFrameStrata("MEDIUM")
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:Hide()
	frame.pixelsPerYard = pixelsPerYard
	frame.radius = radius

	local backdrop = frame:CreateTexture(nil, "BACKGROUND")
	backdrop:SetAllPoints(frame)
	backdrop:SetColorTexture(0, 0, 0, 0.45)

	-- The room floor, recoloured every frame with the safety tint.
	local disc = frame:CreateTexture(nil, "ARTWORK")
	disc:SetSize(radius * 2, radius * 2)
	disc:SetPoint("CENTER")
	disc:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
	frame.disc = disc

	-- One slice per quadrant, drawn above the floor. Only the safe one is ever
	-- painted; the rest sit hidden until their turn comes round.
	frame.slices = {}
	for _, slice in ipairs(SLICES) do
		local tex = frame:CreateTexture(nil, "ARTWORK", nil, 2)
		tex:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
		tex:SetTexCoord(unpack(slice.coords))
		tex:SetSize(radius, radius)
		tex:Hide()
		frame.slices[slice.dir] = { tex = tex, dx = slice.dx, dy = slice.dy }
	end

	-- Quadrant divider lines, rotated with the view.
	local divider1 = frame:CreateTexture(nil, "ARTWORK", nil, 1)
	divider1:SetColorTexture(1, 1, 1, 0.22)
	divider1:SetSize(1.5, radius * 2)
	divider1:SetPoint("CENTER")
	local divider2 = frame:CreateTexture(nil, "ARTWORK", nil, 1)
	divider2:SetColorTexture(1, 1, 1, 0.22)
	divider2:SetSize(radius * 2, 1.5)
	divider2:SetPoint("CENTER")
	frame.dividers = { divider1, divider2 }

	-- One label per quadrant, carrying that quadrant's marker icon so the radar
	-- reads in the same vocabulary as the board and the voice.
	frame.labels = {}
	for _, wedge in ipairs(WEDGES) do
		local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		frame.labels[wedge.dir] = { fs = fs, dx = wedge.dx, dy = wedge.dy }
	end

	local arrow = frame:CreateTexture(nil, "OVERLAY")
	arrow:SetSize(ARROW, ARROW)
	arrow:SetTexture("Interface\\Minimap\\MinimapArrow")
	arrow:SetPoint("CENTER")
	arrow:Hide()
	frame.arrow = arrow

	-- Shown instead of the arrow when facing is withheld: the player's position
	-- is still worth drawing even when their heading isn't known.
	local blip = frame:CreateTexture(nil, "OVERLAY")
	blip:SetSize(BLIP, BLIP)
	blip:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
	blip:SetVertexColor(1, 0.9, 0.2, 1)
	blip:SetPoint("CENTER")
	blip:Hide()
	frame.blip = blip

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	title:SetPoint("BOTTOM", frame, "BOTTOM", 0, 3)
	title:SetText("SnakeSays radar")
	frame.title = title

	frame:SetScript("OnDragStart", function(self)
		if not ns.IsLocked() then self:StartMoving() end
	end)
	frame:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		Radar.SavePosition(point, relPoint, x, y)
	end)

	local elapsed = 0
	frame:SetScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed < UPDATE then return end
		elapsed = 0
		Radar.Update()
	end)

	Radar.ApplyPosition()
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

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

function Radar.Update()
	if not frame then return end

	-- The floor only carries the safe/danger wash when there is no live call. Once
	-- the slices are painted they say it better and per quadrant, and a tint under
	-- them would turn every red slice muddy.
	local discState = Radar.TargetQuadrant() and "neutral" or Radar.SafetyState()
	frame.disc:SetVertexColor(Radar.StateColor(discState))

	-- Turn the room so the player's heading is up. When facing is withheld we
	-- hold north-up rather than spinning to a stale angle.
	local facing = ns.Position.Facing()
	mapRotation = facing and -facing or 0

	local cos, sin = math.cos(mapRotation), math.sin(mapRotation)
	local sliceRotation = mapRotation + BOUNDARY_OFFSET
	for _, divider in ipairs(frame.dividers) do
		divider:SetRotation(sliceRotation)
	end

	-- Paint every slice for what it is right now: the call in green, the preview
	-- in yellow, and everything the wave will hit in red.
	local sliceCos, sliceSin = math.cos(sliceRotation), math.sin(sliceRotation)
	local half = frame.radius / 2

	for dir, slice in pairs(frame.slices) do
		local role = Radar.SliceRole(dir)
		local alpha = Radar.SliceAlpha(role)

		if role and alpha > 0 then
			local ox, oy = slice.dx * half, slice.dy * half
			slice.tex:ClearAllPoints()
			slice.tex:SetPoint("CENTER", frame, "CENTER",
				ox * sliceCos - oy * sliceSin, ox * sliceSin + oy * sliceCos)
			slice.tex:SetRotation(sliceRotation)
			local r, g, b = Radar.SliceColor(role)
			slice.tex:SetVertexColor(r, g, b, alpha)
			slice.tex:Show()
		else
			slice.tex:Hide()
		end
	end

	for dir, label in pairs(frame.labels) do
		local marker = ns.GetMarker(ns.GetAssignment(dir))
		label.fs:SetText(marker and ns.MarkerIconMarkup(marker, LABEL_ICON) or dir)
		local lx, ly = label.dx * frame.radius * 0.74, label.dy * frame.radius * 0.74
		label.fs:ClearAllPoints()
		label.fs:SetPoint("CENTER", frame, "CENTER",
			lx * cos - ly * sin, lx * sin + ly * cos)
	end

	local x, y = ns.Position.Offset()
	if not x then
		markerKind = "none"
		frame.arrow:Hide()
		frame.blip:Hide()
		return
	end

	-- Clamp a player who has wandered outside the drawn area to its edge, dimmed,
	-- so the radar still points the right way instead of losing them entirely.
	local distance = math.sqrt(x * x + y * y)
	local maxRadius = ns.ROOM.radius + ns.ROOM.pad
	local alpha = 1
	if distance > maxRadius and distance > 0 then
		x, y = x * maxRadius / distance, y * maxRadius / distance
		alpha = 0.45
	end

	local screenX = (x * cos - y * sin) * frame.pixelsPerYard
	local screenY = (x * sin + y * cos) * frame.pixelsPerYard

	local marker
	if facing then
		markerKind = "arrow"
		marker = frame.arrow
		-- The arrow art points north; rotating it by facing plus the map's own
		-- rotation leaves it pointing up, which is what "facing up" means.
		pcall(marker.SetRotation, marker, facing + mapRotation)
		frame.blip:Hide()
	else
		markerKind = "blip"
		marker = frame.blip
		frame.arrow:Hide()
	end

	marker:SetAlpha(alpha)
	marker:ClearAllPoints()
	marker:SetPoint("CENTER", frame, "CENTER", screenX, screenY)
	marker:Show()
end

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------

-- Follows the same map restriction as the board: inside the delve by default,
-- everywhere once the player unticks it -- which is also how they get the radar
-- on screen to drag it somewhere without pulling the boss first.
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
	if frame:IsShown() then Radar.Update() end
end

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
