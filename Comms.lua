local _, ns = ...

-- ===========================================================================
-- Comms.lua  ·  one player types the run, the group reads it off their screen.
--
-- Everything an addon could do itself was tried in the field and refused:
--
--   C_ChatInfo.SendAddonMessage   AddOnMessageLockdown (11) in combat inside
--                                 instanced content -- which is the whole fight
--   SendChatMessage from addon    "Interface action failed because of an
--                                 AddOn", sends nothing
--   a secure button with          attributes read back correctly, clicking it
--   `macrotext`                   does nothing at all
--
-- So the sending is a macro the player made and pressed, which is the player
-- acting and which the client allows. That part works.
--
-- The reading has a harder limit, and it is the one that shapes this file:
--
--   Comms.lua:189: attempt to index local 'text' (a secret string value,
--   while execution tainted by 'SnakeSays')
--
-- The message body arrives SECRET, and so does the sender. Matching, comparing,
-- measuring or lowercasing either of them throws -- `sender == ""` is enough to
-- do it. So this addon never learns what was typed, nor who typed it.
--
-- What it can do is hand the value straight back to a display function, where
-- the client does the work. And it can do better than show it: a format string
-- is applied in C, so the secret can be dropped into the middle of a texture
-- escape and come out as a picture --
--
--   SetFormattedText("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%s:24|t", text)
--
-- which is why what travels is the bare marker NUMBER. The prefix is ours and
-- the suffix is theirs, and the two are joined somewhere we are not. This is
-- NorthernSkyRaidTools' L'ura display exactly: their macros type a file name
-- ("Circle", "Cross") into raid chat and the receiver renders
-- "...\\Media\\EncounterPics\\%s:48:48". Same trick, Blizzard's own art.
--
-- A raid-target token would have been prettier in the chat frame, and does not
-- work: {rt2} only becomes an icon inside the chat frame's own render, and
-- "UI-RaidTargetingIcon_{rt2}" is not a path. Tested in the field -- it showed
-- up on the timeline as the literal text "{rt2}".
--
-- It is also why their event registration is scoped to a few seconds around the
-- memory game: unable to tell an assignment from conversation, they narrow the
-- window instead.
--
-- Two facts survive in the clear: that a line arrived, and WHICH event carried
-- it -- CHAT_MSG_PARTY_LEADER being its own event is the last thing the client
-- will say about a sender. Everything here is decided from those two and from
-- what the detector already knows about the pull.
--
-- What the follower gets is the run on screen, in order, as the caller typed
-- it. What they do not get is the voice or the timeline, because those need to
-- know which quadrant it is and this client never can.
-- ===========================================================================

local Comms = {}
ns.Comms = Comms

local MAX_WAVE = 20

-- Blizzard ships each raid target as its own file, which is what makes the
-- number a usable payload. Timeline.lua renders the receiving half of this.
local MARKER_ICON = "Interface\\TargetingFrame\\UI-RaidTargetingIcon_%d"
local QUESTION_MARK = 134400   -- INV_Misc_QuestionMark, by file ID

local driving = false     -- this client pressed, so its own board is the one it uses

-- ---------------------------------------------------------------------------
-- The macros
--
-- The addon cannot install these, and that is the whole finding: a secure
-- button an addon created and set up is still the addon acting as far as the
-- client is concerned, however the click arrived. A macro made in the macro
-- window is the player. So these are printed, and made once by hand.
-- ---------------------------------------------------------------------------

local function chatCommand()
	if type(IsInRaid) == "function" and IsInRaid() then return "/raid" end
	return "/p"
end

-- Press the quadrant locally, then tell the group. The `/click` target is the
-- same named button the keybinds drive (Commands.lua), so the macro and the
-- keybind do exactly the same thing to the board.
--
-- What travels is the marker NUMBER on its own -- "2", not "N" and not "{rt2}".
-- It is not a message, it is the last segment of a texture path: the receiver
-- cannot read it, but it can format it into
-- "Interface\TargetingFrame\UI-RaidTargetingIcon_%s" and put the picture on the
-- timeline. See the header. Anything else in the line, a tag or a word, would
-- land inside that path and break it.
--
-- The marker is this player's own assignment for the quadrant, which is the one
-- they are looking at as they press it.
function Comms.MacroFor(quadrant)
	if not ns.QUADRANT_NAME[quadrant] then return nil end
	return ("/click SNAKESAYS_%s\n%s %d"):format(
		ns.QUADRANT_NAME[quadrant]:upper(), chatCommand(),
		ns.GetAssignment(quadrant) or 1)
end

-- Clearing the board says nothing to the group, and must not: every line that
-- arrives during the window counts as a wave, because none of them can be read.
-- A reset that announced itself would add a wave to everyone else's run.
function Comms.ResetMacro()
	return "/click SNAKESAYS_RESET"
end

-- ---------------------------------------------------------------------------
-- Making them
--
-- The addon may not *press* a macro on the player's behalf -- that was tried,
-- and a secure button carrying macrotext does nothing at all. But it may write
-- one into the macro window, out of combat, like any macro helper. So the
-- player is spared the typing and still owns the press, which is the half the
-- client actually cares about.
--
-- Character macros rather than account ones: they name themselves after this
-- character's marker assignment, and another character may have chosen
-- differently.
-- ---------------------------------------------------------------------------

local MACRO_NAMES = { N = "SS North", E = "SS East", S = "SS South", W = "SS West" }
local RESET_MACRO_NAME = "SS Reset"

-- The macro API wants a file ID, not a path. A path string is accepted without
-- complaint and then ignored, which is how the first cut made five macros with
-- no icon at all on them -- and a macro with no icon cannot be dragged to a bar.
local function macroIcon(quadrant)
	local marker = quadrant and ns.GetAssignment(quadrant)
	if marker and type(GetFileIDFromPath) == "function" then
		local ok, id = pcall(GetFileIDFromPath, MARKER_ICON:format(marker))
		if ok and type(id) == "number" and id > 0 then return id end
	end
	return QUESTION_MARK
end

-- Write one macro, replacing what is under that name rather than piling up
-- duplicates. Returns the index, or nil and why not.
local function writeMacro(name, icon, body)
	if type(CreateMacro) ~= "function" or type(GetMacroIndexByName) ~= "function" then
		return nil, "this client has no macro API"
	end

	local ok, index = pcall(GetMacroIndexByName, name)
	if ok and type(index) == "number" and index > 0 then
		local edited = pcall(EditMacro, index, name, icon, body)
		if not edited then return nil, "could not update " .. name end
		return index
	end

	local made, created = pcall(CreateMacro, name, icon, body, true)
	if not made or not created then
		return nil, "no room left for a character macro"
	end
	return created
end

-- `/ss macro`. Refused in combat, because writing a macro there is one of the
-- things the client will not have.
function Comms.InstallMacros()
	if InCombatLockdown and InCombatLockdown() then
		return false, "not while you are in combat"
	end

	local made = {}
	for _, quadrant in ipairs(ns.QUADRANTS) do
		local name = MACRO_NAMES[quadrant]
		local index, why = writeMacro(name, macroIcon(quadrant), Comms.MacroFor(quadrant))
		if not index then return false, why end
		made[#made + 1] = name
	end

	local index, why = writeMacro(RESET_MACRO_NAME, macroIcon(nil), Comms.ResetMacro())
	if not index then return false, why end
	made[#made + 1] = RESET_MACRO_NAME

	return true, made
end

-- ---------------------------------------------------------------------------
-- Reading
--
-- Nothing here inspects a message. `text` is secret: matching it, comparing it,
-- measuring it or lowercasing it all throw. It is stored and handed to the HUD,
-- which gives it straight to SetFormattedText, and the client renders what we
-- were never allowed to see.
--
-- Which means the addon cannot tell an assignment from "brb". Three things
-- narrow it instead, in descending order of how much they help:
--
--   the round      lines only count while the detector says a round is being
--                  shown, which is the tightest window there is
--   the leader     once a CHAT_MSG_*_LEADER line arrives, only the leader is
--                  calling and everyone else in the window is chatting
--   the count      never more waves than the round is going to have
--
-- NorthernSkyRaidTools has only the first of those, off fixed timers, and it
-- works well enough in a raid. This is the same idea with better fences.
-- ---------------------------------------------------------------------------

local heard = {}          -- the pull's lines, in arrival order, still secret
local firstHeardAt        -- when the first of them arrived
local listening = false   -- whether a pull is up and lines count
local leaderOnly = false  -- the group leader has called, so nobody else counts

function Comms.Heard() return heard end
function Comms.IsListening() return listening end

-- When this run started arriving. The round uses it the same way it uses
-- Seq.FirstPressAt: lines that turned up while an unreadable channel was still
-- proving itself belong to the round about to start, not the one that ended.
function Comms.FirstHeardAt() return firstHeardAt end

local function clearHeard()
	if #heard == 0 and not leaderOnly then return end
	heard = {}
	firstHeardAt = nil
	leaderOnly = false
	if ns.Timeline and ns.Timeline.RenderHeard then ns.Timeline.RenderHeard(heard) end
end

-- Throw away the run heard so far. The round start decides when, under a rule of
-- its own (Detector.beginRound), which is why this is not wired to the board
-- being cleared: those are two different events and a logged pull had the board
-- cleared out from under a run that had only just begun to arrive.
function Comms.Clear() clearHeard() end

-- The detector opens the window for the whole encounter, not just the round.
--
-- Scoping it to the showing half was the first cut and it dropped everything: an
-- unreadable channel spends two seconds proving it is a round (CONFIRM_CHANNEL),
-- and the caller is already typing throughout. A logged pull had every line
-- arrive before the window opened.
function Comms.SetListening(on)
	on = not not on
	if on == listening then return end
	listening = on
	-- Cleared either way. Opening starts a pull with an empty staff; closing takes
	-- the last round's icons off it, which otherwise sit there until the next pull
	-- because nothing else between fights ever touches them.
	clearHeard()
	ns.Trace("chat window %s", on and "open" or "closed")
end

-- The board was cleared, so this client is no longer filling one of its own and
-- can take the group's again. What was already heard is left alone -- see
-- Comms.Clear.
function Comms.OnBoardCleared()
	driving = false
end

-- A local press. This client is filling its own board, so it stops taking the
-- group's: two runs on one screen is worse than either alone.
function Comms.OnLocalPress()
	driving = true
	clearHeard()
end

function Comms.IsDriving() return driving end

-- One line of group chat, while a pull is up.
--
-- Nothing about the message can be looked at. The body is secret, and so is the
-- sender -- `sender == ""` is a comparison and throws just like `text:match`
-- does. So this decides everything from the two facts the client hands over in
-- the clear: WHICH event fired, and that one fired at all.
--
-- Which means our own lines cannot be recognised either. They do not need to
-- be: pressing a quadrant sets `driving`, and the macro runs `/click` before it
-- runs `/p`, so this client is already ignoring chat by the time its own line
-- comes back.
function Comms.ReceiveChat(text, fromLeader)
	if not ns.GetGroupSync() then
		ns.Trace("  ignored: group sync is off")
		return false
	end
	-- Belt and braces with the registration below, which is what actually keeps
	-- the addon out of the guild's conversation: the events are only hooked
	-- inside the delve. This catches the line that arrives between walking out
	-- and the zone event landing.
	if not ns.InDelve() then
		ns.Trace("  ignored: not in the delve")
		return false
	end
	if not listening then
		ns.Trace("  ignored: no encounter is up")
		return false
	end
	if driving then
		ns.Trace("  ignored: we are filling this board ourselves")
		return false
	end

	-- CHAT_MSG_PARTY_LEADER is its own event, which is the one thing the client
	-- will still tell us about a sender. Once the leader has called a wave,
	-- everyone else in the window is chatting.
	if fromLeader and not leaderOnly then
		leaderOnly = true
		if #heard > 0 then
			heard = {}
			ns.Trace("  the leader is calling - starting the run over")
		end
	elseif leaderOnly and not fromLeader then
		ns.Trace("  ignored: the group leader is calling this run")
		return false
	end

	local cap = (ns.Detector and ns.Detector.ExpectedWaves())
		or (ns.Detector and ns.Detector.MaxWaves()) or MAX_WAVE
	if #heard >= cap then
		ns.Trace("  ignored: the round only has %d wave(s)", cap)
		return false
	end

	local first = #heard == 0
	if first then firstHeardAt = GetTime() end
	heard[#heard + 1] = text
	ns.Trace("  wave %d (contents not readable)", #heard)

	if ns.Timeline and ns.Timeline.RenderHeard then ns.Timeline.RenderHeard(heard) end
	if first then
		ns.Print("the run is being called in party chat - watch the timeline.")
	end
	return true
end

-- ---------------------------------------------------------------------------
-- Wiring
--
-- No chat filter. Deciding whether a line is one of ours would mean reading it,
-- and reading it is the thing that throws -- an earlier build's filter did
-- exactly that, inside Blizzard's own dispatch.
-- ---------------------------------------------------------------------------

local LEADER_CHAT = { CHAT_MSG_PARTY_LEADER = true, CHAT_MSG_RAID_LEADER = true }

local CHAT_EVENTS = {
	"CHAT_MSG_PARTY", "CHAT_MSG_PARTY_LEADER", "CHAT_MSG_RAID", "CHAT_MSG_RAID_LEADER",
}

local boot = CreateFrame("Frame")

-- Hooked only inside the delve, and unhooked on the way out.
--
-- Registered for the whole session first, which was wrong in a way that only
-- showed up under `/ss debug`: every line of guild and party chat anywhere in
-- the world came through here to be traced and then ignored. Nothing was ever
-- read -- `listening` is false outside a pull -- but the addon has no business
-- being on the other end of a conversation it is not part of, and the trace
-- said so, one line per message, all evening.
--
-- Same fence the HUD and the timeline already use (ns.InDelve), so all three
-- appear and disappear together.
local hooked = false

local function applyChatEvents()
	local want = ns.InDelve()
	if want == hooked then return end
	hooked = want
	for _, event in ipairs(CHAT_EVENTS) do
		if want then boot:RegisterEvent(event) else boot:UnregisterEvent(event) end
	end
	ns.Trace("party chat %s", want and "hooked" or "unhooked (outside the delve)")
	-- Walking out ends the pull as far as this file is concerned; what was heard
	-- belongs to a run nobody is looking at any more.
	if not want then clearHeard() end
end

for _, event in ipairs({
	"PLAYER_LOGIN", "PLAYER_ENTERING_WORLD",
	"ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
}) do
	boot:RegisterEvent(event)
end

boot:SetScript("OnEvent", function(_, event, ...)
	-- Zone events, which is everything that is not a line of chat.
	if event:sub(1, 9) ~= "CHAT_MSG_" then
		applyChatEvents()
		return
	end

	local text = ...
	-- The sender is not printed, because printing it means touching it.
	ns.Trace("%s", event)

	-- Wrapped, but never silently: a swallowed error here cost two sessions of
	-- field testing before it turned out to be the secret values above.
	local ok, err = pcall(Comms.ReceiveChat, text, LEADER_CHAT[event] == true)
	if not ok then
		-- Traced every single time. Chat is printed once so a broken build does
		-- not spam the frame, but suppressing the *record* of it made a
		-- still-broken client look like a quiet one for a whole session.
		ns.Trace("|cffff5555reading party chat threw:|r %s", tostring(err))
		if not Comms.errorSaid then
			Comms.errorSaid = true
			ns.Print("|cffff5555reading party chat threw:|r " .. tostring(err))
		end
	end
end)
