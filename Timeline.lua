local _, ns = ...

-- ===========================================================================
-- Timeline.lua  ·  the run written out as a bar of music.
--
-- The board says *where* to go. This says *when*. The run reads left to right,
-- one slot per wave, and during the silent repeat a scanning bar sweeps across
-- it, resting on each marker as that wave is called and travelling to the next
-- one over the cast -- so the distance still to run is the time left before the
-- next call.
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
--   calling   the bar sweeps. Each step is animated on its own, from the marker
--             being called to the one after it, over however long the boss' cast
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
local SLOT     = 36      -- icon size, until a run is long enough to need less
local GAP      = 22      -- the gap the nominal width is laid out with
local TRACK_H  = 54
local BAR_W    = 3
local POINTER_W = 16     -- width at the base of the playhead triangle
local POINTER_H = 10
local MIN_ICON = 10      -- floor for a run long enough to need compressing
local MIN_GAP  = 8       -- icons never close up tighter than this

local POP_TIME    = 0.22  -- a press dropping into its slot
local POP_SCALE   = 1.6
local STRIKE_TIME = 0.34  -- the flare as the bar reaches a slot

-- Dimming for slots the bar has not reached yet, and for rests.
local UPCOMING_ALPHA = 0.4
local REST_ALPHA     = 0.22

local frame, strip, track, bar, hint
local background       -- the dark panel behind the staff; its alpha is a setting
local heardText = {}   -- pooled font strings for a run called over party chat
local heardLines = {}  -- the lines themselves, still secret, never read
local heardCount = 0
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
-- The run is spread evenly across the whole staff, however long it is: five
-- waves use the same width seven do, at a wider spacing. The window is a fixed
-- size the player has placed and sized to taste, so leaving two thirds of it
-- empty on a short round wastes the room they gave it.
--
-- The icons only start closing up when the spacing can no longer hold them a
-- gap apart, which is past the longest round the fight is supposed to produce --
-- so in practice a stray extra press costs a little size rather than pushing the
-- rest of the run off the end.
-- ---------------------------------------------------------------------------

local function metrics(count)
	if count <= 1 then return SLOT, 0 end

	local size = SLOT
	local pitch = (trackW - size) / (count - 1)

	if pitch < size + MIN_GAP then
		-- Solve for the largest icon that still leaves MIN_GAP between neighbours.
		size = math.max(MIN_ICON, (trackW - (count - 1) * MIN_GAP) / count)
		pitch = (trackW - size) / (count - 1)
	end

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

-- The playhead: a triangle sitting under the bar, apex on the line and flaring
-- downward, so the bar reads as a needle resting on the staff.
--
-- Stacked slivers rather than a piece of art. Blizzard's arrow textures carry
-- their own padding inside the image, so anchoring one by its edges puts the
-- point a couple of pixels off the line it is supposed to be under -- and this
-- addon has no triangle of its own to use instead. Rows widening by a fixed step
-- are centred on the bar by construction and cannot drift out of line.
--
-- Parented to the bar, so it travels with it and hides with it for free. Each
-- row is two pixels tall on a one pixel step, so the overlap leaves no seams at
-- a non-integer UI scale.
local function buildPointer()
	local step = (POINTER_W - BAR_W) / (POINTER_H - 1)
	for row = 1, POINTER_H do
		local sliver = bar:CreateTexture(nil, "OVERLAY")
		sliver:SetSize(BAR_W + step * (row - 1), 2)
		sliver:SetPoint("TOP", bar, "BOTTOM", 0, -(row - 1))
		sliver:SetColorTexture(1, 0.95, 0.6, 1)
	end
end

local function buildBar()
	bar = CreateFrame("Frame", nil, track)
	bar:SetSize(BAR_W, TRACK_H)
	bar:SetPoint("CENTER", track, "LEFT", 0, 0)
	bar:Hide()

	local core = bar:CreateTexture(nil, "OVERLAY")
	core:SetAllPoints(bar)
	core:SetColorTexture(1, 0.95, 0.6, 1)

	buildPointer()
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

	-- The window is sized for the longest round the fight can show. Shorter runs
	-- spread themselves across the same staff rather than shrinking it, so the
	-- window never changes size under the player once they have placed it.
	nominalSlots = ns.Detector.MaxWaves()
	trackW = nominalSlots * (SLOT + GAP) - GAP
	frameW = trackW + PAD * 2

	frame = CreateFrame("Frame", "SnakeSaysTimeline", UIParent)
	-- Tall enough for the playhead to hang below the staff without touching the
	-- bottom edge of the window.
	frame:SetSize(frameW, STRIP_H + 2 + TRACK_H + POINTER_H + 6)
	frame:SetMovable(true)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("MEDIUM")
	frame:Hide()

	background = frame:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints(frame)
	Timeline.ApplyBackgroundAlpha()

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
--
-- A run heard over party chat stands in for our own while we have not pressed
-- anything. The icons are somebody else's, but they take the same slots, and
-- everything that reads off this -- the rests, the spacing, where the scanning
-- bar travels to -- has to agree about where those slots are.
local function slotCount(list)
	local pressed = #list
	if pressed == 0 then pressed = heardCount end
	local expected = ns.Detector.ExpectedWaves()
	if expected and expected > pressed then return expected, pressed end
	return pressed, pressed
end

-- Whether the staff is showing somebody else's run rather than our own.
local function borrowed()
	return heardCount > 0 and ns.Seq.Count() == 0
end

-- The heard run, drawn but never read.
--
-- The lines are secret values -- matching, comparing or measuring one throws --
-- so nothing here looks at one. What it does instead is build a texture escape
-- around it and let the client join the two:
--
--   |TInterface\TargetingFrame\UI-RaidTargetingIcon_2:24:24|t
--                                                  ^ the secret line
--
-- The caller's macro types the bare marker number, so the secret is exactly the
-- last segment of a path Blizzard ships a file for, and what comes out is the
-- marker itself rather than the digit. Formatting happens in C, which is the one
-- place a secret can be used at all. It is what NorthernSkyRaidTools does for
-- L'ura's runes, against their own art instead of Blizzard's.
--
-- A line that is not a marker number -- somebody talking inside the window --
-- resolves to no file and draws nothing, which is the failure we want.
local HEARD_ICON = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%%s:%d:%d|t"

local function drawHeard(count, size, pitch)
	local icon = HEARD_ICON:format(size, size)
	for i = 1, count do
		local fs = heardText[i]
		if not fs then
			fs = track:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
			heardText[i] = fs
		end
		fs:ClearAllPoints()
		fs:SetPoint("CENTER", track, "LEFT", slotX(i, size, pitch), 0)
		fs:SetFormattedText(icon, heardLines[i])
		fs:Show()
	end
	for i = count + 1, #heardText do
		heardText[i]:Hide()
	end
end

-- Repaint the staff. Safe to call at any time and from anywhere: it derives
-- everything from the sequence and the replay position rather than keeping a
-- running idea of what is already on screen.
function Timeline.Render(list)
	if not frame then return end
	list = list or ns.Seq.Get()

	local count = slotCount(list)
	local size, pitch = metrics(math.max(count, 1))
	local replaying = ns.Detector.IsReplaying()
	local at = ns.Detector.EchoIndex()
	local heardHere = borrowed()

	for i = 1, count do
		local slot = slots[i] or buildSlot(i)
		slot:SetSize(size, size)
		slot:SetPoint("CENTER", track, "LEFT", slotX(i, size, pitch), 0)
		slot.baseSize = size
		slot:Show()

		local quadrant = list[i]
		if heardHere and i <= heardCount then
			-- Somebody else's marker holds this slot. It is drawn as text, below,
			-- because it is a secret value and a texture escape is the only way to
			-- put one on screen -- and the slot's own outline is a child frame, so
			-- leaving it up would draw a ring straight over the icon.
			slot:Hide()
		elseif quadrant then
			-- Just the marker. The outline is scaffolding for an empty slot, and
			-- once every slot is full a row of framed icons is only busier than a
			-- row of icons.
			local marker = ns.GetMarker(ns.GetAssignment(quadrant))
			slot.icon:SetTexCoord(unpack(marker.coords))
			slot.icon:Show()
			slot.ring:Hide()
			slot.hole:Hide()

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
			slot.ring:Show()
			slot.hole:Show()
			slot:SetAlpha(REST_ALPHA)
		end
	end

	for i = count + 1, #slots do
		slots[i]:Hide()
	end

	drawHeard(heardHere and heardCount or 0, size, pitch)

	-- A press that just landed drops into its slot. Worked out by comparing
	-- against the last count rather than by being told, so a reset, a reload and
	-- a repaint from the options page all come out still rather than popping.
	--
	-- Our own presses only. A wave arriving over party chat is not this player
	-- doing anything, and the pop belongs to the hand that pressed.
	local pressed = #list
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

	-- Arrival. The marker the bar has just landed on is the one about to be
	-- called, so the flare and the voice go off together.
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

-- The bar leads the calls by one slot: it sits on the marker being called right
-- now, and spends the cast travelling to the one that will be called next.
--
-- That is a slot ahead of where "the bar arrives as the wave lands" would put
-- it, and it is the sync the player actually hears. The call for a wave goes out
-- at cast start -- voice and popup both -- so the marker under the bar has to be
-- the marker being said aloud. Trailing by a slot meant the voice said "Purple"
-- while the bar was still sitting on the blue before it.
--
-- The travel time comes off the live cast every step rather than from a tempo,
-- because on hard the cast switches between two lengths part way through a
-- round. Where the client will not say -- and it often will not in here -- a
-- slot's length is the same estimate the detector itself falls back on, which
-- keeps the bar moving at roughly the right speed instead of teleporting.
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

	-- Past the last marker there is nowhere left to point, so the bar runs off
	-- the end of the staff instead -- which is the last wave's landing time, and
	-- the replay closes as it gets there.
	local nextIndex = index + 1
	local toX = (nextIndex <= count) and slotX(nextIndex, size, pitch) or trackW

	scan.active  = true
	scan.struck  = false
	scan.fromX   = slotX(index, size, pitch)
	scan.toX     = toX
	scan.startAt = now
	scan.endAt   = endsAt
	scan.toIndex = nextIndex

	-- Land it on the called marker now rather than on the next frame. Waiting
	-- leaves it wherever the previous step finished for a frame, which at the top
	-- of a fresh replay is the far end of the staff.
	bar:SetPoint("CENTER", track, "LEFT", scan.fromX, 0)
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
	if heardCount > 0 then return true end
	return ns.Detector.ExpectedWaves() ~= nil
end

-- Somebody else's run arriving over party chat. Kept, and repainted through the
-- same Render as our own so the two can never disagree about where a slot is --
-- which they have to agree on, because the scanning bar travels over both.
function Timeline.RenderHeard(lines)
	heardLines = lines or {}
	heardCount = #heardLines
	if not frame then return end
	Timeline.Render(ns.Seq.Get())
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

-- The panel behind the staff, at whatever solidity the player asked for. Only
-- the texture thins out; fading the frame would take the slots and the playhead
-- with it.
function Timeline.ApplyBackgroundAlpha()
	if not background then return end
	background:SetColorTexture(0.04, 0.04, 0.05, ns.GetTimelineBackgroundAlpha())
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
function Timeline.GetBackground() return background end
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
function Timeline.HeardFontString(index) return heardText[index] end

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
