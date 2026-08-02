-- ===========================================================================
-- spec/helpers/addon.lua  ·  loads SnakeSays into a fresh namespace headless.
--
-- The file list comes from SnakeSays.toc rather than a copy kept here, so a new
-- file added to the addon is picked up by the suite automatically (and a file
-- listed in the wrong load order fails the tests the same way it would fail
-- in-game).
-- ===========================================================================

local wow = require("spec.helpers.wow")

local M = {}
M.wow = wow

local ROOT = "."
local TOC = ROOT .. "/SnakeSays.toc"

-- The .lua entries of the .toc, in load order.
local function tocFiles()
	local fh = assert(io.open(TOC, "r"), "cannot open " .. TOC)
	local files = {}
	for line in fh:lines() do
		line = line:gsub("^%s*(.-)%s*$", "%1")
		if line ~= "" and not line:match("^#") and line:match("%.lua$") then
			table.insert(files, ROOT .. "/" .. line:gsub("\\", "/"))
		end
	end
	fh:close()
	assert(#files > 0, "no .lua files found in " .. TOC)
	return files
end

M.tocFiles = tocFiles

-- Reset the client mock and run the addon's files into a new namespace.
-- Returns the namespace table the addon populates.
function M.load()
	wow.reset()
	local ns = {}
	for _, path in ipairs(tocFiles()) do
		local chunk, err = loadfile(path)
		assert(chunk, "failed to load " .. path .. ": " .. tostring(err))
		chunk("SnakeSays", ns)
	end
	return ns
end

-- Load, then run the startup events the client would send. After this the
-- SavedVariables defaults are seeded and the UI exists.
function M.boot(opts)
	opts = opts or {}
	local ns = M.load()
	if opts.db then
		-- Simulate SavedVariables restored from disk before ADDON_LOADED.
		_G.SnakeSaysDB = opts.db
	end
	wow.fire("ADDON_LOADED", "SnakeSays")
	wow.fire("PLAYER_LOGIN")
	wow.fire("PLAYER_ENTERING_WORLD")
	return ns
end

return M
