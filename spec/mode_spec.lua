-- Phase 1: the three operating modes, the first-run prompt, and input gating.

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

local DELVE_UI_MAP = 2634

local function bootInDelve(db)
	local ns = addon.boot({ db = db })
	wow.uiMapID = DELVE_UI_MAP
	wow.instanceMapID = ns.ROOM.instanceMapID
	wow.zoneText = "Venomfall Deeps"
	return ns
end

describe("modes", function()
	it("offers exactly automatic, semi-automatic and manual", function()
		local ns = addon.boot()
		local keys = {}
		for _, mode in ipairs(ns.MODES) do keys[#keys + 1] = mode.key end
		assert.same({ "auto", "semi", "manual" }, keys)
	end)

	it("starts undecided on a fresh install", function()
		local ns = addon.boot()
		assert.is_nil(ns.GetMode())
		assert.is_false(ns.IsModeChosen())
	end)

	it("persists a chosen mode to SavedVariables", function()
		local ns = addon.boot()
		ns.SetMode("semi")
		assert.equals("semi", ns.GetMode())
		assert.equals("semi", _G.SnakeSaysDB.mode)
		assert.is_true(ns.IsModeChosen())
	end)

	it("restores a mode chosen in an earlier session", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		assert.equals("auto", ns.GetMode())
		assert.is_true(ns.IsModeChosen())
	end)

	it("refuses an unknown mode and leaves the current one alone", function()
		local ns = addon.boot({ db = { mode = "manual" } })
		assert.is_false(ns.SetMode("turbo"))
		assert.equals("manual", ns.GetMode())
	end)

	it("notifies listeners when the mode changes", function()
		local ns = addon.boot()
		local seen = {}
		ns.OnModeChange(function(mode) seen[#seen + 1] = mode end)
		ns.SetMode("auto")
		ns.SetMode("manual")
		ns.SetMode("manual")   -- no-op, must not re-notify
		assert.same({ "auto", "manual" }, seen)
	end)
end)

describe("mode prompt", function()
	it("appears on entering the delve when no mode was ever chosen", function()
		bootInDelve()
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.is_true(#wow.popups > 0)
		assert.equals("SNAKESAYS_CHOOSE_MODE", wow.popups[1])
	end)

	it("does not appear when a mode is already stored", function()
		bootInDelve({ mode = "manual" })
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.equals(0, #wow.popups)
	end)

	it("does not appear outside the delve", function()
		local ns = addon.boot()
		wow.uiMapID = 84         -- Stormwind
		wow.instanceMapID = 0
		wow.zoneText = "Stormwind City"
		wow.fire("ZONE_CHANGED_NEW_AREA")
		assert.is_false(ns.InDelve())
		assert.equals(0, #wow.popups)
	end)

	it("only asks once per session even if you re-zone", function()
		bootInDelve()
		wow.fire("ZONE_CHANGED_NEW_AREA")
		wow.fire("ZONE_CHANGED_NEW_AREA")
		wow.fire("PLAYER_ENTERING_WORLD")
		assert.equals(1, #wow.popups)
	end)

	it("stores the mode picked from the popup", function()
		local ns = bootInDelve()
		wow.fire("ZONE_CHANGED_NEW_AREA")
		local dialog = _G.StaticPopupDialogs["SNAKESAYS_CHOOSE_MODE"]
		assert.is_table(dialog)
		dialog.OnButton1()          -- Automatic
		assert.equals("auto", ns.GetMode())
		assert.equals("auto", _G.SnakeSaysDB.mode)
	end)

	it("maps each popup button to the right mode", function()
		for button, expected in pairs({ OnButton1 = "auto", OnButton2 = "semi", OnButton3 = "manual" }) do
			local ns = bootInDelve()
			wow.fire("ZONE_CHANGED_NEW_AREA")
			_G.StaticPopupDialogs["SNAKESAYS_CHOOSE_MODE"][button]()
			assert.equals(expected, ns.GetMode())
		end
	end)
end)

describe("manual input gating", function()
	it("blocks HUD and keybind presses by default in automatic mode", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		assert.is_true(ns.GetBlockManualInput())
		assert.is_false(ns.Seq.Press("N"))
		assert.equals(0, ns.Seq.Count())
	end)

	it("allows presses by default in semi-automatic and manual modes", function()
		for _, mode in ipairs({ "semi", "manual" }) do
			local ns = addon.boot({ db = { mode = mode } })
			assert.is_false(ns.GetBlockManualInput())
			assert.is_true(ns.Seq.Press("N"))
			assert.equals(1, ns.Seq.Count())
		end
	end)

	it("honours an explicit override in either direction", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		ns.SetBlockManualInput(false)
		assert.is_true(ns.Seq.Press("N"))

		local ns2 = addon.boot({ db = { mode = "manual" } })
		ns2.SetBlockManualInput(true)
		assert.is_false(ns2.Seq.Press("N"))
	end)

	it("keeps the explicit override when the mode changes afterwards", function()
		local ns = addon.boot({ db = { mode = "manual" } })
		ns.SetBlockManualInput(false)   -- explicitly off
		ns.SetMode("auto")              -- would default to on, but the user has spoken
		assert.is_false(ns.GetBlockManualInput())
	end)

	it("never blocks the automatic recorder itself", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		assert.is_true(ns.Seq.Record("E"))
		assert.equals(1, ns.Seq.Count())
	end)

	it("never blocks reset", function()
		local ns = addon.boot({ db = { mode = "auto" } })
		ns.Seq.Record("N")
		ns.Seq.Reset()
		assert.equals(0, ns.Seq.Count())
	end)
end)

describe("mode slash commands", function()
	it("sets the mode from chat", function()
		local ns = addon.boot()
		wow.slash("SNAKESAYS", "mode semi")
		assert.equals("semi", ns.GetMode())
	end)

	it("reports the current mode when given no argument", function()
		addon.boot({ db = { mode = "auto" } })
		wow.slash("SNAKESAYS", "mode")
		assert.is_true(wow.chatContains("Automatic"))
	end)

	it("rejects an unknown mode with a helpful line", function()
		local ns = addon.boot({ db = { mode = "manual" } })
		wow.slash("SNAKESAYS", "mode banana")
		assert.equals("manual", ns.GetMode())
		assert.is_true(wow.chatContains("auto"))
	end)
end)
