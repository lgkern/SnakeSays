-- Phase 5: the rotating position radar -- a separate movable window showing
-- where the player is standing, tinted by whether that is the safe quadrant.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local RUN = { "W", "N", "S" }

describe("radar visibility", function()
	it("shows inside the delve", function()
		local ns = enc.setup("auto")
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.is_true(ns.Radar.IsShown())
	end)

	it("hides outside the delve", function()
		local ns = enc.setup("auto")
		wow.instanceMapID = 0
		wow.zoneText = "Stormwind City"
		wow.uiMapID = 84
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.is_false(ns.Radar.IsShown())
	end)

	it("stays hidden when the setting is off", function()
		local ns = enc.setup("auto", { radarEnabled = false })
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.is_false(ns.Radar.IsShown())
	end)

	it("shows anywhere once the map restriction is lifted, so it can be placed", function()
		local ns = enc.setup("auto")
		wow.instanceMapID = 0
		wow.zoneText = "Stormwind City"
		wow.uiMapID = 84
		ns.SetRestrictToMap(false)
		assert.is_true(ns.Radar.IsShown())
	end)

	it("can be toggled from chat", function()
		local ns = enc.setup("auto")
		wow.slash("SNAKESAYS", "radar")
		assert.is_false(ns.GetRadarEnabled())
		wow.slash("SNAKESAYS", "radar")
		assert.is_true(ns.GetRadarEnabled())
	end)

	it("remembers a position the player dragged it to", function()
		local ns = enc.setup("auto")
		ns.Radar.SavePosition("LEFT", "LEFT", 40, 10)
		assert.same({ point = "LEFT", relPoint = "LEFT", x = 40, y = 10 },
			_G.SnakeSaysDB.radarPosition)
	end)
end)

describe("radar safety tint", function()
	it("is neutral when no replay is running", function()
		local ns = enc.setup("auto")
		enc.placeIn(ns, "N")
		assert.equals("neutral", ns.Radar.SafetyState())
	end)

	it("is neutral while the run is still being recorded", function()
		local ns = enc.setup("auto")
		enc.pull(ns)
		enc.placeIn(ns, "N")
		assert.equals("neutral", ns.Radar.SafetyState())
	end)

	it("turns green when the player stands in the safe quadrant", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)                      -- step 1: W is safe
		enc.placeIn(ns, "W")
		assert.equals("safe", ns.Radar.SafetyState())
	end)

	it("turns red when the player stands anywhere else", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "E")
		assert.equals("danger", ns.Radar.SafetyState())
	end)

	it("follows the replay from step to step", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)

		enc.echo(ns)                      -- W safe
		enc.placeIn(ns, "N")
		assert.equals("danger", ns.Radar.SafetyState())

		enc.echo(ns)                      -- N safe
		assert.equals("safe", ns.Radar.SafetyState())
	end)

	it("goes neutral again once the replay ends", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		enc.placeIn(ns, "W")
		assert.equals("safe", ns.Radar.SafetyState())

		wow.fire("ENCOUNTER_END", ns.ENCOUNTERS[1].id)
		assert.equals("neutral", ns.Radar.SafetyState())
	end)

	it("is neutral rather than wrong when position cannot be read", function()
		local ns = enc.setup("auto")
		enc.recordRun(ns, RUN)
		enc.echo(ns)
		wow.setPosition(nil)
		assert.equals("neutral", ns.Radar.SafetyState())
	end)

	it("hands out a distinct colour per state", function()
		local ns = enc.setup("auto")
		local safe = { ns.Radar.StateColor("safe") }
		local danger = { ns.Radar.StateColor("danger") }
		local neutral = { ns.Radar.StateColor("neutral") }
		assert.is_not.same(safe, danger)
		assert.is_not.same(safe, neutral)
		assert.is_true(safe[2] > safe[1])      -- green dominant
		assert.is_true(danger[1] > danger[2])  -- red dominant
	end)
end)

describe("radar layout", function()
	-- Each cardinal wedge spans the 90 degrees centred on its marker, so the
	-- boundaries sit on the diagonals. Lines drawn on the marker axes would run
	-- straight through every marker and mark divisions that don't exist.
	it("puts the quadrant boundaries between the markers, not through them", function()
		local ns = enc.setup("auto")
		wow.setFacing(0)
		ns.Radar.Update()
		assert.is_true(math.abs(ns.Radar.DividerRotation() - math.pi / 4) < 0.001)
	end)

	it("keeps the boundaries a quarter turn off the markers as the view turns", function()
		local ns = enc.setup("auto")
		for _, facing in ipairs({ 0.3, 1.1, 2.7, 5.9 }) do
			wow.setFacing(facing)
			ns.Radar.Update()
			local offset = ns.Radar.DividerRotation() - ns.Radar.MapRotation()
			assert.is_true(math.abs(offset - math.pi / 4) < 0.001,
				"boundaries drifted at facing " .. facing)
		end
	end)

	it("hangs off the left of the board until the player moves it", function()
		local ns = enc.setup("auto")
		assert.is_true(ns.Radar.IsAttachedToBoard())

		ns.Radar.ApplyPosition()
		local _, relativeTo = _G.SnakeSaysRadar:GetPoint()
		assert.equals(ns.HUD.GetFrame(), relativeTo)
	end)

	it("pins itself to the screen once the player drags it", function()
		local ns = enc.setup("auto")
		ns.Radar.SavePosition("LEFT", "LEFT", 40, 10)
		assert.is_false(ns.Radar.IsAttachedToBoard())

		local _, relativeTo = _G.SnakeSaysRadar:GetPoint()
		assert.equals(_G.UIParent, relativeTo)
	end)

	it("goes back to the board on recenter", function()
		local ns = enc.setup("auto")
		ns.Radar.SavePosition("LEFT", "LEFT", 40, 10)
		wow.slash("SNAKESAYS", "recenter")

		assert.is_true(ns.Radar.IsAttachedToBoard())
		assert.is_nil(_G.SnakeSaysDB.radarPosition)
		assert.is_nil(_G.SnakeSaysDB.popupPosition)
	end)
end)

describe("radar orientation", function()
	it("rotates the room so the player's facing points up", function()
		local ns = enc.setup("auto")
		wow.setFacing(1.5)
		ns.Radar.Update()
		assert.is_true(math.abs(ns.Radar.MapRotation() + 1.5) < 0.001)
	end)

	it("holds the room north-up when facing is unavailable", function()
		local ns = enc.setup("auto")
		wow.setFacing(1.5, true)           -- secret: unusable
		ns.Radar.Update()
		assert.equals(0, ns.Radar.MapRotation())
	end)

	it("draws an arrow when facing is known and a blip when it is not", function()
		local ns = enc.setup("auto")
		enc.placeIn(ns, "N")

		wow.setFacing(0.4)
		ns.Radar.Update()
		assert.equals("arrow", ns.Radar.MarkerKind())

		wow.setFacing(0.4, true)
		ns.Radar.Update()
		assert.equals("blip", ns.Radar.MarkerKind())
	end)

	it("survives an update with no position at all", function()
		local ns = enc.setup("auto")
		wow.setPosition(nil)
		assert.has_no.errors(function() ns.Radar.Update() end)
		assert.equals("none", ns.Radar.MarkerKind())
	end)

	it("keeps updating on its own while shown", function()
		local ns = enc.setup("auto")
		wow.fire("ZONE_CHANGED_NEW_AREA")
		enc.placeIn(ns, "E")
		wow.setFacing(0.9)
		wow.advance(0.3)
		assert.is_true(math.abs(ns.Radar.MapRotation() + 0.9) < 0.001)
	end)
end)
