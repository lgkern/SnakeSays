-- The dark panel behind each window is the player's to set. What matters here
-- is that the stored number reaches the texture -- including the window that
-- has not been built yet when the value is stored -- and that a deliberate zero
-- survives a relog instead of being read as "unset".

local addon = require("spec.helpers.addon")

local function alphaOf(texture)
	local _, _, _, a = texture:GetColorTexture()
	return a
end

describe("background transparency", function()
	it("ships at the values the windows had before it was a setting", function()
		local ns = addon.boot()
		assert.equals(0.35, ns.GetHUDBackgroundAlpha())
		assert.equals(0.55, ns.GetTimelineBackgroundAlpha())
		assert.equals(0.35, alphaOf(ns.HUD.GetBackground()))
		assert.equals(0.55, alphaOf(ns.Timeline.GetBackground()))
	end)

	it("reaches the board", function()
		local ns = addon.boot()
		ns.SetHUDBackgroundAlpha(0.8)
		assert.equals(0.8, alphaOf(ns.HUD.GetBackground()))
	end)

	it("reaches the timeline", function()
		local ns = addon.boot()
		ns.SetTimelineBackgroundAlpha(0.1)
		assert.equals(0.1, alphaOf(ns.Timeline.GetBackground()))
	end)

	it("leaves the other window alone", function()
		local ns = addon.boot()
		ns.SetHUDBackgroundAlpha(0)
		assert.equals(0.55, alphaOf(ns.Timeline.GetBackground()))
	end)

	it("clamps to 0..1", function()
		local ns = addon.boot()
		ns.SetHUDBackgroundAlpha(4)
		assert.equals(1, ns.GetHUDBackgroundAlpha())
		ns.SetHUDBackgroundAlpha(-2)
		assert.equals(0, ns.GetHUDBackgroundAlpha())
	end)

	it("reads a value that isn't a number as none at all", function()
		local ns = addon.boot()
		ns.SetTimelineBackgroundAlpha("mostly")
		assert.equals(0, ns.GetTimelineBackgroundAlpha())
	end)

	-- No panel at all is a choice a player can make, and one they should not
	-- have to make again every login.
	it("keeps a stored zero across a relog", function()
		local ns = addon.boot({ db = { hudBackgroundAlpha = 0 } })
		assert.equals(0, ns.GetHUDBackgroundAlpha())
		assert.equals(0, alphaOf(ns.HUD.GetBackground()))
	end)
end)
