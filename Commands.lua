local _, ns = ...

-- ===========================================================================
-- Commands.lua  ·  keybind click targets, binding labels, and the /snakesays hub.
--
-- These drive the same Seq API the mouse does (and pulse the wedge for
-- feedback). None of this is protected, so it all works mid-fight.
-- ===========================================================================

function SnakeSays_Press(dir)
	if ns.Seq.Press(dir) and ns.HUD then
		ns.HUD.Flash(dir)
	end
end

function SnakeSays_Reset()
	ns.Seq.Reset()
end

-- The board gives back its last press. Bindable like the rest of these, because
-- somebody who presses the quadrants by key never has the board under the cursor
-- to right-click in the first place.
function SnakeSays_Undo()
	ns.Seq.Undo()
end

-- ---------------------------------------------------------------------------
-- Keybind click targets
--
-- A Bindings.xml used to register these as named actions, but the client
-- misreports every <Binding> in that file as "Unrecognized XML" on load
-- (confirmed harmless, but noisy enough to trip the UI's error-spam warning).
-- Binding a key straight to a named button's click (see Options.lua, which
-- calls SetBindingClick) sidesteps that file entirely. Labels for the
-- addon's own keybind UI live in ns.BINDING_LABEL below.
-- ---------------------------------------------------------------------------

ns.BINDING_LABEL = {
	SNAKESAYS_NORTH   = "Press North quadrant",
	SNAKESAYS_EAST    = "Press East quadrant",
	SNAKESAYS_SOUTH   = "Press South quadrant",
	SNAKESAYS_WEST    = "Press West quadrant",
	SNAKESAYS_RESET   = "Reset sequence",
	SNAKESAYS_UNDO    = "Take the last press back",
}

-- These are also the `/click` targets the group-sharing macros use (see
-- `/ss macro`), which is why they are named and global.
local function bindButton(name, onClick)
	local b = CreateFrame("Button", name, UIParent)
	b:SetScript("OnClick", onClick)
	return b
end

for _, dir in ipairs({ "N", "E", "S", "W" }) do
	bindButton("SNAKESAYS_" .. ns.QUADRANT_NAME[dir]:upper(),
		function() SnakeSays_Press(dir) end)
end
bindButton("SNAKESAYS_RESET", function() SnakeSays_Reset() end)
bindButton("SNAKESAYS_UNDO", function() SnakeSays_Undo() end)

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
	out("  /ss sim        demo run anywhere; `/ss sim 7` for a 7-wave phase")
	out("                 `/ss sim stop` ends it")
	out("  /ss status     report what the addon currently sees")
	out("  /ss probe      report which of the client's reads still work in here")
	out("  /ss sound      test the voice and say what the client did")
	out("  /ss debug      step-by-step detection output in chat")
	out("  /ss show | hide")
	out("  /ss toggle     toggle the HUD")
	out("  /ss lock | unlock")
	out("  /ss reset      clear the recorded sequence")
	out("  /ss undo       take the last press back (right-click the board too)")
	out("  /ss sync       share the sequence with your group (`on` / `off`)")
	out("  /ss macro      the macros that share your board with the group")
	out("  /ss timeline   toggle the timeline bar (`on` / `off` to be explicit)")
	out("  /ss recenter   move every window back to its default place")
	out("  /ss options    open options")
end

-- `/ss status` dumps what the addon currently believes. It exists so a problem
-- in the field can be described precisely instead of as "nothing happened".
local function statusCommand()
	local function yes(v) return v and "|cff44ff44yes|r" or "|cffff5555no|r" end

	out("status:")
	out("  in the delve: " .. yes(ns.InDelve()))

	out(("  board: shown=%s visible=%s"):format(
		yes(ns.IsShown()), yes(ns.HUD.IsVisible())))
	out("  board frame: " .. ns.HUD.Describe())
	out("  in combat: " .. yes(InCombatLockdown and InCombatLockdown()))
	out(("  timeline: on=%s visible=%s slots=%d"):format(
		yes(ns.GetTimelineEnabled()), yes(ns.Timeline.IsVisible()), ns.Timeline.SlotCount()))
	out("  only inside the delve map: " .. yes(ns.GetRestrictToMap()))

	out(("  encounter: armed=%s round showing=%s replaying=%s step=%d of %d"):format(
		yes(ns.Detector.IsArmed()), yes(ns.Detector.IsShowingRound()),
		yes(ns.Detector.IsReplaying()), ns.Detector.EchoIndex(), ns.Seq.Count()))
	local function timing(diff)
		return ("%.3fs%s"):format(ns.SlotLength(diff), ns.IsSlotLearned(diff) and " (learned)" or "")
	end
	out(("  wave timing: normal %s, hard %s"):format(timing("normal"), timing("hard")))

	local grid = ns.Detector.ActiveGrid()
	if grid then
		out(("  round in progress: wave %d of %d, %.3fs slots (%s)"):format(
			grid.wave, grid.waves, grid.slot, grid.difficulty or "difficulty unknown"))
	end
	out("  practice run going: " .. yes(ns.Sim.IsRunning()))

	out(("  group chat: reading=%s window=%s board=%s waves heard=%d"):format(
		yes(ns.GetGroupSync()), yes(ns.Comms.IsListening()),
		ns.Comms.IsDriving() and "|cffffd200yours|r" or "the group's",
		#ns.Comms.Heard()))


	local voices = C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()
	local active = ns.Announce.ActiveVoice()
	out(("  voice: on=%s installed=%d volume=%d"):format(
		yes(ns.GetTTSEnabled()), voices and #voices or 0, ns.GetTTSVolume()))
	out(("    using: %s%s"):format(
		ns.Announce.VoiceName(active) or ("id " .. tostring(active)),
		ns.GetTTSVoice() == nil and " (chosen for you)" or " (you picked it)"))
	out(("    DBM voice: wanted=%s available=%s"):format(
		yes(ns.GetDBMVoice()), yes(ns.Announce.DBMVoiceAvailable())))
end

-- Handlers taking an argument get it as their first parameter; the rest ignore it.
local handlers = {
	[""]        = function() ns.Options.Open() end,
	status      = statusCommand,
	probe       = function() ns.Detector.Probe() end,
	sound       = function() ns.Announce.SelfTest() end,
	debug       = function(arg)
		if arg == "on" then ns.SetDebug(true)
		elseif arg == "off" then ns.SetDebug(false)
		else ns.SetDebug(not ns.GetDebug()) end
		out("detection output: " .. (ns.GetDebug() and "|cff44ff44on|r" or "off"))
	end,
	sim         = function(arg)
		if arg == "stop" then
			if not ns.Sim.Stop() then out("no practice run is going.") end
		else
			ns.Sim.Start(arg ~= "" and arg or nil)
		end
	end,
	toggle      = function() ns.SetShown(not ns.IsShown()) end,
	show        = function() ns.SetShown(true) end,
	hide        = function() ns.SetShown(false) end,
	lock        = function() ns.SetLocked(true);  out("HUD locked.") end,
	unlock      = function() ns.SetLocked(false); out("HUD unlocked — drag it by the title bar.") end,
	-- Both, because they are two runs: the board is this player's, and the staff
	-- may also be carrying one heard in party chat. "Clear it" means both.
	reset       = function() ns.Seq.Reset(); ns.Comms.Clear() end,
	-- Only this client's board, and only its last press: the run heard in party
	-- chat is somebody else's typing and cannot be un-typed.
	undo        = function()
		if not ns.Seq.Undo() then out("nothing on the board to take back.") end
	end,
	-- The addon cannot make these itself, and that is not an oversight: a button
	-- an addon created is the addon acting however the click arrived, and the
	-- client refuses it. A macro the player made is the player. So it prints them
	-- and the player makes them once.
	-- The addon writes these into the macro window itself, out of combat. What it
	-- may not do is press one for you -- a secure button carrying the same text
	-- does nothing at all -- so you bind them and the press stays yours.
	macro       = function()
		local ok, result = ns.Comms.InstallMacros()
		if not ok then
			out("|cffff5555could not make the macros|r - " .. tostring(result) .. ".")
			out("you can make them by hand instead:")
			for _, dir in ipairs(ns.QUADRANTS) do
				out(("  |cffffd200%s|r"):format(ns.QUADRANT_NAME[dir]))
				for line in ns.Comms.MacroFor(dir):gmatch("[^\n]+") do
					out("    " .. line)
				end
			end
			return
		end
		out("made |cffffd200" .. table.concat(result, ", ") .. "|r in your character "
			.. "macros (Esc > Macros).")
		out("bind them where your quadrant keys are now - pressing one records your "
			.. "board |cffffd200and|r puts the marker on your group's timeline.")
		out("run this again if you change which marker a quadrant uses.")
		out("only the person calling needs them; everyone else just reads.")
	end,
	sync        = function(arg)
		if arg == "on" then ns.SetGroupSync(true)
		elseif arg == "off" then ns.SetGroupSync(false)
		else ns.SetGroupSync(not ns.GetGroupSync()) end
		out("group sync: " .. (ns.GetGroupSync() and "|cff44ff44on|r" or "off"))
	end,
	timeline    = function(arg)
		if arg == "on" then ns.SetTimelineEnabled(true)
		elseif arg == "off" then ns.SetTimelineEnabled(false)
		else ns.SetTimelineEnabled(not ns.GetTimelineEnabled()) end
		out("timeline: " .. (ns.GetTimelineEnabled() and "|cff44ff44on|r" or "off"))
	end,
	recenter    = function()
		ns.ClearPosition()
		ns.Announce.ClearPopupPosition()
		ns.Timeline.ClearPosition()
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
