-- BotArena reward accounting.
--
-- One reward per BLIND, paid when the blind is over (at "Cash Out", or at match end if the match stops
-- first). The module only watches the game (it wraps a few game functions and calls the originals
-- untouched); drivers never have to call it. Everything is exposed three ways:
--   * run/results/rewards<ID>.jsonl  one JSON row per finished blind (components + total) - read this to audit
--   * A.reward.snapshot()            totals / last blind / live counters (also inside obs.snapshot().reward)
--   * A.reward.pop()                 rewards finished since the last pop (what an external trainer wants)
--
-- ---------------------------------------------------------------------------------------------------
-- WHAT IS REWARDED
-- ---------------------------------------------------------------------------------------------------
-- "Value generation" during a blind (all of it counted from the moment the blind is selected until Cash Out):
--     money      $ gained while the blind is played (jokers, gold cards, ...) plus the Cash Out payout
--                except the parts that do not depend on the bot: the blind's base reward, the comeback bonus,
--                and the "$ per unused hand/discard" rows (hands have their own weight below).
--                Selling cards is NOT money generation (it just converts assets to cash).
--     tarots     Tarot cards that appear in the consumable slots (created by jokers, tags, other consumables;
--                bought cards and pack picks happen in the shop, outside the blind, and do not count)
--     spectrals  same for Spectral cards (the strongest value, weighted highest)
--     planets    same for Planet cards; a planet for a hand type the bot is AIMING at is worth planet_aimed. The aim is
--                the hand type with the best projected score under the bot's JOKERS (see R.aimed_hand): e.g. with
--                The Family (x4 on four of a kind) that is Four of a Kind, and Five of a Kind / Flush Five count too.
--     hands      unused hands when the blind is beaten (NON-PvP blinds only: PvP pays nothing for them)
--
-- Selling is neutral: sale proceeds are not generation, but the interest / purchases they enable are, and a joker
-- that was worth more than its sale price shows up as lower scores and failed blinds.
--
-- Small / Big / (ante-1) Boss blinds, i.e. every non-PvP blind:
--     beaten      reward = value generated                       (money + tarots + spectrals + unused hands)
--     not beaten  reward = -fail  (flat: only "cleared or not" counts, never by how much; fail_shortfall is 0 by default)
--     value generated on a failed blind is NOT paid: you must beat the blind first.
--
-- PvP blinds (outcome = win / loss / tie from the server's life changes, see below):
--     win         + pvp_win + pvp_margin * (doublings ahead, capped)          <- higher score = more reward
--     loss        - pvp_loss - pvp_loss_margin * (doublings behind, capped)   <- losing is the worst outcome, losing big worse
--     (both)      + pvp_value_scale * value                                 <- value still counts, no hands
--     hopeless    value at pvp_hopeless_value_scale instead (no win/margin bonus; the loss terms stay)
--     skips       each skipped Small/Big pays -skip_penalty at once (no shop, no blind of value). At the next PvP, if
--                 the bot's score margin vs the opponent IMPROVED compared with the previous PvP, the skips taken in
--                 between are credited skip_credit per doubling of improvement (capped).
--     "Hopeless" = when the bot played its LAST hand of the blind, even an optimistic estimate could not reach
--     the opponent's score: hands_left * best_hand * hopeless_slack <= opponent_score - my_score, where
--     best_hand is the largest per-hand score seen this blind or in the previous blinds, or the base-value
--     estimate of the best hand available now. Without any evidence (nothing played yet and nothing seen
--     before) the blind is never called hopeless. Winning always cancels hopeless.
--
-- All weights live in R.W below; override them with BOTARENA_REWARD="money=1,tarot=3,..." (arena.config.json:
-- "reward": { "money": 1, ... }).
return function(A)
	local U, O, C = A.util, A.obs, A.cfg
	local R = {
		installed = false,
		hooks = {},
		cur = nil, -- the blind being played, nil between blinds
		pending = {}, -- finished blinds not yet pop()ed
		total = 0,
		blinds = 0,
		match_total = 0,
		match_blinds = 0,
		last = nil,
		prev_best = { 0, 0 }, -- best single-hand score of the last two finished blinds (for "hopeless")
		sales = {}, -- sell_cost values whose money is about to arrive via ease_dollars
		skips_pending = {}, -- skips taken since the last PvP blind: { {blind=, tag=, ante=} }
		prev_margin = 0, -- score margin (doublings, signed) of the previous PvP blind
		skip_total = 0,
		row_n = 0, -- rows (blinds + skips) booked so far in this match: decisions are stamped with it so a trainer can attach returns
	}

	-- ---------------------------------------------------------------------------------------------
	-- weights
	-- ---------------------------------------------------------------------------------------------
	R.W = {
		-- value generation, per unit
		money = 1.0, -- per $
		tarot = 4.0, -- per Tarot created into the consumable slots
		spectral = 7.0, -- per Spectral created (strongest value generation)
		planet = 1.0, -- per Planet created ...
		planet_aimed = 5.0, -- ... or this much when it levels the hand type the bot is aiming at
		hands = 1.5, -- per unused hand on a beaten non-PvP blind
		-- non-PvP blinds
		fail = 30.0, -- flat penalty for not beating a Small / Big / ante-1 Boss blind (it costs a life)
		fail_shortfall = 0.0, -- + this x (1 - chips/target). 0 = off (user 2026-10-06 13:37: a blind is cleared or it is not, the score margin never matters). Set > 0 only to make near misses hurt less
		-- PvP blinds
		pvp_win = 40.0, -- paid for winning
		pvp_loss = 70.0, -- charged for losing (the main goal of the game; 60 until 2026-10-06 13:54, raised slightly on request)
		pvp_margin = 4.0, -- win bonus per DOUBLING of score lead (2x = 1 doubling; PvP scores end up close, so a fine scale) ...
		pvp_margin_cap = 4.0, -- ... up to this many doublings
		pvp_loss_margin = 14.0, -- extra loss penalty per doubling of score deficit (12 until 2026-10-06 13:54) ...
		pvp_loss_margin_cap = 6.0, -- ... up to this many doublings
		-- lives: losing a PvP hurts more the fewer lives you have and the more you trail (comeback money makes the
		-- leader richer in the shop):  factor = 0.6 + life_low * (4 / my_lives) + life_rel * clamp(enemy_lives - my_lives, -2, 3)
		-- 4v4 = 1.0, 1v4 = 2.65, 2v1 = 1.25, 4v1 = 0.7. 0 for life_low and life_rel switches the scaling off (factor 1).
		life_low = 0.4,
		life_rel = 0.15,
		life_win_mirror = 0.5, -- a win is worth 1 + this x (factor - 1) of its normal bonus (winning from behind matters more)
		pvp_value_scale = 1.0, -- value generation counts this much in PvP (strategy G.10: PvP should make as much money as possible while playing the best hand) ...
		pvp_hopeless_value_scale = 1.0, -- ... and this much once beating the opponent was impossible
		pvp_hopeless_keeps_loss = 1, -- 1: a lost-and-hopeless PvP still pays the loss terms (credit for how you got there)
		hopeless_slack = 2.0, -- optimism factor on the per-hand potential when judging "impossible"
		-- the whole match (user 2026-10-06 13:54: "a giant enormous payout for winning the entire game by dropping your opponent to 0 lives")
		match_win = 400.0, -- booked as its own row at match end when the opponent is at 0 lives (10x a PvP win); an opponent that merely left pays nothing
		-- value generated vs the opponent (same blind, checked once BOTH bots have finished it; see R.settle)
		rel_flat = 0.0, -- flat part of the penalty for generating strictly less value than the opponent in the same blind (was 3 until 2026-10-06 14:14) ...
		rel_per = 1.0, -- ... plus this per point of value behind: the penalty grows with HOW MUCH less value it generated (was 0.5) ...
		rel_cap = 0.0, -- ... at most this much (0 = no cap; was 12)
		rel_pvp = 1, -- 1: PvP blinds are compared too (value only, not the result); 0: Small / Big / boss only
		-- skipping Small / Big blinds
		skip_penalty = 10.0, -- charged at once for each skip (no shop, no blind to generate value in)
		skip_penalty_good = 2.0, -- ante 1 Investment / Rare tag skip (strategy G.6): the tag pays the cost back, so it is nearly free
		ante_base = 0.8, -- PvP loss terms x (ante_base + ante_slope x (ante - 2)), capped at ante_max: a loss at ante 6-8 hurts more (final build, strategy G.5)
		ante_slope = 0.08,
		ante_max = 1.3,
		skip_credit = 15.0, -- paid at the next PvP per doubling the score margin vs the opponent improved since the last PvP
		skip_credit_cap = 40.0, -- upper bound of that credit per PvP
		-- what counts as "money generated"
		count_base_reward = 0, -- 1: also count the blind's base payout and the comeback bonus
	}
	for k, v in pairs(C.reward or {}) do
		if R.W[k] ~= nil and type(v) == "number" then R.W[k] = v end
	end

	local function clamp(x, lo, hi)
		if x < lo then return lo end
		if x > hi then return hi end
		return x
	end

	-- JSON-safe number: NaN -> nil, +-inf -> +-1e308, otherwise rounded to 2 decimals (large values untouched)
	local function round2(x)
		if type(x) ~= "number" then return x end
		if x ~= x then return nil end
		if x == math.huge or x == -math.huge then return x > 0 and 1e308 or -1e308 end
		if math.abs(x) >= 1e12 then return x end
		return math.floor(x * 100 + 0.5) / 100
	end

	local function clean(v)
		if type(v) == "number" then return round2(v) end
		if type(v) == "table" then
			local out = {}
			for k, x in pairs(v) do out[k] = clean(x) end
			return out
		end
		return v
	end

	-- ---------------------------------------------------------------------------------------------
	-- blind lifecycle
	-- ---------------------------------------------------------------------------------------------
	local function lives_now()
		return MP and MP.GAME and tonumber(MP.GAME.lives) or nil
	end

	local function enemy_lives_now()
		local e = MP and MP.GAME and MP.GAME.enemy
		return e and tonumber(e.lives) or nil
	end

	-- multiplier for PvP loss terms from the lives situation (see R.W.life_low)
	function R.life_factor(me, enemy)
		if not me then return 1 end
		if R.W.life_low == 0 and R.W.life_rel == 0 then return 1 end
		me = clamp(me, 1, 8)
		enemy = clamp(enemy or me, 0, 8)
		local f = 0.6 + R.W.life_low * (4 / me) + R.W.life_rel * clamp(enemy - me, -2, 3)
		if R.W.life_low == 0 then f = 1 + R.W.life_rel * clamp(enemy - me, -2, 3) end
		return math.max(0.3, f)
	end

	function R.open(kind)
		local g = G.GAME
		R.cur = {
			kind = kind,
			ante = g.round_resets and g.round_resets.ante or nil,
			round = g.round,
			t0 = U.now(),
			dollars0 = U.num(g.dollars) or 0,
			lives0 = lives_now(),
			enemy_lives0 = enemy_lives_now(),
			target = nil,
			failed = false,
			closed = false,
			money_play = 0,
			tarots = 0,
			spectrals = 0,
			planets = 0,
			planets_aimed = 0,
			aim = nil,
			rows = {},
			best_hand = 0,
			hands_seen = 0,
			last_chips = U.num(g.chips) or 0,
			hopeless = false,
			assess = {},
		}
		return R.cur
	end

	-- A blind was selected (called from the select_blind wrapper, before the game runs its own handler so
	-- effects that fire on selection - Cartomancer & co - are inside the window).
	function R.on_blind_select(e)
		if not (G and G.GAME) then return end
		if R.cur and not R.cur.closed then
			-- should not happen (a blind is closed at Cash Out); keep the books clean anyway
			U.warn("reward: previous blind was never closed; discarding it")
			R.cur.closed = true
		end
		local pvp = O.pvp_on_deck()
		local deck = G.GAME.blind_on_deck
		local kind = pvp and "pvp" or string.lower(tostring(deck or "blind"))
		R.open(kind)
	end

	function R.on_dollars(mod)
		local B = R.cur
		if not B or B.closed or R.in_cash_out then return end
		local d = U.num(mod)
		if not d or d <= 0 then return end
		-- proceeds of a sale are announced by on_sell first; they are asset conversion, not generation
		for i, v in ipairs(R.sales) do
			if v == d then
				table.remove(R.sales, i)
				return
			end
		end
		B.money_play = B.money_play + d
	end

	-- Rental jokers: the game takes $ rental_rate per rental joker at the end of every round (before Cash Out): money destroyed by the build
	function R.on_rental(card)
		local B = R.cur
		if not B or B.closed or not (card and card.ability and card.ability.rental) then return end
		local rate = U.num(G.GAME and G.GAME.rental_rate) or 3
		B.money_play = B.money_play - rate
		B.rental_paid = (B.rental_paid or 0) + rate
	end

	function R.on_sell(card)
		local B = R.cur
		if not B or B.closed then return end
		local c = card and U.num(card.sell_cost)
		if c and c > 0 then
			R.sales[#R.sales + 1] = c
			if #R.sales > 20 then table.remove(R.sales, 1) end
		end
	end

	-- ---------------------------------------------------------------------------------------------
	-- "which hand type is the bot aiming at?" (decides which planets are worth planet_aimed)
	-- ---------------------------------------------------------------------------------------------
	-- Joker-aware projection: for every hand type H,
	--     chips = level chips + sum(t_chips of jokers whose condition type is contained in H)
	--     mult  = level mult  + sum(t_mult  ...)       then x every matching joker's x_mult
	--     projected(H) = chips * mult * feasibility(H)
	-- Jolly/Zany/Mad/Crazy/Droll (t_mult), Sly/Wily/Clever/Devious/Crafty (t_chips) and The Duo/Trio/Family/Order/
	-- Tribe (x_mult) all carry `ability.type` = the hand they need, and "contains" works the way SMODS evaluates
	-- it (a set of N-or-more cards): a Family (4oak) is also triggered by Five of a Kind and Flush Five.
	-- feasibility = how reachable the hand is: a rough prior (Pair .95 ... Flush Five .0008) or the share of hands
	-- the bot has actually played of that type, whichever is higher.
	-- The AIMED SET is the best hand plus, when a joker boosts it, every hand that also triggers that joker and
	-- scores at least as much per hand ("4 of a kind or higher": 4oak, 5oak, Flush Five for The Family).
	local CONTAINS = {
		["High Card"] = { "High Card" },
		["Pair"] = { "Pair" },
		["Two Pair"] = { "Two Pair", "Pair" },
		["Three of a Kind"] = { "Three of a Kind", "Pair" },
		["Straight"] = { "Straight" },
		["Flush"] = { "Flush" },
		["Full House"] = { "Full House", "Three of a Kind", "Two Pair", "Pair" },
		["Four of a Kind"] = { "Four of a Kind", "Three of a Kind", "Pair" },
		["Straight Flush"] = { "Straight Flush", "Straight", "Flush" },
		["Five of a Kind"] = { "Five of a Kind", "Four of a Kind", "Three of a Kind", "Pair" },
		["Flush House"] = { "Flush House", "Full House", "Three of a Kind", "Two Pair", "Pair", "Flush" },
		["Flush Five"] = { "Flush Five", "Five of a Kind", "Four of a Kind", "Three of a Kind", "Pair", "Flush" },
	}
	local FEASIBLE = {
		["High Card"] = 1.0, ["Pair"] = 0.95, ["Two Pair"] = 0.5, ["Three of a Kind"] = 0.3, ["Straight"] = 0.15,
		["Flush"] = 0.2, ["Full House"] = 0.12, ["Four of a Kind"] = 0.04, ["Straight Flush"] = 0.008,
		["Five of a Kind"] = 0.002, ["Flush House"] = 0.002, ["Flush Five"] = 0.0008,
	}

	-- jokers that pay for a hand type: { {type=, t_chips=, t_mult=, x_mult=} }
	local function type_jokers()
		local out = {}
		local cards = G and G.jokers and G.jokers.cards or {}
		for _, j in ipairs(cards) do
			local a = j.ability
			if a and not j.debuff and type(a.type) == "string" and CONTAINS[a.type] then
				local tc, tm, xm = U.num(a.t_chips) or 0, U.num(a.t_mult) or 0, U.num(a.x_mult) or 1
				if tc ~= 0 or tm ~= 0 or xm > 1 then out[#out + 1] = { type = a.type, t_chips = tc, t_mult = tm, x_mult = xm } end
			end
		end
		return out
	end

	local function contains(hand, t)
		for _, c in ipairs(CONTAINS[hand] or {}) do
			if c == t then return true end
		end
		return false
	end

	-- score of one hand under the jokers (skipping joker `skip` if given)
	local function joker_score(h, name, jokers, skip)
		local chips, mult, x = U.num(h.chips) or 0, U.num(h.mult) or 1, 1
		for _, j in ipairs(jokers) do
			if j ~= skip and contains(name, j.type) then
				chips = chips + j.t_chips
				mult = mult + j.t_mult
				x = x * j.x_mult
			end
		end
		return chips * mult * x
	end

	-- -> best hand name | nil, aimed set { [name] = true }, details
	function R.aimed_hand()
		local hands = G and G.GAME and G.GAME.hands
		if type(hands) ~= "table" then return nil, {}, {} end
		local jokers = type_jokers()
		local total = 0
		for _, h in pairs(hands) do total = total + (type(h) == "table" and U.num(h.played) or 0) end
		local best, best_p, scores = nil, -1, {}
		for name, h in pairs(hands) do
			if type(h) == "table" and CONTAINS[name] then
				local share = total > 0 and ((U.num(h.played) or 0) / total) or 0
				local feas = math.max(FEASIBLE[name] or 0.01, share)
				local sc = joker_score(h, name, jokers)
				scores[name] = sc
				local proj = sc * feas
				if proj > best_p or (proj == best_p and best and name < best) then best, best_p = name, proj end
			end
		end
		if not best then return nil, {}, {} end
		local set = { [best] = true }
		-- the joker that boosts the best hand the most defines "or higher"
		local trig, gain = nil, 1.0
		for _, j in ipairs(jokers) do
			if contains(best, j.type) then
				local without = joker_score(hands[best], best, jokers, j)
				local g = without > 0 and (scores[best] / without) or 2
				if g > gain then trig, gain = j.type, g end
			end
		end
		if trig then
			for name, sc in pairs(scores) do
				if contains(name, trig) and sc >= scores[best] then set[name] = true end
			end
		end
		return best, set, { projected = best_p, trigger = trig, scores = scores }
	end

	local function planet_hand(card)
		local a = card.ability
		if a and a.hand_type then return a.hand_type end
		local cfg = card.config and card.config.center and card.config.center.config
		return cfg and cfg.hand_type or nil
	end

	function R.on_emplace(area, card)
		local B = R.cur
		if not B or B.closed or not card or area ~= G.consumeables then return end
		local set = card.ability and card.ability.set
		if set == "Tarot" then B.tarots = B.tarots + 1
		elseif set == "Spectral" then B.spectrals = B.spectrals + 1
		elseif set == "Planet" then
			B.planets = B.planets + 1
			local aim, set = R.aimed_hand()
			local ph = planet_hand(card)
			if aim and ph and set[ph] then
				B.planets_aimed = B.planets_aimed + 1
				B.aim = aim
			end
		end
	end

	-- A Small / Big blind was skipped (hooked before the game runs the skip). Paid at once as its own row.
	function R.on_skip(e)
		if not (G and G.GAME) then return end
		local deck = G.GAME.blind_on_deck
		local tags = G.GAME.round_resets and G.GAME.round_resets.blind_tags
		local tag = tags and deck and tags[deck] or nil
		if type(tag) == "table" then tag = tag.key or tag.name end
		local row = {
			kind = "skip",
			ante = G.GAME.round_resets and G.GAME.round_resets.ante or nil,
			round = G.GAME.round,
			blind = deck and string.lower(tostring(deck)) or nil,
			tag = tag and tostring(tag) or nil,
		}
		local pen = R.W.skip_penalty
		if (row.ante or 1) <= 1 and (tostring(row.tag) == "tag_investment" or tostring(row.tag) == "tag_rare") then pen = R.W.skip_penalty_good end
		row.parts = { skip = round2(-pen) }
		row.reward = round2(-pen)
		R.skips_pending[#R.skips_pending + 1] = { blind = row.blind, tag = row.tag, ante = row.ante }
		R.skip_total = R.skip_total + 1
		R.record(row, "skip", true)
	end

	function R.on_eval_row(config)
		local B = R.cur
		if not B or B.closed or type(config) ~= "table" or not config.name then return end
		local d = U.num(config.dollars) or 0
		B.rows[config.name] = (B.rows[config.name] or 0) + d
	end

	function R.on_fail_round()
		local B = R.cur
		if B and not B.closed and B.kind ~= "pvp" then B.failed = true end
	end

	-- ---------------------------------------------------------------------------------------------
	-- per-frame bookkeeping
	-- ---------------------------------------------------------------------------------------------
	local PLAYING = nil
	local function playing_states()
		if not PLAYING then
			local S = G.STATES
			PLAYING = { [S.SELECTING_HAND] = true, [S.HAND_PLAYED] = true, [S.DRAW_TO_HAND] = true }
		end
		return PLAYING
	end

	function R.tick()
		if not R.installed then R.install() end
		-- the partner may finish its blind after us: look again every couple of seconds
		local now = U.now()
		if R.ledger and now - (R.t_settle or 0) >= 2 then
			R.t_settle = now
			pcall(R.settle)
		end
		local B = R.cur
		if not B or B.closed or not (G and G.GAME) then return end
		-- the chip target is only trustworthy once the new blind object exists (until then G.GAME.blind is the
		-- PREVIOUS blind) and before Multiplayer overwrites it with -1 to let a failed blind roll on
		if not B.target and playing_states()[G.STATE] and G.GAME.blind then
			local n = U.num(G.GAME.blind.chips)
			if n and n > 0 and B.kind ~= "pvp" then B.target = n end
		end
		-- score of each hand, sampled when the game is idle so scoring has finished
		if playing_states()[G.STATE] and O.settled() and G.GAME.current_round then
			local hp = G.GAME.current_round.hands_played or 0
			local chips = U.num(G.GAME.chips) or 0
			if hp > B.hands_seen then
				local delta = chips - B.last_chips
				B.hands_seen = hp
				if delta > B.best_hand then B.best_hand = delta end
			end
			B.last_chips = chips
		end
	end

	-- ---------------------------------------------------------------------------------------------
	-- "is beating the opponent still possible?"
	-- ---------------------------------------------------------------------------------------------
	-- -> feasible (bool), detail (table). Evaluated right before each hand is played in a PvP blind.
	function R.assess_pvp(B)
		local P = A.pvp
		local mine = U.num(G.GAME.chips) or 0
		local theirs = P and P.enemy_score() or nil
		local hl = G.GAME.current_round and G.GAME.current_round.hands_left or 0
		local d = { hand = B.hands_seen + 1, mine = mine, theirs = theirs, hands_left = hl }
		if not P or not P.enemy_known() or theirs == nil then d.why = "no_info"; return true, d end
		if mine > theirs then d.why = "ahead"; return true, d end
		local cap = math.max(B.best_hand or 0, R.prev_best[1], R.prev_best[2])
		local now = A.hands and A.hands.best_estimate and A.hands.best_estimate() or 0
		if now > cap then cap = now end
		d.cap = cap
		if cap <= 0 then d.why = "no_estimate"; return true, d end
		local need = theirs - mine
		local reach = hl * cap * R.W.hopeless_slack
		d.need, d.reach = need, reach
		if reach > need then d.why = "reachable"; return true, d end
		d.why = "unreachable"
		return false, d
	end

	function R.before_play()
		local B = R.cur
		if not B or B.closed or B.kind ~= "pvp" then return end
		local ok, feasible, detail = pcall(R.assess_pvp, B)
		if not ok then return end
		B.hopeless = not feasible
		if #B.assess < 12 then B.assess[#B.assess + 1] = detail end
	end

	-- ---------------------------------------------------------------------------------------------
	-- finishing a blind
	-- ---------------------------------------------------------------------------------------------
	local EXCLUDED_ROWS = { hands = true, discards = true }

	local function cashout_money(B)
		local total = B.cashout_total or 0
		local base = 0
		for name, v in pairs(B.rows) do
			if EXCLUDED_ROWS[name] then base = base + v end
			if R.W.count_base_reward == 0 and (name == "blind1" or name == "comeback") then base = base + v end
		end
		return math.max(0, total - base)
	end

	-- forced = nil | { won = bool }: used when the match ends before the blind could be cashed out
	function R.compute(B, forced)
		local W = R.W
		-- the last hand may still be animating (so never sampled as 'settled') when the round ends
		if G and G.GAME and G.GAME.current_round then
			local hp = G.GAME.current_round.hands_played or 0
			if hp > B.hands_seen then B.hands_seen = hp end
		end
		local row = {
			kind = B.kind,
			ante = B.ante,
			round = B.round,
			secs = round2(U.now() - B.t0),
			target = B.target,
			hands_played = B.hands_seen,
			best_hand = B.best_hand,
		}
		-- deck / stake rules (lib/rules.lua): Green Deck pays $ per unused DISCARD (that row is excluded from the cash-out money above, so it is added
		-- here, in PvP too), the hands row scales with $ per hand, Rental jokers charge $ at the end of every round (booked negative by on_rental)
		local lv = A.rules and A.rules.live() or {}
		local mph, mpd = lv.money_per_hand or 1, lv.money_per_discard or 0
		local disc_money = mpd * (B.discards_left_end or 0)
		local money = B.money_play + cashout_money(B) + disc_money
		row.money = round2(money)
		if disc_money ~= 0 then row.discard_money = disc_money end
		if (B.rental_paid or 0) ~= 0 then row.rental_paid = B.rental_paid end
		row.tarots, row.spectrals, row.planets = B.tarots, B.spectrals, B.planets
		row.planets_aimed, row.aim = B.planets_aimed, B.aim
		local chips_end = B.chips_end or (U.num(G.GAME and G.GAME.chips) or 0)
		row.chips = chips_end
		local value = W.money * money + W.tarot * B.tarots + W.spectral * B.spectrals
			+ W.planet * (B.planets - B.planets_aimed) + W.planet_aimed * B.planets_aimed
		local parts = {}

		if B.kind ~= "pvp" then
			local unused = B.hands_left_end or 0
			local beaten = (not B.failed) and (B.target == nil or chips_end >= B.target)
			row.beaten = beaten
			row.unused_hands = unused
			local hands_val = W.hands * mph * unused -- (a Green Deck hand is worth $2 at the cash-out, so 2x the weight)
			row.gen = round2(value + hands_val) -- value generated, compared with the opponent's by R.settle
			if beaten then
				parts.value = value + hands_val
			else
				local short = 1
				if B.target and B.target > 0 then short = 1 - clamp(chips_end / B.target, 0, 1) end
				parts.fail = -W.fail
				if W.fail_shortfall ~= 0 then parts.shortfall = -W.fail_shortfall * short end
			end
		else
			local P = A.pvp
			local mine = chips_end
			local theirs = P and P.enemy_score() or nil
			local lives_before, lives_after = B.lives0, lives_now()
			local lost = lives_before ~= nil and lives_after ~= nil and lives_after < lives_before
			if forced and forced.won ~= nil then lost = lost or (forced.won == false) end
			if not lost and theirs and mine < theirs and (B.hands_left_end or 0) <= 0 then lost = true end
			local won = (not lost) and theirs ~= nil and mine > theirs
			if forced and forced.won == true then won = true; lost = false end
			row.outcome = won and "win" or (lost and "loss" or "tie")
			row.my_score, row.enemy_score = mine, theirs
			local hopeless = B.hopeless and not won
			row.hopeless = hopeless
			if #B.assess > 0 then row.last_assess = B.assess[#B.assess] end
			-- signed score margin in doublings (2x = 1.0); unknown opponent score -> 0
			local d = 0
			if theirs ~= nil then d = U.log1p2(mine) - U.log1p2(theirs) end
			row.margin = round2(clamp(d, -6, 6))
			local lf = R.life_factor(B.lives0, B.enemy_lives0)
			row.lives_me, row.lives_enemy, row.life_factor = B.lives0, B.enemy_lives0, round2(lf)
			local af = clamp(W.ante_base + W.ante_slope * ((B.ante or 2) - 2), W.ante_base, W.ante_max)
			row.ante_factor = round2(af)
			local function loss_terms()
				parts.outcome = -W.pvp_loss * lf * af
				parts.margin = -W.pvp_loss_margin * lf * af * clamp(-d, 0, W.pvp_loss_margin_cap)
			end
			local wf = 1 + W.life_win_mirror * (lf - 1)
			if hopeless then
				parts.value = W.pvp_hopeless_value_scale * value
				if lost and W.pvp_hopeless_keeps_loss ~= 0 then loss_terms() end
			else
				if won then
					parts.outcome = W.pvp_win * wf
					parts.margin = W.pvp_margin * wf * clamp(d, 0, W.pvp_margin_cap)
				elseif lost then
					loss_terms()
				else
					parts.outcome = 0
				end
				parts.value = W.pvp_value_scale * value
			end
			-- skips since the previous PvP are credited when the margin vs the opponent got better
			local n_skips = #R.skips_pending
			if n_skips > 0 then
				row.skips = n_skips
				local gain = row.margin - (R.prev_margin or 0)
				row.margin_gain = round2(gain)
				if gain > 0 then parts.skip_credit = math.min(W.skip_credit_cap, W.skip_credit * gain) end
			end
		end

		local total = 0
		for k, v in pairs(parts) do
			parts[k] = round2(v)
			total = total + v
		end
		row.parts = parts
		row.reward = round2(total)
		return clean(row)
	end

	-- books one finished row (a blind, or a skip when is_skip)
	function R.record(row, why, is_skip)
		row.t = U.wall()
		row.ridx = R.row_n
		R.row_n = R.row_n + 1
		row.inst = C.id
		row.sess = A.session
		row.match = A.fsm and A.fsm.match and A.fsm.match.n or nil
		row.end_reason = why
		row.seed = A.fsm and A.fsm.match and A.fsm.match.seed or nil
		row.deck = A.fsm and A.fsm.match and A.fsm.match.deck or nil
		row.stake = A.fsm and A.fsm.match and A.fsm.match.stake_key or nil
		R.total = R.total + row.reward
		R.match_total = R.match_total + row.reward
		if not is_skip then
			R.blinds = R.blinds + 1
			R.match_blinds = R.match_blinds + 1
		end
		R.last = row
		R.pending[#R.pending + 1] = row
		if #R.pending > 200 then table.remove(R.pending, 1) end
		if C.rewards_path then U.append_jsonl(C.rewards_path, row) end
		if not is_skip and R.ledger then R.ledger_add(row) end
		if row.kind == "rel" then
			U.info(string.format("reward: less value than the opponent in %s ante %s (%.1f vs %.1f) -> %+.2f", tostring(row.ref), tostring(row.ante), row.my_gen or 0, row.opp_gen or 0, row.reward))
		elseif row.kind == "match" then
			U.info(string.format("reward: MATCH WON (opponent at 0 lives) -> %+.2f", row.reward))
		elseif is_skip then
			U.info(string.format("reward: skip %s (ante %s, tag %s) -> %+.2f", tostring(row.blind), tostring(row.ante), tostring(row.tag), row.reward))
		else
			U.info(string.format("reward: %s ante %s -> %+.2f (%s)", row.kind, tostring(row.ante), row.reward,
				row.kind == "pvp" and (row.outcome .. (row.hopeless and ", hopeless" or "")) or (row.beaten and "beaten" or "failed")))
		end
		return row
	end

	-- ---------------------------------------------------------------------------------------------
	-- value generated vs the opponent (user 2026-10-06 13:54: "if the bot generates lesser value than its opponent in a given blind it is
	-- given a penalty; make the check after both bots have cleared said blind")
	-- Every bot keeps a small ledger of its finished blinds (ante, kind, value generated, cleared) in run/pairval/inst<ID>.json and reads its
	-- partner's. A blind is compared as soon as BOTH ledgers hold it (so nobody is judged before the other one has finished), Small / Big /
	-- boss only when both cleared it. The bot with the strictly lower value gets a "rel" row: -(rel_flat + rel_per x deficit), at most rel_cap.
	-- ---------------------------------------------------------------------------------------------
	local function partner_id()
		return (C.id % 2 == 1) and (C.id + 1) or (C.id - 1)
	end

	local function ledger_path(id)
		return C.run_dir and U.join(C.run_dir, "pairval/inst" .. id .. ".json") or nil
	end

	function R.ledger_reset()
		R.ledger = { seed = A.fsm and A.fsm.match and A.fsm.match.seed or nil, inst = C.id, blinds = {} }
		local pth = ledger_path(C.id)
		if pth then
			U.mkdirs(U.join(C.run_dir, "pairval"))
			U.write_json(pth, R.ledger)
		end
	end

	function R.ledger_add(row)
		local L = R.ledger
		if not L then return end
		L.blinds[#L.blinds + 1] = { ante = row.ante, kind = row.kind, gen = row.gen or 0, beaten = row.beaten and true or false, outcome = row.outcome }
		local pth = ledger_path(C.id)
		if pth then U.write_json(pth, L) end
	end

	function R.settle()
		local W = R.W
		local L = R.ledger
		if not L or (W.rel_flat == 0 and W.rel_per == 0) then return 0 end
		local pend = false
		for _, b in ipairs(L.blinds) do
			if not b.settled then pend = true; break end
		end
		if not pend then return 0 end
		local pth = ledger_path(partner_id())
		local opp = pth and U.read_json(pth) or nil
		if type(opp) ~= "table" or type(opp.blinds) ~= "table" or tostring(opp.seed) ~= tostring(L.seed) then return 0 end
		local booked = 0
		for _, b in ipairs(L.blinds) do
			if not b.settled then
				local o
				for _, x in ipairs(opp.blinds) do
					if x.ante == b.ante and x.kind == b.kind then o = x; break end
				end
				if o then
					b.settled = true
					local eligible
					if b.kind == "pvp" then eligible = W.rel_pvp ~= 0 else eligible = b.beaten and o.beaten end
					local mine, theirs = tonumber(b.gen) or 0, tonumber(o.gen) or 0
					if eligible and mine < theirs - 0.005 then
						local deficit = theirs - mine
						local pen = W.rel_flat + W.rel_per * deficit
						if W.rel_cap > 0 then pen = math.min(W.rel_cap, pen) end
						R.record(clean({
							kind = "rel", ref = b.kind, ante = b.ante, my_gen = mine, opp_gen = theirs, deficit = deficit,
							parts = { rel = -pen }, reward = -pen,
						}), "settle", true)
						booked = booked + 1
					end
				end
			end
		end
		return booked
	end

	function R.finish(B, why, forced)
		if not B or B.closed then return nil end
		B.closed = true
		local ok, row = pcall(R.compute, B, forced)
		if not ok then
			U.err("reward compute failed: " .. tostring(row))
			return nil
		end
		R.record(row, why)
		pcall(R.settle)
		R.prev_best = { R.prev_best[2], math.max(B.best_hand or 0, 0) }
		if row.kind == "pvp" then
			R.prev_margin = row.margin or 0
			R.skips_pending = {}
		end
		return row
	end

	-- Cash Out is about to run (the game still has chips, hands_left and the payout rows in place)
	function R.on_cash_out()
		local B = R.cur
		if not B or B.closed or not (G and G.GAME) then return end
		R.tick()
		B.cashout_total = U.num(G.GAME.current_round and G.GAME.current_round.dollars) or 0
		B.hands_left_end = G.GAME.current_round and G.GAME.current_round.hands_left or 0
		B.discards_left_end = G.GAME.current_round and G.GAME.current_round.discards_left or 0
		B.chips_end = U.num(G.GAME.chips) or 0
		R.finish(B, "cash_out")
	end

	function R.on_match_start()
		if not R.installed then R.install() end
		R.cur = nil
		R.row_n = 0
		R.sales = {}
		R.match_total, R.match_blinds = 0, 0
		R.prev_best = { 0, 0 }
		R.skips_pending, R.prev_margin = {}, 0
		R.ledger_reset()
	end

	-- the match ended (win / loss / abort). A blind that never reached Cash Out is closed here.
	function R.on_match_end(won, aborted)
		local W = R.W
		R.close_blind_at_match_end(won, aborted)
		pcall(R.settle)
		-- the huge payout: the match was won because the opponent is out of lives (not because they left / the match was aborted)
		if won and not aborted and (W.match_win or 0) ~= 0 then
			local el = enemy_lives_now()
			if el ~= nil and el <= 0 then
				R.record(clean({
					kind = "match", ante = G and G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante or nil,
					lives_me = lives_now(), lives_enemy = el, parts = { match_win = W.match_win }, reward = W.match_win,
				}), "match_end", true)
			end
		end
	end

	function R.close_blind_at_match_end(won, aborted)
		local B = R.cur
		if not B or B.closed or aborted then
			R.cur = nil
			return
		end
		if B.kind ~= "pvp" and won then
			-- the OPPONENT ended the match (they lost their last life) while this blind was still being played:
			-- it was neither beaten nor failed, so it is not scored
			U.info("reward: " .. tostring(B.kind) .. " blind unfinished at match end, not scored")
			B.closed = true
			R.cur = nil
			return
		end
		B.cashout_total = B.cashout_total or 0
		B.hands_left_end = G.GAME and G.GAME.current_round and G.GAME.current_round.hands_left or 0
		B.discards_left_end = G.GAME and G.GAME.current_round and G.GAME.current_round.discards_left or 0
		B.chips_end = G.GAME and U.num(G.GAME.chips) or 0
		R.finish(B, "match_end", { won = won and true or false })
		R.cur = nil
	end

	-- ---------------------------------------------------------------------------------------------
	-- reading side
	-- ---------------------------------------------------------------------------------------------
	-- Rewards finished since the previous pop(): { sum = number, blinds = { row, ... } }
	function R.pop()
		local out = { sum = 0, blinds = R.pending }
		for _, r in ipairs(R.pending) do out.sum = out.sum + (r.reward or 0) end
		out.sum = round2(out.sum)
		R.pending = {}
		return out
	end

	function R.live()
		local B = R.cur
		if not B or B.closed then return nil end
		return {
			kind = B.kind,
			ante = B.ante,
			target = B.target,
			money = round2(B.money_play),
			tarots = B.tarots,
			spectrals = B.spectrals,
			planets = B.planets,
			planets_aimed = B.planets_aimed,
			best_hand = B.best_hand,
			hopeless = B.hopeless and true or false,
		}
	end

	function R.snapshot()
		return {
			total = round2(R.total),
			blinds = R.blinds,
			match_total = round2(R.match_total),
			match_blinds = R.match_blinds,
			last = R.last,
			live = R.live(),
			unpopped = #R.pending,
			skips = R.skip_total,
			skips_pending = #R.skips_pending,
			aim = (R.aimed_hand()),
		}
	end

	-- ---------------------------------------------------------------------------------------------
	-- installing the wrappers (idempotent; each wrapper calls the original first-class and shields it from our errors)
	-- ---------------------------------------------------------------------------------------------
	local function guard(fn, ...)
		local ok, err = pcall(fn, ...)
		if not ok then
			R.errors = (R.errors or 0) + 1
			if R.errors <= 5 then U.warn("reward hook error: " .. tostring(err)) end
		end
	end

	function R.install()
		if R.installed or not (G and G.FUNCS) then return end
		R.installed = true
		local function missing(name)
			R.hooks[name] = false
			U.warn("reward: cannot hook " .. name .. " (rewards that depend on it will read zero)")
		end

		-- blind selected -> opens the books
		local select_ref = G.FUNCS.select_blind
		if type(select_ref) == "function" then
			G.FUNCS.select_blind = function(e, ...)
				guard(R.on_blind_select, e)
				return select_ref(e, ...)
			end
			R.hooks.select_blind = true
		else missing("G.FUNCS.select_blind") end

		-- Cash Out -> closes the books. The payout itself goes through ease_dollars, which must not be
		-- counted a second time as in-blind money.
		local cash_ref = G.FUNCS.cash_out
		if type(cash_ref) == "function" then
			G.FUNCS.cash_out = function(e, ...)
				local fresh = e and e.config and e.config.button ~= nil
				if fresh then guard(R.on_cash_out) end
				R.in_cash_out = true
				local res = { pcall(cash_ref, e, ...) }
				R.in_cash_out = false
				if not res[1] then error(res[2], 0) end
				return unpack(res, 2)
			end
			R.hooks.cash_out = true
		else missing("G.FUNCS.cash_out") end

		-- skip (Small / Big only): charged at once
		local skip_ref = G.FUNCS.skip_blind
		if type(skip_ref) == "function" then
			G.FUNCS.skip_blind = function(e, ...)
				guard(R.on_skip, e)
				return skip_ref(e, ...)
			end
			R.hooks.skip_blind = true
		else missing("G.FUNCS.skip_blind") end

		-- hand about to be played (PvP feasibility check)
		local play_ref = G.FUNCS.play_cards_from_highlighted
		if type(play_ref) == "function" then
			G.FUNCS.play_cards_from_highlighted = function(e, ...)
				guard(R.before_play)
				return play_ref(e, ...)
			end
			R.hooks.play = true
		else missing("G.FUNCS.play_cards_from_highlighted") end

		-- money
		local dollars_ref = rawget(_G, "ease_dollars")
		if type(dollars_ref) == "function" then
			_G.ease_dollars = function(mod, ...)
				guard(R.on_dollars, mod)
				return dollars_ref(mod, ...)
			end
			R.hooks.ease_dollars = true
		else missing("ease_dollars") end

		-- sales (so that cashing in a card does not look like money generation)
		if Card and type(Card.sell_card) == "function" then
			local sell_ref = Card.sell_card
			function Card.sell_card(self, ...)
				guard(R.on_sell, self)
				return sell_ref(self, ...)
			end
			R.hooks.sell_card = true
		else missing("Card.sell_card") end

		-- rental fee at the end of a round
		if Card and type(Card.calculate_rental) == "function" then
			local rent_ref = Card.calculate_rental
			function Card.calculate_rental(self, ...)
				guard(R.on_rental, self)
				return rent_ref(self, ...)
			end
			R.hooks.calculate_rental = true
		else missing("Card.calculate_rental") end

		-- consumables appearing in the consumable slots
		if CardArea and type(CardArea.emplace) == "function" then
			local emplace_ref = CardArea.emplace
			function CardArea.emplace(self, card, ...)
				local res = { pcall(emplace_ref, self, card, ...) }
				if not res[1] then error(res[2], 0) end
				guard(R.on_emplace, self, card)
				return unpack(res, 2)
			end
			R.hooks.emplace = true
		else missing("CardArea.emplace") end

		-- payout rows (what the cash-out total is made of)
		local row_ref = rawget(_G, "add_round_eval_row")
		if type(row_ref) == "function" then
			_G.add_round_eval_row = function(config, ...)
				guard(R.on_eval_row, config)
				return row_ref(config, ...)
			end
			R.hooks.eval_row = true
		else missing("add_round_eval_row") end

		-- Multiplayer tells the server about a failed non-PvP blind through this call
		if MP and MP.ACTIONS and type(MP.ACTIONS.fail_round) == "function" then
			local fail_ref = MP.ACTIONS.fail_round
			MP.ACTIONS.fail_round = function(...)
				guard(R.on_fail_round)
				return fail_ref(...)
			end
			R.hooks.fail_round = true
		else missing("MP.ACTIONS.fail_round") end

		U.info("reward hooks installed")
	end

	return R
end
