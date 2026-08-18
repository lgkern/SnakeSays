-- The options page is built headlessly, so we can assert that it reflects and
-- writes back the settings it exposes without a running client.

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

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

	-- The voice row and the DBM row both read state that lives outside
	-- SavedVariables -- the installed voices, and whether DBM is loaded with a
	-- pack -- so the page has to survive every combination of them being absent.
	-- The picker is built behind a pcall, so asking for a template the client does
	-- not have loses it without a word -- which is how it shipped. The mock only
	-- accepts templates the real client has, so this fails if the name is wrong
	-- again.
	it("really builds the voice picker", function()
		local ns = addon.boot()
		assert.is_true(ns.Options.HasVoicePicker())
	end)

	it("refreshes with no text-to-speech voices installed at all", function()
		local ns = addon.boot()
		_G.C_VoiceChat.GetTtsVoices = function() return {} end
		assert.has_no.errors(function() ns.Options.Refresh() end)
	end)

	it("refreshes with a voice picked", function()
		local ns = addon.boot({ db = { ttsVoice = 1 } })
		assert.has_no.errors(function() ns.Options.Refresh() end)
	end)

	it("refreshes when the picked voice has gone away with its language pack", function()
		local ns = addon.boot({ db = { ttsVoice = 42 } })
		assert.has_no.errors(function() ns.Options.Refresh() end)
	end)

	it("refreshes with DBM there and with it gone", function()
		local ns = addon.boot({ db = { dbmVoice = true } })
		assert.has_no.errors(function() ns.Options.Refresh() end)

		wow.installDBM()
		assert.has_no.errors(function() ns.Options.Refresh() end)
	end)

	it("offers a key box for every bindable action, undo included", function()
		local ns = addon.boot()
		ns.Options.Refresh()

		for command in pairs(ns.BINDING_LABEL) do
			assert.is_truthy(_G.GetBindingKey ~= nil)
			assert.is_truthy(_G[command], command .. " has no button to bind to")
		end
	end)
end)
