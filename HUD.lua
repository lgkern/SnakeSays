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
-- we can vertex-colour them). Buttons are rectangular, so each wedge's clickable
-- area is trimmed with hit-rect insets toward the wedge body; the diagonal seams
-- have a small dead zone, which is fine for a click target.
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

-- Clickable-area insets per wedge (fractions of CIRCLE), biasing each button to
-- the body of its own wedge so neighbouring wedges don't steal the click.
local SIDE  = 0.26
local INNER = 0.54

local WEDGES = {
	N = { file = "wedge-n", point = "TOP",    ox =  0, oy = -24, insets = { SIDE, SIDE, 0,     INNER } },
	E = { file = "wedge-e", point = "RIGHT",  ox = -24, oy =  0, insets = { INNER, 0,    SIDE,  SIDE  } },
	S = { file = "wedge-s", point = "BOTTOM", ox =  0, oy =  24, insets = { SIDE, SIDE, INNER, 0     } },
	W = { file = "wedge-w", point = "LEFT",   ox =  24, oy =  0, insets = { 0,    INNER, SIDE,  SIDE  } },
}

local frame, circle, row
local buttons = {}     -- dir -> wedge button
local seqIcons = {}    -- pooled sequence-row textures

-- ---------------------------------------------------------------------------
-- Marker helpers
-- ---------------------------------------------------------------------------

local function applyMarkerIcon(tex, marker)
	tex:SetTexture(ns.MARKER_TEXTURE)
	tex:SetTexCoord(unpack(marker.coords))
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function buildWedge(dir, def)
	local b = CreateFrame("Button", nil, circle)
	b:SetAllPoints(circle)

	local wedge = b:CreateTexture(nil, "ARTWORK")
	wedge:SetTexture(MEDIA .. def.file .. ".tga")
	wedge:SetAllPoints(b)
	b.wedge = wedge

	local icon = b:CreateTexture(nil, "OVERLAY")
	icon:SetSize(30, 30)
	icon:SetPoint(def.point, b, def.point, def.ox, def.oy)
	b.icon = icon

	b:SetHitRectInsets(
		def.insets[1] * CIRCLE, def.insets[2] * CIRCLE,
		def.insets[3] * CIRCLE, def.insets[4] * CIRCLE)

	b:RegisterForClicks("LeftButtonUp")
	b:SetScript("OnClick", function()
		if ns.Seq.Press(dir) then HUD.Flash(dir) end
	end)
	b:SetScript("OnEnter", function()
		wedge:SetVertexColor(b.r * 1.35, b.g * 1.35, b.b * 1.35)
		GameTooltip:SetOwner(b, "ANCHOR_TOP")
		GameTooltip:SetText(ns.QUADRANT_NAME[dir])
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", function()
		wedge:SetVertexColor(b.r, b.g, b.b)
		GameTooltip:Hide()
	end)

	buttons[dir] = b
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

	b:SetScript("OnClick", function() ns.Seq.Reset() end)
	b:SetScript("OnEnter", function()
		bg:SetColorTexture(0.3, 0.3, 0.3, 0.6)
		GameTooltip:SetOwner(b, "ANCHOR_TOP")
		GameTooltip:SetText("Reset sequence")
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

	local width  = math.max(CIRCLE + PAD * 2,
		PAD * 2 + RESET_SIZE + SEQ_GAP + 7 * (SEQ_ICON + SEQ_GAP))
	local height = MOVER_H + 4 + CIRCLE + ROW_GAP + SEQ_ICON + PAD

	frame = CreateFrame("Frame", "SnakeSaysHUD", UIParent)
	frame:SetSize(width, height)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("MEDIUM")

	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(frame)
	bg:SetColorTexture(0, 0, 0, 0.35)

	buildMover()

	circle = CreateFrame("Frame", nil, frame)
	circle:SetSize(CIRCLE, CIRCLE)
	circle:SetPoint("TOP", frame, "TOP", 0, -(MOVER_H + 4))

	row = CreateFrame("Frame", nil, frame)
	row:SetSize(width - PAD * 2, SEQ_ICON)
	row:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(MOVER_H + 4 + CIRCLE + ROW_GAP))

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
		b.wedge:SetVertexColor(c[1], c[2], c[3])
		applyMarkerIcon(b.icon, marker)
	end
	HUD.RenderSequence(ns.Seq.Get())
end

-- Lay out the recorded sequence as a row of marker icons after the reset button.
function HUD.RenderSequence(list)
	if not frame then return end
	local startX = RESET_SIZE + SEQ_GAP * 2
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
		b.wedge:SetVertexColor(b.r, b.g, b.b)
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

-- The player's chosen board size. Scaling the whole frame keeps the wedges,
-- their click areas and the sequence row in proportion, which laying it out
-- again at a new pixel size would not.
function HUD.ApplyScale()
	if not frame then return end
	frame:SetScale(ns.GetHUDScale())
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
