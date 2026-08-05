local _, ns = ...

-- ===========================================================================
-- Timeline.lua  ·  the run written out as a bar of music.
--
-- The board says *where* to go. This says *when*. The run reads left to right,
-- one slot per wave, and during the silent repeat a scanning bar sweeps across
-- it and arrives at each marker at the exact moment that wave lands -- so the
-- distance still to travel is the time the player has left to be standing in
-- that quadrant.
--
-- Its own window, on purpose. The board wants to be small and near the
-- character where it is quick to click; this wants to be large and near the
-- middle of the screen where it is quick to read. It follows the same rules as
-- the board for showing, locking, moving and sizing, and shares its lock: one
-- "unlock" puts every window of the addon up for arranging at once.
--
-- Two halves, matching the two halves of the fight:
--
--   showing   the player presses quadrants, and each press drops into the next
--             slot with a small pop. Slots the round is going to have but the
--             player has not filled yet are drawn hollow -- rests, in the sheet
--             music the whole thing is borrowed from -- so being a press short
--             is visible while there is still time to fix it.
--   calling   the bar sweeps. Each step is animated on its own, from the slot
--             just struck to the next one, over however long the boss' cast
--             actually runs (Detector.CastEndsAt). It is re-aimed every step
--             rather than run at one speed across the whole row: on hard the
--             cast switches between two lengths part way through a round, so a
--             bar with a tempo baked in drifts off the markers by the last one.
--
-- Plain frames and textures driven by a single OnUpdate, so all of it works in
-- combat, and built at PLAYER_LOGIN so requiring this file headless never
-- touches in-game frame APIs.
-- ===========================================================================

local Timeline = {}
ns.Timeline = Timeline

local STRIP_H  = 14      -- drag strip along the top
local PAD      = 14
local SLOT     = 42      -- nominal icon size, at the nominal wave count
local GAP      = 16
local PITCH    = SLOT + GAP
local TRACK_H  = 58
local BAR_W    = 3
local MIN_ICON = 10      -- floor for a run long enough to need compressing

local POP_TIME    = 0.22  -- a press dropping into its slot
local POP_SCALE   = 1.6
local STRIKE_TIME = 0.34  -- the flare as the bar reaches a slot

-- Dimming for slots the bar has not reached yet, and for rests.
local UPCOMING_ALPHA = 0.4
local REST_ALPHA     = 0.22

local frame, strip, track, bar, hint
local slots = {}          -- pooled slot widgets, index -> holder frame
local nominalSlots        -- the longest round the fight can show (Detector.MaxWaves)
local trackW, frameW

-- Scan state. `toIndex` is the slot the bar is currently travelling to; the
-- animation runs on wall-clock times so a frame-rate dip cannot desynchronise
-- it from the cast it is tracking.
local scan = { active = false, fromX = 0, toX = 0, startAt = 0, endAt = 0, toIndex = 0 }

-- ---------------------------------------------------------------------------
-- Geometry
--
-- Constant pitch up to the nominal wave count, so a short run does not stretch
-- itself across the whole window and the markers do not slide sideways as the
-- board fills. Only a run longer than the fight is supposed to produce gets
-- squeezed, which keeps a stray extra press from pushing the rest off the end.
-- ---------------------------------------------------------------------------

local function metrics(count)
	if count <= nominalSlots then return SLOT, PITCH end
	local size = math.max(MIN_ICON, math.min(SLOT, math.floor(trackW / count) - 4))
	local pitch = (trackW - size) / (count - 1)
	return size, pitch
end

local function slotX(index, size, pitch)
	return size / 2 + (index - 1) * pitch
end

-- ---------------------------------------------------------------------------
-- Build
-- ---------------------------------------------------------------------------

local function buildSlot(index)
	local holder = CreateFrame("Frame", nil, track)

	-- The rest: an outline that is all there is to see until a press fills it.
	local ring = holder:CreateTexture(nil, "BACKGROUND")
	ring:SetPoint("TOPLEFT", holder, "TOPLEFT", -2, 2)
	ring:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 2, -2)
	ring:SetColorTexture(1, 1, 1, 0.5)
	holder.ring = ring

	-- Punches the middle out of the ring, leaving an outline rather than a block.
	local hole = holder:CreateTexture(nil, "BORDER")
	hole:SetAllPoints(holder)
	hole:SetColorTexture(0.04, 0.04, 0.05, 1)
	holder.hole = hole

	local icon = holder:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints(holder)
	icon:SetTexture(ns.MARKER_TEXTURE)
	holder.icon = icon

	-- The flare the bar leaves as it strikes a slot.
	local flare = holder:CreateTexture(nil, "OVERLAY")
	flare:SetPoint("TOPLEFT", holder, "TOPLEFT", -5, 5)
	flare:SetPoint("BOTTOMRIGHT", holder, "BOTTOMRIGHT", 5, -5)
	flare:SetColorTexture(1, 1, 1, 1)
	flare:Hide()
	holder.flare = flare

	slots[index] = holder
	return holder
end

local function buildBar()
	bar = CreateFrame("Frame", nil, track)
	bar:SetSize(BAR_W, TRACK_H)
	bar:SetPoint("CENTER", track, "LEFT", 0, 0)
	bar:Hide()

	local core = bar:CreateTexture(nil, "OVERLAY")
	core:SetAllPoints(bar)
	core:SetColorTexture(1, 0.95, 0.6, 1)

	-- A soft leading edge, so the eye reads a direction rather than a stick.
	local glow = bar:CreateTexture(nil, "ARTWORK")
	glow:SetPoint("TOPRIGHT", bar, "TOPLEFT", 0, 0)
	glow:SetPoint("BOTTOMRIGHT", bar, "BOTTOMLEFT", 0, 0)
	glow:SetWidth(26)
	glow:SetColorTexture(1, 0.9, 0.45, 0.18)
end

local function buildStrip()
	strip = CreateFrame("Frame", nil, frame)
	strip:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
	strip:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
	strip:SetHeight(STRIP_H)

	local bg = strip:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(strip)
	bg:SetColorTexture(1, 1, 1, 0.06)

	hint = strip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("CENTER")

	ns.AttachMover(frame, strip, Timeline.SavePosition)

	strip:SetScript("OnEnter", function()
		if not ns.IsLocked() then bg:SetColorTexture(1, 0.82, 0.2, 0.18) end
	end)
	strip:SetScript("OnLeave", function()
		bg:SetColorTexture(1, 1, 1, 0.06)
	end)
end

local function build()
	if frame then return end

	nominalSlots = ns.Detector.MaxWaves()
	trackW = nominalSlots * PITCH - GAP
	frameW = trackW + PAD * 2

	frame = CreateFrame("Frame", "SnakeSaysTimeline", UIParent)
	frame:SetSize(frameW, STRIP_H + TRACK_H + PAD)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("MEDIUM")
	frame:Hide()

	local bg = frame:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(frame)
	bg:SetColorTexture(0.04, 0.04, 0.05, 0.55)

	buildStrip()

	track = CreateFrame("Frame", nil, frame)
	track:SetSize(trackW, TRACK_H)
	track:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(STRIP_H + 2))

	-- The staff: the line the run is written on.
	local line = track:CreateTexture(nil, "BACKGROUND")
	line:SetPoint("LEFT", track, "LEFT", 0, 0)
	line:SetPoint("RIGHT", track, "RIGHT", 0, 0)
	line:SetHeight(2)
	line:SetColorTexture(1, 1, 1, 0.14)

	buildBar()

	frame:SetScript("OnUpdate", Timeline.OnUpdate)

	ns.Seq.OnChange(Timeline.Render)
	Timeline.ResetPosition()
	Timeline.ApplyScale()
	Timeline.ApplyLock()
	Timeline.Render(ns.Seq.Get())
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

-- How many slots to draw: what the player has pressed, or what the round is
-- going to want, whichever is more. The second is what puts the rests on the
-- staff before the presses that fill them.
local function slotCount(list)
	local pressed = #list
	local expected = ns.Detector.ExpectedWaves()
	if expected and expected > pressed then return expected, pressed end
	return pressed, pressed
end

-- Repaint the staff. Safe to call at any time and from anywhere: it derives
-- everything from the sequence and the replay position rather than keeping a
-- running idea of what is already on screen.
function Timeline.Render(list)
	if not frame then return end
	list = list or ns.Seq.Get()

	local count, pressed = slotCount(list)
	local size, pitch = metrics(math.max(count, 1))
	local replaying = ns.Detector.IsReplaying()
	local at = ns.Detector.EchoIndex()

	for i = 1, count do
		local slot = slots[i] or buildSlot(i)
		slot:SetSize(size, size)
		slot:SetPoint("CENTER", track, "LEFT", slotX(i, size, pitch), 0)
		slot.baseSize = size
		slot:Show()

		local quadrant = list[i]
		if quadrant then
			local marker = ns.GetMarker(ns.GetAssignment(quadrant))
			slot.icon:SetTexCoord(unpack(marker.coords))
			slot.icon:Show()
			slot.hole:SetColorTexture(marker.color[1], marker.color[2], marker.color[3], 0.30)
			slot.ring:SetColorTexture(marker.color[1], marker.color[2], marker.color[3], 0.85)

			-- During the replay the staff reads as a progress bar in its own
			-- right: what has already been called stays lit, what is still to
			-- come sits back so the eye goes to the bar.
			if replaying and i > at then
				slot:SetAlpha(UPCOMING_ALPHA)
			else
				slot:SetAlpha(1)
			end
		else
			-- A rest. The round says this wave is coming; nobody has said where.
			slot.icon:Hide()
			slot.hole:SetColorTexture(0.04, 0.04, 0.05, 1)
			slot.ring:SetColorTexture(1, 1, 1, 0.5)
			slot:SetAlpha(REST_ALPHA)
		end
	end

	for i = count + 1, #slots do
		slots[i]:Hide()
	end

	-- A press that just landed drops into its slot. Worked out by comparing
	-- against the last count rather than by being told, so a reset, a reload and
	-- a repaint from the options page all come out still rather than popping.
	if pressed > (Timeline.lastPressed or 0) then
		for i = (Timeline.lastPressed or 0) + 1, pressed do
			local slot = slots[i]
			if slot then slot.popAt = GetTime() end
		end
	end
	Timeline.lastPressed = pressed

	Timeline.ApplyShown()
end

-- ---------------------------------------------------------------------------
-- Animation
--
-- One OnUpdate for the whole window: the pops, the strikes, and the bar. All of
-- them are written as "where should this be at time T" rather than as a running
-- total, so a dropped frame costs nothing and nothing can drift.
-- ---------------------------------------------------------------------------

local function animatePops(now)
	for _, slot in ipairs(slots) do
		if slot.popAt then
			local t = (now - slot.popAt) / POP_TIME
			if t >= 1 then
				slot.popAt = nil
				slot:SetSize(slot.baseSize, slot.baseSize)
			elseif t >= 0 then
				local ease = 1 - (1 - t) * (1 - t)             -- ease out
				local grow = POP_SCALE + (1 - POP_SCALE) * ease
				slot:SetSize(slot.baseSize * grow, slot.baseSize * grow)
			end
		end

		if slot.struckAt then
			local t = (now - slot.struckAt) / STRIKE_TIME
			if t >= 1 then
				slot.struckAt = nil
				slot.flare:Hide()
			elseif t >= 0 then
				slot.flare:Show()
				slot.flare:SetAlpha((1 - t) * 0.75)
			end
		end
	end
end

local function animateBar(now)
	if not scan.active then return end

	local span = scan.endAt - scan.startAt
	local t = span > 0 and ((now - scan.startAt) / span) or 1
	if t < 0 then t = 0 elseif t > 1 then t = 1 end

	bar:SetPoint("CENTER", track, "LEFT", scan.fromX + (scan.toX - scan.fromX) * t, 0)

	-- Arrival: the wave the bar was racing has landed.
	if t >= 1 and not scan.struck then
		scan.struck = true
		local slot = slots[scan.toIndex]
		if slot then
			slot.struckAt = now
			slot:SetAlpha(1)
		end
	end
end

function Timeline.OnUpdate()
	if not frame then return end
	local now = GetTime()
	animatePops(now)
	animateBar(now)
end

-- ---------------------------------------------------------------------------
-- Replay wiring
-- ---------------------------------------------------------------------------

-- Aim the bar at the slot being called, to arrive as its wave lands.
--
-- The span comes off the live cast every step. Where the client will not say --
-- and it often will not in here -- the slot length is the same estimate the
-- detector itself falls back on, which keeps the bar moving at roughly the
-- right speed instead of teleporting.
function Timeline.OnStep(index)
	if not frame then return end

	local now = GetTime()
	local endsAt = ns.Detector.CastEndsAt()
	if type(endsAt) ~= "number" or endsAt <= now then
		endsAt = now + ns.SlotLength("hard")
	end

	local list = ns.Seq.Get()
	local count = slotCount(list)
	local size, pitch = metrics(math.max(count, 1))

	-- Carry on from wherever the bar actually is, so a step arriving early or
	-- late does not make it jump backwards.
	local fromX = scan.active and scan.toX or 0
	if index <= 1 then fromX = 0 end

	scan.active  = true
	scan.struck  = false
	scan.fromX   = fromX
	scan.toX     = slotX(index, size, pitch)
	scan.startAt = now
	scan.endAt   = endsAt
	scan.toIndex = index

	-- Put it at the start of its run now rather than leaving it where the last
	-- step finished until the next frame draws: at the top of a fresh replay that
	-- stale position is the far end of the staff, which flashes.
	bar:SetPoint("CENTER", track, "LEFT", fromX, 0)
	bar:Show()
	Timeline.Render(list)
end

function Timeline.OnEnd()
	scan.active = false
	if bar then bar:Hide() end
	if frame then Timeline.Render(ns.Seq.Get()) end
end

-- ---------------------------------------------------------------------------
-- State application
-- ---------------------------------------------------------------------------

-- The timeline is read, never clicked, so unlike the board it does not sit on
-- screen waiting to be used -- it appears when it has something to say. Which is
-- while a round is being shown (the rests are the cue to start pressing), while
-- there is a run on the board, and through the replay. Unlocking also brings it
-- up, since a window nobody can see is a window nobody can place.
function Timeline.HasSomethingToShow()
	if not ns.IsLocked() then return true end
	if ns.Detector.IsReplaying() then return true end
	if ns.Seq.Count() > 0 then return true end
	return ns.Detector.ExpectedWaves() ~= nil
end

function Timeline.ApplyShown()
	if not frame then return end
	local visible = ns.GetTimelineEnabled()
	if visible and ns.GetRestrictToMap() and not ns.HasVisibilityOverride() then
		visible = (ns.CurrentMapID() == ns.GetMapID())
	end
	frame:SetShown(visible and Timeline.HasSomethingToShow())
end

function Timeline.ApplyScale()
	if not frame then return end
	frame:SetScale(ns.GetTimelineScale())
end

function Timeline.ApplyLock()
	if not frame then return end
	local locked = ns.IsLocked()
	hint:SetText(locked and "" or "SnakeSays timeline  ·  drag to move")
	strip:EnableMouse(not locked)
	Timeline.ApplyShown()
end

function Timeline.ResetPosition()
	if not frame then return end
	frame:ClearAllPoints()
	local stored = ns.db().timelinePosition
	if stored and stored.point then
		frame:SetPoint(stored.point, UIParent, stored.relPoint or stored.point,
			stored.x or 0, stored.y or 0)
	else
		frame:SetPoint("TOP", UIParent, "TOP", 0, -90)
	end
end

function Timeline.SavePosition(point, relPoint, x, y)
	ns.db().timelinePosition = { point = point, relPoint = relPoint, x = x, y = y }
	Timeline.ResetPosition()
end

function Timeline.ClearPosition()
	ns.db().timelinePosition = nil
	Timeline.ResetPosition()
end

-- Test seams / external readers.
function Timeline.GetFrame() return frame end
function Timeline.IsVisible() return frame ~= nil and frame:IsShown() end

function Timeline.SlotCount()
	local count = slotCount(ns.Seq.Get())
	return count
end

-- Where a slot sits along the staff, measured from its left edge.
function Timeline.SlotX(index)
	local count = math.max(slotCount(ns.Seq.Get()), 1)
	local size, pitch = metrics(count)
	return slotX(index, size, pitch)
end

function Timeline.TrackWidth() return trackW end

function Timeline.BarX()
	if not bar or not scan.active then return nil end
	local _, _, _, x = bar:GetPoint(1)
	return x
end
function Timeline.ScanTarget() return scan.active and scan.toIndex or nil end

-- ---------------------------------------------------------------------------
-- Boot (in-game only)
-- ---------------------------------------------------------------------------

ns.Detector.OnReplayStep(Timeline.OnStep)
ns.Detector.OnReplayEnd(Timeline.OnEnd)

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
		Timeline.ApplyShown()
	end
end)
