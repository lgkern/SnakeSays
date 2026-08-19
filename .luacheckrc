std = "lua51"
max_line_length = false

-- Addon files are called with (addonName, ns) varargs. SnakeSaysDB is the
-- SavedVariables global (declared in SnakeSays.toc); SlashCmdList gets the /ss handler.
globals = { "SnakeSaysDB", "SlashCmdList", "StaticPopupDialogs" }

-- WoW API surface the addon reads.
read_globals = {
	"CreateFrame", "UIParent", "GameTooltip",
	"C_Timer", "C_Map", "C_VoiceChat", "C_TTSSettings", "C_UnitAuras",
	"Settings", "SOUNDKIT",
	"GetTime", "GetInstanceInfo", "GetZoneText",
	"GetCursorPosition",
	"UnitPosition", "GetPlayerFacing", "UnitCanAttack", "issecretvalue",
	"UnitGUID", "UnitCastingInfo", "UnitExists",
	"UnitName", "UnitHealth", "UnitHealthMax", "UnitChannelInfo",
	"PlaySound", "PlaySoundFile",
	"StaticPopup_Show", "StaticPopup_Hide",
	"CreateVector2D",
	"GetBindingKey", "GetBindingText", "SetBinding", "SetBindingClick", "SaveBindings", "GetCurrentBindingSet",
	"IsAltKeyDown", "IsControlKeyDown", "IsShiftKeyDown", "IsMouseButtonDown",
	"InCombatLockdown",
	-- Group sync: which chat channel the caller's macros type into, and the
	-- macro window itself, which `/ss macro` writes them to.
	"IsInRaid", "GetFileIDFromPath",
	"CreateMacro", "EditMacro", "GetMacroIndexByName",
	"wipe", "strtrim",
	-- Deadly Boss Mods, when the player has it: Announce plays the marker call
	-- out of its voice pack. Every read of it is guarded -- see Announce.lua.
	"DBM",
}

exclude_files = {
	"tools/",   -- dev tooling, not shipped
}

ignore = {
	"212",              -- unused argument (the addonName/`_` varargs)
	"213",              -- unused loop variable
	"11./SLASH_.*",     -- SLASH_SNAKESAYS1/2 are intentional WoW slash globals
	"11./SnakeSays_.*", -- global funcs used as keybind click targets (SnakeSays_Press/Reset)
}

-- The test suite runs under busted, and the client mock deliberately installs
-- the WoW API into _G (and backfills math.atan2 for Lua 5.2+), so the usual
-- "undefined global" rules don't apply in here.
files["spec/"] = {
	std = "lua51+busted",
	globals = { "_G", "math" },
	read_globals = {
		"CreateFrame", "UIParent", "GameTooltip", "C_Timer", "C_Map",
		"C_VoiceChat", "C_TTSSettings", "C_UnitAuras", "Settings", "SOUNDKIT",
		"GetTime", "GetInstanceInfo", "GetZoneText",
		"UnitPosition", "GetPlayerFacing", "UnitCanAttack", "issecretvalue",
		"UnitGUID", "UnitCastingInfo", "UnitExists",
	"UnitName", "UnitHealth", "UnitHealthMax", "UnitChannelInfo",
		"PlaySound", "PlaySoundFile", "StaticPopup_Show", "StaticPopup_Hide",
		"CreateVector2D", "SlashCmdList", "StaticPopupDialogs",
		"GetBindingKey", "GetBindingText", "SetBinding", "SetBindingClick", "SaveBindings",
		"GetCurrentBindingSet", "InCombatLockdown",
		"wipe", "strtrim", "unpack",
	},
}
