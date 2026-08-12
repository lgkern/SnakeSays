local addonName, ns = ...

-- ===========================================================================
-- Core.lua  ·  shared state: marker catalogue, SavedVariables, accessors.
--
-- SavedVariables timing: WoW restores SnakeSaysDB *after* these files execute,
-- just before ADDON_LOADED. So we must NOT bind the table at file scope (that
-- copy is detached the instant the saved global replaces it). Instead every
-- accessor lazily resolves SnakeSaysDB, and ADDON_LOADED seeds the defaults.
-- The ns.* tables live on the addon namespace (never replaced by WoW), so they
-- are safe to populate now.
-- ===========================================================================

ns.QUADRANTS = { "N", "E", "S", "W" }   -- canonical order (also the cardinal layout)

ns.QUADRANT_NAME = {
	N = "North", E = "East", S = "South", W = "West",
}

-- The eight WoW raid target markers. `coords` index the shared icon atlas
-- (Interface\TargetingFrame\UI-RaidTargetingIcons, 4 columns x 2 rows). `color`
-- tints the HUD wedge; the quadrant colour follows its assigned marker.
--
-- `colorName` is what the voice announcer says, so the eight have to stay
-- audibly distinct: Moon and Skull are both pale, hence Silver vs White.
ns.MARKER_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"

ns.MARKERS = {
	{ id = 1, key = "star",     name = "Star",     colorName = "Yellow", color = { 1.00, 0.93, 0.20 }, coords = { 0.00, 0.25, 0.00, 0.25 } },
	{ id = 2, key = "circle",   name = "Circle",   colorName = "Orange", color = { 1.00, 0.50, 0.00 }, coords = { 0.25, 0.50, 0.00, 0.25 } },
	{ id = 3, key = "diamond",  name = "Diamond",  colorName = "Purple", color = { 0.72, 0.35, 0.93 }, coords = { 0.50, 0.75, 0.00, 0.25 } },
	{ id = 4, key = "triangle", name = "Triangle", colorName = "Green",  color = { 0.16, 0.78, 0.20 }, coords = { 0.75, 1.00, 0.00, 0.25 } },
	{ id = 5, key = "moon",     name = "Moon",     colorName = "Silver", color = { 0.55, 0.78, 0.95 }, coords = { 0.00, 0.25, 0.25, 0.50 } },
	{ id = 6, key = "square",   name = "Square",   colorName = "Blue",   color = { 0.00, 0.55, 1.00 }, coords = { 0.25, 0.50, 0.25, 0.50 } },
	{ id = 7, key = "cross",    name = "Cross",    colorName = "Red",    color = { 0.90, 0.13, 0.13 }, coords = { 0.50, 0.75, 0.25, 0.50 } },
	{ id = 8, key = "skull",    name = "Skull",    colorName = "White",  color = { 0.92, 0.90, 0.85 }, coords = { 0.75, 1.00, 0.25, 0.50 } },
}

function ns.GetMarker(id)
	return ns.MARKERS[id]
end

-- ---------------------------------------------------------------------------
-- The boss room.
--
-- Ids only. The addon used to hold a measured room centre and work out which
-- quarter the player stood in; the client no longer hands out UnitPosition in
-- here during combat, so there is nothing to measure against and no geometry
-- left to keep. These two are the client's own ids for the place, used to decide
-- whether the board should be on screen.
-- ---------------------------------------------------------------------------

ns.ROOM = {
	instanceMapID = 3079,
	uiMapID       = 2634,
}

-- The delve this all happens in. Matched on the name as well as the instance id
-- because ids get renumbered between builds, and an unrecognised delve is one
-- where the addon silently does nothing at all.
local DELVE_ZONE = "Venomfall Deeps"

-- Default assignment matches the boss-fight defaults the player asked for:
-- North=Circle(orange), East=Diamond(purple), South=Square(blue), West=Cross(red).
local DEFAULTS = {
	markers = { N = 2, E = 3, S = 6, W = 7 },
	shown = true,
	locked = false,
	position = nil,   -- nil => centre on first show
	autoReset = true,
	autoResetTime = 40,   -- seconds after the first press
	restrictToMap = true, -- only show the HUD inside the target map
	mapID = 2634,         -- Azta'rec / Delve Nemesis (uiMapID); editable in-game

	-- Replay announcements
	ttsEnabled = true,
	ttsVoice = 0,
	ttsVolume = 50,
	ttsOverlap = true,
	announceStyle = "color",  -- "color" says Red/Orange; "marker" says Cross/Circle
	popupEnabled = true,
	popupSubtitle = true,     -- the "... next" line under the main call
	popupPosition = nil,      -- nil => centre top

	-- The timeline: the run written out left to right, scanned by a bar during
	-- the replay. Its own window, because the board wants to sit small next to
	-- the character where it is quick to click, and this wants to sit large
	-- where it is quick to read.
	timelineEnabled = true,
	timelinePosition = nil,   -- nil => top centre

	-- Group sync: one player fills the board and everyone else's follows. On by
	-- default -- it only ever does anything when somebody else in the group is
	-- running this addon too, and the whole point is that it works without four
	-- people first finding the setting.
	groupSync = true,

	-- Window sizes, as frame-scale multipliers (1 = as shipped).
	hudScale = 1,
	popupScale = 1,
	timelineScale = 1,
}

-- Lazy DB resolver (the SV-timing rule above). Safe to call any time after
-- ADDON_LOADED; before that it returns a transient table that ADDON_LOADED
-- overwrites, so nothing reads it that early.
local function db()
	_G.SnakeSaysDB = _G.SnakeSaysDB or {}
	return _G.SnakeSaysDB
end
ns.db = db

-- Chat output, prefixed so the player can tell it apart from other addons.
function ns.Print(msg)
	print("|cff33ddaaSnakeSays|r: " .. msg)
end

-- ---------------------------------------------------------------------------
-- Marker assignment (one marker per quadrant, never duplicated).
-- ---------------------------------------------------------------------------

function ns.GetAssignment(quadrant)
	return db().markers[quadrant]
end

-- Assign `markerId` to `quadrant`. The eight markers are unique across the four
-- quadrants, so if another quadrant already holds this marker we SWAP: that
-- quadrant inherits the marker this one used to show. This keeps every quadrant
-- distinct without ever rejecting the player's choice.
function ns.SetAssignment(quadrant, markerId)
	local markers = db().markers
	if markers[quadrant] == markerId then return end
	local previous = markers[quadrant]
	for q, id in pairs(markers) do
		if id == markerId and q ~= quadrant then
			markers[q] = previous   -- swap the conflicting quadrant onto our old marker
		end
	end
	markers[quadrant] = markerId
	if ns.HUD then ns.HUD.Refresh() end
end

-- ---------------------------------------------------------------------------
-- Visibility / lock / position (all persisted).
-- ---------------------------------------------------------------------------

function ns.IsShown() return db().shown end
function ns.IsLocked() return db().locked end

function ns.SetShown(v)
	db().shown = not not v
	if ns.HUD then ns.HUD.ApplyShown() end
end

-- One lock for every window the addon owns. "Unlock" is the player saying they
-- want to arrange things, and it would be a poor joke to hand them only one of
-- the three. The call itself is the on-screen call, which had an ApplyLock all
-- along that nothing ever reached.
function ns.SetLocked(v)
	db().locked = not not v
	if ns.HUD then ns.HUD.ApplyLock() end
	if ns.Announce then ns.Announce.ApplyLock() end
	if ns.Timeline then ns.Timeline.ApplyLock() end
end

function ns.GetAutoReset()
	local v = db().autoReset
	if v == nil then return DEFAULTS.autoReset end
	return v
end
function ns.SetAutoReset(v) db().autoReset = not not v end

function ns.GetAutoResetTime() return db().autoResetTime or DEFAULTS.autoResetTime end
function ns.SetAutoResetTime(v) db().autoResetTime = v end

-- Re-ask every window whether it should be on screen. The location gates -- the
-- map restriction, which map, and the override that lifts them -- apply to all of
-- them at once, so they change through here rather than each poking the board and
-- forgetting whatever was added later. Forgetting is exactly what happened: the
-- practice run dropped its override and only the board heard about it, leaving the
-- timeline stranded until a reload.
function ns.ApplyWindowVisibility()
	if ns.HUD then ns.HUD.ApplyShown() end
	if ns.Timeline then ns.Timeline.ApplyShown() end
end

function ns.GetRestrictToMap()
	local v = db().restrictToMap
	if v == nil then return DEFAULTS.restrictToMap end
	return v
end
function ns.SetRestrictToMap(v)
	db().restrictToMap = not not v
	ns.ApplyWindowVisibility()
end

function ns.GetMapID() return db().mapID or DEFAULTS.mapID end
function ns.SetMapID(v)
	db().mapID = v
	ns.ApplyWindowVisibility()
end

-- The player's current uiMapID (nil if unavailable).
function ns.CurrentMapID()
	return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
end

-- ---------------------------------------------------------------------------
-- Visibility override
--
-- Lets something temporarily lift the "only inside the delve" gate on the
-- board -- the practice run needs it on screen out in the world. It lifts the
-- *location* gate only: a board the player has hidden stays hidden, since that
-- is a statement about wanting the feature at all.
--
-- Session state, not saved: a practice run must never outlive a reload.
-- ---------------------------------------------------------------------------

local visibilityOverride = false

function ns.HasVisibilityOverride() return visibilityOverride end

function ns.SetVisibilityOverride(v)
	visibilityOverride = not not v
	ns.ApplyWindowVisibility()
end

-- Whether we are standing in Venomfall Deeps. Two independent signals, either
-- of which is enough: the instance id the client reports, and the zone name.
-- Both reads are guarded, because a location gate that throws is worse than one
-- that says "no".
function ns.InDelve()
	local ok, name, _, _, _, _, _, _, instanceID = pcall(GetInstanceInfo)
	if ok then
		if instanceID == ns.ROOM.instanceMapID then return true end
		if type(name) == "string" and name:find(DELVE_ZONE, 1, true) then return true end
	end

	local okZone, zone = pcall(GetZoneText)
	if okZone and type(zone) == "string" and zone:find(DELVE_ZONE, 1, true) then
		return true
	end

	return false
end

-- ---------------------------------------------------------------------------
-- Replay announcements
-- ---------------------------------------------------------------------------

-- Booleans need the nil check rather than `or DEFAULT`, since a stored `false`
-- is a real answer that `or` would quietly discard.
local function flag(key)
	local v = db()[key]
	if v == nil then return DEFAULTS[key] end
	return v
end

function ns.GetTTSEnabled() return flag("ttsEnabled") end
function ns.SetTTSEnabled(v) db().ttsEnabled = not not v end

function ns.GetTTSVoice() return db().ttsVoice or DEFAULTS.ttsVoice end
function ns.SetTTSVoice(v) db().ttsVoice = v end

function ns.GetTTSVolume() return db().ttsVolume or DEFAULTS.ttsVolume end
function ns.SetTTSVolume(v) db().ttsVolume = v end

function ns.GetTTSOverlap() return flag("ttsOverlap") end
function ns.SetTTSOverlap(v) db().ttsOverlap = not not v end

local ANNOUNCE_STYLES = { color = true, marker = true }

function ns.GetAnnounceStyle()
	local style = db().announceStyle
	return ANNOUNCE_STYLES[style] and style or DEFAULTS.announceStyle
end

function ns.SetAnnounceStyle(style)
	if not ANNOUNCE_STYLES[style] then return false end
	db().announceStyle = style
	return true
end

function ns.GetPopupEnabled() return flag("popupEnabled") end
function ns.SetPopupEnabled(v) db().popupEnabled = not not v end

function ns.GetPopupSubtitle() return flag("popupSubtitle") end
function ns.SetPopupSubtitle(v) db().popupSubtitle = not not v end

-- Whether this client takes part in group sync at all: sending its own presses,
-- and taking somebody else's. One switch for both directions, because a player
-- who does not want the addon talking to the group does not want it listening
-- either, and two switches would be two ways to end up half connected.
function ns.GetGroupSync() return flag("groupSync") end
function ns.SetGroupSync(v) db().groupSync = not not v end

-- Step-by-step chat output from the detector. Off, and not in DEFAULTS, so it
-- can only ever be on because someone asked for it.
function ns.GetDebug() return db().debug == true end
function ns.SetDebug(v) db().debug = not not v end

-- One diagnostic line, when `/ss debug` is on. Detector had its own copy of this
-- from the start; the input path needs it too now, and a field report is worth
-- much more when every step of a press can account for itself.
function ns.Trace(fmt, ...)
	if not ns.GetDebug() then return end
	local ok, line = pcall(string.format, fmt, ...)
	ns.Print("|cff888888[ss]|r " .. (ok and line or tostring(fmt)))
end

-- What the announcer calls a quadrant: its marker's colour, or the marker's own
-- name when the player prefers to hear marks.
function ns.QuadrantLabel(quadrant)
	local marker = ns.GetMarker(ns.GetAssignment(quadrant))
	if not marker then return "" end
	if ns.GetAnnounceStyle() == "marker" then return marker.name end
	return marker.colorName
end

-- Inline texture escape for a marker icon, for use in on-screen text.
function ns.MarkerIconMarkup(marker, size)
	if not marker then return "" end
	local c = marker.coords
	return ("|T%s:%d:%d:0:0:256:256:%d:%d:%d:%d|t"):format(
		ns.MARKER_TEXTURE, size, size,
		c[1] * 256, c[2] * 256, c[3] * 256, c[4] * 256)
end

-- Icon + word for a quadrant, e.g. "{cross} Red".
function ns.QuadrantMarkup(quadrant, size)
	local marker = ns.GetMarker(ns.GetAssignment(quadrant))
	return ns.MarkerIconMarkup(marker, size) .. " " .. ns.QuadrantLabel(quadrant)
end

-- ---------------------------------------------------------------------------
-- Window sizes
--
-- One multiplier per window rather than one shared one: the board is a click
-- target and the on-screen call is read head-on, so a size that suits one is
-- usually wrong for the other.
--
-- Stored as a scale factor and applied with SetScale, so nothing here has to
-- re-lay-out: the frames keep their proportions and their anchors.
-- ---------------------------------------------------------------------------

ns.SCALE_MIN, ns.SCALE_MAX = 0.5, 2.0

function ns.ClampScale(v)
	v = tonumber(v)
	if not v then return 1 end
	if v < ns.SCALE_MIN then return ns.SCALE_MIN end
	if v > ns.SCALE_MAX then return ns.SCALE_MAX end
	return v
end

function ns.GetHUDScale() return ns.ClampScale(db().hudScale or DEFAULTS.hudScale) end
function ns.SetHUDScale(v)
	db().hudScale = ns.ClampScale(v)
	if ns.HUD then ns.HUD.ApplyScale() end
end

function ns.GetPopupScale() return ns.ClampScale(db().popupScale or DEFAULTS.popupScale) end
function ns.SetPopupScale(v)
	db().popupScale = ns.ClampScale(v)
	if ns.Announce then ns.Announce.ApplyScale() end
end

function ns.GetTimelineScale() return ns.ClampScale(db().timelineScale or DEFAULTS.timelineScale) end
function ns.SetTimelineScale(v)
	db().timelineScale = ns.ClampScale(v)
	if ns.Timeline then ns.Timeline.ApplyScale() end
end

function ns.GetTimelineEnabled()
	local v = db().timelineEnabled
	if v == nil then return DEFAULTS.timelineEnabled end
	return v
end

function ns.SetTimelineEnabled(v)
	db().timelineEnabled = not not v
	if ns.Timeline then ns.Timeline.ApplyShown() end
end

function ns.GetPosition() return db().position end
function ns.SavePosition(point, relPoint, x, y)
	db().position = { point = point, relPoint = relPoint, x = x, y = y }
end
function ns.ClearPosition()
	db().position = nil
	if ns.HUD then ns.HUD.ResetPosition() end
end

-- ---------------------------------------------------------------------------
-- Dragging a window by a grab strip
--
-- Moving on mouse-down/up rather than OnDragStart/OnDragStop, with a watchdog
-- that runs only while a move is in progress. With a thin strip plus
-- SetClampedToScreen, dragging into a screen edge separates the cursor from the
-- strip and the drag-stop is missed, leaving the window stuck to the cursor.
-- Watching the button itself catches the release wherever on screen it happens.
--
-- `save` is handed the resulting anchor so each window can persist it its own
-- way. Returns a stop function, for a caller that has to break off a move (a
-- window being hidden mid-drag, say).
-- ---------------------------------------------------------------------------

function ns.AttachMover(frame, strip, save)
	local moving = false

	local function stop()
		if not moving then return end
		moving = false
		strip:SetScript("OnUpdate", nil)
		frame:StopMovingOrSizing()
		local point, _, relPoint, x, y = frame:GetPoint(1)
		save(point, relPoint, x, y)
	end

	strip:EnableMouse(true)
	strip:SetScript("OnMouseDown", function(_, button)
		if button ~= "LeftButton" or ns.IsLocked() then return end
		moving = true
		frame:StartMoving()
		strip:SetScript("OnUpdate", function()
			if not IsMouseButtonDown("LeftButton") then stop() end
		end)
	end)
	strip:SetScript("OnMouseUp", stop)
	strip:SetScript("OnHide", stop)

	return stop
end

-- ---------------------------------------------------------------------------
-- Seed defaults once SnakeSaysDB is restored.
-- ---------------------------------------------------------------------------

local boot = CreateFrame("Frame")
boot:RegisterEvent("ADDON_LOADED")
boot:SetScript("OnEvent", function(_, _, name)
	if name ~= addonName then return end
	boot:UnregisterEvent("ADDON_LOADED")

	local d = db()
	if d.shown == nil then d.shown = DEFAULTS.shown end
	if d.locked == nil then d.locked = DEFAULTS.locked end
	if d.autoReset == nil then d.autoReset = DEFAULTS.autoReset end
	d.autoResetTime = d.autoResetTime or DEFAULTS.autoResetTime
	if d.restrictToMap == nil then d.restrictToMap = DEFAULTS.restrictToMap end
	d.mapID = d.mapID or DEFAULTS.mapID

	for _, key in ipairs({ "ttsEnabled", "ttsOverlap", "popupEnabled", "popupSubtitle",
		"timelineEnabled", "groupSync" }) do
		if d[key] == nil then d[key] = DEFAULTS[key] end
	end
	d.ttsVoice = d.ttsVoice or DEFAULTS.ttsVoice
	d.ttsVolume = d.ttsVolume or DEFAULTS.ttsVolume
	d.announceStyle = d.announceStyle or DEFAULTS.announceStyle
	for _, key in ipairs({ "hudScale", "popupScale", "timelineScale" }) do
		d[key] = ns.ClampScale(d[key] or DEFAULTS[key])
	end
	d.markers = d.markers or {}
	for _, q in ipairs(ns.QUADRANTS) do
		d.markers[q] = d.markers[q] or DEFAULTS.markers[q]
	end
end)
