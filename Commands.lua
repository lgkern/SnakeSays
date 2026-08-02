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
BINDING_NAME_SNAKESAYS_CAPTURE = "Quadrant detection (semi-automatic)"

-- Called by Bindings.xml.
function SnakeSays_Press(dir)
	if ns.Seq.Press(dir) and ns.HUD then
		ns.HUD.Flash(dir)
	end
end

-- Semi-automatic capture: the player picks the moment, the addon reads which
-- quadrant they are standing in.
function SnakeSays_Capture()
	ns.Detector.Capture()
end

function SnakeSays_Reset()
	ns.Seq.Reset()
end

-- AddOn Compartment button (the icon on the minimap compartment, see the .toc).
-- Left-click opens options; right-click toggles the HUD.
function SnakeSays_OnCompartment(_, button)
	if button == "RightButton" then
		ns.SetShown(not ns.IsShown())
	else
		ns.Options.Open()
	end
end

-- ---------------------------------------------------------------------------
-- Slash commands
-- ---------------------------------------------------------------------------

local out = ns.Print

local function help()
	out("commands:")
	out("  /ss            open options (markers, HUD, keybinds)")
	out("  /ss mode       show the mode; `/ss mode auto|semi|manual` sets it")
	out("  /ss measure    re-pin the room centre to where you stand")
	out("  /ss radar      toggle the rotating position radar")
	out("  /ss sim        demo run anywhere; `/ss sim 7` for a 7-wave phase")
	out("                 `/ss sim record` records from where you stand")
	out("                 `/ss sim stop` ends it")
	out("  /ss status     report what the addon currently sees")
	out("  /ss show | hide")
	out("  /ss toggle     toggle the HUD")
	out("  /ss lock | unlock")
	out("  /ss reset      clear the recorded sequence")
	out("  /ss recenter   move the HUD back to the centre")
	out("  /ss options    open options")
end

-- The list of mode keys, for the error line ("auto, semi, manual").
local function modeKeyList()
	local keys = {}
	for _, mode in ipairs(ns.MODES) do keys[#keys + 1] = mode.key end
	return table.concat(keys, ", ")
end

local function modeCommand(arg)
	if arg == "" then
		local key = ns.GetMode()
		if key then
			out(("mode is |cffffd200%s|r. Change it with /ss mode %s"):format(ns.MODE_NAME[key], modeKeyList()))
		else
			out(("no mode chosen yet. Pick one with /ss mode %s"):format(modeKeyList()))
		end
		return
	end
	if ns.SetMode(arg) then
		out(("mode set to |cffffd200%s|r."):format(ns.MODE_NAME[arg]))
	else
		out(("unknown mode '%s'. Valid modes: %s"):format(arg, modeKeyList()))
	end
end

-- `/ss measure` re-pins the room centre to where the player is standing, and
-- `/ss measure reset` puts the shipped constants back.
local function measureCommand(arg)
	if arg == "reset" then
		ns.Position.ClearMeasuredCenter()
		out("room centre reset to the built-in value.")
		return
	end
	if ns.Position.MeasureCenter() then
		local center = ns.GetRoomCenter()
		out(("room centre set to where you stand (%.2f, %.2f)."):format(center.a, center.b))
	else
		out("|cffff5555could not read your position|r - room centre unchanged.")
	end
end

-- `/ss status` dumps what the addon currently believes. It exists so a problem
-- in the field can be described precisely instead of as "nothing happened".
local function statusCommand()
	local function yes(v) return v and "|cff44ff44yes|r" or "|cffff5555no|r" end

	out("status:")
	out("  mode: " .. (ns.MODE_NAME[ns.GetMode()] or "|cffff5555not chosen|r"))
	out("  in the delve: " .. yes(ns.InDelve()))

	local quadrant = ns.Position.Quadrant()
	local distance = ns.Position.Distance()
	out(("  position readable: %s%s"):format(
		yes(ns.Position.IsAvailable()),
		quadrant and (" (" .. quadrant .. ", %.1f yd from centre)"):format(distance or 0)
			or (distance and (" (centre, %.1f yd)"):format(distance) or "")))

	local center = ns.GetRoomCenter()
	out(("  room centre: %.2f, %.2f%s"):format(center.a, center.b,
		ns.db().roomCenter and " (measured)" or " (built in)"))
	out("  facing readable: " .. yes(ns.Position.Facing() ~= nil))

	out(("  board: shown=%s visible=%s | radar: on=%s visible=%s"):format(
		yes(ns.IsShown()), yes(ns.HUD.IsVisible()),
		yes(ns.GetRadarEnabled()), yes(ns.Radar.IsShown())))
	out("  only inside the delve map: " .. yes(ns.GetRestrictToMap()))

	out(("  encounter: armed=%s recording=%s replaying=%s step=%d of %d"):format(
		yes(ns.Detector.IsArmed()), yes(ns.Detector.IsRecording()),
		yes(ns.Detector.IsReplaying()), ns.Detector.EchoIndex(), ns.Seq.Count()))
	out("  practice run going: " .. yes(ns.Sim.IsRunning()))

	local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
	out(("  voice: on=%s installed=%d volume=%d"):format(
		yes(ns.GetTTSEnabled()), voices and #voices or 0, ns.GetTTSVolume()))
end

-- Handlers taking an argument get it as their first parameter; the rest ignore it.
local handlers = {
	[""]        = function() ns.Options.Open() end,
	mode        = modeCommand,
	measure     = measureCommand,
	status      = statusCommand,
	sim         = function(arg)
		if arg == "stop" then
			if not ns.Sim.Stop() then out("no practice run is going.") end
		else
			ns.Sim.Start(arg ~= "" and arg or nil)
		end
	end,
	radar       = function()
		ns.SetRadarEnabled(not ns.GetRadarEnabled())
		out("position radar: " .. (ns.GetRadarEnabled() and "on" or "off"))
	end,
	toggle      = function() ns.SetShown(not ns.IsShown()) end,
	show        = function() ns.SetShown(true) end,
	hide        = function() ns.SetShown(false) end,
	lock        = function() ns.SetLocked(true);  out("HUD locked.") end,
	unlock      = function() ns.SetLocked(false); out("HUD unlocked — drag it by the title bar.") end,
	reset       = function() ns.Seq.Reset() end,
	recenter    = function()
		ns.ClearPosition()
		ns.Radar.ClearPosition()      -- back to riding along with the board
		ns.Announce.ClearPopupPosition()
		out("windows moved back to their default places.")
	end,
	options     = function() ns.Options.Open() end,
	config      = function() ns.Options.Open() end,
	settings    = function() ns.Options.Open() end,
	help        = help,
}

SLASH_SNAKESAYS1 = "/snakesays"
SLASH_SNAKESAYS2 = "/ss"
SlashCmdList.SNAKESAYS = function(msg)
	local input = strtrim((msg or "")):lower()
	local cmd, rest = input:match("^(%S*)%s*(.-)%s*$")
	local handler = handlers[cmd]
	if handler then handler(rest or "") else help() end
end
