-- BotArena state machine: boots into the menu, creates / joins a lobby, readies up, starts matches,
-- runs the bot driver during a match, records the result, returns to the lobby and repeats.
--
-- The machine is "reconciling": each tick it looks at what the game is actually showing (menu / lobby /
-- run) instead of trusting its own bookkeeping, so it recovers from restarts, disconnects, and stray
-- overlays without special cases.
return function(A)
	local U, O, X, C = A.util, A.obs, A.act, A.cfg
	local F = {
		phase = "boot",
		matches = 0,
		wins = 0,
		losses = 0,
		match = nil,
		last_result = nil,
		errors = 0,
		last_error = nil,
		restarts_requested = 0,
	}

	local last = {} -- named rate limiters
	local function every(key, secs)
		local n = U.now()
		if not last[key] or n - last[key] >= secs then
			last[key] = n
			return true
		end
		return false
	end

	local function event(kind, data)
		if not C.events_path then return end
		local row = { t = U.wall(), inst = C.id, ev = kind }
		if data then
			for k, v in pairs(data) do row[k] = v end
		end
		U.append_jsonl(C.events_path, row)
	end
	F.event = event

	-- ---------------------------------------------------------------------------------------------
	-- status file (read by arena.js `status`)
	-- ---------------------------------------------------------------------------------------------
	local function lobby_summary()
		if not (MP and MP.LOBBY) then return nil end
		return {
			code = MP.LOBBY.code,
			host = MP.LOBBY.is_host and true or false,
			opponent = O.opponent_name(),
			ready = MP.LOBBY.ready_to_start and true or false,
		}
	end

	function F.write_status(force)
		if not C.status_path then return end
		if not force and not every("status", C.status_interval) then return end
		local row = {
			inst = C.id,
			pair = C.pair,
			name = C.name,
			role = C.role,
			phase = F.phase,
			t = U.wall(),
			uptime = math.floor(U.now() - (F.t_start or U.now())),
			stage = O.stage(),
			state = O.state_name(),
			lobby = lobby_summary(),
			matches = F.matches,
			wins = F.wins,
			losses = F.losses,
			aborted = F.aborted or 0,
			last_result = F.last_result,
			errors = F.errors,
			last_error = F.last_error,
			fatal = F.fatal,
			finished = F.finished or nil,
			quit_reason = F.quit_reason,
			speed = C.speed,
			fps = love.timer and love.timer.getFPS and love.timer.getFPS() or nil,
			driver = A.driver_name,
			save_dir = A.save_dir,
			connected = O.connected() and true or false,
			waiting = F.turn_wait,
		}
		if C.reward_enabled and A.reward then
			row.reward = { total = A.reward.total, match = A.reward.match_total, blinds = A.reward.blinds }
		end
		if F.match and not F.match.ended and O.stage() == "run" and G.GAME then
			row.match = {
				n = F.match.n,
				secs = math.floor(U.now() - F.match.t0),
				ante = G.GAME.round_resets and G.GAME.round_resets.ante or nil,
				round = G.GAME.round,
				dollars = G.GAME.dollars,
				lives = MP.GAME and MP.GAME.lives or nil,
				enemy_lives = MP.GAME and MP.GAME.enemy and MP.GAME.enemy.lives or nil,
			}
		end
		U.write_json(C.status_path, row)
	end

	-- ---------------------------------------------------------------------------------------------
	-- lobby file exchange (shared directory)
	-- ---------------------------------------------------------------------------------------------
	local function read_lobby_file()
		if not C.lobby_path then return nil end
		local rec = U.read_json(C.lobby_path)
		if type(rec) ~= "table" or not rec.code then return nil end
		if type(rec.ts) ~= "number" or math.abs(U.wall() - rec.ts) > C.lobby_stale then return nil end
		return rec
	end

	local function publish_lobby()
		if not C.lobby_path or not MP.LOBBY.code then return end
		U.mkdirs(C.lobby_path:match("^(.*)/[^/]+$") or ".")
		U.write_json(C.lobby_path, {
			code = MP.LOBBY.code,
			owner = C.id,
			name = C.name,
			ts = U.wall(),
			ruleset = MP.LOBBY.config and MP.LOBBY.config.ruleset or nil,
		})
	end

	-- ---------------------------------------------------------------------------------------------
	-- menu side: connect, find / create / join a lobby, ready up, start
	-- ---------------------------------------------------------------------------------------------
	function F.create_lobby()
		local rs = MP.Rulesets and MP.Rulesets[C.ruleset_key]
		if not rs then
			F.fatal = "ruleset not found: " .. C.ruleset_key
			U.err(F.fatal)
			return false
		end
		MP.LOBBY.config.ruleset = C.ruleset_key
		if C.gamemode_key then MP.LOBBY.config.gamemode = C.gamemode_key end
		-- same preparation the ruleset picker does when you click a ruleset button
		if MP.apply_default_modifiers then pcall(MP.apply_default_modifiers, C.ruleset_short) end
		if MP.LoadReworks then pcall(MP.LoadReworks, C.ruleset_short) end
		F.phase = "creating"
		F.create_started = U.now()
		event("create_lobby", { ruleset = C.ruleset_key })
		U.info("creating lobby (" .. C.ruleset_key .. ")")
		G.FUNCS.start_lobby({ config = {} })
		F.opts_applied_for = nil
		return true
	end

	local failed_codes = {}

	function F.try_join(rec)
		local n = U.now()
		local jt = F.join_attempt
		if jt and jt.code == rec.code and not jt.failed and n - jt.t < C.join_timeout then
			F.phase = "joining"
			return
		end
		if jt and jt.code == rec.code and not jt.failed then
			-- the attempt timed out without us ending up in the lobby
			jt.failed = true
			failed_codes[rec.code] = n
			event("join_failed", { code = rec.code })
			return
		end
		if failed_codes[rec.code] and n - failed_codes[rec.code] < 30 then return end
		F.join_attempt = { code = rec.code, t = n }
		F.phase = "joining"
		MP.LOBBY.temp_code = rec.code
		event("join_lobby", { code = rec.code })
		U.info("joining lobby " .. rec.code)
		MP.ACTIONS.join_lobby(rec.code)
	end

	function F.find_lobby()
		local n = U.now()
		F.menu_since = F.menu_since or n
		F.phase = "find_lobby"

		if F.create_started and n - F.create_started < 10 then
			F.phase = "creating"
			return -- give the server time to answer createLobby
		end

		local rec = read_lobby_file()
		if rec and rec.owner ~= C.id then
			F.try_join(rec)
			if F.phase == "joining" then return end
		end

		local wait = (C.role == "primary") and C.create_wait_primary or C.create_wait_secondary
		if n - F.menu_since >= wait and every("create", 6) then F.create_lobby() end
	end

	function F.apply_lobby_options()
		if F.opts_applied_for == MP.LOBBY.code then return end
		F.opts_applied_for = MP.LOBBY.code
		if next(C.lobby_opts) then
			for k, v in pairs(C.lobby_opts) do
				MP.LOBBY.config[k] = v
			end
			MP.ACTIONS.lobby_options()
			U.info("applied lobby options")
		end
	end

	function F.ready_up()
		local btn = G.MAIN_MENU_UI and G.MAIN_MENU_UI.get_UIE_by_ID and G.MAIN_MENU_UI:get_UIE_by_ID("lobby_menu_start")
		if btn and G.FUNCS.lobby_ready_up then
			local ok = pcall(G.FUNCS.lobby_ready_up, btn)
			if ok and MP.LOBBY.ready_to_start then return true end
		end
		MP.LOBBY.ready_to_start = true
		MP.ACTIONS.ready_lobby()
		return true
	end

	function F.tick_lobby()
		F.phase = "in_lobby"
		F.menu_since = nil
		F.create_started = nil
		F.join_attempt = nil
		local n = U.now()
		F.lobby_since = F.lobby_since or n

		if C.max_matches > 0 and F.matches >= C.max_matches then return F.finish() end

		if O.is_host() then
			if every("publish", 4) then publish_lobby() end
			F.apply_lobby_options()

			-- A secondary that ended up hosting an empty lobby yields to a fresh lobby from its primary.
			if C.role == "secondary" and not O.opponent_present() and n - F.lobby_since > 12 and every("yield", 5) then
				local rec = read_lobby_file()
				if rec and rec.owner ~= C.id and rec.code ~= MP.LOBBY.code then
					event("yield_lobby", { to = rec.code })
					MP.ACTIONS.leave_lobby()
					MP.LOBBY.code = nil
					F.lobby_since = nil
					return
				end
			end

			if O.opponent_present() and MP.LOBBY.ready_to_start then
				F.ready_since = F.ready_since or n
				-- a random deck + stake for this game (lib/rules.lua): rolled once per start, sent to the guest, then wait for it to arrive
				if C.random_loadout and A.rules and not F.loadout then
					local ok, roll = pcall(A.rules.roll)
					if ok and roll and A.rules.apply_roll(roll) then
						F.loadout, F.loadout_t = roll, n
						event("loadout", { deck = roll.deck, stake = roll.stake, stake_key = roll.stake_key })
						U.info(string.format("loadout: %s, stake %s (%d)", roll.deck, tostring(roll.stake_key), roll.stake or 0))
					else
						F.loadout, F.loadout_t = { none = true }, n
						U.warn("random loadout failed: " .. tostring(roll))
					end
				end
				local loadout_ready = (not C.random_loadout) or (F.loadout_t and n - F.loadout_t >= C.loadout_delay)
				if n - F.ready_since >= C.start_delay and loadout_ready and every("start", 8) then
					event("start_game")
					U.info("starting game")
					MP.ACTIONS.start_game()
				end
			else
				F.ready_since = nil
				F.loadout, F.loadout_t = nil, nil
				if O.opponent_present() and every("lobbysync", 10) then pcall(MP.ACTIONS.lobby_info) end
			end
		else
			if O.opponent_present() and not MP.LOBBY.ready_to_start and every("ready", 1.5) then F.ready_up() end
			-- local flag says ready but the host never starts: re-sync with the server's view
			if MP.LOBBY.ready_to_start and every("lobbysync", 10) then pcall(MP.ACTIONS.lobby_info) end
		end
	end

	function F.finish()
		if F.finished then return end
		F.finished = true
		F.phase = "finished"
		event("finished", { matches = F.matches })
		U.info("match limit reached, leaving")
		pcall(MP.ACTIONS.leave_lobby)
		F.quit_at = U.now() + 2
		F.write_status(true)
	end

	function F.tick_menu()
		if F.finished then return end
		F.in_run_since = nil
		-- stray overlays (error popups, "lobby not found", reconnect countdowns...) block the menu buttons
		if G.OVERLAY_MENU and every("dismiss", 0.6) then
			X.dismiss_overlay()
			return
		end
		if G.SETTINGS and G.SETTINGS.paused and not G.OVERLAY_MENU then G.SETTINGS.paused = false end

		if not O.connected() then
			F.phase = "connecting"
			F.connect_since = F.connect_since or U.now()
			if U.now() - F.connect_since > C.connect_timeout and every("connect", C.connect_timeout) then
				U.warn("no server connection, retrying")
				event("reconnect")
				pcall(MP.ACTIONS.connect)
			end
			return
		end
		F.connect_since = nil

		if not O.in_lobby() then
			F.lobby_since = nil
			return F.find_lobby()
		end
		return F.tick_lobby()
	end

	-- ---------------------------------------------------------------------------------------------
	-- match lifecycle
	-- ---------------------------------------------------------------------------------------------
	function F.on_match_start(args)
		F.matches_started = (F.matches_started or 0) + 1
		F.match = {
			n = F.matches_started,
			t0 = U.now(),
			wall = U.wall(),
			seed = args and args.seed or nil,
			ended = false,
			opponent = O.opponent_name(),
		}
		F.loadout, F.loadout_t = nil, nil
		F.stall_level = 0
		F.driver_memo = {}
		if C.reward_enabled and A.reward then pcall(A.reward.on_match_start) end
		if A.plan then pcall(A.plan.reset) end
		event("match_start", { n = F.match.n, seed = F.match.seed, opponent = F.match.opponent })
		U.info("match " .. F.match.n .. " started vs " .. tostring(F.match.opponent))
		if A.driver and A.driver.on_match_start then pcall(A.driver.on_match_start, F.match) end
	end

	-- won: true/false from the game; aborted: set by the arena itself (match timeout) -> logged as "aborted"
	function F.on_match_end(won, aborted)
		local m = F.match
		if not m or m.ended then return end
		if C.reward_enabled and A.reward then pcall(A.reward.on_match_end, won, aborted) end
		m.ended = true
		m.won = (not aborted) and (won and true or false) or false
		m.t_end = U.now()
		F.matches = F.matches + 1
		if aborted then F.aborted = (F.aborted or 0) + 1
		elseif won then F.wins = F.wins + 1 else F.losses = F.losses + 1 end
		local row = {
			t = U.wall(),
			inst = C.id,
			sess = A.session,
			pair = C.pair,
			name = C.name,
			match = m.n,
			result = aborted and "aborted" or (won and "win" or "loss"),
			opponent = m.opponent or O.opponent_name(),
			ruleset = MP.LOBBY.config and MP.LOBBY.config.ruleset or nil,
			gamemode = MP.LOBBY.config and MP.LOBBY.config.gamemode or nil,
			seed = m.seed,
			secs = math.floor((m.t_end - m.t0) * 10) / 10,
			ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante or nil,
			round = G.GAME and G.GAME.round or nil,
			lives = MP.GAME and MP.GAME.lives or nil,
			enemy_lives = MP.GAME and MP.GAME.enemy and MP.GAME.enemy.lives or nil,
			best_score = MP.GAME and U.fmt_score(MP.GAME.highest_score) or nil,
			enemy_best = MP.GAME and MP.GAME.enemy and U.fmt_score(MP.GAME.enemy.highest_score) or nil,
			driver = A.driver_name,
			speed = C.speed,
			deck = m.deck,
			stake = m.stake_key,
			stake_index = m.stake,
		}
		if C.reward_enabled and A.reward then
			row.reward_total = A.reward.match_total
			row.reward_blinds = A.reward.match_blinds
		end
		F.last_result = row
		if C.results_path then U.append_jsonl(C.results_path, row) end
		U.info(string.format("match %d finished: %s (%.1fs)", m.n, row.result, row.secs))
		if A.driver and A.driver.on_match_end then pcall(A.driver.on_match_end, row) end
	end

	function F.tick_post_match()
		F.phase = "post_match"
		local m = F.match
		local n = U.now()
		local waited = n - (m.t_end or n)
		if O.is_host() then
			if waited >= C.post_match_delay and (not m.stop_sent or (n - m.stop_sent > 15 and (m.stop_count or 0) < 3)) then
				m.stop_sent = n
				m.stop_count = (m.stop_count or 0) + 1
				event("stop_game", { by = "host" })
				MP.ACTIONS.stop_game()
			end
		else
			if waited >= C.guest_stop_delay and (not m.stop_sent or n - m.stop_sent > 15) and (m.stop_count or 0) < 3 then
				m.stop_sent = n
				m.stop_count = (m.stop_count or 0) + 1
				event("stop_game", { by = "guest-fallback" })
				MP.ACTIONS.stop_game()
			end
		end
	end

	-- Why is the bot (not) cashing out? One line for the log / events file.
	function F.cash_out_diag()
		local parts = {}
		local function add(k, v) parts[#parts + 1] = k .. "=" .. tostring(v) end
		add("state", O.state_name())
		add("complete", G.STATE_COMPLETE and true or false)
		add("btn", X.find_cash_out_button() and true or false)
		add("ready", X.cash_out_ready() and true or false)
		do -- every Cash Out UIBox the game still holds, newest first: "b" = button callback still set, "d" = disable_button
			local bl = {}
			for _, e in ipairs(X.cash_out_buttons()) do
				bl[#bl + 1] = (e.node.config and e.node.config.button and "b" or "-") .. (e.node.disable_button and "d" or "")
			end
			add("cash_boxes", #bl .. "[" .. table.concat(bl, ",") .. "]")
		end
		add("paused", G.SETTINGS and G.SETTINGS.paused and true or false)
		add("wipe", G.screenwipe and true or false)
		add("locked", G.CONTROLLER and G.CONTROLLER.locked and true or false)
		add("stop_use", G.GAME and G.GAME.STOP_USE or 0)
		add("scoring", G.SCORING_COROUTINE and true or false)
		add("round_eval", G.round_eval and not G.round_eval.REMOVED and true or false)
		add("pack_area", G.pack_cards and (G.pack_cards.REMOVED and "stale" or "live") or "none")
		local blocking, shown = 0, {}
		if G.E_MANAGER and G.E_MANAGER.queues then
			for qname, queue in pairs(G.E_MANAGER.queues) do
				for _, ev in ipairs(queue) do
					if ev.blocking ~= false then
						blocking = blocking + 1
						if #shown < 6 then
							local info = debug and debug.getinfo and type(ev.func) == "function" and debug.getinfo(ev.func, "S")
							shown[#shown + 1] = string.format("%s:%s/%s@%s:%s", tostring(qname), tostring(ev.trigger), tostring(ev.delay),
								info and tostring((info.short_src or "?"):match("[^/\\]+$")) or "?", info and tostring(info.linedefined) or "?")
						end
					end
				end
			end
		end
		add("blocking_events", blocking)
		if #shown > 0 then add("first", table.concat(shown, ","):gsub("%s", "")) end
		return table.concat(parts, " ")
	end

	-- Returns true when it handled this frame (pressed or is waiting for the button).
	function F.tick_round_eval()
		local now = U.now()
		if not F.eval_since then F.eval_since = now end
		local waited = now - F.eval_since
		-- the press did not take (button is live again / screen unchanged): allow another press after 3 s
		if F.eval_pressed and now - F.eval_pressed > 3 and X.cash_out_ready() then
			U.warn("cash out was pressed but the screen is unchanged and a live button exists: pressing again")
			F.eval_pressed = nil
		end
		-- last resort: a Cash Out box exists, the payout rows are done, but no box has its callback any more for 10 s: revive the newest
		if not F.eval_pressed and waited > 10 and G.round_eval and not X.cash_out_ready() and every("cashout_revive", 5) then
			local list = X.cash_out_buttons()
			local e = list[1]
			if e and e.node.config and e.node.config.button == nil then
				e.node.config.button = "cash_out"
				e.node.disable_button = nil
				U.warn("no pressable Cash Out button for 10 s: re-armed the newest one")
				event("cash_out_revive", { waited = math.floor(waited) })
			end
		end
		if not F.eval_pressed and every("cashout_try", 0.2) then
			if X.cash_out_ready() then
				local ok, why = X.cash_out()
				if ok then
					F.eval_pressed = now
					F.cash_outs = (F.cash_outs or 0) + 1
					event("cash_out", { waited = math.floor(waited * 10) / 10, settled = O.settled() and true or false, n = F.cash_outs })
					U.info(string.format("cash out pressed after %.1fs (queue settled=%s)", waited, tostring(O.settled())))
				else
					U.warn("cash out refused: " .. tostring(why))
				end
			end
		end
		-- diagnostics: nothing pressed after 2 s -> say exactly what is holding things up (every 5 s)
		local diag_from = F.eval_pressed or F.eval_since
		if now - diag_from > (F.eval_pressed and 4 or 2) and (not F.eval_last_diag or now - F.eval_last_diag >= 5) then
			F.eval_last_diag = now
			local d = F.cash_out_diag()
			U.warn(string.format("round-end screen %.0fs, %s: %s", now - F.eval_since, F.eval_pressed and "cash out pressed but screen unchanged" or "cash out not pressed yet", d))
			event("cash_out_wait", { waited = math.floor(now - F.eval_since), pressed = F.eval_pressed and true or false, diag = d })
		end
		-- after a press, let the normal gating handle the rest (nothing else to do on this screen)
		return true
	end

	function F.tick_run()
		F.connect_since = nil
		F.menu_since = nil
		F.in_run_since = F.in_run_since or U.now()
		if not O.in_lobby() then
			-- a run with no lobby should never exist in the arena; get back to the menu
			if every("nolobby", 4) then
				U.warn("run without lobby, returning to menu")
				G.FUNCS.go_to_menu()
			end
			return
		end
		if not F.match then
			-- joined mid-run after a restart: nothing sensible to do but wait for the match to end
			F.match = { n = (F.matches_started or 0) + 1, t0 = U.now(), wall = U.wall(), ended = false }
		end
		if F.match.ended then return F.tick_post_match() end

		F.phase = "in_match"
		if C.match_timeout > 0 and U.now() - F.match.t0 > C.match_timeout then
			-- e.g. two mirrored bots tying every PvP blind forever: the server never ends a match on a tie
			U.warn(string.format("match %d exceeded %.0fs, aborting it", F.match.n, C.match_timeout))
			event("match_timeout", { n = F.match.n })
			F.on_match_end(false, true)
			return
		end
		-- the deck / stake the game really started with (lobby_start_run runs after on_match_start, so it is read on the first tick)
		if not F.match.rules_read and A.rules and G.GAME and G.GAME.selected_back then
			local okr, live = pcall(A.rules.live)
			if okr and live and live.deck then
				F.match.rules_read = true
				F.match.deck, F.match.deck_key, F.match.stake, F.match.stake_key = live.deck, live.deck_key, live.stake, live.stake_key
				event("rules", { deck = live.deck, stake = live.stake_key, scaling = live.scaling, small_pays = live.small_pays, no_interest = live.no_interest,
					eternals = live.eternals, perishables = live.perishables, rentals = live.rentals, money_per_hand = live.money_per_hand, money_per_discard = live.money_per_discard })
				U.info(string.format("rules: %s on %s | scaling %s, small blind %s, interest %s, stickers %s%s%s", tostring(live.deck), tostring(live.stake_key), tostring(live.scaling),
					live.small_pays and "pays" or "pays nothing", live.no_interest and "off" or "on", live.eternals and "eternal " or "", live.perishables and "perishable " or "", live.rentals and "rental" or ""))
			end
		end
		if C.reward_enabled and A.reward then pcall(A.reward.tick) end
		if A.plan then pcall(A.plan.observe) end
		-- Round-end screen: press Cash Out the moment its button exists. This deliberately does NOT wait for
		-- O.settled(): the game only creates the button once its own animations are done, a human can click it
		-- at once, and a stray blocking event in the queue must never be able to hold the bot at this screen.
		if G.STATE == G.STATES.ROUND_EVAL and C.auto_cash_out then
			if F.tick_round_eval() then return end
		else
			F.eval_since, F.eval_last_diag, F.eval_pressed = nil, nil, nil
			-- the game keeps every used Cash Out box forever (and updates / draws it every frame): drop them once the round is over
			if every("prune_cash", 3) then
				local okp, n = pcall(X.prune_cash_out_boxes)
				if okp and n and n > 0 then F.pruned_cash_boxes = (F.pruned_cash_boxes or 0) + n end
			end
		end
		if not O.settled() then return end
		if C.act_interval > 0 and not every("act", C.act_interval) then return end
		if not A.driver then return end
		-- PvP turn order: after both players have played, the player who is behind plays next; the leader waits
		F.turn_wait = nil
		if A.pvp and G.STATE == G.STATES.SELECTING_HAND and O.in_pvp_blind() then
			local ok_gate, go, why = pcall(A.pvp.gate)
			if ok_gate and not go then
				F.turn_wait = why
				return
			end
		end
		-- joker row order (+mult before x-mult, Brainstorm / Blueprint next to the right joker): re-optimised when the joker set changes
		if A.order and C.joker_order then
			local oko, moved = pcall(A.order.tick)
			if not oko then
				F.errors = F.errors + 1
				F.last_error = tostring(moved)
				U.err("joker order error: " .. tostring(moved))
			elseif moved then
				return
			end
		end
		local ok, acted = pcall(A.driver.step, F.driver_memo)
		if not ok then
			F.errors = F.errors + 1
			F.last_error = tostring(acted)
			U.err("driver error: " .. tostring(acted))
			event("driver_error", { err = tostring(acted) })
		end
	end

	-- ---------------------------------------------------------------------------------------------
	-- watchdog
	-- ---------------------------------------------------------------------------------------------
	function F.watchdog()
		local n = U.now()
		local sig = table.concat({ O.progress_signature(), tostring(F.phase), tostring(MP and MP.LOBBY and MP.LOBBY.code) }, "|")
		if MP and MP.GAME and MP.GAME.enemy and O.stage() == "run" then
			sig = sig .. "|" .. tostring(MP.GAME.enemy.hands) .. "|" .. tostring(U.fmt_score(MP.GAME.enemy.score))
		end
		if sig ~= F.last_sig then
			F.last_sig = sig
			F.last_progress = n
			F.stall_level = 0
			return
		end
		local idle = n - (F.last_progress or n)
		local limit
		if F.phase == "in_match" or F.phase == "post_match" then
			limit = C.stall_timeout
		elseif F.phase == "boot" then
			limit = 240
		elseif F.phase == "connecting" then
			limit = 120
		else
			return -- lobby phases legitimately wait on the other instance
		end
		local level = F.stall_level or 0
		if level == 0 and idle > limit then
			F.stall_level = 1
			U.warn(string.format("stalled %.0fs in %s/%s: soft recovery", idle, F.phase, O.state_name()))
			event("stall", { level = 1, phase = F.phase, state = O.state_name() })
			X.dismiss_overlay()
			if G.SETTINGS then G.SETTINGS.paused = false end
			if A.driver and A.driver.unstick then pcall(A.driver.unstick) end
		elseif level == 1 and idle > limit * 1.6 then
			F.stall_level = 2
			U.warn("still stalled: asking server to stop the game")
			event("stall", { level = 2 })
			if O.in_lobby() then pcall(MP.ACTIONS.stop_game) end
		elseif level == 2 and idle > limit * 2.6 then
			F.stall_level = 3
			U.err("hard stall: quitting so arena.js can restart this instance")
			event("stall", { level = 3 })
			F.request_quit("stalled")
		end
	end

	function F.request_quit(reason)
		F.quit_at = F.quit_at or (U.now() + 0.5)
		F.quit_reason = reason
		F.restarts_requested = F.restarts_requested + 1
		F.write_status(true)
	end

	-- ---------------------------------------------------------------------------------------------
	-- commands from arena.js
	-- ---------------------------------------------------------------------------------------------
	function F.poll_commands()
		if not C.command_path or not every("cmd", 1.0) then return end
		local cmd = U.read_json(C.command_path)
		if type(cmd) ~= "table" then return end
		U.remove(C.command_path)
		event("command", { cmd = cmd.cmd })
		if cmd.cmd == "quit" then
			pcall(function() if O.in_lobby() then MP.ACTIONS.leave_lobby() end end)
			F.finished = true
			F.phase = "finished"
			F.quit_at = U.now() + 0.8
		elseif cmd.cmd == "speed" and tonumber(cmd.value) then
			C.speed = tonumber(cmd.value)
		elseif cmd.cmd == "stop_game" then
			pcall(MP.ACTIONS.stop_game)
		end
	end

	-- ---------------------------------------------------------------------------------------------
	-- main tick (called once per frame after Game:update)
	-- ---------------------------------------------------------------------------------------------
	function F.once_menu()
		if F.menu_ready then return end
		F.menu_ready = true
		pcall(function()
			SMODS.Mods["Multiplayer"].config.username = C.name
			MP.ACTIONS.set_username(C.name)
		end)
		A.speed.on_menu()
		event("menu_ready", { save_dir = A.save_dir, name = C.name })
		U.info("menu reached as " .. C.name)
	end

	function F.tick(dt)
		F.t_start = F.t_start or U.now()
		if F.quit_at and U.now() >= F.quit_at then
			F.quit_at = nil
			U.info("quitting (" .. tostring(F.quit_reason or "finished") .. ")")
			F.write_status(true)
			love.event.quit()
			return
		end
		F.poll_commands()

		local stage = O.stage()
		if stage == "boot" then
			F.phase = "boot"
		else
			F.once_menu()
			if stage == "run" then
				F.tick_run()
			elseif stage == "menu" then
				F.tick_menu()
			end
		end
		local ok_wd, err_wd = pcall(F.watchdog)
		if not ok_wd then
			F.errors = F.errors + 1
			F.last_error = "watchdog: " .. tostring(err_wd)
			if every("wd_err", 30) then U.err("watchdog error: " .. tostring(err_wd)) end
		end
		F.write_status()
	end

	-- Called by main.lua inside a pcall; keeps the machine alive across driver / logic errors.
	function F.safe_tick(dt)
		local ok, err = pcall(F.tick, dt)
		if ok then
			F.consecutive_errors = 0
			return
		end
		F.errors = F.errors + 1
		F.consecutive_errors = (F.consecutive_errors or 0) + 1
		F.last_error = tostring(err)
		if F.consecutive_errors <= 3 or F.consecutive_errors % 100 == 0 then
			U.err("tick error: " .. tostring(err))
			event("tick_error", { err = tostring(err) })
		end
		if F.consecutive_errors == 600 then F.request_quit("too many errors") end
	end

	return F
end
