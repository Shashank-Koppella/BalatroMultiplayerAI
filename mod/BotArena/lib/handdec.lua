-- BotArena hand decision layer: everything a trainer needs to LEARN how to play hands (which cards to play, which to discard).
--
-- The planner (lib/plan.lua) stays in the game as the teacher / safety net, but the hand choice itself can now be made by a
-- learned model. This module turns "I hold these 8 cards, with these jokers, against this blind" into
--     * a candidate list   - plays and discards (<= BOTARENA_HAND_MAX_OPTS, default 44), every one with numeric features ("fx"):
--                            what the play scores with my jokers, what is left in hand afterwards, what a discard keeps, how
--                            many outs the deck still has, a small Monte-Carlo estimate of what the redraw is worth, ...
--     * state features     - hands / discards left, how much of the blind is still missing, PvP score race, lives, boss, ...
--     * a decision log     - run/decisions/inst<N>.hand.jsonl, one JSON row per hand decision, stamped with the reward row it is
--                            paid in (`bidx`), in the same format as the strategic decisions so the trainer reads both.
--     * an executor        - plays / discards through lib/act.lua (the game's own buttons).
--
-- Candidates are NOT the planner's choices only: all subsets of the hand are generated (as many as the game allows), reduced to
-- equivalent classes (same scoring cards + same number of kickers), and the best-looking plus a few random ones are kept - so a
-- better idea than the planner's can be tried and learned. The planner's own pick is always in the list (it is the teacher label
-- `pl` and the fallback), and its Monte-Carlo verdict is offered as features (`pl_u`, `pl_pc`) unless BOTARENA_HAND_PLANFEAT=0
-- ("pure learning": the model sees only the game mechanics, never the planner's opinion).
return function(A)
	local U, O, X, C, P = A.util, A.obs, A.act, A.cfg, A.plan
	local H = {
		stats = { decisions = 0, logged = 0, bytes = 0, errors = 0, mc = 0, failed = 0 },
		visit = { sig = nil, bans = {} },
		cur = nil,
		seq = 0,
	}

	local LN10 = math.log(10)
	local HT = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House", "Four of a Kind", "Straight Flush",
		"Five of a Kind", "Flush House", "Flush Five" }
	local HT_IDX = {}
	for i, n in ipairs(HT) do HT_IDX[n] = i end

	local function fin(x)
		if x ~= x or x == math.huge or x == -math.huge then return 0 end
		return x
	end
	local function r3(x) return math.floor(fin(x) * 1000 + 0.5) / 1000 end
	local function num(x, d)
		local n = U.num(x)
		if n == nil then return d end
		return n
	end
	local function lg(x) return math.log(math.max(x, 0) + 1) / LN10 end

	-- private PRNG (never touches the game's RNG)
	local rs = 88172645
	local function rnd()
		rs = (rs * 1664525 + 1013904223) % 4294967296
		return rs / 4294967296
	end
	rs = ((os.time() or 1) * 31 + (C.id or 0) * 7919) % 4294967296
	if rs == 0 then rs = 1 end

	-- ---------------------------------------------------------------------------------------------
	-- goal: chips still needed to clear (nil = maximise the score), same rule the baseline gives the planner
	-- ---------------------------------------------------------------------------------------------
	function H.goal()
		local g = G.GAME or {}
		local chips = num(g.chips, 0)
		local pvp = O.in_pvp_blind() and true or false
		local info = { pvp = pvp, chips = chips }
		local need
		if not pvp then
			local bc = g.blind and num(g.blind.chips, 0) or 0
			info.blind = bc
			if bc - chips > 0 then need = bc - chips end
		else
			local e = MP and MP.GAME and MP.GAME.enemy
			local theirs = A.pvp and A.pvp.enemy_score()
			info.theirs = theirs
			info.enemy_hands = e and tonumber(e.hands) or nil
			info.enemy_done = (info.enemy_hands ~= nil and info.enemy_hands <= 0) and true or false
			if info.enemy_done and theirs then need = math.max(1, theirs - chips + 1) end
		end
		return need, info
	end

	-- ---------------------------------------------------------------------------------------------
	-- helpers over descriptors (plain tables made by P.describe)
	-- ---------------------------------------------------------------------------------------------
	local function keepworth(c)
		return c.chips + 6 * c.mult + 40 * (c.x - 1) + 40 * (c.hx - 1) + 4 * c.hm + c.e_chips + 6 * c.e_mult + 40 * (c.e_x - 1)
	end
	local function special(c)
		return (c.mult ~= 0 or c.x ~= 1 or c.hx ~= 1 or c.hm ~= 0 or c.e_chips ~= 0 or c.e_mult ~= 0 or c.e_x ~= 1 or c.lucky or c.retrig ~= 0) and 1 or 0
	end

	-- structure of a set of kept cards: pairs / trips, suited cards, straight run length
	local function structure(K)
		local rc, sc, ranks = {}, { 0, 0, 0, 0 }, {}
		for _, c in ipairs(K) do
			if not c.stone then
				rc[c.rank] = (rc[c.rank] or 0) + 1
				if c.suit >= 1 and c.suit <= 4 then sc[c.suit] = sc[c.suit] + 1 end
				ranks[c.rank] = true
			end
		end
		local grp, pairs_n, top = 0, 0, 0
		for _, n in pairs(rc) do
			if n >= 2 then grp = grp + n * n; pairs_n = pairs_n + 1 end
			if n > top then top = n end
		end
		local suit_max, suit_i = 0, 0
		for s = 1, 4 do if sc[s] > suit_max then suit_max, suit_i = sc[s], s end end
		if ranks[14] then ranks[1] = true end
		local run, best = 0, 0
		for r = 1, 14 do
			if ranks[r] then run = run + 1; if run > best then best = run end else run = 0 end
		end
		local fl = suit_max >= 3 and suit_max * suit_max or 0
		local st = best >= 3 and best ^ 1.5 or 0
		return { score = grp + 0.6 * fl + st, grp = top, pairs = pairs_n, suit = suit_max, suit_i = suit_i, run = best, ranks = rc }
	end

	local function each_subset(n, kmin, kmax, fn)
		local idx = {}
		local function rec(start, depth)
			if depth >= kmin then fn(idx, depth) end
			if depth == kmax then return end
			for i = start, n do
				idx[depth + 1] = i
				rec(i + 1, depth + 1)
			end
		end
		rec(1, 0)
	end

	local function key_idx(ids)
		return table.concat(ids, ",")
	end

	-- ---------------------------------------------------------------------------------------------
	-- the live state
	-- ---------------------------------------------------------------------------------------------
	local function live_state()
		local cards = U.cards(G.hand)
		if #cards == 0 then return nil end
		local hand = {}
		for i, c in ipairs(cards) do
			local d = P.describe(c, i)
			d.uid = i
			hand[i] = d
		end
		local deck = {}
		for i, c in ipairs(U.cards(G.deck)) do
			local d = P.describe(c)
			d.uid = 1000 + i
			deck[i] = d
		end
		local ctx = P.live_context()
		for _, list in ipairs({ hand, deck }) do
			for _, c in ipairs(list) do
				if c.hx ~= 1 or c.hm ~= 0 then ctx.held_effects = true; break end
			end
		end
		local cr = G.GAME.current_round
		local sp = G.GAME.starting_params or {}
		local S = {
			hand = hand, deck = deck, ctx = ctx,
			hands_left = num(cr.hands_left, 1), discards_left = num(cr.discards_left, 0),
			hand_limit = math.max(#hand, num(G.hand.config and G.hand.config.card_limit, #hand)),
			play_limit = math.max(1, math.min(num(sp.play_limit, 5), 5)),
			discard_limit = math.max(1, math.min(num(sp.discard_limit, 5), 5)),
		}
		ctx.hands_left, ctx.discards_left, ctx.deck_n = S.hands_left, S.discards_left, #deck
		return S
	end

	local function held_of(S, sel)
		local ctx = S.ctx
		if not (ctx.has_held or ctx.held_effects) then return nil end
		local inplay, held = {}, {}
		for _, c in ipairs(sel) do inplay[c] = true end
		for _, c in ipairs(S.hand) do if not inplay[c] then held[#held + 1] = c end end
		return held
	end

	local function best_score_of(S, cards)
		if #cards == 0 then return 0 end
		local list = P._candidates(cards, S.ctx, S.play_limit, true)
		return list[1] and list[1].score or 0
	end

	-- ---------------------------------------------------------------------------------------------
	-- candidate generation
	-- ---------------------------------------------------------------------------------------------
	local function gen_plays(S, max_n)
		local hand, ctx = S.hand, S.ctx
		local n = #hand
		local by_key = {}
		local function consider(sel)
			local name, sc = P.classify(sel, ctx)
			if name == "NULL" then return end
			local s = P.score(sel, held_of(S, sel), ctx, name, sc)
			local ids = {}
			for _, c in ipairs(sc) do ids[#ids + 1] = c.uid end
			table.sort(ids)
			local key = key_idx(ids) .. "|" .. (#sel - #sc)
			local junk = 0
			for _, c in ipairs(sel) do junk = junk + keepworth(c) end
			local cur = by_key[key]
			if not cur or s > cur.score + 1e-9 or (math.abs(s - cur.score) <= 1e-9 and junk < cur.junk) then
				local copy = {}
				for i, c in ipairs(sel) do copy[i] = c end
				by_key[key] = { sel = copy, score = s, name = name, nsc = #sc, junk = junk }
			end
		end
		if n <= 11 then
			each_subset(n, 1, S.play_limit, function(idx, k)
				local sel = {}
				for i = 1, k do sel[i] = hand[idx[i]] end
				consider(sel)
			end)
		else
			-- big hands: the structural list of the planner plus random subsets
			for _, c in ipairs(P._candidates(hand, ctx, S.play_limit, false)) do consider(c.played) end
			for _ = 1, 160 do
				local k = 1 + math.floor(rnd() * S.play_limit)
				local used, sel = {}, {}
				while #sel < k do
					local j = 1 + math.floor(rnd() * n)
					if not used[j] then used[j] = true; sel[#sel + 1] = hand[j] end
				end
				consider(sel)
			end
		end
		local list = {}
		for _, v in pairs(by_key) do list[#list + 1] = v end
		table.sort(list, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			if #a.sel ~= #b.sel then return #a.sel < #b.sel end
			return a.junk < b.junk
		end)
		-- the top by score, the best of every hand type, then a few random ones
		local out, taken, seen_name = {}, {}, {}
		local function take(v)
			if taken[v] then return end
			taken[v] = true
			out[#out + 1] = v
		end
		for i = 1, math.min(#list, math.ceil(max_n * 0.6)) do take(list[i]) end
		for _, v in ipairs(list) do
			if not seen_name[v.name] then
				seen_name[v.name] = true
				if #out < max_n then take(v) end
			end
		end
		local rest = {}
		for _, v in ipairs(list) do if not taken[v] then rest[#rest + 1] = v end end
		local extra = max_n - #out
		while extra > 0 and #rest > 0 do
			local j = 1 + math.floor(rnd() * #rest)
			take(table.remove(rest, j))
			extra = extra - 1
		end
		return out, (list[1] and list[1].score or 0)
	end

	local function gen_discards(S, max_n)
		local hand = S.hand
		local n = #hand
		local subsets = {}
		local function consider(idx, k)
			local drop, keep, ids = {}, {}, {}
			local gone = {}
			for i = 1, k do gone[idx[i]] = true; drop[i] = hand[idx[i]]; ids[i] = idx[i] end
			for i = 1, n do if not gone[i] then keep[#keep + 1] = hand[i] end end
			local st = structure(keep)
			local kb = best_score_of(S, keep)
			subsets[#subsets + 1] = { drop = drop, keep = keep, ids = ids, proxy = st.score + 2 * lg(kb) + 0.01 * rnd(), kept_best = kb }
		end
		if n <= 9 then
			each_subset(n, 1, S.discard_limit, consider)
		else
			for _ = 1, 220 do
				local k = 1 + math.floor(rnd() * S.discard_limit)
				local used, ids = {}, {}
				while #ids < k do
					local j = 1 + math.floor(rnd() * n)
					if not used[j] then used[j] = true; ids[#ids + 1] = j end
				end
				table.sort(ids)
				consider(ids, k)
			end
		end
		table.sort(subsets, function(a, b) return a.proxy > b.proxy end)
		local out = {}
		local top = math.ceil(max_n * 0.7)
		for i = 1, math.min(#subsets, top) do out[#out + 1] = subsets[i] end
		local rest = {}
		for i = top + 1, #subsets do rest[#rest + 1] = subsets[i] end
		while #out < max_n and #rest > 0 do
			local j = 1 + math.floor(rnd() * #rest)
			out[#out + 1] = table.remove(rest, j)
		end
		return out
	end

	-- ---------------------------------------------------------------------------------------------
	-- Monte-Carlo value of a redraw: keep `keep`, draw (#hand - #keep) random cards, score the best play
	-- ---------------------------------------------------------------------------------------------
	local function mc_redraw(S, keep, need, k, t_end)
		local deck = S.deck
		local m = #deck
		local draw_n = math.min(S.hand_limit - #keep, m)
		if draw_n <= 0 then return nil end
		if os.clock() > t_end then k = math.min(k, 2) end
		local sum, sumlog, clears, mx = 0, 0, 0, 0
		for _ = 1, k do
			local nh = {}
			for i, c in ipairs(keep) do nh[i] = c end
			local used = {}
			local got = 0
			while got < draw_n do
				local j = 1 + math.floor(rnd() * m)
				if not used[j] then used[j] = true; got = got + 1; nh[#nh + 1] = deck[j] end
			end
			local b = best_score_of(S, nh)
			sum = sum + b
			sumlog = sumlog + lg(b)
			if need and b >= need then clears = clears + 1 end
			if b > mx then mx = b end
		end
		H.stats.mc = H.stats.mc + k
		return { mean = sum / k, log = sumlog / k, pclear = clears / k, max = mx }
	end

	-- ---------------------------------------------------------------------------------------------
	-- building a decision
	-- ---------------------------------------------------------------------------------------------
	local function visit_sig()
		local g = G.GAME or {}
		local cr = g.current_round or {}
		return table.concat({ tostring(g.round), tostring(cr.hands_left), tostring(cr.discards_left), tostring(#(G.hand and G.hand.cards or {})) }, "|")
	end

	function H.ban(id)
		H.visit.bans[id] = (H.visit.bans[id] or 0) + 1
		H.stats.failed = H.stats.failed + 1
	end

	local function plan_result(opts)
		if opts.plan ~= nil then return opts.plan or nil end
		if opts.run_plan == false or not (C.plan_enabled and P) then return nil end
		local ok, res = pcall(P.decide, { need = opts.need })
		if ok and res and res.idx and #res.idx > 0 then return res end
		return nil
	end

	-- opts: { plan = planner result (optional), need = chips still needed (nil = maximise), ginfo = second value of H.goal() }
	-- -> dec { seq, kind = "hand", bidx, match, sx, jokers, cons, options = { {id, act, kind, key, idx, name, score, fx}, ... }, pl = 1-based planner index }
	function H.begin(opts)
		opts = opts or {}
		if not (G and G.GAME and G.hand and P and P.describe and P._candidates) then return nil end
		local need, ginfo = opts.need, opts.ginfo
		if ginfo == nil then need, ginfo = H.goal() end
		local S = live_state()
		if not S then return nil end
		local sig = visit_sig()
		if H.visit.sig ~= sig then H.visit.sig, H.visit.bans = sig, {} end
		local ctx = S.ctx
		local res = plan_result({ plan = opts.plan, need = need, run_plan = opts.run_plan })
		local max_n = math.max(8, math.floor(C.hand_max_opts or 44))
		local n_play_max = S.discards_left > 0 and #S.deck > 0 and math.floor(max_n * 0.4) or max_n
		local can_discard = S.discards_left > 0 and #S.deck > 0

		local plays, best_play = gen_plays(S, n_play_max)
		local drops = can_discard and gen_discards(S, max_n - #plays) or {}

		local options, by_id = {}, {}
		-- PvP: a lone card that is clearly weaker than the best play is a wasted hand (user 2026-10-06 15:27): not offered
		local function wasted_single(v)
			return ginfo and ginfo.pvp and (S.hands_left or 0) > 1 and #v.sel == 1 and best_play and v.score < best_play * 0.9
		end
		local function add_play(v)
			if wasted_single(v) then return nil end
			local ids = {}
			for _, c in ipairs(v.sel) do ids[#ids + 1] = c.i end
			table.sort(ids)
			local id = "play:" .. key_idx(ids)
			if by_id[id] then return by_id[id] end
			local o = { id = id, act = "play", kind = "play", key = v.name, idx = ids, sel = v.sel, name = v.name, score = v.score, nsc = v.nsc, fx = {} }
			options[#options + 1] = o
			by_id[id] = o
			return o
		end
		local function add_discard(d)
			local ids = {}
			for _, c in ipairs(d.drop) do ids[#ids + 1] = c.i end
			table.sort(ids)
			local id = "discard:" .. key_idx(ids)
			if by_id[id] then return by_id[id] end
			local o = { id = id, act = "discard", kind = "discard", key = "discard", idx = ids, sel = d.drop, keep = d.keep, kept_best = d.kept_best, fx = {} }
			options[#options + 1] = o
			by_id[id] = o
			return o
		end
		for _, v in ipairs(plays) do add_play(v) end
		for _, d in ipairs(drops) do add_discard(d) end

		-- planner candidates (and its pick) are always offered
		local pl_pick_id
		local pl_info = {}
		if res and res.idx then
			pl_pick_id = (res.action == "discard" and "discard:" or "play:") .. key_idx(res.idx)
		end
		local function from_idx(ids)
			local sel = {}
			for _, i in ipairs(ids) do if S.hand[i] then sel[#sel + 1] = S.hand[i] end end
			return sel
		end
		local function ensure(act, ids)
			local id = (act == "discard" and "discard:" or "play:") .. key_idx(ids)
			if by_id[id] then return by_id[id] end
			local sel = from_idx(ids)
			if #sel == 0 then return nil end
			if act == "discard" then
				local gone, keep = {}, {}
				for _, c in ipairs(sel) do gone[c] = true end
				for _, c in ipairs(S.hand) do if not gone[c] then keep[#keep + 1] = c end end
				return add_discard({ drop = sel, keep = keep, kept_best = best_score_of(S, keep) })
			end
			local name, sc = P.classify(sel, ctx)
			if name == "NULL" then return nil end
			local s = P.score(sel, held_of(S, sel), ctx, name, sc)
			return add_play({ sel = sel, score = s, name = name, nsc = #sc })
		end
		if res and res.info and res.info.table then
			for _, row in ipairs(res.info.table) do
				if row.idx and #row.idx > 0 then
					local o = ensure(row.action, row.idx)
					if o then pl_info[o.id] = { util = row.util, pc = row.p_clear } end
				end
			end
		end
		if res and res.idx then
			local o = ensure(res.action, res.idx)
			if o and not pl_info[o.id] then pl_info[o.id] = { util = res.util, pc = res.p_clear } end
		end

		-- drop options that failed earlier in this very hand state (never the only one)
		do
			local keep = {}
			for _, o in ipairs(options) do
				if (H.visit.bans[o.id] or 0) < 1 then keep[#keep + 1] = o end
			end
			if #keep > 0 then options = keep end
		end
		-- hard cap: planner candidates stay, random surplus of the generated ones goes
		if #options > max_n then
			local removable = {}
			for i, o in ipairs(options) do
				if not pl_info[o.id] and o.id ~= pl_pick_id then removable[#removable + 1] = i end
			end
			local drop = {}
			local surplus = #options - max_n
			while surplus > 0 and #removable > 0 do
				local j = 1 + math.floor(rnd() * #removable)
				drop[table.remove(removable, j)] = true
				surplus = surplus - 1
			end
			local keep = {}
			for i, o in ipairs(options) do if not drop[i] then keep[#keep + 1] = o end end
			options = keep
		end
		if #options == 0 then return nil end

		-- ---------------- state features
		local g = G.GAME
		local rr = g.round_resets or {}
		local sx = {}
		sx.ante = num(rr.ante, 1)
		sx.round = num(g.round, 0)
		sx.dollars = num(g.dollars, 0)
		local lives = MP and MP.GAME and num(MP.GAME.lives, nil)
		local elives = MP and MP.GAME and MP.GAME.enemy and num(MP.GAME.enemy.lives, nil)
		sx.lives = lives or 4
		sx.enemy_lives = elives or sx.lives
		sx.life_diff = sx.lives - sx.enemy_lives
		sx.n_jokers = #U.cards(G.jokers)
		if A.rules then pcall(A.rules.sx, sx) end -- deck + stake + rules (Plasma, Green's $ per hand / discard, ...)
		sx.hand_size = S.hand_limit
		sx.h_hl = S.hands_left
		sx.h_dl = S.discards_left
		sx.h_last = S.hands_left <= 1 and 1 or 0
		sx.h_deck_n = #S.deck
		sx.h_hand_n = #S.hand
		sx.h_pvp = ginfo.pvp and 1 or 0
		sx.h_chips_log = r3(lg(ginfo.chips or 0))
		sx.h_best_log = r3(lg(best_play))
		if need then
			sx.h_has_need = 1
			sx.h_need_log = r3(lg(need))
			sx.h_per_hand = r3(lg(need / math.max(1, S.hands_left)))
			sx.h_best_frac = r3(math.min(3, best_play / math.max(1, need)))
		else
			sx.h_has_need = 0
		end
		if ginfo.blind and ginfo.blind > 0 then
			sx.h_blind_log = r3(lg(ginfo.blind))
			sx.h_prog = r3(math.min(2, (ginfo.chips or 0) / ginfo.blind))
		end
		if ginfo.pvp then
			sx.h_enemy_done = ginfo.enemy_done and 1 or 0
			sx.h_enemy_hands = ginfo.enemy_hands or 0
			if ginfo.theirs then
				sx.h_theirs_log = r3(lg(ginfo.theirs))
				local d = (ginfo.chips or 0) - ginfo.theirs
				sx.h_lead = r3((d >= 0 and 1 or -1) * lg(math.abs(d)))
			end
		end
		local bl = g.blind
		sx.h_boss = (bl and bl.boss) and 1 or 0
		sx.h_hook = (bl and (bl.name == "The Hook" or (bl.config and bl.config.blind and bl.config.blind.key == "bl_hook"))) and 1 or 0
		do
			local st = structure(S.hand)
			sx.h_hand_suit = st.suit
			sx.h_hand_run = st.run
			sx.h_hand_grp = st.grp
			local suits = { 0, 0, 0, 0 }
			for _, c in ipairs(S.deck) do if c.suit >= 1 and c.suit <= 4 then suits[c.suit] = suits[c.suit] + 1 end end
			local m = 0
			for s = 1, 4 do if suits[s] > m then m = suits[s] end end
			sx.h_deck_suit_max = #S.deck > 0 and r3(m / #S.deck) or 0
		end

		-- ---------------- option features
		local plan_feat = C.hand_planfeat ~= false
		local t_end = os.clock() + (C.hand_ms or 150) / 1000
		local mc_k = math.max(1, math.floor(C.hand_mc or 6))
		local deck_n = #S.deck
		local best_log = lg(best_play)
		local rank_cnt_deck, suit_cnt_deck = {}, { 0, 0, 0, 0 }
		for _, c in ipairs(S.deck) do
			rank_cnt_deck[c.rank] = (rank_cnt_deck[c.rank] or 0) + 1
			if c.suit >= 1 and c.suit <= 4 then suit_cnt_deck[c.suit] = suit_cnt_deck[c.suit] + 1 end
		end
		local tarot_room = 0
		do
			local cons = G.consumeables
			local limit = cons and cons.config and num(cons.config.card_limit, 0) or 0
			tarot_room = math.max(0, limit - #U.cards(cons) - num(g.consumeable_buffer, 0))
		end
		for _, o in ipairs(options) do
			local fx = o.fx
			fx.n_sel = #o.idx
			if o.act == "play" then
				fx["ht_" .. HT_IDX[o.name]] = 1
				fx.sc_log = r3(lg(o.score))
				fx.sc_rel = r3(best_play > 0 and o.score / best_play or 0)
				fx.is_max = o.score >= best_play - 1e-9 and 1 or 0
				if need then
					fx.sc_frac = r3(math.min(3, o.score / math.max(1, need)))
					fx.clears = o.score >= need and 1 or 0
				end
				fx.n_scoring = o.nsc or 0
				fx.n_junk = #o.sel - (o.nsc or 0)
				local inp, rest = {}, {}
				local sp = 0
				for _, c in ipairs(o.sel) do inp[c] = true; sp = sp + special(c) end
				for _, c in ipairs(S.hand) do if not inp[c] then rest[#rest + 1] = c end end
				fx.play_special = sp
				fx.rest_log = r3(lg(best_score_of(S, rest)))
				fx.rest_gain = r3(fx.rest_log - best_log)
			else
				local keep = o.keep
				local st = structure(keep)
				fx.draw_n = #o.idx
				fx.kept_log = r3(lg(o.kept_best or 0))
				fx.k_grp, fx.k_pairs, fx.k_suit, fx.k_run = st.grp, st.pairs, st.suit, st.run
				if st.suit_i > 0 then fx.o_suit = suit_cnt_deck[st.suit_i] end
				local oranks = 0
				for r, c in pairs(st.ranks) do oranks = oranks + (rank_cnt_deck[r] or 0) * (c >= 2 and 1.5 or 1) end
				fx.o_rank = oranks
				local dchips, dworth, dspecial = 0, 0, 0
				for _, c in ipairs(o.sel) do dchips = dchips + c.chips; dworth = dworth + keepworth(c); dspecial = dspecial + special(c) end
				fx.disc_chips = dchips
				fx.disc_worth = r3(dworth)
				fx.disc_special = dspecial
				local mc = mc_redraw(S, keep, need, mc_k, t_end)
				if mc then
					fx.ev_log = r3(mc.log)
					fx.ev_gain = r3(mc.log - best_log)
					fx.ev_max = r3(lg(mc.max))
					if need then fx.ev_pclear = r3(mc.pclear) end
				end
			end
			-- seals in the selection (Purple: a Tarot when discarded, Gold: $3 when played, Blue: a Planet when HELD at round end)
			do
				local np, ng, nb = 0, 0, 0
				for _, c in ipairs(o.sel) do
					if c.seal == "Purple" then np = np + 1 elseif c.seal == "Gold" then ng = ng + 1 elseif c.seal == "Blue" then nb = nb + 1 end
				end
				if np > 0 then fx.seal_purple = np end
				if ng > 0 then fx.seal_gold = ng end
				if nb > 0 then fx.seal_blue = nb end
				if np > 0 and tarot_room > 0 then fx.tarot_room = tarot_room end
			end
			local pi = pl_info[o.id]
			if plan_feat and pi then
				fx.pl_has = 1
				if pi.util then
					local u = pi.util
					fx.pl_u = r3(need and (u / 10) or u) -- need mode: ~ -4 .. +2 ; max mode: expected score / today's best
				end
				if pi.pc then fx.pl_pc = r3(pi.pc) end
			end
			-- planner agreement is never a feature (it would make the label trivial); only the dec.pl index carries it
		end

		-- jokers / consumables (hashed by the trainer)
		local jk = {}
		for i, j in ipairs(U.cards(G.jokers)) do
			local c = j.config and j.config.center
			jk[i] = (c and c.key) or (j.ability and j.ability.name) or "?"
		end

		H.seq = H.seq + 1
		local pl_index
		for i, o in ipairs(options) do if o.id == pl_pick_id then pl_index = i end end
		-- a Purple Seal discard that keeps a clearing play in hand is a rule, not a choice (the models have never seen seals: the
		-- learner would keep playing them). The external driver plays it directly and logs it as a teacher decision.
		local forced = (pl_index and res and res.action == "discard" and type(res.tag) == "string" and res.tag:sub(1, 12) == "purple seal:") and true or nil
		local dec = {
			seq = H.seq, kind = "hand", sx = sx, jokers = jk, options = options, pl = pl_index, forced = forced,
			bidx = A.reward and A.reward.row_n or 0,
			match = A.fsm and A.fsm.match and A.fsm.match.n or nil,
			n_hand = #S.hand, need = need,
		}
		H.cur = dec
		H.stats.decisions = H.stats.decisions + 1
		return dec
	end

	-- JSON-safe copy: zero features are dropped (the trainer treats a missing feature as 0), no card references
	function H.serialize(dec)
		if not dec then return nil end
		local opts = {}
		for i, o in ipairs(dec.options) do
			local fx = {}
			for k, x in pairs(o.fx or {}) do
				if type(x) == "number" then
					if x ~= 0 then fx[k] = r3(x) end
				else
					fx[k] = x
				end
			end
			opts[i] = { id = o.id, act = o.act, kind = o.kind, key = o.key, fx = fx }
		end
		local sx = {}
		for k, x in pairs(dec.sx) do sx[k] = type(x) == "number" and r3(x) or x end
		return { seq = dec.seq, kind = "hand", bidx = dec.bidx, match = dec.match, sx = sx, jokers = dec.jokers, options = opts, pl = dec.pl and (dec.pl - 1) or nil }
	end

	-- ---------------------------------------------------------------------------------------------
	-- logging
	-- ---------------------------------------------------------------------------------------------
	local function hand_log_path()
		local p = C.decisions_path
		if not p then return nil end
		return (p:gsub("%.jsonl$", ".hand.jsonl"))
	end

	-- record the choice (index is 1-based into dec.options). src: "baseline" | "agent". extra: p, v, eps ...
	function H.commit(dec, index, src, extra)
		if not dec or not dec.options[index] then return false end
		if not C.log_decisions then return false end
		local path = hand_log_path()
		if not path then return false end
		if H.stats.bytes > (C.hand_decisions_max_mb or 600) * 1024 * 1024 then
			if not H.log_full then
				H.log_full = true
				U.warn("hand decision log reached its size cap (BOTARENA_HAND_DECISIONS_MAX_MB); no more hand decisions are recorded this session")
			end
			return false
		end
		local row = H.serialize(dec)
		row.chosen = index - 1
		row.src = src or "?"
		row.inst = C.id
		row.sess = A.session
		row.t = U.wall()
		if extra then
			if type(extra.p) == "number" then row.p = fin(extra.p) end
			if type(extra.v) == "number" then row.v = fin(extra.v) end
			if extra.eps then row.eps = extra.eps end
			if extra.ts then row.ts = extra.ts end
		end
		local s = U.encode(row)
		if not s then return false end
		U.append(path, s .. "\n")
		H.stats.bytes = H.stats.bytes + #s + 1
		H.stats.logged = H.stats.logged + 1
		return true
	end

	-- ---------------------------------------------------------------------------------------------
	-- executing / the teacher
	-- ---------------------------------------------------------------------------------------------
	function H.execute(opt, dec)
		if dec and dec.n_hand and G.hand and #G.hand.cards ~= dec.n_hand then return false, "hand changed" end
		local ok, res, info
		if opt.act == "play" then
			if P and P.expect then pcall(P.expect, opt.name, opt.score) end
			ok, res, info = pcall(X.play, opt.idx)
		elseif opt.act == "discard" then
			ok, res, info = pcall(X.discard, opt.idx)
		else
			return false, "unknown action"
		end
		if not ok then
			H.stats.errors = H.stats.errors + 1
			return false, tostring(res)
		end
		return res and true or false, info
	end

	-- the planner's pick (1-based), or the best-scoring play when there is no planner result; eps = chance of a random option
	function H.heuristic(dec, eps)
		if eps and eps > 0 and rnd() < eps then
			return 1 + math.floor(rnd() * #dec.options), true
		end
		if dec.pl then return dec.pl, false end
		local bi, bs = 1, -1e18
		for i, o in ipairs(dec.options) do
			if o.act == "play" and o.score > bs then bi, bs = i, o.score end
		end
		return bi, false
	end

	return H
end
