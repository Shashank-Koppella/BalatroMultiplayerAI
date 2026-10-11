-- BotArena entry point. Inert unless arena.js launched this instance (BOTARENA_ID is set).
BotArena = BotArena or {}
local A = BotArena
A.mod = SMODS.current_mod

local function load_module(rel)
	local chunk, err = SMODS.load_file(rel, "BotArena")
	if not chunk then error("BotArena: cannot load " .. rel .. ": " .. tostring(err)) end
	return chunk()
end

A.util = load_module("lib/util.lua")(A)
A.cfg = load_module("lib/config.lua")(A)

if not A.cfg.enabled then
	sendInfoMessage("BOTARENA_ID not set: BotArena is inactive", "BotArena")
	return
end

local U, C = A.util, A.cfg
-- unique per game process: match numbers restart at 1 after every restart, (inst, sess, match) never repeats
A.session = string.format("%d-%d", math.floor(U.wall()), C.id)
U.mkdirs(C.run_dir or ".")
if C.run_dir then
	for _, sub in ipairs({ "status", "results", "logs", "lobby", "commands", "bridge", "decisions" }) do
		U.mkdirs(U.join(C.run_dir, sub))
	end
end
U.set_log_path(C.log_path)
U.info(string.format("BotArena %s starting as instance %d (%s, %s)", A.mod.version or "?", C.id, C.name, C.role))

A.obs = load_module("lib/obs.lua")(A)
A.act = load_module("lib/act.lua")(A)
A.rules = load_module("lib/rules.lua")(A)
A.hands = load_module("lib/hands.lua")(A)
A.plan = load_module("lib/plan.lua")(A)
A.order = load_module("lib/order.lua")(A)
A.pvp = load_module("lib/pvp.lua")(A)
A.reward = load_module("lib/reward.lua")(A)
A.decide = load_module("lib/decide.lua")(A)
A.handdec = load_module("lib/handdec.lua")(A)
A.speed = load_module("lib/speed.lua")(A)
A.fsm = load_module("lib/arena.lua")(A)

-- ------------------------------------------------------------------------------------------------
-- save-folder isolation guard: never run bots against the real %APPDATA%/Balatro profile
-- ------------------------------------------------------------------------------------------------
A.save_dir = U.norm(love.filesystem.getSaveDirectory() or "")
local save_name = A.save_dir:match("([^/]+)/*$") or ""
if C.require_isolation and save_name:lower() == "balatro" then
	A.fatal = "this instance is using the real Balatro save folder (" .. A.save_dir .. "); refusing to run bots against your profile"
	A.fsm.fatal = A.fatal
	U.err(A.fatal)
else
	U.info("save folder: " .. A.save_dir)
end

-- ------------------------------------------------------------------------------------------------
-- drivers
-- ------------------------------------------------------------------------------------------------
function A.load_driver(name)
	local chunk, err
	if name:find("[/\\]") or name:lower():match("%.lua$") then
		local src = U.read(name)
		if not src then error("driver file not found: " .. name) end
		chunk, err = load(src, "=[BotArena driver " .. name .. "]")
	else
		chunk, err = SMODS.load_file("drivers/" .. name .. ".lua", "BotArena")
	end
	if not chunk then error("cannot load driver '" .. name .. "': " .. tostring(err)) end
	local factory = chunk()
	local driver = factory(A)
	driver.name = driver.name or name
	return driver
end

local ok, drv = pcall(A.load_driver, C.driver)
if ok then
	A.driver = drv
	A.driver_name = drv.name
	U.info("driver: " .. drv.name)
else
	U.err("driver load failed (" .. tostring(drv) .. "), falling back to baseline")
	local ok2, drv2 = pcall(A.load_driver, "baseline")
	if ok2 then
		A.driver, A.driver_name = drv2, drv2.name
	end
end

-- ------------------------------------------------------------------------------------------------
-- hooks into Multiplayer (loaded earlier: our priority is higher)
-- ------------------------------------------------------------------------------------------------
local lobby_start_run_ref = G.FUNCS.lobby_start_run
function G.FUNCS.lobby_start_run(e, args)
	pcall(A.fsm.on_match_start, args)
	return lobby_start_run_ref(e, args)
end

if MP and MP.STATS and MP.STATS.record_match then
	local record_match_ref = MP.STATS.record_match
	function MP.STATS.record_match(won)
		pcall(A.fsm.on_match_end, won)
		return record_match_ref(won)
	end
else
	U.warn("MP.STATS.record_match not found; results will not be recorded")
end

-- suppress the "dev build" popup and similar nags on every launch
if MP and MP.EXPERIMENTAL then MP.EXPERIMENTAL.suppress_dev_warning = true end

-- ------------------------------------------------------------------------------------------------
-- frame hook
-- ------------------------------------------------------------------------------------------------
local game_update_ref = Game.update
function Game:update(dt)
	if A.fsm.fatal then
		-- show nothing fancy: just stop after letting the status file land
		if not A.fatal_at then
			A.fatal_at = U.now()
			A.fsm.write_status(true)
			A.fsm.event("fatal", { reason = A.fsm.fatal })
		elseif U.now() - A.fatal_at > 3 then
			love.event.quit(2)
		end
		return game_update_ref(self, dt)
	end
	pcall(A.speed.pre)
	game_update_ref(self, dt)
	pcall(A.speed.post)
	A.fsm.safe_tick(dt)
end

pcall(A.speed.install_draw_skip)
U.info("BotArena ready")
