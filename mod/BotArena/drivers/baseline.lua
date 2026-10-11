-- Baseline driver: a simple heuristic Balatro player. It exists so the arena has something that can finish
-- real matches end to end (blind select -> play/discard -> cash out -> shop -> PvP ready ...). It is not
-- meant to be strong; swap in your own driver with BOTARENA_DRIVER=<file.lua> or the "external" driver.
--
-- Driver contract (see drivers/template.lua):
--   D.step(memo)          called only when the game is idle/settled; perform AT MOST ONE action
--   D.on_match_start(m)   optional
--   D.on_match_end(row)   optional
--   D.unstick()           optional, called when the watchdog thinks we are stuck
return function(A)
	local U, O, X, C = A.util, A.obs, A.act, A.cfg
	local D = { name = "baseline" }

	local rng_state = C.driver_seed or 1
	local function rand()
		-- tiny LCG so the driver is reproducible and independent of the game's RNG streams
		rng_state = (rng_state * 1103515245 + 12345) % 2147483648
		return rng_state / 2147483648
	end

	-- remember what we tried in the current state so we never loop on a failing action
	local function tried(memo, key, limit)
		memo.tries = memo.tries or {}
		local n = (memo.tries[key] or 0) + 1
		memo.tries[key] = n
		return n > (limit or 2)
	end

	local function reset_on_state_change(memo)
		local sig = tostring(G.STATE) .. ":" .. tostring(G.GAME and G.GAME.round) .. ":" .. tostring(G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante)
		if memo.sig ~= sig then
			memo.sig = sig
			memo.tries = {}
		end
	end

	-- ---------------------------------------------------------------------------------------------
	-- hand evaluation (shared helpers live in lib/hands.lua)
	-- ---------------------------------------------------------------------------------------------
	local function best_play()
		return A.hands.best_play(320)
	end

	local function discard_candidates(best)
		-- cards that are not part of the best hand's scoring cards, lowest rank first
		local keep = {}
		for _, c in ipairs(best.scoring or {}) do keep[c] = true end
		local out = {}
		for i, c in ipairs(G.hand.cards) do
			if not keep[c] then out[#out + 1] = { i = i, v = c.base and c.base.nominal or 0 } end
		end
		table.sort(out, function(a, b) return a.v < b.v end)
		local idx = {}
		local limit = G.GAME.starting_params and G.GAME.starting_params.discard_limit or 5
		for k = 1, math.min(#out, limit, 5) do idx[k] = out[k].i end
		return idx
	end

	local function selecting_hand(memo)
		if not G.hand or #G.hand.cards == 0 then return false end
		local best = best_play()
		if #best.idx == 0 then return false end

		-- Purple Seal cards in hand and every consumable slot taken: use / sell one first so the discard makes a Tarot (decide.lua)
		if A.decide and A.decide.make_room then
			local okr, acted = pcall(A.decide.make_room)
			if okr and acted then memo.tries = {}; return true end
		end

		local hands_left = G.GAME.current_round.hands_left or 0
		local discards_left = G.GAME.current_round.discards_left or 0
		local need = (G.GAME.blind and G.GAME.blind.chips or 0) - (G.GAME.chips or 0)
		local pvp = O.in_pvp_blind()
		if pvp then
			-- the PvP "blind" has no chip target; what we must beat is the opponent's current score
			local theirs = A.pvp and A.pvp.enemy_score()
			need = theirs and (theirs - (G.GAME.chips or 0)) or 0
		end

		-- Planner (lib/plan.lua): joker-aware scores + odds of drawing what we need from the cards left in the deck
		if C.plan_enabled and A.plan and not memo.plan_failed then
			local goal
			if not pvp then
				goal = need > 0 and need or nil
			else
				local e = MP and MP.GAME and MP.GAME.enemy
				local done = e and tonumber(e.hands) ~= nil and tonumber(e.hands) <= 0
				local theirs = A.pvp and A.pvp.enemy_score()
				-- opponent has finished: beating their score is a clear/fail question; otherwise just score as much as possible
				if done and theirs then goal = math.max(1, theirs - (G.GAME.chips or 0) + 1) end
			end
			local ok, res = pcall(A.plan.decide, { need = goal })
			if ok and res and res.idx and #res.idx > 0 then
				local pl = A.plan.last or {}
				U.info(string.format("plan: %s %s [%s] score~%s need=%s p_clear=%s hands=%d discards=%d deck=%s opts=%s",
					res.action, table.concat(res.idx, ","), tostring(res.tag), tostring(pl.score), tostring(goal and math.floor(goal) or "max"),
					tostring(res.p_clear), hands_left, discards_left, tostring(pl.deck), tostring(res.options)))
				-- learned-hands layer (lib/handdec.lua): log the candidate list with the planner's pick (the trainer's teacher data) and play
				-- the pick through the layer's executor; if that fails the planner path below plays the hand as before.
				if ok and res and res.idx and #res.idx > 0 and C.hand_decisions and A.handdec and not memo.hand_failed then
					local okh, hd = pcall(A.handdec.begin, { plan = res, need = goal })
					if okh and hd and #hd.options > 0 then
						local hi, explored = A.handdec.heuristic(hd, C.hand_eps)
						local opt = hd.options[hi]
						if opt and not tried(memo, "hd" .. opt.id, 1) then
							local okx = A.handdec.execute(opt, hd)
							if okx then
								A.handdec.commit(hd, hi, "baseline", explored and { eps = C.hand_eps } or nil)
								memo.tries = {}
								return true
							end
							A.handdec.ban(opt.id)
						end
					elseif not okh then
						memo.hand_errors = (memo.hand_errors or 0) + 1
						U.err("handdec.begin failed: " .. tostring(hd))
						if memo.hand_errors >= 5 then memo.hand_failed = true end
					end
				end
				if res.action == "discard" then
					if not tried(memo, "pdiscard", 3) and X.discard(res.idx) then
						memo.tries = {}
						return true
					end
				else
					if not tried(memo, "pplay", 4) then
						A.plan.expect(res.name, res.score)
						if X.play(res.idx) then
							memo.tries = {}
							return true
						end
					end
				end
			elseif not ok then
				A.plan.stats.errors = (A.plan.stats.errors or 0) + 1
				U.err("planner error: " .. tostring(res))
				if A.fsm and A.fsm.event then A.fsm.event("plan_error", { err = tostring(res) }) end
				if A.plan.stats.errors >= 5 then memo.plan_failed = true end
			end
		end

		-- Try to improve a weak hand with a discard when we have both discards and spare hands.
		local weak = best.text == "High Card" or best.text == "Pair"
		local want_discard = discards_left > 0
			and hands_left > 1
			and weak
			and best.score < need / math.max(1, hands_left) * (pvp and 1.2 or 0.9)
		if want_discard and not tried(memo, "discard", 3) then
			local idx = discard_candidates(best)
			if #idx > 0 then
				local ok = X.discard(idx)
				if ok then
					memo.tries = {} -- a successful action starts a fresh decision
					return true
				end
			end
		end

		if tried(memo, "play", 4) then
			-- the "best" play keeps failing; fall back to the first card
			return X.play({ 1 })
		end
		local ok = X.play(best.idx)
		if not ok then return X.play({ 1 }) end
		memo.tries = {}
		return true
	end

	-- ---------------------------------------------------------------------------------------------
	-- blind select
	-- ---------------------------------------------------------------------------------------------
	local function blind_select(memo)
		-- use planets we are holding before the next blind
		for _, card in ipairs(G.consumeables and G.consumeables.cards or {}) do
			if card.ability and card.ability.set == "Planet" and not tried(memo, "use" .. tostring(card.sort_id), 1) then
				local ok = X.use_consumable(card)
				if ok then return true end
			end
		end
		if C.skip_blinds > 0 and X.can_skip_blind() and rand() < C.skip_blinds and not tried(memo, "skip", 1) then
			local ok = X.skip_blind()
			if ok then return true end
		end
		if tried(memo, "select", 6) then return false end
		return X.select_blind()
	end

	-- ---------------------------------------------------------------------------------------------
	-- shop
	-- ---------------------------------------------------------------------------------------------
	local function joker_value(card)
		local v = 10 - math.min(card.cost or 5, 10) * 0.5
		if card.edition then
			local t = card.edition.type
			if t == "negative" then v = v + 6 elseif t == "polychrome" then v = v + 5 elseif t == "holo" then v = v + 3 elseif t == "foil" then v = v + 2 end
		end
		local r = card.config and card.config.center and card.config.center.rarity
		if type(r) == "number" then v = v + r * 2 end
		return v
	end

	local function shop(memo)
		local dollars = X.dollars_available()
		local ante = G.GAME.round_resets and G.GAME.round_resets.ante or 1
		local reserve = (ante <= 1) and 0 or math.min(15, 5 * ante) -- keep a little for interest later

		-- planets in hand are free value
		for _, card in ipairs(G.consumeables and G.consumeables.cards or {}) do
			if card.ability and card.ability.set == "Planet" and not tried(memo, "use" .. tostring(card.sort_id), 1) then
				if X.use_consumable(card) then return true end
			end
		end

		-- jokers, best value first
		local jokers = {}
		for _, card in ipairs(G.shop_jokers and G.shop_jokers.cards or {}) do
			if card.ability and card.ability.set == "Joker" then jokers[#jokers + 1] = card end
		end
		table.sort(jokers, function(a, b) return joker_value(a) > joker_value(b) end)
		for _, card in ipairs(jokers) do
			local key = "buy" .. tostring(card.sort_id)
			if card.cost <= dollars - reserve and not tried(memo, key, 1) then
				local ok = X.buy(card)
				if ok then return true end
			end
		end

		-- planet / standard packs are cheap and need no targeting
		for _, card in ipairs(G.shop_booster and G.shop_booster.cards or {}) do
			local key = card.config and card.config.center and card.config.center.key or ""
			if (key:find("celestial") or key:find("standard")) and card.cost <= dollars - reserve - 2 then
				local tkey = "pack" .. tostring(card.sort_id)
				if not tried(memo, tkey, 1) then
					local ok = X.use_shop_card(card)
					if ok then return true end
				end
			end
		end

		if not tried(memo, "leave", 5) then
			local ok = X.leave_shop()
			if ok then return true end
		end
		return false
	end

	-- ---------------------------------------------------------------------------------------------
	-- booster packs
	-- ---------------------------------------------------------------------------------------------
	local function pack(memo)
		local cards = U.cards(G.pack_cards)
		local choices = G.GAME.pack_choices or 0
		if choices > 0 and #cards > 0 and not tried(memo, "pick", 2) then
			-- pick the first card we can use without needing targets
			for _, card in ipairs(cards) do
				local set = card.ability and card.ability.set
				if set == "Planet" or set == "Joker" or set == "Default" or set == "Enhanced" then
					local ok = X.pick_pack_card(card)
					if ok then
						memo.tries["pick"] = 0 -- allow picking again in mega packs
						return true
					end
				end
			end
		end
		if not tried(memo, "skip_pack", 5) then return X.skip_pack() end
		return false
	end

	-- ---------------------------------------------------------------------------------------------
	-- strategic screens through the decision layer (lib/decide.lua): value model + decision log for the trainer
	-- ---------------------------------------------------------------------------------------------
	-- Returns true when an action was taken, false when it failed / nothing to do, nil when the layer cannot be used
	-- (the old hand-written logic above then handles the screen).
	local function strategic(memo, kind)
		if not (C.decide_heuristic and A.decide) or memo.decide_failed then return nil end
		local ok, res = pcall(function()
			local dec = A.decide.begin(kind)
			if not dec then return nil end
			local idx, explored
			if kind == "blind" and C.skip_blinds > 0 and not tried(memo, "skiproll", 1) and rand() < C.skip_blinds then
				for i, o in ipairs(dec.options) do
					if o.kind == "skip" then idx = i end
				end
			end
			if not idx then idx, _, explored = A.decide.heuristic(dec, C.decide_eps, rand) end
			local opt = dec.options[idx]
			if not opt then return nil end
			local okx, info = A.decide.execute(opt)
			if okx then
				A.decide.commit(dec, idx, "baseline", explored and { eps = C.decide_eps } or nil)
				memo.tries = {}
				return true
			end
			A.decide.ban(opt.id)
			U.debug("decide: " .. tostring(opt.id) .. " failed: " .. tostring(info))
			return false
		end)
		if not ok then
			memo.decide_errors = (memo.decide_errors or 0) + 1
			U.err("decision layer error: " .. tostring(res))
			if memo.decide_errors >= 5 then memo.decide_failed = true end
			return nil
		end
		return res
	end

	-- ---------------------------------------------------------------------------------------------
	-- dispatch
	-- ---------------------------------------------------------------------------------------------
	local PACK_STATES

	function D.step(memo)
		reset_on_state_change(memo)
		local S = G.STATES
		PACK_STATES = PACK_STATES or {
			[S.TAROT_PACK] = true,
			[S.PLANET_PACK] = true,
			[S.SPECTRAL_PACK] = true,
			[S.STANDARD_PACK] = true,
			[S.BUFFOON_PACK] = true,
			[S.SMODS_BOOSTER_OPENED or -1] = true,
		}
		local st = G.STATE
		local r
		if st == S.BLIND_SELECT then
			r = strategic(memo, "blind")
			if r ~= nil then return r end
			return blind_select(memo)
		elseif st == S.SELECTING_HAND then
			return selecting_hand(memo)
		elseif st == S.ROUND_EVAL then
			return X.cash_out()
		elseif st == S.SHOP then
			r = strategic(memo, "shop")
			if r ~= nil then return r end
			return shop(memo)
		elseif PACK_STATES[st] then
			r = strategic(memo, "pack")
			if r ~= nil then return r end
			return pack(memo)
		end
		return false
	end

	function D.unstick()
		-- try the "progress" button of whatever screen we are on
		local S = G.STATES
		if G.STATE == S.SHOP then
			X.leave_shop()
		elseif G.STATE == S.ROUND_EVAL then
			X.cash_out()
		elseif PACK_STATES[G.STATE] or U.pack_open() then
			X.skip_pack()
		end
	end

	return D
end
