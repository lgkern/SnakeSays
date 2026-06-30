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
--     (Esc cancels, right-click clears). Real game bindings via SetBinding, so
--     they match the Keybindings panel.
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
local showCB, lockCB, autoResetCB, timerSlider, timerValue, restrictCB
local capture             -- fullscreen key-capture overlay (created on demand)
local pendingButton       -- the key box whose binding we're setting

-- The five bindable actions (must match Bindings.xml binding names).
local BIND_COMMAND = {
	N = "SNAKESAYS_NORTH", E = "SNAKESAYS_EAST",
	S = "SNAKESAYS_SOUTH", W = "SNAKESAYS_WEST",
}
local RESET_COMMAND = "SNAKESAYS_RESET"

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
	return _G["BINDING_NAME_" .. command] or command
end

local function refreshKeybinds()
	for command, btn in pairs(keybindButtons) do
		local key = GetBindingKey(command)
		btn:SetText(key and GetBindingText(key) or "Unbound")
	end
end

-- Replace this command's binding with `chord` (or clear it when chord is nil),
-- then persist. We keep one key per action: clear any existing keys first.
local function applyBinding(command, chord)
	local k1, k2 = GetBindingKey(command)
	if k1 then SetBinding(k1) end
	if k2 then SetBinding(k2) end
	if chord then SetBinding(chord, command) end
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

local function buildCheckbox(label, y, getter, setter)
	local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
	cb:SetPoint("TOPLEFT", panel, "TOPLEFT", LEFT, y)
	cb:SetScript("OnClick", function(self) setter(self:GetChecked()) end)
	local text = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	text:SetPoint("LEFT", cb, "RIGHT", 2, 0)
	text:SetText(label)
	cb.getter = getter
	return cb
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

	local y = -64
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

	-- Reset row: label on the left, its keybind box aligned with the others.
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
	showCB:SetChecked(showCB.getter())
	lockCB:SetChecked(lockCB.getter())
	autoResetCB:SetChecked(autoResetCB.getter())
	local secs = ns.GetAutoResetTime()
	if secs < 30 then secs = 30 elseif secs > 60 then secs = 60 end
	timerSlider:SetValue(secs)            -- fires OnValueChanged -> updates label + db
	timerValue:SetText(secs .. "s")       -- explicit, in case the value didn't change
	restrictCB:SetChecked(restrictCB.getter())
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
