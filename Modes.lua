local _, ns = ...

-- ===========================================================================
-- Modes.lua  ·  the first-run mode prompt.
--
-- The addon does nothing on its own until the player has picked how it should
-- behave. The first time they walk into the delve without a stored choice, this
-- asks once and remembers the answer forever (the options page and `/ss mode`
-- can change it later).
--
-- Deliberately once *per session*: if the player dismisses the popup we don't
-- nag them again every time they re-zone, and with no mode stored the addon
-- simply stays passive, exactly as it did before any of this existed.
-- ===========================================================================

local Modes = {}
ns.Modes = Modes

local POPUP = "SNAKESAYS_CHOOSE_MODE"
local askedThisSession = false

local function choose(key)
	if not ns.SetMode(key) then return end
	ns.Print(("mode set to |cffffd200%s|r."):format(ns.MODE_NAME[key]))
	-- Picking an automatic mode is only meaningful if position actually works;
	-- Position.Verify warns and drops back to manual if it doesn't.
	ns.Position.Verify()
end

-- Buttons are laid out in ns.MODES order, so the popup and the options page
-- always present the three the same way round.
local function buildPopup()
	if StaticPopupDialogs[POPUP] then return end
	StaticPopupDialogs[POPUP] = {
		text = "How should SnakeSays record the sequence?\n\n"
			.. "|cffffd200Automatic|r - hands off, it watches and calls everything.\n"
			.. "|cffffd200Semi|r - you press a key at each wave, it reads your quadrant.\n"
			.. "|cffffd200Manual|r - you press the quadrant yourself.\n\n"
			.. "You can change this any time with /ss mode.",
		button1 = ns.MODES[1].name,
		button2 = ns.MODES[2].name,
		button3 = ns.MODES[3].name,
		OnButton1 = function() choose(ns.MODES[1].key) end,
		OnButton2 = function() choose(ns.MODES[2].key) end,
		OnButton3 = function() choose(ns.MODES[3].key) end,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,   -- avoids tainting Blizzard's own popup slots
	}
end

-- Ask now, if the player has never answered and we're somewhere it matters.
function Modes.PromptIfNeeded()
	if askedThisSession or ns.IsModeChosen() then return end
	if not ns.InDelve() then return end
	askedThisSession = true
	buildPopup()
	StaticPopup_Show(POPUP)
end

-- Test seam: forget that we already asked this session.
function Modes.ResetPrompt()
	askedThisSession = false
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_ENTERING_WORLD")
boot:RegisterEvent("ZONE_CHANGED_NEW_AREA")
boot:SetScript("OnEvent", function()
	Modes.PromptIfNeeded()
end)
