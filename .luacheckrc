std = "lua51"
max_line_length = false

-- Addon files are called with (addonName, ns) varargs. SnakeSaysDB is the
-- SavedVariables global (declared in SnakeSays.toc); SlashCmdList gets the /ss handler.
globals = { "SnakeSaysDB", "SlashCmdList" }

-- WoW API surface the addon reads.
read_globals = {
	"CreateFrame", "UIParent", "GameTooltip",
	"C_Timer", "C_Map",
	"Settings",
	"GetBindingKey", "GetBindingText", "SetBinding", "SaveBindings", "GetCurrentBindingSet",
	"IsAltKeyDown", "IsControlKeyDown", "IsShiftKeyDown", "IsMouseButtonDown",
	"wipe", "strtrim",
}

exclude_files = {
	"tools/",   -- dev tooling, not shipped
}

ignore = {
	"212",              -- unused argument (the addonName/`_` varargs)
	"213",              -- unused loop variable
	"11./SLASH_.*",     -- SLASH_SNAKESAYS1/2 are intentional WoW slash globals
	"11./BINDING_.*",   -- BINDING_HEADER_/BINDING_NAME_ are read by the keybinding UI
	"11./SnakeSays_.*", -- global funcs called from Bindings.xml (SnakeSays_Press/Reset)
}
