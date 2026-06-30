local _, ns = ...

-- ===========================================================================
-- Commands.lua  ·  keybind globals, binding labels, and the /snakesays hub.
--
-- The keybind globals are called from Bindings.xml; they drive the same Seq API
-- the mouse does (and pulse the wedge for feedback). None of this is protected,
-- so it all works mid-fight.
-- ===========================================================================

-- Keybinding labels (consumed by the Keybindings UI; see Bindings.xml).
BINDING_HEADER_SNAKESAYS = "SnakeSays"
BINDING_NAME_SNAKESAYS_NORTH = "Press North quadrant"
BINDING_NAME_SNAKESAYS_EAST  = "Press East quadrant"
BINDING_NAME_SNAKESAYS_SOUTH = "Press South quadrant"
BINDING_NAME_SNAKESAYS_WEST  = "Press West quadrant"
BINDING_NAME_SNAKESAYS_RESET = "Reset sequence"

-- Called by Bindings.xml.
function SnakeSays_Press(dir)
	if ns.Seq.Press(dir) and ns.HUD then
		ns.HUD.Flash(dir)
	end
end

function SnakeSays_Reset()
	ns.Seq.Reset()
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local function out(msg)
	print("|cff33ddaaSnakeSays|r: " .. msg)
end

local function help()
	out("commands:")
	out("  /ss            open options (markers, HUD, keybinds)")
	out("  /ss show | hide")
	out("  /ss toggle     toggle the HUD")
	out("  /ss lock | unlock")
	out("  /ss reset      clear the recorded sequence")
	out("  /ss recenter   move the HUD back to the centre")
	out("  /ss options    open options")
end

local handlers = {
	[""]        = function() ns.Options.Open() end,
	toggle      = function() ns.SetShown(not ns.IsShown()) end,
	show        = function() ns.SetShown(true) end,
	hide        = function() ns.SetShown(false) end,
	lock        = function() ns.SetLocked(true);  out("HUD locked.") end,
	unlock      = function() ns.SetLocked(false); out("HUD unlocked — drag it by the title bar.") end,
	reset       = function() ns.Seq.Reset() end,
	recenter    = function() ns.ClearPosition() end,
	options     = function() ns.Options.Open() end,
	config      = function() ns.Options.Open() end,
	settings    = function() ns.Options.Open() end,
	help        = help,
}

SLASH_SNAKESAYS1 = "/snakesays"
SLASH_SNAKESAYS2 = "/ss"
SlashCmdList.SNAKESAYS = function(msg)
	local cmd = strtrim((msg or "")):lower()
	local handler = handlers[cmd]
	if handler then handler() else help() end
end
