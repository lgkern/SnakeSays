-- Each window carries its own size. The interesting part isn't the arithmetic,
-- it's that the setting reaches the frame -- including the frames that don't
-- exist yet when the value is stored.

local addon = require("spec.helpers.addon")

describe("window sizes", function()
	it("ship at 100%", function()
		local ns = addon.boot()
		assert.equals(1, ns.GetHUDScale())
		assert.equals(1, ns.GetPopupScale())
	end)

	it("apply to the board", function()
		local ns = addon.boot()
		ns.SetHUDScale(1.4)
		assert.equals(1.4, ns.HUD.GetFrame():GetScale())
	end)

	it("apply to the on-screen call", function()
		local ns = addon.boot()
		ns.SetPopupScale(1.8)
		assert.equals(1.8, ns.Announce.GetPopup():GetScale())
	end)

	it("are independent of each other", function()
		local ns = addon.boot()
		ns.SetHUDScale(1.5)
		assert.equals(1, ns.Announce.GetPopup():GetScale())
	end)

	it("clamp to the allowed range", function()
		local ns = addon.boot()
		ns.SetHUDScale(9)
		assert.equals(ns.SCALE_MAX, ns.GetHUDScale())
		ns.SetHUDScale(0.01)
		assert.equals(ns.SCALE_MIN, ns.GetHUDScale())
	end)

	it("ignore a value that isn't a number", function()
		local ns = addon.boot()
		ns.SetHUDScale("huge")
		assert.equals(1, ns.GetHUDScale())
	end)

	-- The windows are built at PLAYER_LOGIN, after SavedVariables comes back, so
	-- a stored size has to be picked up by the build rather than only by the
	-- setter that wrote it.
	it("survive a reload", function()
		local ns = addon.boot({ db = { hudScale = 1.25, popupScale = 1.75 } })
		assert.equals(1.25, ns.HUD.GetFrame():GetScale())
		assert.equals(1.75, ns.Announce.GetPopup():GetScale())
	end)

	it("repair a stored size that is out of range", function()
		local ns = addon.boot({ db = { hudScale = 40 } })
		assert.equals(ns.SCALE_MAX, ns.GetHUDScale())
		assert.equals(ns.SCALE_MAX, ns.HUD.GetFrame():GetScale())
	end)

	it("are written back by the options page", function()
		local ns = addon.boot()
		assert.has_no.errors(function() ns.Options.Refresh() end)

		ns.SetPopupScale(1.3)
		ns.Options.Refresh()
		assert.equals(1.3, ns.GetPopupScale())          -- refresh must not overwrite it
		assert.equals(1.3, ns.Announce.GetPopup():GetScale())
	end)
end)
