local addonName, ns = ...

-- ===========================================================================
-- HUD.lua  ·  the Simon-Says board.
--
-- A circle split by an X into four cardinal wedges (N/E/S/W), each tinted to
-- its assigned marker's colour and stamped with that marker's raid icon. Click
-- a wedge (or press its keybind) to append it to the recorded sequence, which
-- renders as a row of marker icons beneath the circle. A reset button sits at
-- the left of that row. Everything here is plain frames/textures, so it all
-- works while in combat.
--
-- Wedge shapes come from pre-oriented art (Media/wedge-{n,e,s,w}.tga, white so
-- we can vertex-colour them). A single button covers the circle and works out
-- which wedge the cursor is over from its offset to the centre -- see
-- HUD.DirectionAt, which is the predicate the art itself was drawn from, so the
-- area that answers a click is the area that is coloured.
--
-- It used to be four buttons, each a full-circle rectangle trimmed to its wedge
-- with hit-rect insets. Rectangles cannot tile a disc into sectors: adjacent
-- boxes overlapped across a fifth of the board -- whichever button was on top
-- took the press, which beside a seam was the wrong one -- and the outer part of
-- every diagonal answered to nobody. Reported from the field as marking the
-- wrong colour, which it was.
--
-- Built at PLAYER_LOGIN so requiring this file headless never touches in-game
-- frame APIs.
-- ===========================================================================

local HUD = {}
ns.HUD = HUD

local MEDIA = "Interface\\AddOns\\" .. addonName .. "\\Media\\"

local CIRCLE     = 150     -- wedge circle diameter
local MOVER_H    = 16
local SEQ_ICON   = 26
local SEQ_GAP    = 4
local RESET_SIZE = 26
local PAD        = 12
local ROW_GAP    = 8

-- Where the run starts in the row: after the reset button.
local SEQ_START = RESET_SIZE + SEQ_GAP * 2

local WEDGES = {
	N = { file = "wedge-n", point = "TOP",    ox =  0, oy = -24 },
	E = { file = "wedge-e", point = "RIGHT",  ox = -24, oy =  0 },
	S = { file = "wedge-s", point = "BOTTOM", ox =  0, oy =  24 },
	W = { file = "wedge-w", point = "LEFT",   ox =  24, oy =  0 },
}

-- Where the paint actually is, taken from the numbers the art was generated
-- with (tools/gen_wedge.py: a 256px texture, OUTER_R 125, INNER_R 18, measured
-- from a half-size of 128) and scaled to the size it is drawn at. Hit-testing
-- against these rather than against the frame means a click just past the rim,
-- or in the hub hole, is not a press: there is nothing there to press.
local ART_HALF = 128
local RADIUS   = CIRCLE / 2 * (125 / ART_HALF)   -- outer edge of the paint
local HUB      = CIRCLE / 2 * (18 / ART_HALF)    -- the hole in the middle

local frame, circle, row, board
local background       -- the dark panel behind everything; its alpha is a setting
local buttons = {}     -- dir -> { wedge, icon, colour } for one direction
local seqIcons = {}    -- pooled sequence-row textures
local hovered          -- dir currently lit by the cursor, nil when it is away

-- ---------------------------------------------------------------------------
-- Marker helpers
-- ---------------------------------------------------------------------------

local function applyMarkerIcon(tex, marker)
	tex:SetTexture(ns.MARKER_TEXTURE)
	tex:SetTexCoord(unpack(marker.coords))
end

-- A wedge in its resting colour, or brightened under the mouse. One function,
-- because three places put a wedge back to normal -- a repaint, the end of a
-- flash, and the mouse leaving -- and each of them used to do it by hand.
local function paintWedge(b, highlight)
	local boost = highlight and 1.35 or 1
	b.wedge:SetVertexColor(b.r * boost, b.g * boost, b.b * boost)
end

-- ---------------------------------------------------------------------------
-- Hit-testing
-- ---------------------------------------------------------------------------

-- Which wedge covers the point (dx, dy) offset from the centre of the circle,
-- in board pixels with y pointing up; nil for the hub hole and for anything
-- past the rim, where there is no wedge to press.
--
-- Pure, and deliberately so: this is the one piece of the board's behaviour a
-- player can be made to get wrong in a fight, and it can be proven headlessly
-- over every point of the circle rather than trusted.
--
-- The diagonal seams the art leaves as a narrow transparent gap are not dead
-- here. A band that swallows presses is worse in a fight than a boundary that
-- answers consistently, so a point in a seam goes to the wedge whose side of it
-- it is on, and a point exactly on the diagonal goes to N/S.
function HUD.DirectionAt(dx, dy)
	local r2 = dx * dx + dy * dy
	if r2 > RADIUS * RADIUS or r2 < HUB * HUB then return nil end
	if math.abs(dy) >= math.abs(dx) then
		return dy > 0 and "N" or "S"
	end
	return dx > 0 and "E" or "W"
end

-- The cursor's offset from the centre of the circle, in board pixels. The
-- cursor comes back in screen pixels, so it is the frame's effective scale --
-- the player's board scale times the UI scale -- that puts the two in the same
-- units; without that division a scaled board reads every press off-centre.
local function cursorOffset()
	local cx, cy = circle:GetCenter()
	local scale = circle:GetEffectiveScale()
	if not cx or not scale or scale == 0 then return nil end
	local mx, my = GetCursorPosition()
	return mx / scale - cx, my / scale - cy
end

local function dirUnderCursor()
	local dx, dy = cursorOffset()
	if not dx then return nil end
	return HUD.DirectionAt(dx, dy)
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

-- A wedge is now paint and an icon; the pressing is the board's job.
local function buildWedge(dir, def)
	local b = {}

	local wedge = board:CreateTexture(nil, "ARTWORK")
	wedge:SetTexture(MEDIA .. def.file .. ".tga")
	wedge:SetAllPoints(board)
	b.wedge = wedge

	local icon = board:CreateTexture(nil, "OVERLAY")
	icon:SetSize(30, 30)
	icon:SetPoint(def.point, board, def.point, def.ox, def.oy)
	b.icon = icon

	buttons[dir] = b
end

-- Light the wedge under the cursor, and only that one. Called as the cursor
-- moves, so it does nothing at all until the answer changes.
local function hover(dir)
	if dir == hovered then return end
	if hovered then paintWedge(buttons[hovered]) end
	hovered = dir
	if not dir then
		GameTooltip:Hide()
		return
	end
	paintWedge(buttons[dir], true)
	GameTooltip:SetOwner(board, "ANCHOR_TOP")
	GameTooltip:SetText(ns.QUADRANT_NAME[dir])
	GameTooltip:AddLine("Right-click takes the last press back.", 0.7, 0.7, 0.7)
	GameTooltip:Show()
end

-- One button for all four wedges, which is what lets a wedge be a wedge: the
-- shape is decided in DirectionAt, not by the rectangle that took the click.
local function buildBoard()
	-- Named so it can be looked at from a `/run` line: this is the one part of
	-- the addon whose behaviour cannot be reproduced headlessly.
	board = CreateFrame("Button", "SnakeSaysBoard", circle)
	board:SetAllPoints(circle)

	-- Right-click undoes wherever it lands on the board, wedge or not: a misclick
	-- is noticed a fraction of a second after it happens, with the cursor still on
	-- the circle, and the fix has to be where the hand already is. Where exactly
	-- does not matter -- the board only ever gives back its last press.
	board:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	board:SetScript("OnClick", function(_, mouseButton)
		local dir = dirUnderCursor()
		-- Traced before anything else: "the board did nothing" and "the click
		-- never reached the board" are different problems with the same symptom,
		-- and only this line tells them apart. The direction is in it because a
		-- press landing on the wrong wedge is a third one.
		ns.Trace("board %s-clicked over %s%s", mouseButton == "RightButton" and "right" or "left",
			dir or "nothing",
			InCombatLockdown and InCombatLockdown() and " (in combat)" or "")
		if mouseButton == "RightButton" then
			ns.Seq.Undo()
		elseif dir and ns.Seq.Press(dir) then
			HUD.Flash(dir)
		end
	end)

	-- The cursor can cross a seam without ever leaving the button, so the
	-- highlight has to follow it while it is inside. The watcher runs only
	-- between enter and leave -- the same shape as the mover's drag watchdog
	-- below, and for the same reason: nothing ticks when nothing is happening.
	local function track() hover(dirUnderCursor()) end
	board:SetScript("OnEnter", function(self)
		self:SetScript("OnUpdate", track)
		track()
	end)
	board:SetScript("OnLeave", function(self)
		self:SetScript("OnUpdate", nil)
		hover(nil)
	end)
	-- A board hidden under the cursor never gets its OnLeave, and would come back
	-- with a wedge still lit.
	board:SetScript("OnHide", function(self)
		self:SetScript("OnUpdate", nil)
		hover(nil)
	end)
end

local function buildResetButton()
	local b = CreateFrame("Button", nil, row)
	b:SetSize(RESET_SIZE, RESET_SIZE)
	b:SetPoint("LEFT", row, "LEFT", 0, 0)

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(b)
	bg:SetColorTexture(0, 0, 0, 0.45)
	b.bg = bg

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("CENTER")
	icon:SetSize(RESET_SIZE - 6, RESET_SIZE - 6)
	icon:SetAtlas("common-icon-undo")     -- circular "undo" arrow; harmless if absent
	icon:SetVertexColor(1, 0.82, 0.2)

	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnClick", function(_, mouseButton)
		if mouseButton == "RightButton" then ns.Seq.Undo() else ns.Seq.Reset() end
	end)
	b:SetScript("OnEnter", function()
		bg:SetColorTexture(0.3, 0.3, 0.3, 0.6)
		GameTooltip:SetOwner(b, "ANCHOR_TOP")
		GameTooltip:SetText("Reset sequence")
		GameTooltip:AddLine("Right-click takes the last press back.", 0.7, 0.7, 0.7)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		bg:SetColorTexture(0, 0, 0, 0.45)
		GameTooltip:Hide()
	end)
end

local function buildMover()
	local mover = CreateFrame("Frame", nil, frame)
	mover:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	mover:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
	mover:SetHeight(MOVER_H)
	mover:EnableMouse(true)

	local bg = mover:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(mover)
	bg:SetColorTexture(1, 1, 1, 0.06)
	mover.bg = bg

	local title = mover:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	title:SetPoint("CENTER")
	title:SetText("SnakeSays")
	local font, size, flags = title:GetFont()
	if font then title:SetFont(font, (size or 10) + 2, flags) end
	mover.title = title

	-- Move via mouse-down/up rather than OnDragStart/OnDragStop: with a thin drag
	-- strip plus SetClampedToScreen, dragging into a screen edge separates the
	-- cursor from the strip and the drag-stop is missed, leaving the frame stuck
	-- to the cursor. A watchdog (only active while moving) stops the move the
	-- instant the button is released anywhere on screen.
	local moving = false
	local function stopDrag()
		if not moving then return end
		moving = false
		mover:SetScript("OnUpdate", nil)
		frame:StopMovingOrSizing()
		local point, _, relPoint, x, y = frame:GetPoint(1)
		ns.SavePosition(point, relPoint, x, y)
	end
	mover:SetScript("OnMouseDown", function(_, button)
		if button ~= "LeftButton" or ns.IsLocked() then return end
		moving = true
		frame:StartMoving()
		mover:SetScript("OnUpdate", function()
			if not IsMouseButtonDown("LeftButton") then stopDrag() end
		end)
	end)
	mover:SetScript("OnMouseUp", stopDrag)
	mover:SetScript("OnHide", stopDrag)
	mover:SetScript("OnEnter", function()
		if not ns.IsLocked() then bg:SetColorTexture(1, 0.82, 0.2, 0.18) end
	end)
	mover:SetScript("OnLeave", function()
		bg:SetColorTexture(1, 1, 1, 0.06)
	end)

	frame.mover = mover
end

local function build()
	if frame then return end

	-- Wide enough for the longest round the fight can show, asked of the detector
	-- rather than written down: the wave counts live in one table, and the board
	-- should follow them if they ever change.
	local width  = math.max(CIRCLE + PAD * 2,
		PAD * 2 + SEQ_START + ns.Detector.MaxWaves() * (SEQ_ICON + SEQ_GAP))
	local height = MOVER_H + 4 + CIRCLE + ROW_GAP + SEQ_ICON + PAD

	frame = CreateFrame("Frame", "SnakeSaysHUD", UIParent)
	frame:SetSize(width, height)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("MEDIUM")

	background = frame:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints(frame)
	HUD.ApplyBackgroundAlpha()

	buildMover()

	circle = CreateFrame("Frame", nil, frame)
	circle:SetSize(CIRCLE, CIRCLE)
	circle:SetPoint("TOP", frame, "TOP", 0, -(MOVER_H + 4))

	row = CreateFrame("Frame", nil, frame)
	row:SetSize(width - PAD * 2, SEQ_ICON)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(MOVER_H + 4 + CIRCLE + ROW_GAP))

	buildBoard()
	for _, dir in ipairs(ns.QUADRANTS) do
		buildWedge(dir, WEDGES[dir])
	end
	buildResetButton()

	ns.Seq.OnChange(HUD.RenderSequence)
	HUD.Refresh()
	HUD.ResetPosition()
	HUD.ApplyScale()
	HUD.ApplyShown()
	HUD.ApplyLock()
	-- Last, and it has to be here rather than only in Comms: Comms.lua loads
	-- first, so its PLAYER_LOGIN runs before this frame exists and its call to
	-- install the chat macros finds nothing to install them on. Without this line
	-- the wedges carry no macro until the setting is next touched.
end

-- ---------------------------------------------------------------------------
-- Render / state application
-- ---------------------------------------------------------------------------

-- Repaint each wedge from its current marker assignment (colour + icon).
function HUD.Refresh()
	if not frame then return end
	for _, dir in ipairs(ns.QUADRANTS) do
		local b = buttons[dir]
		local marker = ns.GetMarker(ns.GetAssignment(dir))
		local c = marker.color
		b.r, b.g, b.b = c[1], c[2], c[3]
		applyMarkerIcon(b.icon, marker)
		paintWedge(b)
	end
	HUD.RenderSequence(ns.Seq.Get())
end

-- Lay out the recorded sequence as a row of marker icons after the buttons.
function HUD.RenderSequence(list)
	if not frame then return end
	local startX = SEQ_START
	for i, dir in ipairs(list) do
		local tex = seqIcons[i]
		if not tex then
			tex = row:CreateTexture(nil, "ARTWORK")
			tex:SetSize(SEQ_ICON, SEQ_ICON)
			tex:SetPoint("LEFT", row, "LEFT", startX + (i - 1) * (SEQ_ICON + SEQ_GAP), 0)
			seqIcons[i] = tex
		end
		applyMarkerIcon(tex, ns.GetMarker(ns.GetAssignment(dir)))
		tex:Show()
	end
	for i = #list + 1, #seqIcons do
		seqIcons[i]:Hide()
	end
end

-- Brief white pulse on a wedge to confirm a press (mouse or keybind).
function HUD.Flash(dir)
	local b = frame and buttons[dir]
	if not b then return end
	b.wedge:SetVertexColor(1, 1, 1, 1)
	if b.flashTimer then b.flashTimer:Cancel() end
	b.flashTimer = C_Timer.NewTimer(0.16, function()
		paintWedge(b, hovered == dir)
		b.flashTimer = nil
	end)
end

-- Effective visibility = master "show" toggle, gated by the map restriction
-- (when on, the board only appears inside the target delve map). A visibility
-- override lifts the map gate but not the master toggle.
function HUD.ApplyShown()
	if not frame then return end
	local visible = ns.IsShown()
	if visible and ns.GetRestrictToMap() and not ns.HasVisibilityOverride() then
		visible = (ns.CurrentMapID() == ns.GetMapID())
	end
	frame:SetShown(visible)
end

function HUD.IsVisible()
	return frame ~= nil and frame:IsShown()
end

-- The board frame, for anything that wants to sit against it.
function HUD.GetFrame()
	return frame
end

-- Where the board sits in the stacking order, and whether it is taking mouse
-- input at all. Reported by `/ss status`, because "I clicked it and nothing
-- happened" is answered by something covering it far more often than by the
-- click handler being wrong -- and the two are indistinguishable from the chair.
-- The panel texture itself, so a test can read the colour it was filled with.
function HUD.GetBackground() return background end

function HUD.Describe()
	if not frame then return "not built" end
	return ("strata=%s level=%d mouse=%s board-mouse=%s board-enabled=%s"):format(
		frame:GetFrameStrata() or "?", frame:GetFrameLevel() or 0,
		tostring(frame:IsMouseEnabled()),
		board and tostring(board:IsMouseEnabled()) or "?",
		board and tostring(board:IsEnabled()) or "?")
end

-- The player's chosen board size. Scaling the whole frame keeps the wedges,
-- their click areas and the sequence row in proportion, which laying it out
-- again at a new pixel size would not.
function HUD.ApplyScale()
	if not frame then return end
	frame:SetScale(ns.GetHUDScale())
end

-- How solid the panel behind the board is. Re-coloured rather than faded with
-- SetAlpha: the texture is the only thing that should thin out, and fading the
-- frame would take the wedges and the icons with it.
function HUD.ApplyBackgroundAlpha()
	if not background then return end
	background:SetColorTexture(0, 0, 0, ns.GetHUDBackgroundAlpha())
end

function HUD.ApplyLock()
	if not frame then return end
	local locked = ns.IsLocked()
	frame.mover.title:SetText(locked and "SnakeSays" or "SnakeSays  ·  drag to move")
	frame.mover:EnableMouse(not locked)
end

function HUD.ResetPosition()
	if not frame then return end
	frame:ClearAllPoints()
	local p = ns.GetPosition()
	if p then
		frame:SetPoint(p.point, UIParent, p.relPoint or p.point, p.x, p.y)
	else
		frame:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
	end
end

-- ---------------------------------------------------------------------------
-- Boot (in-game only)
-- ---------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:RegisterEvent("ZONE_CHANGED")
boot:RegisterEvent("ZONE_CHANGED_INDOORS")
boot:SetScript("OnEvent", function(_, event)
	if event == "PLAYER_LOGIN" then
		build()
	else
		HUD.ApplyShown()   -- re-evaluate the map restriction on zone changes
	end
end)
