-- BotArena configuration. Everything comes from environment variables that arena.js sets per instance.
-- Without BOTARENA_ID the mod stays completely inert, so installing it by accident is harmless.
return function(A)
	local U = A.util
	local C = {}

	C.id = U.env_num("BOTARENA_ID", nil)
	C.enabled = C.id ~= nil
	if not C.enabled then return C end

	C.id = math.floor(C.id)
	C.pair = U.env_num("BOTARENA_PAIR", math.ceil(C.id / 2))
	-- "primary" instances create the lobby, "secondary" instances wait for / join it.
	-- Roles are only a tie-breaker: whoever is currently host of a lobby acts as host.
	C.role = U.env("BOTARENA_ROLE", (C.id % 2 == 1) and "primary" or "secondary")
	C.name = U.env("BOTARENA_NAME", "Bot" .. C.id)

	C.shared_dir = U.norm(U.env("BOTARENA_SHARED", ""))
	C.run_dir = C.shared_dir ~= "" and C.shared_dir or nil

	-- matchmaking / rules
	local ruleset = U.env("BOTARENA_RULESET", "standard_ranked")
	C.ruleset_short = (ruleset:gsub("^ruleset_mp_", ""))
	C.ruleset_key = "ruleset_mp_" .. C.ruleset_short
	local gm = U.env("BOTARENA_GAMEMODE", "")
	if gm ~= "" then
		C.gamemode_key = gm:match("^gamemode_mp_") and gm or ("gamemode_mp_" .. gm)
	end
	C.lobby_opts = U.parse_kv_list(U.env("BOTARENA_LOBBY_OPTS", ""))
	C.max_matches = U.env_num("BOTARENA_MATCHES", 0) -- 0 = endless
	C.start_delay = U.env_num("BOTARENA_START_DELAY", 1.5) -- seconds after guest is ready
	C.post_match_delay = U.env_num("BOTARENA_POST_MATCH_DELAY", 2.0) -- host waits this long before stopGame
	C.guest_stop_delay = U.env_num("BOTARENA_GUEST_STOP_DELAY", 20.0) -- guest fallback if host never stops
	C.create_wait_primary = U.env_num("BOTARENA_CREATE_WAIT_PRIMARY", 3.0)
	C.create_wait_secondary = U.env_num("BOTARENA_CREATE_WAIT_SECONDARY", 20.0)
	C.lobby_stale = U.env_num("BOTARENA_LOBBY_STALE", 30.0) -- ignore lobby files older than this (wall seconds)

	-- performance
	C.speed = U.env_num("BOTARENA_SPEED", 16) -- G.SETTINGS.GAMESPEED
	C.boost = math.floor(U.env_num("BOTARENA_BOOST", 4)) -- extra event-queue passes per frame
	C.fps_cap = U.env_num("BOTARENA_FPS_CAP", 0) -- 0 = leave the game's own cap
	C.draw_every = math.max(1, math.floor(U.env_num("BOTARENA_DRAW_EVERY", 1))) -- >1 skips rendering frames
	C.vsync_off = U.env_bool("BOTARENA_VSYNC_OFF", true)
	C.mute = U.env_bool("BOTARENA_MUTE", true)
	local win = U.env("BOTARENA_WINDOW", "")
	if win ~= "" then
		local x, y, w, h = win:match("^(-?%d+),(-?%d+),(%d+),(%d+)$")
		if x then C.window = { x = tonumber(x), y = tonumber(y), w = tonumber(w), h = tonumber(h) } end
	end

	-- bot / driver
	C.driver = U.env("BOTARENA_DRIVER", "baseline")
	C.act_interval = U.env_num("BOTARENA_ACT_INTERVAL", 0.0) -- min real seconds between bot actions
	C.driver_seed = U.env_num("BOTARENA_SEED", C.id * 7919)
	C.skip_blinds = U.env_num("BOTARENA_SKIP_RATE", 0) -- baseline driver: chance (0..1) to skip small/big blind

	-- PvP turn order: after both players have played a hand, the player with the lower score plays next
	-- (the leader waits). See lib/pvp.lua. turn_timeout = real seconds a waiting bot sits idle before it plays anyway.
	C.pvp_turn = U.env_bool("BOTARENA_PVP_TURN", true)
	C.turn_timeout = U.env_num("BOTARENA_TURN_TIMEOUT", 45)

	-- reward accounting (lib/reward.lua). BOTARENA_REWARD="money=1,tarot=3,fail=30,..." overrides single weights.
	C.reward_enabled = U.env_bool("BOTARENA_REWARD_ENABLED", true)
	-- press Cash Out as soon as its button exists, whatever the driver / event queue is doing (see arena.lua)
	C.log_decisions = U.env_bool("BOTARENA_LOG_DECISIONS", true) -- strategic decisions (shop / skips / packs) -> run/decisions/inst<N>.jsonl for the trainer
	C.decisions_max_mb = U.env_num("BOTARENA_DECISIONS_MAX_MB", 400)
	C.decide_heuristic = U.env_bool("BOTARENA_DECIDE_HEURISTIC", true) -- baseline driver: shop / pack / blind choices from lib/decide.lua's value model
	C.decide_skips = U.env_bool("BOTARENA_DECIDE_SKIPS", true) -- baseline value model may skip blinds by the strategy rules (false = never skip)
	C.decide_eps = U.env_num("BOTARENA_DECIDE_EPS", 0) -- baseline: chance of a random (non-destructive) strategic choice, for training-data diversity
	C.decide_potential = U.env_bool("BOTARENA_DECIDE_POTENTIAL", true) -- compute the planner's "what does this add to my best hands" feature
	C.decide_samples = math.floor(U.env_num("BOTARENA_DECIDE_SAMPLES", 8)) -- sampled hands per potential estimate
	C.decide_ms = U.env_num("BOTARENA_DECIDE_MS", 250) -- real-time budget for those estimates per decision
	C.decide_max_steps = math.floor(U.env_num("BOTARENA_DECIDE_MAX_STEPS", 40)) -- actions per shop visit before only "move on" is offered
	C.decide_max_rerolls = math.floor(U.env_num("BOTARENA_DECIDE_MAX_REROLLS", 12))
	C.external_hands = U.env("BOTARENA_EXTERNAL_HANDS", "learned") -- external driver: "learned" = the hand candidates go to your program / the trainer's hand model (lib/handdec.lua), "planner" = built-in planner plays hands, "agent" = raw bridge: your program picks card indices itself
	C.hand_decisions = U.env_bool("BOTARENA_HAND_DECISIONS", true) -- baseline driver: log every hand decision (candidate list + the planner's pick) for the trainer
	C.hand_eps = U.env_num("BOTARENA_HAND_EPS", 0) -- baseline: chance of a random candidate instead of the planner's pick (data diversity; costs score)
	C.hand_max_opts = math.floor(U.env_num("BOTARENA_HAND_MAX_OPTS", 44)) -- candidates (plays + discards) offered per hand decision
	C.hand_mc = math.floor(U.env_num("BOTARENA_HAND_MC", 6)) -- redraw samples per discard candidate (feature ev_*)
	C.hand_ms = U.env_num("BOTARENA_HAND_MS", 150) -- real-time budget for those samples per decision
	C.hand_planfeat = U.env_bool("BOTARENA_HAND_PLANFEAT", true) -- offer the planner's Monte-Carlo verdict as candidate features (false = pure learning from game mechanics only)
	C.hand_decisions_max_mb = U.env_num("BOTARENA_HAND_DECISIONS_MAX_MB", 600)
	C.random_loadout = U.env_bool("BOTARENA_RANDOM_LOADOUT", true) -- the host rolls a random vanilla deck + stake for every game (lib/rules.lua)
	C.loadout_decks = U.env("BOTARENA_DECKS", "") -- limit the pool, e.g. "plasma,ghost"
	C.loadout_stakes = U.env("BOTARENA_STAKES", "") -- limit the pool, e.g. "gold,spectralplus"
	C.loadout_delay = U.env_num("BOTARENA_LOADOUT_DELAY", 1.5) -- seconds between sending the loadout and pressing Start (the guest must have received it)
	C.joker_order = U.env_bool("BOTARENA_JOKER_ORDER", true) -- re-order the joker row automatically (+mult left of x-mult, Brainstorm / Blueprint next to the right joker; lib/order.lua)
	C.joker_order_ms = U.env_num("BOTARENA_JOKER_ORDER_MS", 400) -- real-time budget per order search
	C.joker_order_gain = U.env_num("BOTARENA_JOKER_ORDER_GAIN", 0.01) -- only move when the new order scores at least this fraction better (1 %)
	C.joker_order_samples = math.floor(U.env_num("BOTARENA_JOKER_ORDER_SAMPLES", 14)) -- sampled hands per evaluation
	C.joker_order_gap = U.env_num("BOTARENA_JOKER_ORDER_GAP", 1.0) -- minimum seconds between searches
	C.plan_enabled = U.env_bool("BOTARENA_PLAN", true) -- joker-aware, draw-probability hand planner (lib/plan.lua)
	C.plan_ms = U.env_num("BOTARENA_PLAN_MS", 60) -- thinking budget per hand decision (real milliseconds)
	C.auto_cash_out = U.env_bool("BOTARENA_AUTO_CASH_OUT", true)
	C.reward = U.parse_kv_list(U.env("BOTARENA_REWARD", ""))

	-- safety / recovery
	C.require_isolation = U.env_bool("BOTARENA_REQUIRE_ISOLATION", true)
	C.stall_timeout = U.env_num("BOTARENA_STALL_TIMEOUT", 240)
	C.match_timeout = U.env_num("BOTARENA_MATCH_TIMEOUT", 3600) -- wall seconds; 0 = unlimited
	C.connect_timeout = U.env_num("BOTARENA_CONNECT_TIMEOUT", 20)
	C.join_timeout = U.env_num("BOTARENA_JOIN_TIMEOUT", 10)
	C.status_interval = U.env_num("BOTARENA_STATUS_INTERVAL", 1.0)

	-- output
	if C.run_dir then
		C.status_path = U.join(C.run_dir, "status/inst" .. C.id .. ".json")
		C.results_path = U.join(C.run_dir, "results/inst" .. C.id .. ".jsonl")
		C.events_path = U.join(C.run_dir, "results/events" .. C.id .. ".jsonl")
		C.log_path = U.join(C.run_dir, "logs/inst" .. C.id .. ".arena.log")
		C.lobby_path = U.join(C.run_dir, "lobby/pair" .. C.pair .. ".json")
		C.command_path = U.join(C.run_dir, "commands/inst" .. C.id .. ".json")
		C.rewards_path = U.join(C.run_dir, "results/rewards" .. C.id .. ".jsonl")
		C.decisions_path = U.join(C.run_dir, "decisions/inst" .. C.id .. ".jsonl")
	end

	return C
end
