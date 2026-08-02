local _, ns = ...

-- ===========================================================================
-- Radar.lua  ·  a top-down view of the room, in its own window.
--
-- NOT YET WRITTEN: everything that draws the room. See SPEC-detection.md,
-- requirement R7, which says what the view has to convey and leaves how to
-- convey it open.
--
-- What is left is the window itself and how the player places it: it hangs off
-- the left edge of the board and rides along with it until dragged, at which
-- point it pins to the screen and stays there.
--
-- The settings, the accessors and the show/hide rules are unchanged, so the
-- rebuild fills in the drawing without the rest of the addon moving.
-- ===========================================================================

local Radar = {}
ns.Radar = Radar

local SIZE   = 190     -- canvas px
local UPDATE = 0.05    -- redraw interval while shown

local frame

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

	-- Stands in for the room view until there is one again, so the window can
	-- still be found and placed.
	local notice = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	notice:SetPoint("CENTER")
	notice:SetText("room view\nbeing rebuilt")
	frame.notice = notice

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

-- QUARANTINE: nothing to draw yet.
function Radar.Update()
	return false
end

-- ---------------------------------------------------------------------------
-- Visibility
-- ---------------------------------------------------------------------------

-- Follows the same map restriction as the board. With no way to tell where we
-- are, the location gate is inert and the radar follows its own setting.
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
