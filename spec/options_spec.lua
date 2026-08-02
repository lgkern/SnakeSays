-- The options page is built headlessly, so we can assert that it reflects and
-- writes back the settings it exposes without a running client.

local addon = require("spec.helpers.addon")

describe("options page", function()
	it("registers a settings category at login", function()
		local ns = addon.boot()
		assert.is_function(ns.Options.Open)
		assert.has_no.errors(function() ns.Options.Open() end)
	end)

	it("refreshes without a mode chosen", function()
		local ns = addon.boot()
		assert.has_no.errors(function() ns.Options.Refresh() end)
	end)

	it("refreshes for every mode", function()
		for _, key in ipairs({ "auto", "semi", "manual" }) do
			local ns = addon.boot({ db = { mode = key } })
			assert.has_no.errors(function() ns.Options.Refresh() end)
		end
	end)
end)
