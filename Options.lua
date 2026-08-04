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

local panel, categoryID
local iconButtons = {}    -- dir -> { markerId -> button }
local keybindButtons = {} -- command -> button
local modeButtons = {}    -- mode key -> radio button
local styleButtons = {}   -- announce style key -> radio button
local arrivalButtons = {} -- arrival cue key -> radio button
local showCB, lockCB, autoResetCB, timerSlider, timerValue, restrictCB, blockInputCB
local ttsCB, overlapCB, popupCB, subtitleCB, radarCB, blinkCB
local volumeSlider, volumeValue
local scaleSliders = {}   -- the three window-size sliders, refreshed together
local capture             -- fullscreen key-capture overlay (created on demand)
local pendingButton       -- the key box whose binding we're setting

-- The five bindable actions (must match the button names Commands.lua creates).
local BIND_COMMAND = {
	N = "SNAKESAYS_NORTH", E = "SNAKESAYS_EAST",
	S = "SNAKESAYS_SOUTH", W = "SNAKESAYS_WEST",
}
local RESET_COMMAND = "SNAKESAYS_RESET"
local CAPTURE_COMMAND = "SNAKESAYS_CAPTURE"

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
-- Mode picker
--
-- Three radio buttons rather than a dropdown: the choice drives how the whole
-- addon behaves, so it should be readable at a glance without opening anything.
-- ---------------------------------------------------------------------------

local function buildModeRow(mode, x, y)
	local b = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
	b:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
	b:SetScript("OnClick", function()
		ns.SetMode(mode.key)
		Options.Refresh()
	end)

	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", b, "RIGHT", 4, 0)
	text:SetText(mode.name)

	b:SetScript("OnEnter", function()
		GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
		GameTooltip:SetText(mode.name)
		GameTooltip:AddLine(mode.desc, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	b:SetScript("OnLeave", hideTooltip)

	modeButtons[mode.key] = b
	return b, text
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
	slider:SetWidth(180)
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

local ANNOUNCE_X = 430

local function buildAnnounceColumn()
	local heading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	heading:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X, -62)
	heading:SetText("During the replay")

	ttsCB = buildCheckbox("Speak the safe quadrant", -84,
		ns.GetTTSEnabled, ns.SetTTSEnabled, ANNOUNCE_X)

	-- What the voice and the popup call things. Two radios rather than a
	-- checkbox: "say marks instead of colours" is a choice, not an on/off.
	local styleLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	styleLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 24, -110)
	styleLabel:SetText("Call them by:")

	local styles = { { key = "color", label = "Colour" }, { key = "marker", label = "Marker" } }
	local styleX = ANNOUNCE_X + 24
	for _, style in ipairs(styles) do
		local b = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
		b:SetPoint("TOPLEFT", panel, "TOPLEFT", styleX, -128)
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

	local volumeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	volumeLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 24, -158)
	volumeLabel:SetText("Voice volume:")

	volumeSlider = CreateFrame("Slider", nil, panel, "OptionsSliderTemplate")
	volumeSlider:SetWidth(180)
	volumeSlider:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 28, -184)
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

	overlapCB = buildCheckbox("Let calls overlap each other", -208,
		ns.GetTTSOverlap, ns.SetTTSOverlap, ANNOUNCE_X)
	-- Three radios rather than a checkbox: "make a noise" and "tell me out loud"
	-- are different wants, and neither is a louder version of the other.
	--
	-- Packed by measured width rather than on a fixed pitch. This column is only
	-- so wide, and three labels of the length these have on a hundred-pixel
	-- pitch put the last one off the edge of the panel -- which is not something
	-- a constant can be tuned to avoid at every font size.
	local arrivalLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	arrivalLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 24, -234)
	arrivalLabel:SetText("When reach the safe slice:")

	local RADIO_W, TEXT_GAP, GROUP_GAP = 20, 4, 14
	local arrivalX = ANNOUNCE_X
	for _, cue in ipairs(ns.ARRIVAL_CUES) do
		local b = CreateFrame("CheckButton", nil, panel, "UIRadioButtonTemplate")
		b:SetPoint("TOPLEFT", panel, "TOPLEFT", arrivalX, -252)
		b:SetScript("OnClick", function()
			ns.SetArrivalCue(cue.key)
			Options.Refresh()
		end)
		local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		text:SetPoint("LEFT", b, "RIGHT", TEXT_GAP, 0)
		text:SetText(cue.name)
		arrivalButtons[cue.key] = b
		arrivalX = arrivalX + RADIO_W + TEXT_GAP + (text:GetStringWidth() or 60) + GROUP_GAP
	end
	popupCB = buildCheckbox("Show the call on screen", -278,
		ns.GetPopupEnabled, ns.SetPopupEnabled, ANNOUNCE_X)
	subtitleCB = buildCheckbox("Include the next-up line", -304,
		ns.GetPopupSubtitle, ns.SetPopupSubtitle, ANNOUNCE_X + 24)

	radarCB = buildCheckbox("Show the rotating position radar", -330,
		ns.GetRadarEnabled, ns.SetRadarEnabled, ANNOUNCE_X)
	blinkCB = buildCheckbox("Blink the safe slice until you reach it", -356,
		ns.GetTargetBlink, ns.SetTargetBlink, ANNOUNCE_X + 24)

	local moveHint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	moveHint:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X + 24, -382)
	moveHint:SetText("Unlock the HUD to drag the call and the radar.")

	local sizeHeading = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	sizeHeading:SetPoint("TOPLEFT", panel, "TOPLEFT", ANNOUNCE_X, -406)
	sizeHeading:SetText("Window size")

	buildScaleSlider("Board", ANNOUNCE_X + 28, -436, ns.GetHUDScale, ns.SetHUDScale)
	buildScaleSlider("Position radar", ANNOUNCE_X + 28, -474, ns.GetRadarScale, ns.SetRadarScale)
	buildScaleSlider("On-screen call", ANNOUNCE_X + 28, -512, ns.GetPopupScale, ns.SetPopupScale)
end

-- ---------------------------------------------------------------------------
-- Build the canvas page
-- ---------------------------------------------------------------------------

local function buildPanel()
	panel = CreateFrame("Frame")
	panel:Hide()

	local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", LEFT, -16)
	title:SetText("SnakeSays")

	local hint = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", LEFT, -38)
	hint:SetText("Click a marker to assign · click a key box to bind (right-click clears)")

	local modeLabel = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	modeLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT, -62)
	modeLabel:SetText("Recording mode")

	local modeX = LEFT
	for _, mode in ipairs(ns.MODES) do
		buildModeRow(mode, modeX, -84)
		modeX = modeX + 26 + #mode.name * 7 + 18
	end

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
		y = y - 52
	end

	-- Capture and reset rows: labels on the left, key boxes aligned with the
	-- quadrant ones above.
	local captureBtn = buildKeybindButton(CAPTURE_COMMAND, KB_X, y - 2)
	local captureLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	captureLbl:SetPoint("LEFT", captureBtn, "LEFT", -(KB_X - LEFT), 0)
	captureLbl:SetText("Quadrant detection")
	y = y - 30

	local resetBtn = buildKeybindButton(RESET_COMMAND, KB_X, y - 2)
	local resetLbl = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	resetLbl:SetPoint("LEFT", resetBtn, "LEFT", -(KB_X - LEFT), 0)
	resetLbl:SetText("Reset sequence")
	y = y - 42

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

	blockInputCB = buildCheckbox("Ignore board clicks and quadrant keybinds", y - 168,
		ns.GetBlockManualInput, ns.SetBlockManualInput)

	buildAnnounceColumn()

	panel:SetScript("OnShow", Options.Refresh)
	panel:SetScript("OnHide", stopListening)
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
	local mode = ns.GetMode()
	for key, b in pairs(modeButtons) do
		b:SetChecked(key == mode)
	end
	blockInputCB:SetChecked(blockInputCB.getter())
	showCB:SetChecked(showCB.getter())
	lockCB:SetChecked(lockCB.getter())
	autoResetCB:SetChecked(autoResetCB.getter())
	local secs = ns.GetAutoResetTime()
	if secs < 30 then secs = 30 elseif secs > 60 then secs = 60 end
	timerSlider:SetValue(secs)            -- fires OnValueChanged -> updates label + db
	timerValue:SetText(secs .. "s")       -- explicit, in case the value didn't change
	restrictCB:SetChecked(restrictCB.getter())

	local style = ns.GetAnnounceStyle()
	for key, b in pairs(styleButtons) do
		b:SetChecked(key == style)
	end

	local cue = ns.GetArrivalCue()
	for key, b in pairs(arrivalButtons) do
		b:SetChecked(key == cue)
	end

	local speaking = ns.GetTTSEnabled()
	ttsCB:SetChecked(speaking)
	overlapCB:SetChecked(overlapCB.getter())
	popupCB:SetChecked(popupCB.getter())
	subtitleCB:SetChecked(subtitleCB.getter())
	radarCB:SetChecked(radarCB.getter())
	blinkCB:SetChecked(blinkCB.getter())
	blinkCB:SetEnabled(ns.GetRadarEnabled())   -- nothing to blink without the radar

	local volume = ns.GetTTSVolume()
	volumeSlider:SetValue(volume)
	volumeValue:SetText(tostring(volume))

	for _, slider in ipairs(scaleSliders) do
		local scale = slider.getter()
		slider:SetValue(scale)                                     -- fires OnValueChanged
		slider.valueText:SetText(math.floor(scale * 100 + 0.5) .. "%")
	end

	-- The voice controls only mean anything while the voice is on, and the
	-- next-up line only while the popup is drawn at all.
	volumeSlider:SetEnabled(speaking)
	overlapCB:SetEnabled(speaking)
	subtitleCB:SetEnabled(ns.GetPopupEnabled())
end

function Options.Open()
	if Settings and categoryID then
		Settings.OpenToCategory(categoryID)
	end
end

local function register()
	if not Settings or categoryID then return end
	buildPanel()
	local category = Settings.RegisterCanvasLayoutCategory(panel, "SnakeSays")
	Settings.RegisterAddOnCategory(category)
	categoryID = category:GetID()
end

local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
	boot:UnregisterEvent("PLAYER_LOGIN")
	register()
end)
