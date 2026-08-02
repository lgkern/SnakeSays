-- Proves the headless harness can load and boot the real addon files, and that
-- the client mock behaves the way the rest of the suite assumes.

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

describe("harness", function()
	it("loads every .lua listed in the .toc", function()
		local files = addon.tocFiles()
		assert.is_true(#files > 0)
		for _, path in ipairs(files) do
			local fh = io.open(path, "r")
			assert.is_truthy(fh, "missing file listed in .toc: " .. path)
			fh:close()
		end
	end)

	it("boots the addon and seeds SavedVariables", function()
		local ns = addon.boot()
		assert.is_table(ns.MARKERS)
		assert.is_table(_G.SnakeSaysDB)
		assert.is_table(_G.SnakeSaysDB.markers)
	end)

	it("keeps SavedVariables that were restored from disk", function()
		addon.boot({ db = { markers = { N = 8, E = 3, S = 6, W = 7 } } })
		assert.equals(8, _G.SnakeSaysDB.markers.N)
	end)
end)

describe("client mock", function()
	before_each(function() wow.reset() end)

	it("runs one-shot timers when the clock passes their due time", function()
		local fired = false
		C_Timer.NewTimer(5, function() fired = true end)
		wow.advance(4)
		assert.is_false(fired)
		wow.advance(2)
		assert.is_true(fired)
	end)

	it("repeats tickers on their interval and honours Cancel", function()
		local count = 0
		local ticker = C_Timer.NewTicker(1, function() count = count + 1 end)
		wow.advance(3.5)
		assert.equals(3, count)
		ticker:Cancel()
		wow.advance(5)
		assert.equals(3, count)
	end)

	it("dispatches events to registered frames only", function()
		local seen = {}
		local f = CreateFrame("Frame")
		f:RegisterEvent("TEST_EVENT")
		f:SetScript("OnEvent", function(_, event, arg) seen[#seen + 1] = event .. ":" .. tostring(arg) end)

		local quiet = CreateFrame("Frame")
		quiet:SetScript("OnEvent", function() seen[#seen + 1] = "should not happen" end)

		wow.fire("TEST_EVENT", 42)
		wow.fire("OTHER_EVENT", 1)
		assert.same({ "TEST_EVENT:42" }, seen)
	end)

	it("models secret values as arithmetic landmines", function()
		local s = wow.secret(12.5)
		assert.is_true(issecretvalue(s))
		assert.is_false(pcall(function() return s + 1 end))
		assert.is_false(pcall(function() return s < 3 end))
		-- ...but passing one around is fine, which is what makes them dangerous
		assert.is_true(pcall(function() local t = { s } return t end))
	end)

	it("reports position as unavailable when set to nil", function()
		wow.setPosition(nil)
		assert.is_nil(UnitPosition("player"))
	end)

	it("hands back secret coordinates on request", function()
		wow.setPosition(10, 20, 0, 3079, true)
		local a = UnitPosition("player")
		assert.is_true(issecretvalue(a))
	end)
end)
