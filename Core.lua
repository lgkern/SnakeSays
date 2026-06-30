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
ns.MARKER_TEXTURE = "Interface\\TargetingFrame\\UI-RaidTargetingIcons"

ns.MARKERS = {
	{ id = 1, key = "star",     name = "Star",     color = { 1.00, 0.93, 0.20 }, coords = { 0.00, 0.25, 0.00, 0.25 } },
	{ id = 2, key = "circle",   name = "Circle",   color = { 1.00, 0.50, 0.00 }, coords = { 0.25, 0.50, 0.00, 0.25 } },
	{ id = 3, key = "diamond",  name = "Diamond",  color = { 0.72, 0.35, 0.93 }, coords = { 0.50, 0.75, 0.00, 0.25 } },
	{ id = 4, key = "triangle", name = "Triangle", color = { 0.16, 0.78, 0.20 }, coords = { 0.75, 1.00, 0.00, 0.25 } },
	{ id = 5, key = "moon",     name = "Moon",     color = { 0.55, 0.78, 0.95 }, coords = { 0.00, 0.25, 0.25, 0.50 } },
	{ id = 6, key = "square",   name = "Square",   color = { 0.00, 0.55, 1.00 }, coords = { 0.25, 0.50, 0.25, 0.50 } },
	{ id = 7, key = "cross",    name = "Cross",    color = { 0.90, 0.13, 0.13 }, coords = { 0.50, 0.75, 0.25, 0.50 } },
	{ id = 8, key = "skull",    name = "Skull",    color = { 0.92, 0.90, 0.85 }, coords = { 0.75, 1.00, 0.25, 0.50 } },
}

function ns.GetMarker(id)
	return ns.MARKERS[id]
end

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
}

-- Lazy DB resolver (the SV-timing rule above). Safe to call any time after
-- ADDON_LOADED; before that it returns a transient table that ADDON_LOADED
-- overwrites, so nothing reads it that early.
local function db()
	_G.SnakeSaysDB = _G.SnakeSaysDB or {}
	return _G.SnakeSaysDB
end
ns.db = db

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

function ns.SetLocked(v)
	db().locked = not not v
	if ns.HUD then ns.HUD.ApplyLock() end
end

function ns.GetAutoReset()
	local v = db().autoReset
	if v == nil then return DEFAULTS.autoReset end
	return v
end
function ns.SetAutoReset(v) db().autoReset = not not v end

function ns.GetAutoResetTime() return db().autoResetTime or DEFAULTS.autoResetTime end
function ns.SetAutoResetTime(v) db().autoResetTime = v end

function ns.GetRestrictToMap()
	local v = db().restrictToMap
	if v == nil then return DEFAULTS.restrictToMap end
	return v
end
function ns.SetRestrictToMap(v)
	db().restrictToMap = not not v
	if ns.HUD then ns.HUD.ApplyShown() end
end

function ns.GetMapID() return db().mapID or DEFAULTS.mapID end
function ns.SetMapID(v)
	db().mapID = v
	if ns.HUD then ns.HUD.ApplyShown() end
end

-- The player's current uiMapID (nil if unavailable).
function ns.CurrentMapID()
	return C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
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
	d.markers = d.markers or {}
	for _, q in ipairs(ns.QUADRANTS) do
		d.markers[q] = d.markers[q] or DEFAULTS.markers[q]
	end
end)
