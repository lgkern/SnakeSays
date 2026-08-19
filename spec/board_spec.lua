-- Where a click on the board lands.
--
-- The board is a circle cut into four 90-degree wedges, and for a long time the
-- thing that answered a click was not a wedge but a rectangle roughly over one:
-- four full-circle buttons, each trimmed with hit-rect insets. Rectangles do not
-- tile a disc into sectors. Adjacent boxes overlapped across about a fifth of
-- the circle -- beside a seam the press went to whichever button happened to be
-- on top, so a cursor plainly on red marked blue -- and the outer part of each
-- diagonal was covered by nothing at all. It was reported from the field as
-- marking the wrong colour in a fight, and it cost the reporter pulls.
--
-- These cover the replacement: one button, and a hit test in the same shape as
-- the paint.

local addon = require("spec.helpers.addon")
local wow = require("spec.helpers.wow")

-- The board as it is drawn: CIRCLE = 150 in HUD.lua, and the art's own radii
-- measured out of a half-size of 128 (tools/gen_wedge.py: OUTER_R 125, INNER_R
-- 18, and GAP 6 of transparent seam either side of each diagonal). Written out
-- again here rather than read from the addon, because agreeing with the numbers
-- the art was drawn from is the whole claim being tested.
local HALF = 150 / 2
local RIM  = HALF * 125 / 128
local HUB  = HALF * 18 / 128
local GAP  = HALF * 6 / 128

-- What the texture generator paints at (dx, dy), y pointing up: the direction,
-- or nil for the hub hole, the outside, and the seam gaps.
local function painted(dx, dy)
	local r = math.sqrt(dx * dx + dy * dy)
	if r > RIM or r < HUB then return nil end
	local ax, ay = math.abs(dx), math.abs(dy)
	if ay >= ax + GAP then return dy > 0 and "N" or "S" end
	if ax >= ay + GAP then return dx > 0 and "E" or "W" end
	return nil                                  -- in a seam
end

local function boot()
	local ns = addon.boot()
	return ns
end

local function clickAt(x, y, button)
	wow.setCursor(x, y)
	_G.SnakeSaysBoard:Run("OnClick", button or "LeftButton")
end

describe("the wedge under the cursor", function()
	it("is the wedge the art has painted there, everywhere on the circle", function()
		local ns = boot()

		local wrong = {}
		for x = -80, 80, 0.5 do
			for y = -80, 80, 0.5 do
				local want = painted(x, y)
				local got = ns.HUD.DirectionAt(x, y)
				if want and got ~= want and #wrong < 8 then
					table.insert(wrong, ("(%.1f, %.1f) is %s, answered %s")
						:format(x, y, want, tostring(got)))
				end
			end
		end

		assert.same({}, wrong)
	end)

	-- The seams are three and a half pixels of transparent gap. A press landing
	-- in one is a press the player meant, so it goes to the nearer wedge rather
	-- than nowhere: between the hub and the rim there is no dead ground left.
	it("answers everywhere between the hub and the rim, seams included", function()
		local ns = boot()

		local dead = {}
		for x = -80, 80, 0.5 do
			for y = -80, 80, 0.5 do
				local r = math.sqrt(x * x + y * y)
				if r > HUB + 0.5 and r < RIM - 0.5 and not ns.HUD.DirectionAt(x, y) then
					if #dead < 8 then
						table.insert(dead, ("(%.1f, %.1f) at r=%.1f"):format(x, y, r))
					end
				end
			end
		end

		assert.same({}, dead)
	end)

	it("is nothing at all past the rim or inside the hub", function()
		local ns = boot()

		assert.is_nil(ns.HUD.DirectionAt(0, RIM + 1))
		assert.is_nil(ns.HUD.DirectionAt(RIM + 1, 0))
		assert.is_nil(ns.HUD.DirectionAt(60, 60))      -- the corner of the frame
		assert.is_nil(ns.HUD.DirectionAt(0, 0))
		assert.is_nil(ns.HUD.DirectionAt(HUB - 1, 0))
	end)
end)

describe("clicking the board", function()
	-- The reported case, in the reporter's own units: the cursor a little left
	-- of centre and barely above it is on red, and used to mark orange, because
	-- it fell inside the north button's rectangle as well as the west one's.
	it("marks the colour under the cursor beside a seam, not its neighbour", function()
		local ns = boot()

		clickAt(-34, 6)

		assert.same({ "W" }, ns.Seq.Get())
	end)

	it("marks the right colour in all four of those corners", function()
		local ns = boot()

		clickAt(30, 10)     assert.equals("E", ns.Seq.Get()[1])
		clickAt(10, 30)     assert.equals("N", ns.Seq.Get()[2])
		clickAt(-10, -30)   assert.equals("S", ns.Seq.Get()[3])
		clickAt(-30, -10)   assert.equals("W", ns.Seq.Get()[4])
	end)

	-- The far end of a diagonal used to be inside no button's rectangle, so a
	-- press out there did nothing and the player pressed again.
	it("marks at the outer end of a diagonal, where nothing used to answer", function()
		local ns = boot()

		clickAt(52, 48)

		assert.same({ "E" }, ns.Seq.Get())
	end)

	it("records nothing past the rim or in the hub hole", function()
		local ns = boot()

		clickAt(0, RIM + 4)
		clickAt(60, 60)
		clickAt(0, 0)

		assert.equals(0, ns.Seq.Count())
	end)

	-- The cursor arrives in screen pixels and the circle measures itself in board
	-- pixels; the scale is the only thing between them. Miss the division and a
	-- board at 1.6 reads every press as though it were nearer the rim than it is,
	-- which past the rim means no press at all.
	it("reads the cursor in the board's own units at any scale", function()
		local ns = boot()
		ns.SetHUDScale(1.6)

		clickAt(-34 * 1.6, 6 * 1.6)

		assert.same({ "W" }, ns.Seq.Get())
	end)
end)

describe("the highlight and the tooltip", function()
	local function hoverAt(x, y, script)
		wow.setCursor(x, y)
		_G.SnakeSaysBoard:Run(script or "OnUpdate", 0.05)
	end

	it("names the wedge the cursor is actually on", function()
		boot()

		hoverAt(-34, 6, "OnEnter")

		assert.equals("West", _G.GameTooltip:GetText())
	end)

	-- One button now, so the cursor can cross a seam without ever entering or
	-- leaving anything. Nothing would repaint if the crossing were not watched
	-- for, and the board would name the wrong wedge until the cursor left it.
	it("follows the cursor across a seam without leaving the board", function()
		boot()

		hoverAt(-34, 6, "OnEnter")
		hoverAt(-6, 34)

		assert.equals("North", _G.GameTooltip:GetText())
	end)

	it("says nothing while the cursor is on the frame but off the paint", function()
		boot()

		hoverAt(-34, 6, "OnEnter")
		hoverAt(70, 70)

		assert.is_false(_G.GameTooltip:IsShown())
	end)

	it("lets go when the cursor leaves", function()
		boot()

		hoverAt(-34, 6, "OnEnter")
		_G.SnakeSaysBoard:Run("OnLeave")

		assert.is_false(_G.GameTooltip:IsShown())
	end)
end)
