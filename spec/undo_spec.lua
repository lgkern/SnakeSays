-- Taking a press back.
--
-- A misclick used to cost the whole run, because Reset was the only way to
-- change what was recorded. These cover the one press the board will give back
-- and the three ways of asking for it: the right-click on the board, the
-- keybind, and the slash command.

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

local function press(ns, ...)
	for _, dir in ipairs({ ... }) do ns.Seq.Press(dir) end
	return ns
end

describe("taking a press back", function()
	it("removes the last one and leaves the rest alone", function()
		local ns = addon.boot()
		press(ns, "N", "E", "S")

		assert.is_true(ns.Seq.Undo())
		assert.same({ "N", "E" }, ns.Seq.Get())
	end)

	it("can be asked more than once, back to an empty board", function()
		local ns = addon.boot()
		press(ns, "N", "E")

		ns.Seq.Undo()
		ns.Seq.Undo()
		assert.equals(0, ns.Seq.Count())
	end)

	it("says no rather than erroring on an empty board", function()
		local ns = addon.boot()
		assert.is_false(ns.Seq.Undo())
		assert.equals(0, ns.Seq.Count())
	end)

	-- The row of markers is drawn by a listener, so a press that is taken back
	-- without telling anybody stays on screen. That is the whole bug this would
	-- be: the board says one thing and the addon believes another.
	it("tells the listeners, so what is drawn follows", function()
		local ns = addon.boot()
		local seen
		ns.Seq.OnChange(function(list) seen = #list end)

		press(ns, "N", "E")
		ns.Seq.Undo()

		assert.equals(1, seen)
	end)

	it("lets the quadrant that was taken back be pressed again", function()
		local ns = addon.boot()
		press(ns, "N", "E")
		ns.Seq.Undo()          -- board is {N}

		assert.is_true(ns.Seq.Press("S"))
		assert.same({ "N", "S" }, ns.Seq.Get())
	end)

	-- Emptying the board by hand is emptying the board: this client is no longer
	-- filling one of its own, so the group's run may come back onto the timeline.
	-- Reset already did this; undo has to as well or the two disagree.
	it("stops this client driving once the board is empty", function()
		local ns = addon.boot()
		press(ns, "N")
		assert.is_true(ns.Comms.IsDriving())

		ns.Seq.Undo()
		assert.is_false(ns.Comms.IsDriving())
	end)

	it("keeps driving while anything is still on the board", function()
		local ns = addon.boot()
		press(ns, "N", "E")

		ns.Seq.Undo()
		assert.is_true(ns.Comms.IsDriving())
	end)
end)

describe("asking for it", function()
	it("right-clicking a wedge takes the last press back", function()
		local ns = addon.boot()
		press(ns, "N", "E")

		wow.setCursor(0, 40)
		_G.SnakeSaysBoard:Run("OnClick", "RightButton")

		assert.same({ "N" }, ns.Seq.Get())
	end)

	-- Where on the board the right-click lands must not matter, and must
	-- certainly not record: the cursor is wherever the misclick left it. Even
	-- the hub hole, which no left-click can press, still gives a press back.
	it("right-clicking never records the wedge it was clicked on", function()
		local ns = addon.boot()
		press(ns, "N")

		wow.setCursor(40, 0)
		_G.SnakeSaysBoard:Run("OnClick", "RightButton")

		assert.equals(0, ns.Seq.Count())
	end)

	it("right-clicking the hub hole still takes the last press back", function()
		local ns = addon.boot()
		press(ns, "N", "E")

		wow.setCursor(0, 0)
		_G.SnakeSaysBoard:Run("OnClick", "RightButton")

		assert.same({ "N" }, ns.Seq.Get())
	end)

	it("left-clicking still records, as it always did", function()
		local ns = addon.boot()

		wow.setCursor(40, 0)
		_G.SnakeSaysBoard:Run("OnClick", "LeftButton")

		assert.same({ "E" }, ns.Seq.Get())
	end)

	it("is bindable, for a player whose hand is not on the board", function()
		local ns = addon.boot()
		press(ns, "N", "E")

		_G.SnakeSays_Undo()

		assert.same({ "N" }, ns.Seq.Get())
	end)

	it("is on the named button the keybinds click", function()
		local ns = addon.boot()
		press(ns, "N", "E")

		_G.SNAKESAYS_UNDO:Run("OnClick")

		assert.same({ "N" }, ns.Seq.Get())
	end)

	it("answers /ss undo", function()
		local ns = addon.boot()
		press(ns, "N", "E")

		wow.slash("SNAKESAYS", "undo")

		assert.same({ "N" }, ns.Seq.Get())
	end)

	it("says so when /ss undo has nothing to take back", function()
		addon.boot()

		wow.slash("SNAKESAYS", "undo")

		assert.is_true(wow.chatContains("nothing on the board"))
	end)
end)
