-- The options page is built headlessly, so we can assert that it reflects and
-- writes back the settings it exposes without a running client.

local addon = require("spec.helpers.addon")

describe("options page", function()
	it("registers a settings category at login", function()
		local ns = addon.boot()
		assert.is_function(ns.Options.Open)
		assert.has_no.errors(function() ns.Options.Open() end)
	end)

	it("refreshes on a fresh install", function()
		local ns = addon.boot()
		assert.has_no.errors(function() ns.Options.Refresh() end)
	end)

	-- An install carried over from a version that had recording modes still has
	-- their keys sitting in SavedVariables. Nothing reads them any more, and
	-- nothing may trip over them either.
	it("refreshes with a stale mode left in SavedVariables", function()
		for _, key in ipairs({ "auto", "semi", "manual" }) do
			local ns = addon.boot({ db = { mode = key, blockManualInput = true } })
			assert.has_no.errors(function() ns.Options.Refresh() end)
			assert.has_no.errors(function() ns.Seq.Press("N") end)
			assert.equals(1, ns.Seq.Count())     -- the old block must not still bite
		end
	end)
end)
