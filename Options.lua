local _, ns = ...

-- ===========================================================================
-- Options.lua  ·  SnakeSays' options page, hosted inside Blizzard's AddOns
-- settings panel (Esc > Options > AddOns > SnakeSays, or /ss).
--
-- Registered as a CANVAS category (Settings.RegisterCanvasLayoutCategory): the
-- whole page is our own frame, so everything lives in one place -- the marker
-- picker, the keybinds, and the show/lock toggles -- rather than a separate
-- window. Because it's a canvas with no registered proxy settings, the panel's
-- Defaults button has nothing of ours to touch.
--
--   · Marker per quadrant — click one of the eight marker icons (unique across
--     quadrants; Core.SetAssignment swaps on conflict).
--   · A keybind per quadrant + reset — click the key box and press a combo
--     (Esc cancels, right-click clears). Real game bindings via
--     SetBindingClick, bound to the named buttons Commands.lua creates.
--   · Show / Lock checkboxes.
--
-- Built at PLAYER_LOGIN (Settings is nil headless, so this never runs there).
-- ===========================================================================

local Options = {}
ns.Options = Options

local ICON = 24
local GAP  = 3
local KBW  = 110
local KBH  = 24
local LEFT = 16

local ICON_ROW_W = #ns.MARKERS * ICON + (#ns.MARKERS - 1) * GAP
local KB_X = LEFT + ICON_ROW_W + 14

local container           -- what Settings is given: the scrolling frame
local panel, categoryID   -- the page inside it, which is what everything anchors to
local iconButtons = {}    -- dir -> { markerId -> button }
local keybindButtons = {} -- command -> button
local styleButtons = {}   -- announce style key -> radio button
local showCB, lockCB, autoResetCB, timerSlider, timerValue, restrictCB, syncCB
local ttsCB, overlapCB, popupCB, subtitleCB, timelineCB, dbmCB
local volumeSlider, volumeValue
local voiceDropdown       -- nil on a client with no menu API (see buildVoicePicker)
local dbmHint             -- says whether DBM can actually answer right now
local scaleSliders = {}   -- the three window-size sliders, refreshed together
local capture             -- fullscreen key-capture overlay (created on demand)
local pendingButton       -- the key box whose binding we're setting

-- The five bindable actions (must match the button names Commands.lua creates).
local BIND_COMMAND = {
	N = "SNAKESAYS_NORTH", E = "SNAKESAYS_EAST",
	S = "SNAKESAYS_SOUTH", W = "SNAKESAYS_WEST",
}
local RESET_COMMAND = "SNAKESAYS_RESET"
local UNDO_COMMAND  = "SNAKESAYS_UNDO"

local MODIFIER_KEYS = {
	LSHIFT = true, RSHIFT = true, LCTRL = true, RCTRL = true, LALT = true, RALT = true,
}

local function hideTooltip() GameTooltip:Hide() end

-- ---------------------------------------------------------------------------
-- Marker picker
-- ---------------------------------------------------------------------------

local function buildIconButton(marker, dir)
	local b = CreateFrame("Button", nil, panel)
	b:SetSize(ICON, ICON)

	local sel = b:CreateTexture(nil, "BACKGROUND")
	sel:SetPoint("TOPLEFT", -2, 2)
	sel:SetPoint("BOTTOMRIGHT", 2, -2)
	sel:SetColorTexture(1, 0.82, 0.2, 1)   -- gold outline behind the selected marker
	sel:Hide()
	b.sel = sel

	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetAllPoints(b)
	icon:SetTexture(ns.MARKER_TEXTURE)
	icon:SetTexCoord(unpack(marker.coords))

	b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
	b:SetScript("OnClick", function()
		ns.SetAssignment(dir, marker.id)
		Options.Refresh()
	end)
	b:SetScript("OnEnter", function()
		GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
		GameTooltip:SetText(marker.name)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", hideTooltip)
	return b
end

-- ---------------------------------------------------------------------------
-- Inline keybinding
--
-- Capturing keys from a small button inside the Settings panel doesn't work --
-- the panel sits above it in the keyboard stack and eats the press. So while
-- binding we raise a fullscreen overlay at the top of the strata; it reliably
-- captures the next key (or Esc / a click to cancel), sets the binding, hides.
-- ---------------------------------------------------------------------------

local function commandLabel(command)
	return ns.BINDING_LABEL[command] or command
end

-- SetBindingClick(key, name, "LeftButton") is stored as the action string
-- "CLICK name:LeftButton" — GetBindingKey/GetBindingText need that same
-- string to look the binding back up.
local function clickAction(command)
	return "CLICK " .. command .. ":LeftButton"
end

local function refreshKeybinds()
	for command, btn in pairs(keybindButtons) do
		local key = GetBindingKey(clickAction(command))
		btn:SetText(key and GetBindingText(key) or "Unbound")
	end
end

-- Replace this command's binding with `chord` (or clear it when chord is nil),
-- then persist. We keep one key per action: clear any existing keys first.
local function applyBinding(command, chord)
	local k1, k2 = GetBindingKey(clickAction(command))
	if k1 then SetBinding(k1) end
	if k2 then SetBinding(k2) end
	if chord then SetBindingClick(chord, command, "LeftButton") end
	SaveBindings(GetCurrentBindingSet())
end

local function stopListening()
	pendingButton = nil
	if capture then capture:Hide() end
	refreshKeybinds()
end

local function ensureCapture()
	if capture then return end
	capture = CreateFrame("Frame", nil, UIParent)
	capture:SetAllPoints(UIParent)
	capture:SetFrameStrata("TOOLTIP")     -- above the Settings panel
	capture:EnableMouse(true)
	capture:EnableKeyboard(true)
	capture:SetPropagateKeyboardInput(false)
	capture:Hide()

	local bg = capture:CreateTexture(nil, "BACKGROUND")
	bg:SetAllPoints(capture)
	bg:SetColorTexture(0, 0, 0, 0.6)

	local text = capture:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
	text:SetPoint("CENTER")
	capture.text = text

	capture:SetScript("OnKeyDown", function(_, key)
		if key == "ESCAPE" then stopListening(); return end
		if MODIFIER_KEYS[key] then return end   -- wait for the non-modifier key
		local chord = ""
		if IsAltKeyDown() then chord = "ALT-" end
		if IsControlKeyDown() then chord = "CTRL-" .. chord end
		if IsShiftKeyDown() then chord = "SHIFT-" .. chord end
		if pendingButton then applyBinding(pendingButton.command, chord .. key) end
		stopListening()
	end)
	capture:SetScript("OnMouseDown", stopListening)   -- click anywhere to cancel
end

local function startListening(btn)
	ensureCapture()
	pendingButton = btn
	capture.text:SetText("Press a key to bind:\n|cffffd200" .. commandLabel(btn.command)
		.. "|r\n\n(Esc or click to cancel)")
	capture:Show()
	capture:EnableKeyboard(true)
	capture:SetPropagateKeyboardInput(false)
end

local function buildKeybindButton(command, x, y)
	local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
	b:SetSize(KBW, KBH)
	b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
	b.command = command
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:SetScript("OnClick", function(self, mouseButton)
		if mouseButton == "RightButton" then
			applyBinding(self.command, nil)
			refreshKeybinds()
		else
			startListening(self)
		end
	end)
	keybindButtons[command] = b
	return b
end

-- ---------------------------------------------------------------------------
-- Checkboxes
-- ---------------------------------------------------------------------------

local function buildCheckbox(label, y, getter, setter, x)
	local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", panel, "TOPLEFT", x or LEFT, y)
	cb:SetScript("OnClick", function(self)
		setter(self:GetChecked())
		Options.Refresh()
	end)
	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	text:SetText(label)
	cb.getter = getter
	return cb
end

-- ---------------------------------------------------------------------------
-- Window sizes
--
-- One slider per window. They read as percentages because that is what the
-- player is judging ("a bit bigger"), while the stored value is the frame scale
-- the game wants.
-- ---------------------------------------------------------------------------

local function buildScaleSlider(label, x, y, getter, setter)
	local slider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
	slider:SetWidth(160)
	slider:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
	slider:SetMinMaxValues(ns.SCALE_MIN, ns.SCALE_MAX)
	slider:SetValueStep(0.05)
	slider:SetObeyStepOnDrag(true)
	if slider.Low then slider.Low:SetText(math.floor(ns.SCALE_MIN * 100) .. "%") end
	if slider.High then slider.High:SetText(math.floor(ns.SCALE_MAX * 100) .. "%") end
	if slider.Text then slider.Text:SetText(label) end

	local value = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	value:SetPoint("LEFT", slider, "RIGHT", 14, 0)

	slider:SetScript("OnValueChanged", function(_, v)
		local percent = math.floor(v * 20 + 0.5) * 5   -- snap to the 5% step
		setter(percent / 100)
		value:SetText(percent .. "%")
	end)

	slider.getter = getter
	slider.valueText = value
	scaleSliders[#scaleSliders + 1] = slider
	return slider
end

-- ---------------------------------------------------------------------------
-- Replay announcements
--
-- Their own column on the right: they all concern what happens during the
-- silent repeat, and the left column is already full of recording settings.
-- ---------------------------------------------------------------------------

-- Where the second column starts, and how wide anything in it may be.
--
-- Both are measured against the narrowest canvas the Settings panel hands out
-- rather than against a comfortable one. A screenshot from the field had the
-- right column running off the edge -- "Use Deadly Boss Mods' voice inste", the
-- timeline hint losing its last word -- because the column was placed where
-- there was room on a tall screen and the widths were never checked against the
-- panel at all. The left column's key boxes end at 353, so this clears them.
local ANNOUNCE_X = 400
local ANNOUNCE_W = 240      -- widest an indented hint may be and still fit

-- What the voice picker shows when nothing has been picked. The name of the
-- voice the addon settled on is part of it, because "Automatic" on its own
-- cannot be checked against what is coming out of the speakers -- which is the
-- one thing a player with a wrong-sounding voice needs to do.
local function automaticVoiceLabel()
	local name = ns.Announce.VoiceName(ns.Announce.AutoVoice())
	if not name then return "Automatic" end
	return ("Automatic (%s)"):format(name)
end

-- The list of installed text-to-speech voices, as a dropdown.
--
-- Built through the client's own menu API and not by hand: the number of voices
-- is whatever the operating system has, which on macOS is dozens, and anything
-- laid out in this panel would have to scroll. Guarded, because this template
-- arrived in 11.0 and the addon still loads on clients without it -- there, the
-- automatic choice stands and the row says so.
-- The dropdown's styled template, current name first.
--
-- The name matters and is not guessable. "WowStyle1DropdownTemplate" is what the
-- client ships; an earlier build of this page asked for
-- "WowStyleDropdownTemplate", which is one character out, throws inside
-- CreateFrame, and left the page announcing that the client had no picker -- on
-- a client with a picker and two voices installed. The second name is kept for
-- the older clients the .toc still covers.
--
-- Every entry has to be a *styled* template. An untemplated DropdownButton
-- carries the same mixin and would work, but it has no artwork and no text, so
-- falling back to one trades a missing picker for an invisible one.
local DROPDOWN_TEMPLATES = { "WowStyle1DropdownTemplate", "WowStyleDropdownTemplate" }

local function createDropdown(parent)
	for _, template in ipairs(DROPDOWN_TEMPLATES) do
		local ok, dropdown = pcall(CreateFrame, "DropdownButton", nil, parent, template)
		if ok and type(dropdown) == "table" and type(dropdown.SetupMenu) == "function" then
			return dropdown
		end
	end
	return nil
end

local function buildVoicePicker(x, y)
	local label = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
	label:SetText("Voice:")

	local dropdown = createDropdown(panel)
	if not dropdown then
		label:SetText("Voice: chosen automatically (this client has no picker)")
		return
	end

	dropdown:SetSize(170, 24)
	dropdown:SetPoint("LEFT", label, "RIGHT", 8, 0)

	-- The generator runs each time the menu opens, so a voice pack installed
	-- mid-session turns up without a reload, and the ticked entry is always read
	-- from the setting rather than from anything cached here.
	dropdown:SetupMenu(function(_, rootDescription)
		rootDescription:CreateRadio(automaticVoiceLabel(),
			function() return ns.GetTTSVoice() == nil end,
			function() ns.SetTTSVoice(nil); Options.Refresh() end)

		for _, voice in ipairs(ns.Announce.Voices()) do
			local id = voice.voiceID
			rootDescription:CreateRadio(tostring(voice.name),
				function() return ns.GetTTSVoice() == id end,
				function() ns.SetTTSVoice(id); Options.Refresh() end)
		end
	end)

	voiceDropdown = dropdown
end

local function buildAnnounceColumn()
	local y = -62

	local heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	heading:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X, y)
	heading:SetText("During the replay")

	y = y - 22
	ttsCB = buildCheckbox("Speak the safe quadrant", y,
		ns.GetTTSEnabled, ns.SetTTSEnabled, ANNOUNCE_X)

	-- Further down than a row of text would need. The dropdown is anchored by its
	-- middle to the side of the "Voice:" label, so it stands 6px taller than the
	-- label's own top -- at a plain 28 it reached back up into the checkbox above.
	y = y - 40
	buildVoicePicker(ANNOUNCE_X + 24, y)

	y = y - 34
	dbmCB = buildCheckbox("Use Deadly Boss Mods' voice", y,
		ns.GetDBMVoice, ns.SetDBMVoice, ANNOUNCE_X + 24)

	y = y - 22
	dbmHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	dbmHint:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 48, y)
	dbmHint:SetWidth(ANNOUNCE_W - 24)
	dbmHint:SetJustifyH("LEFT")

	-- What the voice and the popup call things. Two radios rather than a
	-- checkbox: "say marks instead of colours" is a choice, not an on/off.
	y = y - 34
	local styleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	styleLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 24, y)
	styleLabel:SetText("Call them by:")

	y = y - 18
	local styles = { { key = "color", label = "Colour" }, { key = "marker", label = "Marker" } }
	local styleX = ANNOUNCE_X + 24
	for _, style in ipairs(styles) do
		local b = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
		b:SetPoint("TOPLEFT", panel, "TOPLEFT", styleX, y)
		b:SetScript("OnClick", function()
			ns.SetAnnounceStyle(style.key)
			Options.Refresh()
		end)
		local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		text:SetPoint("LEFT", b, "RIGHT", 4, 0)
		text:SetText(style.label)
		styleButtons[style.key] = b
		styleX = styleX + 100
	end

	y = y - 30
	local volumeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	volumeLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 24, y)
	volumeLabel:SetText("Voice volume:")

	y = y - 26
	volumeSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
	volumeSlider:SetWidth(160)
	volumeSlider:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 28, y)
	volumeSlider:SetMinMaxValues(0, 100)
	volumeSlider:SetValueStep(5)
	volumeSlider:SetObeyStepOnDrag(true)
	if volumeSlider.Low then volumeSlider.Low:SetText("0") end
	if volumeSlider.High then volumeSlider.High:SetText("100") end
	if volumeSlider.Text then volumeSlider.Text:SetText("") end

	volumeValue = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	volumeValue:SetPoint("LEFT", volumeSlider, "RIGHT", 14, 0)

	volumeSlider:SetScript("OnValueChanged", function(_, value)
		value = math.floor(value + 0.5)
		ns.SetTTSVolume(value)
		volumeValue:SetText(tostring(value))
	end)

	y = y - 26
	overlapCB = buildCheckbox("Let calls overlap each other", y,
		ns.GetTTSOverlap, ns.SetTTSOverlap, ANNOUNCE_X)
	y = y - 24
	popupCB = buildCheckbox("Show the call on screen", y,
		ns.GetPopupEnabled, ns.SetPopupEnabled, ANNOUNCE_X)
	y = y - 24
	subtitleCB = buildCheckbox("Include the next-up line", y,
		ns.GetPopupSubtitle, ns.SetPopupSubtitle, ANNOUNCE_X + 24)

	y = y - 26
	timelineCB = buildCheckbox("Show the timeline", y,
		ns.GetTimelineEnabled, ns.SetTimelineEnabled, ANNOUNCE_X)

	y = y - 22
	local timelineHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	timelineHint:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 24, y)
	timelineHint:SetText("The run written left to right, with a bar that reaches each "
		.. "marker as its wave lands. Unlock the HUD to drag all three windows.")
	timelineHint:SetWidth(ANNOUNCE_W)
	timelineHint:SetJustifyH("LEFT")

	y = y - 56
	local sizeHeading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	sizeHeading:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X, y)
	sizeHeading:SetText("Window size")

	y = y - 30
	buildScaleSlider("Board", ANNOUNCE_X + 28, y, ns.GetHUDScale, ns.SetHUDScale)
	y = y - 38
	buildScaleSlider("On-screen call", ANNOUNCE_X + 28, y, ns.GetPopupScale, ns.SetPopupScale)
	y = y - 38
	buildScaleSlider("Timeline", ANNOUNCE_X + 28, y, ns.GetTimelineScale, ns.SetTimelineScale)

	return y - 30      -- the bottom of this column, for sizing the scrolling page
end

-- ---------------------------------------------------------------------------
-- Build the canvas page
-- ---------------------------------------------------------------------------

-- The frame the Settings panel is handed, with the page proper inside it.
--
-- Two frames rather than one because a canvas category does not scroll, and this
-- page is taller than the canvas on a good many screens: the panel's height
-- follows the window, which follows the resolution and the UI scale, and the
-- bottom rows were simply unreachable when it came up short. Reported from the
-- field as "options are going off screen".
--
-- Scrolled by the wheel rather than by a scrollbar widget: the bar templates
-- have been renamed twice across expansions and getting one wrong is what broke
-- the voice picker, whereas SetVerticalScroll has been the same call for years.
-- The footer says so when there is anything below the fold, since a scrolling
-- area with nothing sticking out is invisible.
local function buildScrollingCanvas()
	container = CreateFrame("Frame")
	container:Hide()

	local scroll = CreateFrame("ScrollFrame", nil, container)
	scroll:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
	scroll:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)

	-- Started at the width the page is laid out for rather than at nothing. A
	-- scroll child with no width draws nothing, and the canvas has no size of its
	-- own until the Settings panel gets around to anchoring it -- which may be
	-- after the first OnShow. Better to be briefly the wrong width than briefly
	-- blank; SyncToCanvas corrects it the moment there is a real width to read.
	panel = CreateFrame("Frame", nil, scroll)
	panel:SetSize(680, 1)
	scroll:SetScrollChild(panel)

	local footer = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	footer:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -8, 6)
	footer:SetText("scroll for more")
	footer:Hide()

	local function scrollLimit()
		return math.max(0, (panel:GetHeight() or 0) - (scroll:GetHeight() or 0))
	end

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local at = self:GetVerticalScroll() - delta * 40
		self:SetVerticalScroll(math.max(0, math.min(scrollLimit(), at)))
	end)

	-- The canvas has no size until the Settings panel has laid it out, so this
	-- has to be asked again every time the page is shown rather than once here.
	container.SyncToCanvas = function()
		local width = scroll:GetWidth() or 0
		if width > 0 then panel:SetWidth(width) end
		footer:SetShown(scrollLimit() > 0)
		scroll:SetVerticalScroll(math.min(scroll:GetVerticalScroll(), scrollLimit()))
	end
	-- On the scroll frame rather than the container: it is the one whose height
	-- decides whether anything is below the fold, and it is sized last.
	scroll:SetScript("OnSizeChanged", container.SyncToCanvas)

	return container
end

local function buildPanel()
	buildScrollingCanvas()

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", LEFT, -16)
	title:SetText("SnakeSays")

	local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", LEFT, -38)
	hint:SetText("Click a marker to assign · click a key box to bind (right-click clears) · "
		.. "right-click the board to take a press back")
	hint:SetWidth(ANNOUNCE_X - LEFT - 14)
	hint:SetJustifyH("LEFT")

	local howLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	howLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT, -74)
	howLabel:SetText("Press the quadrants on the board or by keybind as the waves are shown; "
		.. "SnakeSays calls them back when the boss repeats them.")
	howLabel:SetWidth(ANNOUNCE_X - LEFT - 14)
	howLabel:SetJustifyH("LEFT")

	local y = -128
	for _, dir in ipairs(ns.QUADRANTS) do
		local label = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		label:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT, y)
		label:SetText(ns.QUADRANT_NAME[dir])

		local row = {}
		for i, marker in ipairs(ns.MARKERS) do
			local b = buildIconButton(marker, dir)
			b:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT + (i - 1) * (ICON + GAP), y - 20)
			row[marker.id] = b
		end
		iconButtons[dir] = row

		buildKeybindButton(BIND_COMMAND[dir], KB_X, y - 20)
		y = y - 48
	end

	-- The two board-wide actions: label on the left, key box aligned with the
	-- quadrant ones above. Undo has a key of its own because the right-click on
	-- the board only helps a player whose hand is on the board -- somebody playing
	-- this on keybinds has no cursor there to right-click with.
	for _, action in ipairs({
		{ command = RESET_COMMAND, label = "Reset sequence" },
		{ command = UNDO_COMMAND,  label = "Take the last press back" },
	}) do
		local btn = buildKeybindButton(action.command, KB_X, y - 2)
		local lbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		lbl:SetPoint("LEFT", btn, "LEFT", -(KB_X - LEFT), 0)
		lbl:SetText(action.label)
		y = y - 28
	end
	y = y - 10

	showCB = buildCheckbox("Show HUD", y, ns.IsShown, ns.SetShown)
	lockCB = buildCheckbox("Lock HUD (uncheck to drag it)", y - 26, ns.IsLocked, ns.SetLocked)
	autoResetCB = buildCheckbox("Auto-reset the sequence after the first press", y - 52,
		ns.GetAutoReset, ns.SetAutoReset)

	-- Auto-reset delay: label + a 30-60s slider with a live value readout.
	local timerLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	timerLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT + 24, y - 80)
	timerLabel:SetText("Auto-reset after (seconds):")

	timerSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
	timerSlider:SetWidth(200)
	timerSlider:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT + 28, y - 106)
	timerSlider:SetMinMaxValues(30, 60)
	timerSlider:SetValueStep(1)
	timerSlider:SetObeyStepOnDrag(true)
	if timerSlider.Low then timerSlider.Low:SetText("30") end
	if timerSlider.High then timerSlider.High:SetText("60") end
	if timerSlider.Text then timerSlider.Text:SetText("") end

	timerValue = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	timerValue:SetPoint("LEFT", timerSlider, "RIGHT", 14, 0)

	timerSlider:SetScript("OnValueChanged", function(_, value)
		value = math.floor(value + 0.5)
		ns.SetAutoResetTime(value)
		timerValue:SetText(value .. "s")
	end)

	restrictCB = buildCheckbox("Only show the HUD inside the Delve Nemesis map", y - 142,
		ns.GetRestrictToMap, ns.SetRestrictToMap)

	syncCB = buildCheckbox("Share the sequence with my group", y - 168,
		ns.GetGroupSync, ns.SetGroupSync)

	local syncHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	syncHint:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT + 24, y - 190)
	syncHint:SetText("Read the caller's board off party chat; your own presses always win "
		.. "on it. /ss macro makes what the caller sends.")
	syncHint:SetWidth(ANNOUNCE_X - LEFT - 38)
	syncHint:SetJustifyH("LEFT")

	local announceBottom = buildAnnounceColumn()

	-- However tall the two columns came out. Measured rather than written down,
	-- so a row added to either one scrolls instead of falling off the end.
	panel:SetHeight(math.abs(math.min(y - 230, announceBottom)))

	container:SetScript("OnShow", function()
		container.SyncToCanvas()
		Options.Refresh()
	end)
	container:SetScript("OnHide", stopListening)
end

-- Reflect current state: assigned markers, keybinds, checkboxes.
function Options.Refresh()
	if not panel then return end
	for _, dir in ipairs(ns.QUADRANTS) do
		local assigned = ns.GetAssignment(dir)
		for id, b in pairs(iconButtons[dir]) do
			b.sel:SetShown(id == assigned)
		end
	end
	refreshKeybinds()
	showCB:SetChecked(showCB.getter())
	lockCB:SetChecked(lockCB.getter())
	autoResetCB:SetChecked(autoResetCB.getter())
	local secs = ns.GetAutoResetTime()
	if secs < 30 then secs = 30 elseif secs > 60 then secs = 60 end
	timerSlider:SetValue(secs)            -- fires OnValueChanged -> updates label + db
	timerValue:SetText(secs .. "s")       -- explicit, in case the value didn't change
	restrictCB:SetChecked(restrictCB.getter())
	syncCB:SetChecked(syncCB.getter())

	local style = ns.GetAnnounceStyle()
	for key, b in pairs(styleButtons) do
		b:SetChecked(key == style)
	end

	local speaking = ns.GetTTSEnabled()
	ttsCB:SetChecked(speaking)
	overlapCB:SetChecked(overlapCB.getter())
	popupCB:SetChecked(popupCB.getter())
	subtitleCB:SetChecked(subtitleCB.getter())
	timelineCB:SetChecked(timelineCB.getter())

	local volume = ns.GetTTSVolume()
	volumeSlider:SetValue(volume)
	volumeValue:SetText(tostring(volume))

	for _, slider in ipairs(scaleSliders) do
		local scale = slider.getter()
		slider:SetValue(scale)                                     -- fires OnValueChanged
		slider.valueText:SetText(math.floor(scale * 100 + 0.5) .. "%")
	end

	-- Which voice is doing the calling, and whether the one that was asked for can
	-- answer. Both are read fresh: a stored voice can vanish with a language pack,
	-- and DBM's voice pack can be enabled or disabled without this addon hearing
	-- about it.
	local usingDBM = ns.GetDBMVoice() and ns.Announce.DBMVoiceAvailable()
	dbmCB:SetChecked(dbmCB.getter())
	if ns.Announce.DBMVoiceAvailable() then
		dbmHint:SetText("Plays DBM's own recorded call (\"move to square\"). It always names "
			.. "the marker, whatever the style below says.")
	else
		dbmHint:SetText("|cffffd200Nothing to play right now|r - DBM is not loaded, or has no "
			.. "voice pack chosen in its own options. Falls back to the voice above.")
	end

	if voiceDropdown then
		if voiceDropdown.SetDefaultText then
			voiceDropdown:SetDefaultText(automaticVoiceLabel())
		end
		if voiceDropdown.GenerateMenu then voiceDropdown:GenerateMenu() end
		voiceDropdown:SetEnabled(speaking and not usingDBM)
	end

	-- The voice controls only mean anything while the voice is on, and the
	-- next-up line only while the popup is drawn at all. Volume and overlap are
	-- the client's text-to-speech settings, so DBM doing the talking takes them
	-- out of play too -- it plays a sound file on its own channel at its own level.
	volumeSlider:SetEnabled(speaking and not usingDBM)
	overlapCB:SetEnabled(speaking and not usingDBM)
	dbmCB:SetEnabled(speaking)
	subtitleCB:SetEnabled(ns.GetPopupEnabled())
end

-- Whether the voice picker is really there. A test seam, and the thing the
-- broken template name silently turned off: everything downstream of it is
-- guarded, so the page carried on looking fine with the picker missing.
function Options.HasVoicePicker() return voiceDropdown ~= nil end

function Options.Open()
	if Settings and categoryID then
		Settings.OpenToCategory(categoryID)
	end
end

local function register()
	if not Settings or categoryID then return end
	buildPanel()
	local category = Settings.RegisterCanvasLayoutCategory(container, "SnakeSays")
	Settings.RegisterAddOnCategory(category)
	categoryID = category:GetID()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
	boot:UnregisterEvent("PLAYER_LOGIN")
	register()
end)
