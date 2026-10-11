-- BotArena decision layer: everything a trainer needs for the STRATEGIC choices (not the hands).
--
-- Hands (which cards to play / discard) are the planner's job (lib/plan.lua). The decisions in between are:
--     blind select   select / skip / ready for PvP, use planets we hold
--     shop           buy a joker / consumable / voucher / pack, reroll, sell a joker, use a consumable, leave
--     booster pack   pick card i, or skip
-- This module turns the live game into
--     * a LEGAL OPTION LIST   - every action that can be tried right now, each with numeric features ("fx"),
--     * STATE FEATURES ("sx") - ante, money, lives, jokers' joint scoring potential, deck shape, ...
--     * a DECISION LOG        - run/decisions/inst<N>.jsonl, one JSON row per decision actually taken, stamped with
--                               `bidx` = the reward row index it will be paid in (see lib/reward.lua, row.ridx), so a trainer
--                               can attach returns (blind-level rewards, discounted) to each decision.
--     * an EXECUTOR           - D.execute(option) presses the game's own buttons through lib/act.lua; failures ban the option
--                               for the rest of the visit and per-visit step caps guarantee the bot always leaves the screen.
--
-- Who chooses: the baseline driver uses D.heuristic() (a hand-written value model, logged as src "baseline"), the external
-- driver forwards the option list to your program (src "agent"). Both go through the same log, so behaviour cloning and
-- reinforcement learning read one file.
--
-- Option ids are stable strings (act:area:key:position) - the agent answers {"action":"choose","i":<0-based index>}.
return function(A)
	local U, O, X, C = A.util, A.obs, A.act, A.cfg
	local D = {
		stats = { decisions = 0, logged = 0, bytes = 0, failed = 0, capped = 0, errors = 0 },
		visit = { sig = nil, bans = {}, n = 0, rerolls = 0 },
		cur = nil, -- the pending decision (with live card references) so an agent's index can be resolved
		seq = 0,
	}

	local PACK_STATE_NAMES = { "TAROT_PACK", "PLANET_PACK", "SPECTRAL_PACK", "STANDARD_PACK", "BUFFOON_PACK", "SMODS_BOOSTER_OPENED" }
	local MAX_STEPS = C.decide_max_steps or 40
	local MAX_REROLLS = C.decide_max_rerolls or 12

	-- ---------------------------------------------------------------------------------------------
	-- small helpers
	-- ---------------------------------------------------------------------------------------------
	local function fin(x)
		if type(x) ~= "number" then return x end
		if x ~= x then return 0 end
		if x == math.huge then return 1e300 end
		if x == -math.huge then return -1e300 end
		return x
	end
	local function r3(x) return math.floor(fin(x) * 1000 + 0.5) / 1000 end
	local function num(x, d)
		local n = U.num(x)
		if n == nil then return d end
		return n
	end
	local function b2n(b) return b and 1 or 0 end

	local function in_set(list)
		local s = {}
		for _, n in ipairs(list) do s[n] = true end
		return s
	end

	-- joker families (by ability.name). They are hints for the model; the scoring value of a joker comes from the planner.
	local CAT = {
		econ = in_set({ "Golden Joker", "Rocket", "To the Moon", "Egg", "Cloud 9", "Delayed Gratification", "Satellite", "Business Card",
			"Reserved Parking", "Faceless Joker", "Credit Card", "Gift Card", "Mail-In Rebate", "To Do List", "Matador", "Midas Mask",
			"Trading Card", "Bull", "Rough Gem", "Golden Ticket", "Investment Tag", "Mr. Bones", "Ceremonial Dagger", "Penny Pincher" }),
		scaling = in_set({ "Ride the Bus", "Green Joker", "Constellation", "Hologram", "Obelisk", "Vampire", "Red Card", "Flash Card",
			"Spare Trousers", "Square Joker", "Runner", "Ice Cream", "Wee Joker", "Castle", "Madness", "Campfire", "Lucky Cat", "Glass Joker",
			"Canio", "Yorick", "Hiker", "Fortune Teller", "Throwback", "Popcorn", "Turtle Bean", "Ceremonial Dagger" }),
		retrigger = in_set({ "Hack", "Dusk", "Sock and Buskin", "Seltzer", "Hanging Chad", "Mime", "Blueprint", "Brainstorm" }),
		held = in_set({ "Baron", "Mime", "Shoot the Moon", "Raised Fist", "Blackboard", "Steel Joker", "Reserved Parking" }),
		xmult = in_set({ "Joker Stencil", "Loyalty Card", "Steel Joker", "Blackboard", "Constellation", "Madness", "Vampire", "Hologram",
			"Obelisk", "Lucky Cat", "Baseball Card", "Ancient Joker", "Cavendish", "Card Sharp", "Red Card", "Glass Joker", "The Duo", "The Trio",
			"The Family", "The Order", "The Tribe", "Photograph", "Bloodstone", "Driver's License", "Campfire", "Acrobat", "Triboulet", "Canio",
			"Yorick", "Idol", "Baron", "Flower Pot", "Seeing Double" }),
		copy = in_set({ "Blueprint", "Brainstorm" }),
		slots = in_set({ "Stuntman", "Juggler", "Troubadour", "Merry Andy", "Turtle Bean", "Burglar", "Drunkard" }),
		-- Multiplayer-mod jokers (names as shown in the mod; unknown names simply stay 0)
		-- (current ruleset: only these four exist; Defensive / Conjoined / Magnet / Speedrun are gone)
		mp = in_set({ "Pacifist", "Skip-Off", "Lets Go Gambling", "Penny Pincher" }),
	}

	-- strategy sets (docs/HANDOFF.md, Strategy G.5-G.12)
	local STRONG_ECON = in_set({ "Mail-In Rebate", "To the Moon", "Rocket", "Cloud 9", "Golden Joker", "Delayed Gratification", "Satellite", "Gift Card" })
	local STRONG_VOUCHERS = in_set({ "v_overstock_norm", "v_overstock_plus", "v_reroll_surplus", "v_reroll_glut", "v_crystal_ball", "v_omen_globe" })
	local BLIND_PAY = { Small = 3, Big = 4, Boss = 5 }
	local FACE_ECON = in_set({ "Business Card", "Reserved Parking", "Midas Mask", "Faceless Joker" })
	-- RETRIGGER jokers (user 2026-10-06 23:27): they show little on their own but are among the strongest with the right support. A retrigger
	-- repeats everything a played card does: its score, its Gold Seal $3, a Lucky card's $20 chance, a Red Seal, the jokers that fire per card.
	local RETRIG_CARD = in_set({ "Hack", "Dusk", "Sock and Buskin", "Seltzer", "Hanging Chad", "MP Hanging Chad" })
	local ON_CARD = in_set({ "Photograph", "Smiley Face", "Scary Face", "Bloodstone", "Onyx Agate", "Arrowhead", "Fibonacci", "Even Steven",
		"Odd Todd", "Walkie Talkie", "Triboulet", "Hiker", "Scholar", "Ancient Joker", "The Idol", "Rough Gem", "Greedy Joker", "Lusty Joker",
		"Wrathful Joker", "Gluttonous Joker", "8 Ball", "Lucky Cat", "Golden Ticket", "Business Card", "Hanging Chad" })
	local function is_retrig_card(card)
		local n = (card.ability and card.ability.name) or (card.config and card.config.center and card.config.center.name) or "?"
		local k = card.config and card.config.center and card.config.center.key or ""
		return RETRIG_CARD[n] or k:find("hanging_chad", 1, true) ~= nil
	end
	-- vouchers never taken (strategy G.14): Telescope / Observatory, Planet Merchant / Tycoon, Magic Trick / Illusion, Tarot Tycoon (bloats the shop)
	local NEVER_VOUCHERS = in_set({ "v_telescope", "v_observatory", "v_planet_merchant", "v_planet_tycoon", "v_magic_trick", "v_illusion", "v_tarot_tycoon" })

	local function jname(card)
		return (card.ability and card.ability.name) or (card.config and card.config.center and card.config.center.name) or "?"
	end
	local function ckey(card)
		return card.config and card.config.center and card.config.center.key or nil
	end

	local function rarity_of(card)
		local r = card.config and card.config.center and card.config.center.rarity
		if type(r) == "number" then return r end
		return 1
	end

	local EDITIONS = { "foil", "holo", "polychrome", "negative" }
	local function put_edition(fx, card)
		local t = type(card.edition) == "table" and card.edition.type or nil
		for _, e in ipairs(EDITIONS) do fx["ed_" .. e] = b2n(t == e) end
	end

	-- ---------------------------------------------------------------------------------------------
	-- screens
	-- ---------------------------------------------------------------------------------------------
	local function pack_states()
		if D._ps then return D._ps end
		D._ps = {}
		for _, n in ipairs(PACK_STATE_NAMES) do
			local id = G.STATES[n]
			if id then D._ps[id] = true end
		end
		return D._ps
	end

	-- "blind" | "shop" | "pack" | nil
	function D.kind_of_state()
		if not (G and G.STATES and G.STATE) then return nil end
		local S = G.STATES
		if G.STATE == S.BLIND_SELECT then return "blind" end
		if G.STATE == S.SHOP then return "shop" end
		if pack_states()[G.STATE] then return "pack" end
		return nil
	end

	-- visit bookkeeping: bans and step counters reset whenever the screen / round changes
	local function visit_check(kind)
		local g = G.GAME or {}
		local sig = table.concat({ tostring(kind), tostring(g.round), tostring(g.round_resets and g.round_resets.ante), tostring(G.STATE) }, "|")
		if kind == "pack" then sig = sig .. "|" .. tostring(g.pack_choices or 0) end
		-- the pack screen is a new visit after every pick; the shop keeps one visit for the whole stay
		local v = D.visit
		if v.sig ~= sig then
			if kind == "pack" and v.kind == "pack" and v.round == g.round then
				-- still the same pack: keep counters, just refresh the signature
				v.sig = sig
			else
				v.sig, v.bans, v.n, v.rerolls = sig, {}, 0, 0
			end
			v.kind, v.round = kind, g.round
		end
		return v
	end

	function D.ban(id)
		D.visit.bans[id] = (D.visit.bans[id] or 0) + 1
		D.stats.failed = D.stats.failed + 1
	end

	-- ---------------------------------------------------------------------------------------------
	-- state features
	-- ---------------------------------------------------------------------------------------------
	local function next_blind_chips()
		local ok, v = pcall(function()
			local rr = G.GAME.round_resets
			local deck = G.GAME.blind_on_deck
			local key = rr and rr.blind_choices and rr.blind_choices[deck]
			local b = key and G.P_BLINDS and G.P_BLINDS[key]
			if b and get_blind_amount then
				return get_blind_amount(rr.ante) * (b.mult or 1) * num(G.GAME.starting_params and G.GAME.starting_params.ante_scaling, 1)
			end
			return nil
		end)
		if ok then return v end
		return nil
	end

	local function deck_stats()
		local out = { n = 0, steel = 0, faces = 0, aces = 0, glass = 0, gold = 0, stone = 0, suit_max = 0, rank_max = 0, enh = 0, ed = 0, seal = 0,
			goldseal = 0, redseal = 0, lucky = 0 }
		local suits, ranks = {}, {}
		for _, c in ipairs((G and G.playing_cards) or {}) do
			out.n = out.n + 1
			local key = ckey(c)
			if key == "m_steel" then out.steel = out.steel + 1 end
			if key == "m_glass" then out.glass = out.glass + 1 end
			if key == "m_gold" then out.gold = out.gold + 1 end
			if key == "m_stone" then out.stone = out.stone + 1 end
			if key and key ~= "c_base" then out.enh = out.enh + 1 end
			if c.edition then out.ed = out.ed + 1 end
			if c.seal then out.seal = out.seal + 1 end
			if c.seal == "Gold" then out.goldseal = out.goldseal + 1 elseif c.seal == "Red" then out.redseal = out.redseal + 1 end
			if key == "m_lucky" then out.lucky = out.lucky + 1 end
			local id = c.base and c.base.id
			if id then
				if id >= 11 and id <= 13 then out.faces = out.faces + 1 end
				if id == 14 then out.aces = out.aces + 1 end
				ranks[id] = (ranks[id] or 0) + 1
				suits[c.base.suit or "?"] = (suits[c.base.suit or "?"] or 0) + 1
			end
		end
		for _, n in pairs(suits) do out.suit_max = math.max(out.suit_max, n) end
		for _, n in pairs(ranks) do out.rank_max = math.max(out.rank_max, n) end
		return out
	end

	-- how much a card-retrigger joker has to work with: jokers that fire per scoring card + the share of the deck that pays when retriggered
	-- (Gold / Red Seals, Lucky and Glass cards). ~0 = nothing to repeat, 1 = decent, 3 = a real engine.
	local function retrig_support(ds, jokers)
		local on_card, rt = 0, 0
		for _, j in ipairs(jokers or {}) do
			if ON_CARD[jname(j)] then on_card = on_card + 1 end
			if is_retrig_card(j) then rt = rt + 1 end
		end
		local n = math.max(1, ds.n or 0)
		local deck = ((ds.goldseal or 0) + (ds.redseal or 0) + (ds.lucky or 0) + 0.5 * (ds.glass or 0)) / n
		return 0.8 * on_card + 8 * deck, on_card, rt
	end

	-- Green Deck: no interest at all (G.GAME.modifiers.no_interest)
	local function no_interest()
		return G and G.GAME and G.GAME.modifiers and G.GAME.modifiers.no_interest and true or false
	end
	-- the balance the shop likes to keep: the interest cap, or a plain reserve of $10 when there is no interest to earn
	local function money_goal()
		if no_interest() then return 10 end
		return num(G.GAME and G.GAME.interest_cap, 25)
	end

	local function interest_of(dollars)
		if no_interest() then return 0 end
		local g = G.GAME or {}
		local cap = num(g.interest_cap, 25)
		local amt = num(g.interest_amount, 1)
		return math.floor(math.max(0, math.min(dollars, cap)) / 5) * amt
	end

	local function joker_list()
		return U.cards(G.jokers)
	end

	-- the shared sampled-hand set + base potential (computed once per decision)
	local function potential_base(ctx)
		if not (C.decide_potential and A.plan and A.plan.sample_hands and G.playing_cards and #G.playing_cards >= 8) then return nil end
		local size = num(G.hand and G.hand.config and G.hand.config.card_limit, 8)
		if size < 5 then size = 8 end
		local ok, samples = pcall(A.plan.sample_hands, C.decide_samples or 8, size)
		if not ok or not samples or #samples == 0 then return nil end
		local ok2, m, l = pcall(A.plan.potential, samples, joker_list())
		if not ok2 then return nil end
		ctx.samples = samples
		ctx.pot_mean, ctx.pot_log = m, l
		ctx.t_limit = U.now() + (C.decide_ms or 250) / 1000
		-- the same build inside a PvP blind (jokers like Pacifist do nothing there)
		local ok3, _, lp = pcall(A.plan.potential, samples, joker_list(), function(c2) c2.pvp = true end)
		if ok3 then ctx.pot_pvp_log = lp end
		return true
	end

	-- potential (log10 of mean best-hand score) with a different joker list / hand levels; nil when out of budget
	local function pot_with(ctx, jokers, mod)
		if not ctx.samples or U.now() > ctx.t_limit then return nil end
		local ok, m, l = pcall(A.plan.potential, ctx.samples, jokers, mod)
		if not ok then return nil end
		return m, l
	end

	local function state_features(kind, ctx)
		local g = G.GAME or {}
		local rr = g.round_resets or {}
		local sx = {}
		local ante = num(rr.ante, 1)
		local dollars = num(g.dollars, 0)
		sx.ante = ante
		sx.round = num(g.round, 0)
		sx.dollars = dollars
		sx.dollars_avail = X.dollars_available and num(X.dollars_available(), dollars) or dollars
		sx.interest_now = interest_of(dollars)
		sx.interest_room = no_interest() and 0 or math.max(0, num(g.interest_cap, 25) - dollars)
		sx.reroll_cost = num(g.current_round and g.current_round.reroll_cost, 5)
		sx.skips = num(g.skips, 0)
		local deck = g.blind_on_deck
		sx.on_deck_small = b2n(deck == "Small")
		sx.on_deck_big = b2n(deck == "Big")
		sx.on_deck_boss = b2n(deck == "Boss")
		sx.pvp_on_deck = b2n(O.pvp_on_deck())
		-- lives
		local lives = MP and MP.GAME and num(MP.GAME.lives, nil)
		local elives = MP and MP.GAME and MP.GAME.enemy and num(MP.GAME.enemy.lives, nil)
		sx.lives = lives or 4
		sx.enemy_lives = elives or sx.lives
		sx.life_diff = sx.lives - sx.enemy_lives
		if A.reward and A.reward.life_factor then sx.life_factor = r3(A.reward.life_factor(sx.lives, sx.enemy_lives)) end
		-- rounds until the next PvP boss: from ante 2 on, every boss is PvP (small, big, boss)
		local pos = ({ Small = 0, Big = 1, Boss = 2 })[deck or "Small"] or 0
		sx.blinds_to_pvp = (ante >= 2) and (2 - pos) or ((1 - ante) * 3 + 5 - pos)
		-- jokers / consumables
		local jokers = joker_list()
		sx.n_jokers = #jokers
		sx.joker_limit = num(G.jokers and G.jokers.config and G.jokers.config.card_limit, 5)
		sx.joker_free = math.max(0, sx.joker_limit - #jokers)
		sx.n_cons = U.count(G.consumeables)
		sx.cons_limit = num(G.consumeables and G.consumeables.config and G.consumeables.config.card_limit, 2)
		local fam = { econ = 0, scaling = 0, retrigger = 0, held = 0, xmult = 0, mp = 0 }
		for _, j in ipairs(jokers) do
			local n = jname(j)
			for k in pairs(fam) do if CAT[k][n] then fam[k] = fam[k] + 1 end end
		end
		for k, v in pairs(fam) do sx["jk_" .. k] = v end
		do
			local sup, on_card, rt = retrig_support(ctx.ds or deck_stats(), jokers)
			sx.rt_support = r3(sup)
			if rt > 0 then sx.jk_retrig_card = rt end
			if on_card > 0 then sx.jk_on_card = on_card end
		end
		-- deck shape
		local ds = deck_stats()
		sx.deck_n = ds.n
		if ds.n > 0 then
			sx.deck_steel = ds.steel / ds.n
			sx.deck_faces = ds.faces / ds.n
			sx.deck_suit_max = ds.suit_max / ds.n
			sx.deck_rank_max = ds.rank_max / ds.n
			sx.deck_enh = ds.enh / ds.n
			sx.deck_glass = ds.glass / ds.n
			sx.deck_gold = ds.gold / ds.n
			if ds.goldseal > 0 then sx.deck_goldseal = ds.goldseal / ds.n end
			if ds.redseal > 0 then sx.deck_redseal = ds.redseal / ds.n end
			if ds.lucky > 0 then sx.deck_lucky = ds.lucky / ds.n end
		end
		sx.hand_size = num(G.hand and G.hand.config and G.hand.config.card_limit, 8)
		sx.hands = num(rr.hands, 4)
		sx.discards = num(rr.discards, 3)
		-- what the next blind asks vs what the build can do
		local need = next_blind_chips()
		if need and need > 0 then sx.need_log = r3(math.log10(need + 1)) end
		if ctx.pot_pvp_log then sx.pot_pvp_log = r3(ctx.pot_pvp_log) end
		if ctx.pot_log then
			sx.pot_log = r3(ctx.pot_log)
			if sx.need_log then sx.pot_gap = r3(sx.need_log - ctx.pot_log) end -- >0: one best hand is not enough, needs several / better
		end
		-- strategy features ------------------------------------------------------------------------------
		sx.stake = num(g.stake, 1)
		local strong_econ = 0
		local has_idol, has_ancient = false, false
		for _, j in ipairs(jokers) do
			local n = jname(j)
			if STRONG_ECON[n] then strong_econ = strong_econ + 1 end
			if n == "The Idol" then has_idol = true end
			if n == "Ancient Joker" then has_ancient = true end
		end
		sx.jk_econ_strong = strong_econ
		-- money we expect to make in the next blind (payout + a couple of unused-hand dollars + economy jokers): the shop spends
		-- down to the point where that income refills us to the interest cap by the time the blind is cleared
		-- (Small Blind pays $0 on every stake above White; Green Deck pays $2 per unused hand and $1 per unused discard; Rental jokers charge every round)
		local rl = ctx.rl or {}
		local pay = A.rules and A.rules.blind_pay(deck or "Small", rl) or (BLIND_PAY[deck or "Small"] or 3)
		sx.income_est = pay + 2 * (rl.money_per_hand or 1) + (rl.money_per_discard or 0) * 1 + 3 * (sx.jk_econ or 0) - (rl.rental_cost or 0)
		if A.rules then A.rules.sx(sx, rl) end
		-- Hex (Ghost Deck starts with it): destroys every other joker that is not eternal
		sx.n_destroyable = math.max(0, #jokers - (rl.n_eternal or 0))
		sx.hex_others = math.max(0, sx.n_destroyable - 1)
		if sx.need_log and sx.pot_log then sx.comfort = r3(sx.pot_log + 0.45 - sx.need_log) end -- >0: the build clears the next blind with room to spare
		-- the voucher of this ante
		do
			local cr = g.current_round or {}
			local vk = cr.voucher
			if type(vk) == "table" then vk = vk[1] or vk.key end
			if type(vk) == "string" and STRONG_VOUCHERS[vk] and not (g.used_vouchers and g.used_vouchers[vk]) then
				local c = G.P_CENTERS and G.P_CENTERS[vk]
				-- crystal ball is not worth a blind once the stake is high (purple+): the Investment tag pays more
				local protected = not (vk == "v_crystal_ball" and sx.stake >= 6)
				sx.voucher_strong = protected and 1 or 0
				sx.voucher_cost = c and num(c.cost, 10) or 10
			else
				sx.voucher_strong = 0
			end
		end
		-- held-card build (steel + Baron / Mime / Shoot the Moon ...) and jokers whose current round target is lined up
		sx.held_build = b2n((sx.jk_held or 0) >= 1 and (sx.deck_steel or 0) >= 0.1)
		sx.idol_hit, sx.ancient_ok = 0, 0
		do
			local cr = g.current_round or {}
			if has_idol and type(cr.idol_card) == "table" then
				for _, c in ipairs((G and G.playing_cards) or {}) do
					local id = c.base and c.base.id
					if id == cr.idol_card.id and c.base.suit == cr.idol_card.suit and (ckey(c) ~= "c_base" or c.seal or c.edition or id >= 11) then
						sx.idol_hit = 1
						break
					end
				end
			end
			if has_ancient and type(cr.ancient_card) == "table" and ds.n > 0 then
				local cnt = 0
				for _, c in ipairs((G and G.playing_cards) or {}) do
					if c.base and c.base.suit == cr.ancient_card.suit then cnt = cnt + 1 end
				end
				if cnt / ds.n >= 0.3 then sx.ancient_ok = 1 end
			end
		end
		-- aimed hand (reward module) and its level
		if A.reward and A.reward.aimed_hand then
			local ok, name = pcall(A.reward.aimed_hand)
			if ok and name and g.hands and g.hands[name] then
				sx.aim = name
				sx.aim_level = num(g.hands[name].level, 1)
			end
		end
		return sx
	end

	-- ---------------------------------------------------------------------------------------------
	-- option builders
	-- ---------------------------------------------------------------------------------------------
	local function cost_feats(fx, card, dollars, ctx_sx)
		local cost = num(card.cost, 0)
		fx.cost = cost
		fx.money_after = dollars - cost
		fx.interest_loss = interest_of(dollars) - interest_of(dollars - cost)
		fx.sell = num(card.sell_cost, 0)
	end

	local function planet_hand(card)
		local a = card.ability
		if a and a.hand_type then return a.hand_type end
		if a and type(a.consumeable) == "table" and a.consumeable.hand_type then return a.consumeable.hand_type end
		local cfg = card.config and card.config.center and card.config.center.config
		return cfg and cfg.hand_type or nil
	end

	local function planet_feats(fx, card, ctx, aim)
		local h = planet_hand(card)
		local rec = h and G.GAME.hands and G.GAME.hands[h]
		fx.is_planet = 1
		if rec then
			fx.hand_level = num(rec.level, 1)
			fx.hand_played = num(rec.played, 0)
			fx.hand_aimed = b2n(aim == h)
			-- potential after the level-up (planets are worth what they add to the sampled best hands)
			local l_chips, l_mult = num(rec.l_chips, 0), num(rec.l_mult, 0)
			local _, p2 = pot_with(ctx, joker_list(), function(c2)
				local lv = {}
				for k, v in pairs(c2.lvl or {}) do lv[k] = v end
				local cur = lv[h] or { chips = num(rec.chips, 0), mult = num(rec.mult, 1) }
				lv[h] = { chips = cur.chips + l_chips, mult = cur.mult + l_mult, played = cur.played, played_this_round = cur.played_this_round }
				c2.lvl = lv
			end)
			if p2 and ctx.pot_log then fx.d_pot = r3(p2 - ctx.pot_log) end
		end
	end

	local function joker_feats(fx, card, ctx, jokers_with)
		local n = jname(card)
		fx.rarity = rarity_of(card)
		put_edition(fx, card)
		fx.eternal = b2n(card.ability and card.ability.eternal)
		fx.perishable = b2n(card.ability and card.ability.perishable)
		fx.rental = b2n(card.ability and card.ability.rental)
		if card.ability and card.ability.perishable then fx.perish_left = num(card.ability.perish_tally, 5) end
		if no_interest() and (n == "To the Moon") then fx.dead_econ = 1 end -- its whole job is interest
		-- Abandoned Deck has no face cards: face-triggered economy jokers never fire (unless Pareidolia makes every card a face), Ride the Bus never resets
		if ctx and ctx.rl and ctx.rl.abandoned then
			local pareidolia = false
			for _, j in ipairs(joker_list()) do if jname(j) == "Pareidolia" then pareidolia = true end end
			if n == "Pareidolia" then pareidolia = true end
			if not pareidolia and FACE_ECON[n] then fx.dead_econ = 1 end
			if n == "Ride the Bus" and not pareidolia then fx.deck_bonus = 4 end
		end
		for k, set in pairs(CAT) do fx["cat_" .. k] = b2n(set[n]) end
		if is_retrig_card(card) then
			fx.retrig_card = 1
			fx.rt_synergy = r3(math.min(3, (ctx and ctx.rt_support) or 0))
		end
		local ckk = ckey(card) or ""
		-- Lets Go Gambling and Penny Pincher are the strongest Multiplayer jokers (strategy G.16)
		fx.mp_strong = b2n(n == "Lets Go Gambling" or n == "Penny Pincher" or ckk == "j_mp_lets_go_gambling" or ckk == "j_mp_penny_pincher")
		local ab = card.ability or {}
		fx.ab_mult = num(ab.mult, 0) + num(ab.t_mult, 0)
		fx.ab_chips = num(ab.t_chips, 0) + num(ab.chips, 0)
		fx.ab_x = math.max(1, num(ab.x_mult, 1))
		if jokers_with then
			local _, p2 = pot_with(ctx, jokers_with)
			if p2 and ctx.pot_log then fx.d_pot = r3(p2 - ctx.pot_log) end
			local _, p3 = pot_with(ctx, jokers_with, function(c2) c2.pvp = true end)
			if p3 and ctx.pot_pvp_log then fx.d_pot_pvp = r3(p3 - ctx.pot_pvp_log) end
		end
	end

	local function playing_card_feats(fx, card, ds)
		local id = card.base and card.base.id or 0
		fx.is_playing = 1
		fx.rank = id
		fx.face = b2n(id >= 11 and id <= 13)
		fx.enh = b2n(ckey(card) and ckey(card) ~= "c_base")
		fx.seal = b2n(card.seal)
		fx.blue_seal = b2n(card.seal == "Blue")
		fx.lucky = b2n(ckey(card) == "m_lucky")
		fx.steel = b2n(ckey(card) == "m_steel")
		put_edition(fx, card)
	end

	-- ---------------------------------------------------------------------------------------------
	-- tarot / spectral targets (cards of the hand that a pack consumable needs highlighted)
	-- ---------------------------------------------------------------------------------------------
	-- Strategy (docs/HANDOFF.md G.9): Lucky and Steel are the best enhancements, deck fixing matters (Hanged Man removes bad cards,
	-- Death copies the best card over a bad one), all seals except Blue are strong. Each policy returns the list of hand cards
	-- to highlight, or nil when there is no sensible target (the option is then not offered).
	local function rank_of(c) return c.base and c.base.id or 0 end
	local function is_plain(c)
		local k = ckey(c)
		return (not k or k == "c_base") and not c.seal and not c.edition
	end
	local function worth(c)
		local k = ckey(c)
		local w = rank_of(c)
		if k and k ~= "c_base" then w = w + 4 end
		if c.seal then w = w + 4 end
		if c.edition then w = w + 3 end
		return w
	end
	local function sorted_hand(pred, desc)
		local out = {}
		for i, c in ipairs(U.cards(G.hand)) do
			if (not pred) or pred(c) then out[#out + 1] = { c = c, i = i, w = worth(c) } end
		end
		table.sort(out, function(a, b)
			if a.w ~= b.w then
				if desc then return a.w > b.w end
				return a.w < b.w
			end
			return a.i < b.i
		end)
		return out
	end
	local function firstn(list, n)
		local out = {}
		for i = 1, math.min(n, #list) do out[i] = list[i].c end
		return out
	end
	local SUIT_OF = { c_star = "Diamonds", c_moon = "Clubs", c_sun = "Hearts", c_world = "Spades" }
	local BEST_PLAIN = in_set({ "c_magician", "c_empress", "c_hierophant", "c_lovers", "c_justice" })
	local WORST_PLAIN = in_set({ "c_chariot", "c_devil", "c_tower" })
	local ONE_BEST_UNSEALED = in_set({ "c_deja_vu", "c_medium", "c_talisman", "c_trance" })

	local function choose_targets(key, nmax, nmin, ds)
		if not (G.hand and G.hand.cards and #G.hand.cards > 0) then return nil end
		nmax, nmin = nmax or 1, nmin or 1
		local list
		if BEST_PLAIN[key] then
			list = firstn(sorted_hand(is_plain, true), nmax)
		elseif WORST_PLAIN[key] then
			list = firstn(sorted_hand(is_plain, false), nmax)
		elseif ONE_BEST_UNSEALED[key] then
			list = firstn(sorted_hand(function(c) return not c.seal end, true), 1)
		elseif key == "c_aura" then
			list = firstn(sorted_hand(function(c) return not c.edition end, true), 1)
		elseif key == "c_cryptid" then
			list = firstn(sorted_hand(nil, true), 1)
		elseif key == "c_hanged_man" then
			if (ds.n or 0) <= 30 then return nil end -- the deck is already thin
			list = firstn(sorted_hand(function(c) return is_plain(c) and rank_of(c) <= 8 end, false), nmax)
		elseif key == "c_death" then
			-- the LEFTMOST highlighted card becomes a copy of the rightmost one: the source must sit to the right of the victim
			local hand = sorted_hand(nil, true)
			local best = hand[1]
			if best then
				local victim
				for _, e in ipairs(sorted_hand(is_plain, false)) do
					if e.i < best.i and best.w - e.w >= 4 then victim = e; break end
				end
				if victim then list = { victim.c, best.c } end
			end
		elseif key == "c_strength" then
			local counts = {}
			for _, c in ipairs((G and G.playing_cards) or {}) do counts[rank_of(c)] = (counts[rank_of(c)] or 0) + 1 end
			local cand = {}
			for i, c in ipairs(U.cards(G.hand)) do
				local r = rank_of(c)
				if r >= 2 and r <= 13 and is_plain(c) then cand[#cand + 1] = { c = c, w = (counts[r + 1] or 0) - (counts[r] or 0) * 0.5, i = i } end
			end
			table.sort(cand, function(a, b)
				if a.w ~= b.w then return a.w > b.w end
				return a.i < b.i
			end)
			list = firstn(cand, nmax)
		elseif SUIT_OF[key] then
			local share = {}
			for _, c in ipairs((G and G.playing_cards) or {}) do
				local su = c.base and c.base.suit or "?"
				share[su] = (share[su] or 0) + 1
			end
			local dom, dn = nil, 0
			for su, n in pairs(share) do if n > dn then dom, dn = su, n end end
			if dom ~= SUIT_OF[key] then return nil end -- only convert towards the suit the deck already leans to
			list = firstn(sorted_hand(function(c) return c.base and c.base.suit ~= dom end, false), nmax)
		else
			list = firstn(sorted_hand(nil, false), nmin)
		end
		if not list or #list < nmin or #list == 0 then return nil end
		return list
	end

	-- how many hand cards does this consumable want highlighted? (nil when none: it works without targets)
	local function target_counts(c)
		local cons = c.ability and c.ability.consumeable
		local cfg = c.config and c.config.center and c.config.center.config
		local mx = (type(cons) == "table" and cons.max_highlighted) or (cfg and cfg.max_highlighted)
		local mn = (type(cons) == "table" and cons.min_highlighted) or (cfg and cfg.min_highlighted) or 1
		if mx then return mx, mn end
		return nil
	end

	local function highlight_cards(cards)
		if not (G.hand and G.hand.unhighlight_all and G.hand.add_to_highlighted) then return false end
		G.hand:unhighlight_all()
		local n = 0
		for _, c in ipairs(cards) do
			for _, hc in ipairs(G.hand.cards) do
				if hc == c then
					G.hand:add_to_highlighted(c, true)
					n = n + 1
					break
				end
			end
		end
		return n == #cards
	end

	D.choose_targets, D.target_counts = choose_targets, target_counts -- (exported for the tests)

	-- `opts` is the list being built; add() applies bans
	local function builder(kind)
		local list = {}
		local v = D.visit
		local function add(o)
			o.id = o.id or table.concat({ o.act, o.area or "", o.key or "", tostring(o.pos or 0) }, ":")
			if (v.bans[o.id] or 0) >= 1 then return end
			o.fx = o.fx or {}
			list[#list + 1] = o
		end
		return list, add
	end

	local function enumerate_blind(ctx, sx)
		local list, add = builder("blind")
		local dollars = sx.dollars
		-- select / ready
		if X.blind_select_button and X.blind_select_button() then
			local pvp = O.pvp_on_deck()
			if not (pvp and MP and MP.GAME and MP.GAME.ready_blind) then
				add({ act = "select_blind", kind = "select", fx = { pvp = b2n(pvp) } })
			end
		end
		if X.can_skip_blind and X.can_skip_blind() then
			local deck = G.GAME.blind_on_deck
			local tag = G.GAME.round_resets and G.GAME.round_resets.blind_tags and G.GAME.round_resets.blind_tags[deck]
			add({ act = "skip_blind", kind = "skip", key = tag, fx = { skips = sx.skips } })
		end
		for i, c in ipairs(U.cards(G.consumeables)) do
			local ok = c.can_use_consumeable == nil or select(2, pcall(c.can_use_consumeable, c))
			if ok and c.ability and c.ability.set == "Planet" then
				local fx = {}
				planet_feats(fx, c, ctx, sx.aim)
				add({ act = "use_consumable", area = "consumables", kind = "use_planet", key = ckey(c), pos = i, card = c, fx = fx })
			end
		end
		return list
	end

	local function enumerate_shop(ctx, sx)
		local list, add = builder("shop")
		local dollars = sx.dollars
		local avail = sx.dollars_avail
		local jokers = joker_list()
		local v = D.visit

		-- shop row (jokers and consumables / playing cards share this area)
		for i, c in ipairs(U.cards(G.shop_jokers)) do
			local set = c.ability and c.ability.set
			if X.can_afford(c) and (set == "Joker" or set == "Planet" or set == "Tarot" or set == "Spectral" or set == "Default" or set == "Enhanced") then
				local space = (not X.has_space) or X.has_space(c)
				if space or set == "Joker" then -- a joker with no free slot is listed (flagged) so a swap can be valued: sell the weakest, then buy
					local fx = {}
					cost_feats(fx, c, dollars, sx)
					local kd
					if set == "Joker" then
						kd = "buy_joker"
						local with = {}
						for k, j in ipairs(jokers) do with[k] = j end
						with[#with + 1] = c
						joker_feats(fx, c, ctx, with)
					elseif set == "Planet" then
						kd = "buy_planet"
						planet_feats(fx, c, ctx, sx.aim)
					elseif set == "Tarot" or set == "Spectral" then
						kd = set == "Tarot" and "buy_tarot" or "buy_spectral"
					else
						kd = "buy_card"
						playing_card_feats(fx, c)
					end
					if not space then fx.noslot = 1 end
					add({ act = "buy", area = "shop_jokers", kind = kd, key = ckey(c), pos = i, card = c, fx = fx })
				end
			end
		end
		for i, c in ipairs(U.cards(G.shop_vouchers)) do
			if X.can_afford(c) then
				local fx = {}
				cost_feats(fx, c, dollars, sx)
				add({ act = "use_shop_card", area = "vouchers", kind = "buy_voucher", key = ckey(c), pos = i, card = c, fx = fx })
			end
		end
		for i, c in ipairs(U.cards(G.shop_booster)) do
			if X.can_afford(c) then
				local fx = {}
				cost_feats(fx, c, dollars, sx)
				local key = ckey(c) or ""
				fx.pk_celestial = b2n(key:find("celestial") ~= nil)
				fx.pk_arcana = b2n(key:find("arcana") ~= nil)
				fx.pk_spectral = b2n(key:find("spectral") ~= nil)
				fx.pk_standard = b2n(key:find("standard") ~= nil)
				fx.pk_buffoon = b2n(key:find("buffoon") ~= nil)
				fx.pk_jumbo = b2n(key:find("jumbo") ~= nil)
				fx.pk_mega = b2n(key:find("mega") ~= nil)
				add({ act = "use_shop_card", area = "boosters", kind = "open_pack", key = key, pos = i, card = c, fx = fx })
			end
		end
		-- reroll
		if v.rerolls < MAX_REROLLS and X.can_reroll and X.can_reroll() then
			local rc = sx.reroll_cost
			add({ act = "reroll", kind = "reroll", fx = { cost = rc, money_after = dollars - rc, interest_loss = interest_of(dollars) - interest_of(dollars - rc),
				rerolls_done = v.rerolls } })
		end
		-- sell a joker (never eternal ones; the game says whether it can be sold)
		for i, c in ipairs(jokers) do
			local ok = c.can_sell_card == nil or select(2, pcall(c.can_sell_card, c))
			if ok and not (c.ability and c.ability.eternal) then
				local fx = {}
				fx.sell = num(c.sell_cost, 0)
				local without = {}
				for k, j in ipairs(jokers) do if k ~= i then without[#without + 1] = j end end
				joker_feats(fx, c, ctx, without)
				if fx.d_pot then fx.d_pot = -fx.d_pot end -- "what the joker adds" (the same sign as when buying)
				if fx.d_pot_pvp then fx.d_pot_pvp = -fx.d_pot_pvp end
				fx.slot = i
				add({ act = "sell", area = "jokers", kind = "sell_joker", key = ckey(c), pos = i, card = c, fx = fx })
			end
		end
		-- consumables we hold
		for i, c in ipairs(U.cards(G.consumeables)) do
			local ok = c.can_use_consumeable == nil or select(2, pcall(c.can_use_consumeable, c))
			if ok then
				local fx = {}
				local set = c.ability and c.ability.set
				if set == "Planet" then planet_feats(fx, c, ctx, sx.aim) end
				fx.is_tarot = b2n(set == "Tarot")
				fx.is_spectral = b2n(set == "Spectral")
				add({ act = "use_consumable", area = "consumables", kind = "use_consumable", key = ckey(c), pos = i, card = c, fx = fx })
			end
		end
		add({ act = "leave_shop", kind = "leave", fx = { money = dollars, interest = interest_of(dollars) } })
		return list
	end

	local function enumerate_pack(ctx, sx)
		local list, add = builder("pack")
		local jokers = joker_list()
		local choices = num(G.GAME.pack_choices, 0)
		local cards = U.cards(G.pack_cards)
		if choices > 0 then
			for i, c in ipairs(cards) do
				local set = c.ability and c.ability.set
				local fx = {}
				local kd
				local legal = true
				local targets
				if set == "Joker" then
					kd = "pick_joker"
					legal = (not X.has_space) or X.has_space(c) or (type(c.edition) == "table" and c.edition.type == "negative")
					local with = {}
					for k, j in ipairs(jokers) do with[k] = j end
					with[#with + 1] = c
					joker_feats(fx, c, ctx, with)
				elseif set == "Planet" then
					kd = "pick_planet"
					planet_feats(fx, c, ctx, sx.aim)
				elseif set == "Tarot" or set == "Spectral" then
					kd = set == "Tarot" and "pick_tarot" or "pick_spectral"
					legal = c.can_use_consumeable == nil or select(2, pcall(c.can_use_consumeable, c, true)) and true or false
					fx.is_tarot = b2n(set == "Tarot")
					fx.is_spectral = b2n(set == "Spectral")
					if not legal then
						-- needs highlighted hand cards: pick targets by policy; they are highlighted just before the card is used
						local mx, mn = target_counts(c)
						if mx then
							local ok, list = pcall(choose_targets, ckey(c), mx, mn, ctx.ds)
							if ok and list then
								targets = list
								legal = true
								fx.tgt = #list
							end
						end
					end
				elseif set == "Default" or set == "Enhanced" then
					kd = "pick_card"
					playing_card_feats(fx, c)
				else
					legal = false
				end
				if legal then
					fx.choices_left = choices
					add({ act = "pick_pack", area = "pack", kind = kd, key = ckey(c), pos = i, card = c, targets = targets, fx = fx })
				end
			end
		end
		add({ act = "skip_pack", kind = "skip_pack", fx = { choices_left = choices, n_cards = #cards } })
		return list
	end

	-- ---------------------------------------------------------------------------------------------
	-- building a decision
	-- ---------------------------------------------------------------------------------------------
	-- Returns the decision table { kind, bidx, sx, jokers, options } (options carry live card refs under .card) or nil when the
	-- screen is not a strategic one. After MAX_STEPS actions in one visit only the "move on" option is offered.
	function D.begin(kind)
		kind = kind or D.kind_of_state()
		if not kind or not (G and G.GAME) then return nil end
		local v = visit_check(kind)
		local ctx = {}
		ctx.ds = deck_stats()
		ctx.rt_support = retrig_support(ctx.ds, joker_list())
		ctx.rl = (A.rules and A.rules.live()) or {}
		potential_base(ctx)
		local sx = state_features(kind, ctx)
		local list
		if kind == "blind" then list = enumerate_blind(ctx, sx)
		elseif kind == "shop" then list = enumerate_shop(ctx, sx)
		else list = enumerate_pack(ctx, sx) end
		if v.n >= MAX_STEPS then
			local keep = {}
			for _, o in ipairs(list) do
				if o.act == "leave_shop" or o.act == "skip_pack" or o.act == "select_blind" or o.act == "skip_blind" then keep[#keep + 1] = o end
			end
			if #keep > 0 then list = keep end
			D.stats.capped = D.stats.capped + 1
		end
		if #list == 0 then return nil end
		if kind == "shop" and (sx.joker_free or 0) <= 0 then
			-- best joker we could buy if a slot were free: drives the "sell the weakest joker" option (strategy G.13)
			local sx_free = {}
			for k2, v2 in pairs(sx) do sx_free[k2] = v2 end
			sx_free.joker_free = 1
			local best_v
			for _, o in ipairs(list) do
				if o.kind == "buy_joker" and o.fx.noslot == 1 then
					local okv, v2 = pcall(D.value, o, sx_free)
					if okv and type(v2) == "number" and (not best_v or v2 > best_v) then best_v = v2 end
				end
			end
			if best_v then sx.swap_v = r3(best_v) end
		end
		for _, o in ipairs(list) do
			local okv, hv = pcall(D.value, o, sx)
			if okv and type(hv) == "number" then o.fx.h = r3(math.max(-100, math.min(100, hv))) end
		end
		D.seq = D.seq + 1
		local jk = {}
		for i, j in ipairs(joker_list()) do jk[i] = ckey(j) or jname(j) end
		local cons = {}
		for i, c in ipairs(U.cards(G.consumeables)) do cons[i] = ckey(c) or "?" end
		local dec = {
			seq = D.seq, kind = kind, sx = sx, jokers = jk, cons = cons, options = list,
			bidx = A.reward and A.reward.row_n or 0,
			match = A.fsm and A.fsm.match and A.fsm.match.n or nil,
			visit_n = v.n,
		}
		D.cur = dec
		D.stats.decisions = D.stats.decisions + 1
		return dec
	end

	-- JSON-safe copy of a decision (no card references), what goes into the log and into snap.dec
	function D.serialize(dec)
		if not dec then return nil end
		local opts = {}
		for i, o in ipairs(dec.options) do
			local fx = {}
			for k, x in pairs(o.fx or {}) do fx[k] = type(x) == "number" and r3(x) or x end
			opts[i] = { id = o.id, act = o.act, area = o.area, kind = o.kind, key = o.key, pos = o.pos, fx = fx }
		end
		local sx = {}
		for k, x in pairs(dec.sx) do sx[k] = type(x) == "number" and r3(x) or x end
		return { seq = dec.seq, kind = dec.kind, bidx = dec.bidx, match = dec.match, sx = sx, jokers = dec.jokers, cons = dec.cons, options = opts, visit_n = dec.visit_n }
	end

	-- ---------------------------------------------------------------------------------------------
	-- logging
	-- ---------------------------------------------------------------------------------------------
	local function log_row(row)
		if not (C.log_decisions and C.decisions_path) then return false end
		if D.stats.bytes > (C.decisions_max_mb or 400) * 1024 * 1024 then
			if not D.log_full then
				D.log_full = true
				U.warn("decision log reached its size cap (BOTARENA_DECISIONS_MAX_MB); no more decisions are recorded this session")
			end
			return false
		end
		local s = U.encode(row)
		if not s then return false end
		U.append(C.decisions_path, s .. "\n")
		D.stats.bytes = D.stats.bytes + #s + 1
		D.stats.logged = D.stats.logged + 1
		return true
	end

	-- record the choice (index is 1-based into dec.options). src: "baseline" | "agent". extra: p, v, ... from the agent
	function D.commit(dec, index, src, extra)
		if not dec or not dec.options[index] then return false end
		local v = D.visit
		v.n = v.n + 1
		if dec.options[index].act == "reroll" then v.rerolls = v.rerolls + 1 end
		local row = D.serialize(dec)
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
		return log_row(row)
	end

	-- ---------------------------------------------------------------------------------------------
	-- executing
	-- ---------------------------------------------------------------------------------------------
	function D.execute(opt)
		local act, card = opt.act, opt.card
		local ok, res, info
		if act == "select_blind" then ok, res, info = pcall(X.select_blind)
		elseif act == "skip_blind" then ok, res, info = pcall(X.skip_blind)
		elseif act == "buy" then ok, res, info = pcall(X.buy, card)
		elseif act == "use_shop_card" then ok, res, info = pcall(X.use_shop_card, card)
		elseif act == "reroll" then ok, res, info = pcall(X.reroll)
		elseif act == "sell" then ok, res, info = pcall(X.sell, card)
		elseif act == "use_consumable" then ok, res, info = pcall(X.use_consumable, card)
		elseif act == "pick_pack" then
			if opt.targets then
				local hok = pcall(highlight_cards, opt.targets)
				local usable = hok and (card.can_use_consumeable == nil or select(2, pcall(card.can_use_consumeable, card, true)))
				if not usable then
					if G.hand and G.hand.unhighlight_all then pcall(G.hand.unhighlight_all, G.hand) end
					return false, "targets rejected"
				end
			end
			ok, res, info = pcall(X.pick_pack_card, card)
		elseif act == "skip_pack" then ok, res, info = pcall(X.skip_pack)
		elseif act == "leave_shop" then ok, res, info = pcall(X.leave_shop)
		else return false, "unknown action" end
		if not ok then
			D.stats.errors = D.stats.errors + 1
			return false, tostring(res)
		end
		return res and true or false, info
	end

	-- ---------------------------------------------------------------------------------------------
	-- baseline recording: the hand-written driver tells us what it is about to do
	-- ---------------------------------------------------------------------------------------------
	-- pick: function(option) -> true for the option the baseline chose. Never throws.
	function D.record_pick(dec, pick, src)
		local ok, err = pcall(function()
			if not dec then return end
			for i, o in ipairs(dec.options) do
				if pick(o) then
					D.commit(dec, i, src or "baseline")
					return
				end
			end
		end)
		if not ok then D.stats.errors = D.stats.errors + 1 end
	end

	-- ---------------------------------------------------------------------------------------------
	-- the hand-written value model ("heuristic teacher")
	-- ---------------------------------------------------------------------------------------------
	-- Values are in dollars-ish units. Strategy encoded here (docs/HANDOFF.md, Strategy G.1-G.12, the user's own rules):
	--   * SKIPS: bad in general. Ante 1 only: Investment tag ($25 after the boss) and Rare tag (free rare joker), unless a strong
	--     economy joker is owned or a strong voucher (Overstock, Reroll Surplus, Crystal Ball, Omen Globe) could not be bought
	--     without this blind. Later antes only when the joker conditions are lined up (Idol hit our best card, Ancient on our suit,
	--     Juggle tag for a held-card build).
	--   * EARLY GAME = ECONOMY: scoring jokers only as far as the next blind needs them (comfort), economy jokers first.
	--   * INTEREST: spend so that the blind's income refills us to the cap; the shop before PvP may spend a little more.
	--   * REROLLS: barely, and never with so little money that a Blueprint-class joker could not be bought afterwards.
	--   * PACKS: Spectral always (last dollars of the visit), Buffoon second, Arcana when money > $15 (Hermit), Standard when
	--     there is money to spare; picks: Lucky / Steel / deck fixing (Hanged Man, Death), seals (not Blue), Wraith/Immolate/...
	-- `h` (this value) is also logged as option feature "h" so the learned policy starts from the teacher.
	local TAROT_V = {
		c_magician = 7, c_chariot = 6.5, c_death = 5.5, c_hanged_man = 5, c_empress = 4, c_hierophant = 3.5, c_lovers = 3.5,
		c_devil = 3, c_tower = 2.5, c_justice = 3, c_strength = 2, c_temperance = 3.5, c_wheel_of_fortune = 3, c_judgement = 4.5,
		c_fool = 2.5, c_emperor = 3, c_high_priestess = 3, c_star = 1.5, c_moon = 1.5, c_sun = 1.5, c_world = 1.5,
	}
	local SPECTRAL_V = {
		c_wraith = 8.5, c_cryptid = 7, c_deja_vu = 7, c_medium = 6.5, c_immolate = 7, c_talisman = 8, c_ectoplasm = 4, c_soul = 14,
		c_black_hole = 10, c_aura = 5, c_familiar = 4, c_grim = 4.5, c_incantation = 3.5, c_sigil = 1.5, c_ouija = 2, c_trance = 3,
		c_ankh = 2, c_hex = 4,
	}

	-- ---------------------------------------------------------------------------------------------
	-- Purple Seal needs a free consumable slot (user 2026-10-06 23:27: "if tarot slots are full the bot should learn to either use or sell
	-- tarots to then discard a purple seal and generate more tarots")
	-- ---------------------------------------------------------------------------------------------
	-- Called by the drivers on the hand screen. When Purple Seal cards sit in the hand, every consumable slot is taken and the planner WOULD
	-- discard them (with one slot free), this makes the room: it USES a Planet or an untargeted Tarot (the effect is not lost), else SELLS the
	-- least valuable held consumable (only when it is worth clearly less than the random Tarot the discard makes). One action per call;
	-- returns true when it acted (the driver ends its step). At most 4 per round.
	D._room = { sig = nil, n = 0 }
	function D.make_room()
		if not (G and G.STATES and G.STATE == G.STATES.SELECTING_HAND and G.hand and G.GAME and G.GAME.current_round) then return false end
		local cr = G.GAME.current_round
		if (cr.discards_left or 0) <= 0 or #U.cards(G.deck) == 0 then return false end
		local cons = G.consumeables
		if not (cons and cons.config) then return false end
		local limit = num(cons.config.card_limit, 0)
		local held = U.cards(cons)
		if limit <= 0 or #held + num(G.GAME.consumeable_buffer, 0) < limit then return false end
		local np = 0
		for _, c in ipairs(U.cards(G.hand)) do
			if c.seal == "Purple" and not c.debuff then np = np + 1 end
		end
		if np == 0 then return false end
		local sig = tostring(G.GAME.round) .. ":" .. tostring(G.GAME.round_resets and G.GAME.round_resets.ante)
		if D._room.sig ~= sig then D._room = { sig = sig, n = 0 } end
		if D._room.n >= 4 then return false end
		if not (A.plan and A.plan.decide) then return false end
		-- the planner decides whether discarding the Purple cards is right (it may want to play them to clear the blind)
		local need
		if A.handdec and A.handdec.goal then
			local okg, nd = pcall(A.handdec.goal)
			if okg then need = nd end
		end
		local ok, res = pcall(A.plan.decide, { need = need, tarot_slots = 1 })
		if not ok or not res or res.action ~= "discard" then return false end
		local wants = false
		for _, c in ipairs(res.cards or {}) do if c.seal == "Purple" then wants = true end end
		if not wants then return false end
		-- 1) use something: Planets and Tarots that need no target (can_use_consumeable is false for the ones that want highlighted cards)
		local dollars = num(G.GAME.dollars, 0)
		for _, c in ipairs(held) do
			local set = c.ability and c.ability.set
			local key = ckey(c)
			local usable = c.can_use_consumeable == nil or select(2, pcall(c.can_use_consumeable, c))
			if usable and (set == "Planet" or set == "Tarot") and not (key == "c_hermit" and dollars < 15) then
				D._room.n = D._room.n + 1
				local okx, done = pcall(X.use_consumable, c)
				if okx and done then
					U.info("make_room: used " .. tostring(key) .. " to free a slot for a Purple Seal discard")
					return true
				end
			end
		end
		-- 2) sell the weakest one when it is worth less than the Tarot we get (a random Tarot ~ 3.3 in TAROT_V units)
		local worst, worst_v
		for _, c in ipairs(held) do
			local key = ckey(c)
			local set = c.ability and c.ability.set
			local kv = (set == "Spectral") and (SPECTRAL_V[key] or 3) or (TAROT_V[key] or 2)
			if set == "Planet" then kv = 2.5 end
			local sellable = c.can_sell_card == nil or select(2, pcall(c.can_sell_card, c))
			if sellable and (not worst_v or kv < worst_v) then worst, worst_v = c, kv end
		end
		if worst and worst_v < 2.5 then
			D._room.n = D._room.n + 1
			local okx, done = pcall(X.sell, worst)
			if okx and done then
				U.info("make_room: sold " .. tostring(ckey(worst)) .. " to free a slot for a Purple Seal discard")
				return true
			end
		end
		return false
	end

	local function interest_val(x)
		if no_interest() then return 0 end
		local g = G.GAME or {}
		local cap = num(g.interest_cap, 25)
		return math.floor(math.max(0, math.min(x, cap)) / 5) * num(g.interest_amount, 1)
	end

	-- interest we really give up by spending: money we would have at the end of the next blind anyway is not lost
	local function eff_loss(fx, sx)
		local d = sx.dollars or 0
		local after = fx.money_after or d
		local inc = sx.income_est or 6
		return math.max(0, interest_val(d + inc) - interest_val(after + inc))
	end

	local DOUBLE_TAG_V = {
		tag_rare = 9.5, tag_negative = 9.5, tag_voucher = 9, tag_investment = 9, tag_economy = 8, tag_buffoon = 7, tag_orbital = 5,
		tag_charm = 4, tag_meteor = 4, tag_ethereal = 4, tag_standard = 3, tag_uncommon = 5.5, tag_polychrome = 5, tag_holo = 4.5, tag_foil = 4,
	}

	local function skip_value(o, sx)
		if C.decide_skips == false then return -8 end
		local key = o.key
		local ante = sx.ante or 1
		-- Anaglyph Deck: a Double Tag is waiting, so the tag of this skip comes twice
		if (sx.r_double_tags or 0) > 0 and not ((sx.n_jokers or 0) < 1 and (sx.skips or 0) >= 1) then
			local dv = DOUBLE_TAG_V[key]
			if key == "tag_economy" then dv = (sx.dollars or 0) >= 15 and 8 or 3 end
			if dv and dv >= 5 then return dv end
		end
		if ante <= 1 then
			if (sx.n_jokers or 0) < 1 and (sx.skips or 0) >= 1 then return -8 end -- one skip is enough with an empty board
			if key == "tag_investment" then
				if (sx.jk_econ_strong or 0) > 0 then return -4 end -- a strong economy joker already makes the money
				if (sx.voucher_strong or 0) == 1 and (sx.dollars or 0) < (sx.voucher_cost or 10) then return -4 end -- need this blind to afford the voucher
				return 9
			elseif key == "tag_rare" then
				if (sx.voucher_strong or 0) == 1 and (sx.dollars or 0) < (sx.voucher_cost or 10) then return -4 end
				return 8
			end
			return -8
		end
		-- later: only when a build condition would be lost by playing the blind
		if ante >= 3 then
			if (sx.idol_hit or 0) == 1 then return 4 end
			if (sx.ancient_ok or 0) == 1 then return 4 end
			if key == "tag_juggle" and (sx.held_build or 0) == 1 then return 5 end
		end
		return -8
	end

	-- shared by joker purchases and joker pack picks
	-- scoring potential of a joker: the non-PvP part saturates (Small / Big / ante-1 boss only have to be CLEARED, extra score there pays nothing,
	-- so a x10 that works only outside PvP like Pacifist is worth little more than a x3) and PvP counts for most (user 2026-10-06 15:27)
	local function blended_dpot(fx)
		local np = fx.d_pot or 0
		if np > 0.5 then np = 0.5 end
		return 0.35 * np + 0.65 * (fx.d_pot_pvp or fx.d_pot or 0)
	end

	local function joker_value(fx, sx)
		local ante = sx.ante or 1
		local early = ante <= 3 and 1 or 0
		-- early: only as much scoring as the next blind needs (the planner potential says how comfortable we are)
		local sw = 1
		if early == 1 and sx.comfort and (sx.pvp_on_deck or 0) ~= 1 then
			if sx.comfort >= 0.3 then sw = 0.3 elseif sx.comfort >= 0 then sw = 0.65 end
		end
		local dp = blended_dpot(fx)
		-- economy jokers: protected in the early game, less so mid game, the first to go late when the scoring lineup is strong (G.13)
		local econ_w = ante <= 3 and 8 or (ante <= 5 and 3 or 0)
		local v = sw * (55 * dp + (fx.rarity or 1) * 1.5) + 4 * (fx.ed_negative or 0) + 3 * (fx.ed_polychrome or 0) * sw + 2 * (fx.ed_holo or 0) * sw
			+ 1.5 * (fx.ed_foil or 0) * sw
		v = v + econ_w * (fx.cat_econ or 0) + 6 * (fx.mp_strong or 0) + (1.5 + early * 1.5) * (fx.cat_scaling or 0) + 1.5 * (fx.cat_xmult or 0) * sw + 1 * (fx.cat_retrigger or 0) * sw
		if (fx.dead_econ or 0) == 1 then v = v - econ_w end
		v = v + (fx.deck_bonus or 0)
		-- retrigger jokers: the planner's potential only sees the score of today's cards; the money (Gold Seal $3, Lucky $20) and the
		-- jokers that fire per card are worth much more with support, and a second retrigger joker multiplies the first (user 2026-10-06 23:27)
		if (fx.retrig_card or 0) == 1 then
			local sup = math.min(3, fx.rt_synergy or sx.rt_support or 0)
			local others = math.min(2, sx.jk_retrig_card or 0)
			local late = ante >= 7 and 0.6 or 1
			v = v + late * (2.5 + 4.5 * sup + 1.5 * others * math.min(1, sup))
		end
		-- stickers (Black / Gold / Spectral+ stakes)
		if (fx.perishable or 0) == 1 then
			-- debuffed after `perish_left` more rounds (5 when new): worth only the rounds it still works, and it blocks a slot for good until sold
			local left = fx.perish_left or 5
			if left <= 0 then return -30 end
			v = v * (0.1 + 0.07 * math.min(left, 5)) - 2
		end
		if (fx.rental or 0) == 1 then v = v - 5 * (sx.r_rental_rate or 3) end -- $3 at the end of every round, about five rounds before it is replaced anyway
		if (fx.eternal or 0) == 1 then
			-- never sellable: a weak one clogs a slot forever, any one removes the freedom to swap it for something better
			v = v - 5
			if blended_dpot(fx) < 0.02 then v = v - 8 end
			if (sx.joker_limit or 5) - (sx.r_eternal_n or 0) <= 3 then v = v - 5 end
		end
		return v
	end

	function D.value(o, sx)
		local fx = o.fx or {}
		local ante = sx.ante or 1
		local desperate = (sx.lives or 4) <= 2 and 1 or 0
		local k = o.kind
		local interest_w = 2.0 - desperate * 1.0
		if (sx.pvp_on_deck or 0) == 1 then interest_w = interest_w - 0.8 end -- the shop before PvP: spend a little more
		local loss = eff_loss(fx, sx)
		if k == "leave" or k == "select" then return 0.5 end
		if k == "skip_pack" then return 0.5 end
		if k == "skip" then return skip_value(o, sx) end
		if k == "buy_joker" or k == "pick_joker" then
			local v = joker_value(fx, sx)
			if (sx.joker_free or 0) <= 0 and k == "buy_joker" then v = v - 100 end -- no slot: pointless
			if k == "pick_joker" then return v - 1 end
			return v - (fx.cost or 0) - interest_w * loss - 1
		end
		if k == "buy_planet" or k == "pick_planet" or k == "use_planet" then
			local v = (fx.hand_aimed or 0) == 1 and 7 or 2.5
			v = v + 30 * (fx.d_pot or 0)
			if k == "use_planet" then return v + 3 end
			if k == "pick_planet" then return v end
			-- early game: jokers and deck fixing first. Buy planets only when levels are needed to beat the blinds, or when the money is there
			-- (what is left after the purchase still fills the interest cap)  (strategy G.15)
			if ante <= 3 and not ((sx.comfort or 1) < 0 or (fx.money_after or 0) >= money_goal()) then v = v - 8 end
			return v - (fx.cost or 0) - interest_w * loss
		end
		if k == "buy_voucher" then
			local base = 13 -- anything not listed as bad: take it (a voucher costs about $10)
			local key = o.key or ""
			if NEVER_VOUCHERS[key] then return -50 end
			if (sx.r_no_interest or 0) == 1 and (key == "v_seed_money" or key == "v_money_tree") then return -50 end -- they raise the interest cap
			if key == "v_overstock_norm" or key == "v_overstock_plus" or key == "v_reroll_surplus" or key == "v_reroll_glut" or key == "v_omen_globe" then base = 17
			elseif key == "v_crystal_ball" then base = 15 end
			return base - (fx.cost or 0) - interest_w * loss
		end
		if k == "open_pack" then
			local w = interest_w
			local v
			if (fx.pk_spectral or 0) == 1 then
				v = 12 -- always open one; it is picked last (see D.heuristic) so it takes the money that is left
				w = 0.5
			elseif (fx.pk_buffoon or 0) == 1 then
				v = 8.5
			elseif (fx.pk_arcana or 0) == 1 then
				if (sx.dollars or 0) > 15 then
					v = 10 -- above $15: open Arcana first (a Hermit doubles up to $20)
					w = 0.5
				else
					v = 3.5
				end
			elseif (fx.pk_standard or 0) == 1 then
				-- strong if there is money to keep afterwards and the deck does not already hold the strong cards
				if (fx.money_after or 0) >= 10 then v = 6 - 4 * math.min(1, (sx.deck_enh or 0) * 2) else v = 1 end
			elseif (fx.pk_celestial or 0) == 1 then
				v = 4.5
				if ante <= 3 and not ((sx.comfort or 1) < 0 or (fx.money_after or 0) >= money_goal()) then v = v - 8 end
			else
				v = 3
			end
			if (fx.pk_mega or 0) == 1 or (fx.pk_jumbo or 0) == 1 then v = v + 2 end
			return v - (fx.cost or 0) - w * loss - 1
		end
		if k == "buy_tarot" or k == "buy_spectral" or k == "buy_card" then return -5 end
		if k == "pick_tarot" then
			local key = o.key or ""
			local v = TAROT_V[key] or 2
			if key == "c_hermit" then v = 3 + 0.5 * math.min(sx.dollars or 0, 20) end
			if (fx.tgt or 0) > 0 then v = v + 0.2 end
			return v
		end
		if k == "pick_spectral" then
			local key = o.key or ""
			local v = SPECTRAL_V[key] or 3
			if key == "c_hex" then
				-- the pick is used at once: only worth it as the lone joker (a free Polychrome), never with a board to lose
				if (sx.n_destroyable or 0) == 1 then v = 9 else v = -40 end
			end
			if key == "c_wraith" then
				v = v - 0.4 * (sx.dollars or 0) -- Wraith sets the money to $0
				if ante >= 4 and (sx.n_jokers or 0) >= 4 then v = v - 5 end -- a stable lineup is not worth risking
			end
			if key == "c_immolate" and (sx.deck_n or 52) <= 32 then v = v - 3 end
			return v
		end
		if k == "pick_card" then
			local v = 0.8 + 0.8 * ((fx.ed_polychrome or 0) + (fx.ed_holo or 0) + (fx.ed_foil or 0))
			v = v + 2 * (fx.enh or 0) + 3 * (fx.seal or 0) * (1 - 0.7 * (fx.blue_seal or 0))
			if (fx.lucky or 0) + (fx.steel or 0) > 0 then v = v + 1.5 end
			return v
		end
		if k == "use_consumable" then
			-- Hermit doubles the money (max +$20): keep it until the bank is worth doubling, then use it. Everything else: use it.
			if o.key == "c_hermit" then
				if (sx.dollars or 0) >= 15 then return 4 end
				return -3
			end
			-- Hex (Ghost Deck's starting card): Polychrome on a random joker, every OTHER joker that is not eternal is destroyed.
			-- With exactly one joker it is a free x1.5 (use it before buying the next one); with more it would wipe the board.
			if o.key == "c_hex" then
				if (sx.hex_others or 0) == 0 then return 30 end
				return -60
			end
			return 1
		end
		if k == "reroll" then
			-- barely, and only with money that interest would not have paid for; never down to a balance that cannot buy a Blueprint
			local thr = 25
			if (sx.pvp_on_deck or 0) == 1 then thr = 15 end
			if ante >= 5 then thr = thr - 5 end
			if (fx.money_after or 0) >= thr then return 1 - 0.45 * (fx.rerolls_done or 0) end
			return -10
		end
		if k == "sell_joker" then
			-- a Perishable joker whose rounds are up is debuffed for good: it only blocks the slot
			if (fx.perishable or 0) == 1 and (fx.perish_left or 1) <= 0 then return 4 end
			-- a Rental joker that is not worth its $3 a round (joker_value already charges it)
			if (fx.rental or 0) == 1 then
				local keep = joker_value(fx, sx)
				if keep < 0 then return math.min(6, 1 + 0.2 * -keep) end
			end
			-- full board and a better joker is on offer: sell the one worth least to us (least scoring early, economy jokers late)
			if (sx.joker_free or 0) <= 0 and sx.swap_v and sx.swap_v > 1 then
				local keep = joker_value(fx, sx)
				local gain = sx.swap_v - keep + 0.15 * (fx.sell or 0)
				if gain > 1.5 then return 0.5 + gain end
			end
			-- otherwise only jokers that are net harmful (negative potential contribution)
			local dp = blended_dpot(fx)
			if dp < -0.02 then return 1.5 + 55 * -dp end
			return -20
		end
		return -50
	end

	-- the index (1-based) of the option the heuristic prefers; deterministic except for optional epsilon-random exploration
	-- Spectral packs are "late": they are opened with the money that is left once nothing else in the shop is worth buying.
	function D.heuristic(dec, eps, rand)
		local best, bi = -1e9, nil
		local best_early, bi_early = -1e9, nil
		for i, o in ipairs(dec.options) do
			local v = D.value(o, dec.sx)
			if v > best then best, bi = v, i end
			if not (o.kind == "open_pack" and o.fx and o.fx.pk_spectral == 1) and v > best_early then best_early, bi_early = v, i end
		end
		if bi_early and best_early >= 3 and bi ~= bi_early then best, bi = best_early, bi_early end
		if eps and eps > 0 and rand and rand() < eps then
			-- explore: any option except selling / rerolling / skipping at random (those make bad data), the move-on option stays reachable
			local pool = {}
			for i, o in ipairs(dec.options) do
				if o.kind ~= "sell_joker" and o.kind ~= "reroll" and o.kind ~= "skip" and not (o.fx and o.fx.noslot == 1) then pool[#pool + 1] = i end
			end
			if #pool > 0 then return pool[1 + math.floor(rand() * #pool)], best, true end
		end
		return bi, best, false
	end

	return D
end
