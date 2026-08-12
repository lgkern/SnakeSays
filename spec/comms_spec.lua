-- Group sync: one player types the run into party chat, the group reads it off
-- their screen.
--
-- Nothing here parses a message, and the tests do not either. The message body
-- arrives as a secret value -- matching, comparing, measuring or lowercasing it
-- all throw:
--
--   attempt to index local 'text' (a secret string value, while execution
--   tainted by 'SnakeSays')
--
-- The sender is secret too -- `sender == ""` throws. So what is proved here is
-- everything the addon decides from the two facts left in the clear: which event
-- carried the line, and that one arrived.

local wow = require("spec.helpers.wow")
local enc = require("spec.helpers.encounter")

local function inGroup(extraDB)
	local ns = enc.setup(extraDB)
	wow.groupSize = 3
	return ns
end

-- A line of party chat. The body is wrapped as a secret, exactly as the live
-- client delivers it, so any code that tries to read it fails here too.
-- Both the body AND the sender arrive secret, exactly as the live client
-- delivers them, so any code that touches either fails here too.
local function say(sender, text, asLeader)
	wow.fire(asLeader and "CHAT_MSG_PARTY_LEADER" or "CHAT_MSG_PARTY",
		wow.secret(text or "N"), wow.secret(sender or "Caller-Realm"))
end

-- The window opens with the pull. It has to: an unreadable channel spends two
-- seconds proving it is a round, and the caller is typing throughout -- a logged
-- pull had every line arrive before a round-scoped window would have opened.
local function roundStarts(ns)
	enc.pull(ns, enc.HARD)
	enc.beginSermon("boss1", enc.SLOT[enc.HARD] * 5, {})
	wow.advance(2.5)
	return ns
end

describe("group sync over party chat", function()
	describe("the macros", function()
		-- The bare number is not a message, it is the last segment of a texture
		-- path: the receiver cannot read it, but it can format it into
		-- "...\UI-RaidTargetingIcon_%s" and draw the marker. A token like {rt2}
		-- only becomes an icon inside the chat frame's own render, and
		-- "UI-RaidTargetingIcon_{rt2}" is not a path -- the field test showed it on
		-- the timeline as literal text.
		it("presses the quadrant and sends the marker number, in that order", function()
			local ns = inGroup()

			-- North is Circle by default, which is raid target 2.
			assert.equals("/click SNAKESAYS_NORTH\n/p 2", ns.Comms.MacroFor("N"))
		end)

		-- Every line inside the window counts as a wave, because none can be read.
		-- A reset that announced itself would add one to everyone else's run.
		it("says nothing to the group when the board is cleared", function()
			local ns = inGroup()
			assert.equals("/click SNAKESAYS_RESET", ns.Comms.ResetMacro())
		end)

		it("follows this character's own marker assignment", function()
			local ns = inGroup()
			ns.SetAssignment("N", 5)   -- Moon

			assert.equals("/click SNAKESAYS_NORTH\n/p 5", ns.Comms.MacroFor("N"))
		end)

		it("uses raid chat in a raid", function()
			local ns = inGroup()
			wow.inRaid = true
			assert.equals("/click SNAKESAYS_NORTH\n/raid 2", ns.Comms.MacroFor("N"))
		end)

		-- Anything else on the line lands inside the texture path and breaks it.
		it("sends the number and nothing else", function()
			local ns = inGroup()
			for _, dir in ipairs(ns.QUADRANTS) do
				local sent = ns.Comms.MacroFor(dir):match("\n/%a+ (.*)$")
				assert.is_truthy(sent:match("^%d$"))
			end
		end)

		-- Square brackets are macro conditional syntax: `/p [SS] N` parses as `/p`
		-- with the clause `[SS]`, which is not a condition, so the macro sends
		-- nothing while the `/click` above it still records. Silently. Braces are
		-- not conditionals and are safe.
		it("carries nothing a macro would read as a conditional", function()
			local ns = inGroup()
			for _, dir in ipairs(ns.QUADRANTS) do
				assert.is_nil(ns.Comms.MacroFor(dir):find("[%[%]]"))
			end
		end)

		it("targets buttons that exist", function()
			inGroup()
			assert.is_truthy(_G.SNAKESAYS_NORTH)
			assert.is_truthy(_G.SNAKESAYS_RESET)
		end)
	end)

	-- The addon may write a macro; it may not press one. Writing spares the
	-- player the typing and leaves the press theirs, which is the half the
	-- client cares about.
	describe("/ss macro", function()
		it("makes all five, with the right bodies", function()
			local ns = inGroup()

			wow.slash("SNAKESAYS", "macro")

			assert.equals(5, #wow.macros)
			assert.equals("SS North", wow.macros[1].name)
			assert.equals("/click SNAKESAYS_NORTH\n/p 2", wow.macros[1].body)
			assert.is_true(wow.chatContains("SS North"))
		end)

		-- A file ID, not a path. The client takes a path without complaint and
		-- then ignores it, and a macro with no icon cannot be dragged to a bar --
		-- which is what the first cut shipped.
		it("gives each one its own marker icon, by file ID", function()
			local ns = inGroup()
			wow.slash("SNAKESAYS", "macro")

			assert.equals("number", type(wow.macros[1].icon))
			assert.equals(wow.fileIDs["Interface\\TargetingFrame\\UI-RaidTargetingIcon_2"],
				wow.macros[1].icon)
			assert.are_not.equals(wow.macros[1].icon, wow.macros[2].icon)
		end)

		it("still gives the reset macro something draggable", function()
			local ns = inGroup()
			wow.slash("SNAKESAYS", "macro")
			assert.equals("number", type(wow.macros[5].icon))
		end)

		it("updates them rather than making more", function()
			local ns = inGroup()

			wow.slash("SNAKESAYS", "macro")
			ns.SetAssignment("N", 5)
			wow.slash("SNAKESAYS", "macro")

			assert.equals(5, #wow.macros)
			assert.equals("/click SNAKESAYS_NORTH\n/p 5", wow.macros[1].body)
		end)

		it("refuses in combat rather than being refused", function()
			local ns = inGroup()
			_G.InCombatLockdown = function() return true end

			wow.slash("SNAKESAYS", "macro")

			assert.equals(0, #wow.macros)
			assert.is_true(wow.chatContains("not while you are in combat"))
		end)

		it("prints them to copy when there is no room", function()
			local ns = inGroup()
			wow.macroLimit = 0

			wow.slash("SNAKESAYS", "macro")

			assert.equals(0, #wow.macros)
			assert.is_true(wow.chatContains("no room left"))
			assert.is_true(wow.chatContains("/p 2"))
		end)
	end)

	-- The one thing that must never regress: a secret body must not throw, and
	-- must not be inspected on any path.
	describe("a secret message body", function()
		it("does not throw", function()
			local ns = roundStarts(inGroup())

			assert.has_no.errors(function() say("Caller-Realm", "N") end)
			assert.is_false(wow.chatContains("threw"))
		end)

		it("is kept and handed on without being read", function()
			local ns = roundStarts(inGroup())

			say("Caller-Realm", "N")
			say("Caller-Realm", "E")

			assert.equals(2, #ns.Comms.Heard())
			-- Still the value the client gave us, untouched.
			assert.is_true(wow.isSecret(ns.Comms.Heard()[1]))
		end)

		-- The whole point of sending a number: the addon cannot read it, but it
		-- can wrap it in a texture escape and let the client join the two. What
		-- lands on the timeline is the marker, not the digit.
		it("is drawn as a marker by being made into a texture path", function()
			local ns = roundStarts(inGroup())

			say("Caller-Realm", "2")

			local fs = ns.Timeline.HeardFontString(1)
			assert.is_truthy(fs)
			-- The mock keeps the format string and the arguments apart, exactly as
			-- the client does -- a secret is never concatenated into the result.
			assert.is_truthy(fs._format:find(
				"|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%s:", 1, true))
			assert.is_true(wow.isSecret(fs._formatArgs[1]))
			-- One placeholder, so the line cannot carry anything but the number.
			local _, specifiers = fs._format:gsub("%%s", "")
			assert.equals(1, specifiers)
		end)
	end)

	describe("the window a round opens", function()
		it("hears nothing outside an encounter", function()
			local ns = inGroup()

			say("Caller-Realm", "N")

			assert.equals(0, #ns.Comms.Heard())
			assert.is_false(ns.Comms.IsListening())
		end)

		-- The first cut opened the window when a round began, and dropped the whole
		-- run: the caller types while the channel is still proving itself.
		it("hears the caller before any round has been read", function()
			local ns = inGroup()
			enc.pull(ns, enc.HARD)

			assert.is_true(ns.Comms.IsListening())
			say("Caller-Realm", "N")
			assert.equals(1, #ns.Comms.Heard())
		end)

		it("hears while the round is being shown", function()
			local ns = roundStarts(inGroup())

			assert.is_true(ns.Comms.IsListening())
			say("Caller-Realm", "N")
			assert.equals(1, #ns.Comms.Heard())
		end)

		it("stops hearing when the pull ends", function()
			local ns = roundStarts(inGroup())
			say("Caller-Realm", "N")

			enc.endSermon("boss1", {})
			enc.kill(ns, enc.HARD)

			assert.is_false(ns.Comms.IsListening())
			say("Caller-Realm", "E")
			assert.equals(0, #ns.Comms.Heard())
		end)

		it("starts empty each round", function()
			local ns = roundStarts(inGroup())
			say("Caller-Realm", "2")
			assert.equals(1, #ns.Comms.Heard())

			-- The next round beginning, which is the one thing that ends a run.
			enc.endSermon("boss1", {})
			enc.beginSermon("boss1", enc.SLOT[enc.HARD] * 5, {})
			wow.advance(2.5)
			assert.equals(0, #ns.Comms.Heard())
		end)

		-- Clearing the board is not the same event as a round ending, and used to
		-- be wired to it. An unreadable channel spends two seconds proving itself
		-- and the caller types throughout, so on a follower most of the run lands
		-- inside that window -- and the reset that begins the round threw it away.
		it("keeps a run that arrived while the channel was proving itself", function()
			local ns = inGroup()
			enc.pull(ns, enc.HARD)

			enc.beginSermon("boss1", enc.SLOT[enc.HARD] * 5, {})
			say("Caller-Realm", "2")
			say("Caller-Realm", "4")
			wow.advance(2.5)   -- the round is only now believed

			assert.equals(2, #ns.Comms.Heard())
		end)

		it("is cleared by hand with /ss reset", function()
			local ns = roundStarts(inGroup())
			say("Caller-Realm", "2")

			wow.slash("SNAKESAYS", "reset")

			assert.equals(0, #ns.Comms.Heard())
		end)
	end)

	describe("who is calling", function()
		it("says a run is being called, once", function()
			local ns = roundStarts(inGroup())

			say("Caller-Realm", "N")
			say("Caller-Realm", "E")

			local said = 0
			for _, line in ipairs(wow.chat) do
				if line:find("being called in party chat", 1, true) then said = said + 1 end
			end
			assert.equals(1, said)
		end)

		-- CHAT_MSG_PARTY_LEADER is a separate event, so the client vouches for
		-- who leads without the addon having to work it out.
		it("lets the group leader take it over", function()
			local ns = roundStarts(inGroup())

			say("Caller-Realm", "N")
			say("Boss-Realm", "W", true)

			assert.equals(1, #ns.Comms.Heard())   -- started over on the leader
		end)

		it("ignores everyone else once the leader has called", function()
			local ns = roundStarts(inGroup())

			say("Boss-Realm", "N", true)
			say("Someone-Realm", "brb")

			assert.equals(1, #ns.Comms.Heard())
		end)

		-- Our own line cannot be recognised -- the sender is secret -- and does
		-- not need to be: the macro runs /click before /p, so this client is
		-- already driving its own board by the time the line comes back.
		it("is already driving by the time its own line returns", function()
			local ns = roundStarts(inGroup())

			ns.Seq.Press("N")
			say("anyone", "N")

			assert.equals(0, #ns.Comms.Heard())
		end)

		it("stops listening once this client fills its own board", function()
			local ns = roundStarts(inGroup())

			say("Caller-Realm", "N")
			ns.Seq.Press("W")
			say("Caller-Realm", "E")

			assert.is_true(ns.Comms.IsDriving())
			assert.equals(0, #ns.Comms.Heard())
		end)

		it("takes nothing when the player has switched sync off", function()
			local ns = roundStarts(inGroup({ groupSync = false }))
			say("Caller-Realm", "N")
			assert.equals(0, #ns.Comms.Heard())
		end)
	end)

	-- The round's own wave count is a rail: conversation during the showing half
	-- cannot stretch the run past what the boss is going to call.
	describe("the wave cap", function()
		it("never hears more waves than the round has", function()
			local ns = roundStarts(inGroup())

			for _ = 1, 10 do say("Caller-Realm", "N") end

			assert.equals(5, #ns.Comms.Heard())   -- a hard round one is five waves
		end)
	end)

	-- A follower presses nothing, so its board is empty for the whole pull. That
	-- used to leave it with no calling half at all: no replay, no fence on the
	-- call counter, and no idea the round had ended.
	describe("a follower's calling half", function()
		-- Round one on normal is three waves, called with everything about the
		-- casts unreadable -- which is what the client gives in this content.
		local function followerRound(ns, waves)
			local length = waves * enc.SLOT[enc.NORMAL]
			wow.startChannel("boss1", 1288103, length, { secret = true, nameless = true })
			wow.advance(2.5)                    -- the channel proving itself
			for _ = 1, waves do say("Caller-Realm", "2") end
			wow.advance(length - 2.5)
			wow.stopChannel("boss1")
		end

		local function callTimes(ns, n)
			for _ = 1, n do
				wow.startCast("boss1", 0, 3.34, { secret = true, nameless = true })
				wow.advance(3.55)
			end
		end

		-- The fence that keeps the boss' ordinary casts from being taken for calls
		-- counts the calls it is told about, and it used to be told only about the
		-- ones there was something to announce. A client with an empty board never
		-- reached it: a logged follower counted seven calls on a three-wave round
		-- and was still counting when the group wiped.
		it("stops counting calls once the round's waves are used up", function()
			local ns = inGroup()
			ns.SetDebug(true)
			enc.pull(ns, enc.NORMAL)
			wow.aurasBlocked = true

			followerRound(ns, 3)
			callTimes(ns, 9)

			assert.is_true(wow.chatContains("call 3 from"))
			assert.is_false(wow.chatContains("call 4 from"))
			assert.is_false(wow.chatContains("wave timing corrected"))
		end)

		-- And with nothing to replay at all -- nobody pressed, nobody called --
		-- which is the case that has no run to bound the counter for it. A call is
		-- still a call whether or not there was anything to say about it.
		it("stops counting calls even with nothing on the staff", function()
			local ns = inGroup({ groupSync = false })
			ns.SetDebug(true)
			enc.pull(ns, enc.NORMAL)
			wow.aurasBlocked = true

			followerRound(ns, 3)
			assert.equals(0, #ns.Comms.Heard())
			callTimes(ns, 9)

			assert.is_true(wow.chatContains("call 3 from"))
			assert.is_false(wow.chatContains("call 4 from"))
		end)

		-- The bar is all a follower gets, and all it can have: which quadrant each
		-- wave is arrives as a secret value. But the calls are real, so the bar can
		-- travel over the icons in time with them.
		it("runs the scanning bar over the icons it heard", function()
			local ns = inGroup()
			enc.pull(ns, enc.NORMAL)
			wow.aurasBlocked = true

			followerRound(ns, 3)
			assert.equals(3, #ns.Comms.Heard())

			callTimes(ns, 1)
			assert.is_true(ns.Detector.IsReplaying())
			assert.equals(1, ns.Detector.EchoIndex())

			callTimes(ns, 1)
			assert.equals(2, ns.Detector.EchoIndex())
		end)

		it("says nothing aloud about a run it cannot read", function()
			local ns = inGroup()
			enc.pull(ns, enc.NORMAL)
			wow.aurasBlocked = true

			followerRound(ns, 3)
			callTimes(ns, 3)

			assert.equals(0, #wow.spoken)
		end)

		-- The warning exists to tell a broken addon apart from a player who never
		-- pressed. A run that came over party chat is neither.
		it("does not warn that nothing was heard when something was", function()
			local ns = inGroup()
			enc.pull(ns, enc.NORMAL)
			wow.aurasBlocked = true

			followerRound(ns, 3)

			assert.is_false(wow.chatContains("No input detected"))
		end)
	end)

	describe("/ss status", function()
		it("reports the window and who is calling", function()
			local ns = roundStarts(inGroup())
			say("Caller-Realm", "N")

			wow.slash("SNAKESAYS", "status")

			assert.is_true(wow.chatContains("group chat:"))
			assert.is_true(wow.chatContains("waves heard=1"))
		end)
	end)

end)
