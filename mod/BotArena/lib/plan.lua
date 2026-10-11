-- BotArena hand planner: "which hand scores the most WITH MY JOKERS, and how likely am I to actually get it?"
--
-- What it does, every time the bot has to choose between playing a hand and discarding:
--   1. Scores every sensible play with a fast re-implementation of Balatro's scoring that knows the bot's
--      JOKERS (Jolly/Duo-style hand-type jokers, per-card jokers like Fibonacci or Greedy, scaling jokers,
--      retriggers, editions, Steel/Glass/Mult/Bonus cards, held-in-hand effects, hand levels).
--   2. Reads the cards still left in the DRAW PILE (as an unordered pile - it never peeks at the shuffle
--      order) and runs Monte Carlo rollouts of what would happen next, given how many hands and discards are
--      left: "if I discard these 4 and draw 4 from this deck, how often do I still clear the blind in time?"
--   3. Picks the action with the best expected reward. A sure 3-hand clear beats a 4-of-a-kind that needs
--      a 4% draw: the objective is `P(clear) * (1.5 per unused hand)  -  (1 - P(clear)) * 30` (the same
--      numbers the reward module pays), so slim odds lose to likely ones even when the likely line uses more
--      hands, and a play that clears the blind right now always wins.
--   In a PvP blind the goal is either "beat the opponent's final score" (opponent has no hands left) or
--   "maximise my expected score" (they can still add to theirs).
--
-- The scorer is a model, not the game's own code, so it is calibrated: after every hand the bot plays, the
-- real score is compared with the prediction and a per-hand-type correction factor is learned (see P.observe).
-- Cards / jokers it does not understand simply fall back to the generic rules the game itself uses
-- (ability.x_mult, t_mult, t_chips with ability.type) and the calibration absorbs the rest.
return function(A)
	local U = A.util
	local P = { calib = {}, calib_all = nil, stats = { decisions = 0, errors = 0 }, last = nil }

	local SUITS = { Spades = 1, Hearts = 2, Clubs = 3, Diamonds = 4 }
	local SMEAR = { [1] = 1, [3] = 1, [2] = 2, [4] = 2 } -- Smeared Joker: black suits / red suits are one suit

	-- what each hand type "contains" (same table as reward.lua; SMODS evaluates N-or-more sets)
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
	P.CONTAINS = CONTAINS
	local CONTAINS_SET = {}
	for k, list in pairs(CONTAINS) do
		CONTAINS_SET[k] = {}
		for _, t in ipairs(list) do CONTAINS_SET[k][t] = true end
	end

	-- Unconditional "+mult" jokers that keep their current value in ability.mult
	local MULT_FIELD = {
		["Joker"] = true, ["Ceremonial Dagger"] = true, ["Swashbuckler"] = true, ["Spare Trousers"] = true,
		["Ride the Bus"] = true, ["Flash Card"] = true, ["Popcorn"] = true, ["Green Joker"] = true, ["Red Card"] = true,
	}
	-- Unconditional "+chips" jokers that keep their current value in ability.extra.chips
	local CHIPS_EXTRA = { ["Ice Cream"] = true, ["Runner"] = true, ["Square Joker"] = true, ["Castle"] = true, ["Wee Joker"] = true }

	-- ---------------------------------------------------------------------------------------------
	-- tiny private PRNG (never touch the game's RNG or math.random state)
	-- ---------------------------------------------------------------------------------------------
	local rng_state = 2463534242
	local function rnd() -- uniform [0,1) (LCG; the product stays below 2^53 so the arithmetic is exact)
		rng_state = (rng_state * 1664525 + 1013904223) % 4294967296
		return rng_state / 4294967296
	end
	function P.seed(n) rng_state = math.floor(tonumber(n) or 1) % 4294967296; if rng_state == 0 then rng_state = 1 end end
	P.seed((os.time() or 1) + (A.cfg and A.cfg.id or 0) * 7919)

	-- ---------------------------------------------------------------------------------------------
	-- card descriptors: plain tables so the search never touches game objects
	-- ---------------------------------------------------------------------------------------------
	-- P.card(rank, suit, opts) is also how the tests build hands. rank 2..14 (14 = Ace), suit 1..4 (S,H,C,D).
	function P.card(rank, suit, o)
		o = o or {}
		local d = {
			rank = o.stone and 0 or rank, suit = o.stone and 0 or suit, stone = o.stone or false, wild = o.wild or false,
			chips = o.chips or (o.stone and 50 or math.min(rank, 10) + (rank == 14 and 1 or 0)),
			mult = o.mult or 0, x = o.x or 1, hx = o.hx or 1, hm = o.hm or 0,
			e_chips = o.e_chips or 0, e_mult = o.e_mult or 0, e_x = o.e_x or 1,
			retrig = o.retrig or 0, debuff = o.debuff or false, lucky = o.lucky or false,
			face = o.face, ref = o.ref, i = o.i, seal = o.seal,
		}
		if d.face == nil then d.face = (rank >= 11 and rank <= 13) end
		if d.debuff then d.chips, d.mult, d.x, d.e_chips, d.e_mult, d.e_x, d.hx, d.hm = 0, 0, 1, 0, 0, 1, 1, 0 end
		return d
	end

	local function num(x, default)
		local n = U.num(x)
		if n == nil then return default end
		return n
	end

	-- real game card -> descriptor
	function P.describe(card, i)
		local base = card.base or {}
		local ab = card.ability or {}
		local center = card.config and card.config.center
		local key = center and center.key
		local stone = (key == "m_stone") or ab.effect == "Stone Card"
		local rank = num(base.id, 0)
		local o = {
			stone = stone, ref = card, i = i,
			wild = (key == "m_wild") or ab.effect == "Wild Card",
			debuff = card.debuff and true or false,
			lucky = (key == "m_lucky") or ab.effect == "Lucky Card",
		}
		local okc, bonus = pcall(card.get_chip_bonus, card)
		if okc and type(bonus) == "number" then o.chips = bonus end
		if not o.lucky then o.mult = num(ab.mult, 0) + num(ab.perma_mult, 0) else o.mult = 4 end -- Lucky: 1 in 5 for +20
		local ax = num(ab.x_mult, 1)
		if ax > 1 and (key == "m_glass" or ab.effect == "Glass Card" or ab.set == "Enhanced") then o.x = ax end
		local px = num(ab.perma_x_mult, 0)
		if px > 0 then o.x = o.x * (1 + px) end
		local hx = num(ab.h_x_mult, 1)
		if hx > 1 then o.hx = hx end
		o.hm = num(ab.h_mult, 0) + num(ab.perma_h_mult, 0)
		local ed = card.edition
		if type(ed) == "table" then
			o.e_chips = num(ed.chips, 0)
			o.e_mult = num(ed.mult, 0)
			o.e_x = num(ed.x_mult, 1)
		end
		if card.seal == "Red" then o.retrig = 1 end
		o.seal = type(card.seal) == "string" and card.seal or nil -- Gold / Purple / Blue matter to the planner (see seal_value)
		local okf, face = pcall(card.is_face, card)
		if okf and face ~= nil then o.face = face and true or false else o.face = (rank >= 11 and rank <= 13) end
		local d = P.card(rank, SUITS[base.suit] or 0, o)
		d.suit_name = base.suit
		return d
	end

	-- ---------------------------------------------------------------------------------------------
	-- context: jokers, hand levels, flags (built once per decision)
	-- ---------------------------------------------------------------------------------------------
	-- Multiplayer-mod jokers have no vanilla display name (SMODS names them after their key), so map their keys to the names the
	-- rules below use. "MP Hanging Chad" is the standard-ranked rework (first TWO scoring cards retrigger).
	local MP_NAMES = {
		hanging_chad = "MP Hanging Chad", seltzer = "Seltzer", bloodstone = "Bloodstone", ticket = "Golden Ticket", turtle_bean = "Turtle Bean",
		pacifist = "Pacifist", taxes = "Taxes", skip_off = "Skip-Off", pizza = "Pizza", penny_pincher = "Penny Pincher",
		lets_go_gambling = "Lets Go Gambling", speedrun = "Speedrun", conjoined_joker = "Conjoined Joker", defensive_joker = "Defensive Joker",
	}
	P.MP_NAMES = MP_NAMES

	local function canon_name(j)
		local ab = j.ability or {}
		local center = j.config and j.config.center
		local key = center and center.key
		if type(key) == "string" then
			local mp = key:match("^j_mp_(.+)$")
			if mp and MP_NAMES[mp] then return MP_NAMES[mp], key end
			if mp then
				mp = mp:gsub("_sandbox$", ""):gsub("_experimental$", ""):gsub("_rare$", ""):gsub("_uncommon$", "")
				if MP_NAMES[mp] then return MP_NAMES[mp], key end
			end
		end
		return ab.name or (center and center.name) or "?", key
	end

	local function joker_data(j)
		local ab = j.ability or {}
		local ed = type(j.edition) == "table" and j.edition or {}
		local name, key = canon_name(j)
		return {
			ref = j, name = name, key = key, ab = ab,
			debuff = j.debuff and true or false,
			e_chips = num(ed.chips, 0), e_mult = num(ed.mult, 0), e_x = num(ed.x_mult, 1),
			rarity = j.config and j.config.center and j.config.center.rarity,
		}
	end

	-- Blueprint copies the joker to its right, Brainstorm the leftmost one: give them that joker's behaviour
	local function resolve_copies(list)
		for i, jd in ipairs(list) do
			if jd.name == "Blueprint" or jd.name == "Brainstorm" then
				local target
				if jd.name == "Blueprint" then target = list[i + 1] else target = list[1] end
				local hops = 0
				while target and (target.name == "Blueprint" or target.name == "Brainstorm") and hops < 5 do
					if target.name == "Blueprint" then target = list[(target.pos or 0) + 1] else target = list[1] end
					hops = hops + 1
				end
				if target and target ~= jd then
					jd.copy = { name = target.name, ab = target.ab, debuff = target.debuff, e_chips = jd.e_chips, e_mult = jd.e_mult, e_x = jd.e_x }
				else
					jd.debuff = true
				end
			end
			jd.pos = i
		end
	end

	-- opts: { jokers = {joker objects}, lvl = {[hand] = {chips, mult}}, hands_left, discards_left, ... } (all optional)
	function P.context(o)
		o = o or {}
		local ctx = {
			jd = {}, lvl = o.lvl or {}, hands_left = o.hands_left or 1, discards_left = o.discards_left or 0,
			dollars = o.dollars or 0, deck_n = o.deck_n or 0, n_jokers = 0, played_counts = o.played_counts or {},
			played_this_round = o.played_this_round or {}, consumeable_tarots = o.tarots_used or 0,
			start_deck = o.start_deck or 52, stone_tally = o.stone_tally or 0,
			idol = o.idol, ancient_suit = o.ancient_suit, flags = {}, calib = o.calib or P.calib,
			calib_all = o.calib_all or P.calib_all, has_held = false, has_hand_size_jokers = false,
			pvp = o.pvp or false, plasma = o.plasma or false, game_hands_played = o.game_hands_played or 0, enemy_hands = o.enemy_hands,
		}
		for i, j in ipairs(o.jokers or {}) do
			local jd = j.name and j.ab and j or joker_data(j)
			ctx.jd[i] = jd
		end
		resolve_copies(ctx.jd)
		ctx.n_jokers = #ctx.jd
		for _, jd in ipairs(ctx.jd) do
			if not jd.debuff then
				local n = (jd.copy and jd.copy.name) or jd.name
				if n == "Four Fingers" then ctx.flags.four = true
				elseif n == "Shortcut" then ctx.flags.shortcut = true
				elseif n == "Smeared Joker" then ctx.flags.smeared = true
				elseif n == "Splash" then ctx.flags.splash = true
				elseif n == "Pareidolia" then ctx.flags.pareidolia = true
				elseif n == "Mime" or n == "Baron" or n == "Shoot the Moon" or n == "Raised Fist" or n == "Blackboard" then
					ctx.has_held = true
					if n == "Baron" then ctx.keep_kings = true elseif n == "Shoot the Moon" then ctx.keep_queens = true end
				end
			end
		end
		return ctx
	end

	-- build a context from the live game
	function P.live_context(extra)
		local jokers = (G and G.jokers and U.cards(G.jokers)) or {}
		local lvl = {}
		for name, h in pairs((G and G.GAME and G.GAME.hands) or {}) do
			if type(h) == "table" then
				lvl[name] = { chips = num(h.chips, 0), mult = num(h.mult, 1), played = num(h.played, 0), played_this_round = num(h.played_this_round, 0) }
			end
		end
		local cr = G and G.GAME and G.GAME.current_round or {}
		local o = {
			jokers = jokers, lvl = lvl, hands_left = cr.hands_left, discards_left = cr.discards_left,
			dollars = num(G and G.GAME and G.GAME.dollars, 0), deck_n = G and G.deck and U.count(G.deck) or 0,
			tarots_used = num(G and G.GAME and G.GAME.consumeable_usage_total and G.GAME.consumeable_usage_total.tarot, 0),
			start_deck = (G and G.playing_cards and #G.playing_cards) or 52,
			game_hands_played = num(G and G.GAME and G.GAME.hands_played, 0),
		}
		if A.rules then
			local okr, lv = pcall(A.rules.live)
			if okr and lv then o.plasma = lv.plasma end
		end
		if MP and MP.is_pvp_boss then
			local okp, isp = pcall(MP.is_pvp_boss)
			o.pvp = okp and isp and true or false
		end
		if MP and MP.GAME and MP.GAME.enemy then o.enemy_hands = num(MP.GAME.enemy.hands, nil) end
		if G and G.GAME and G.GAME.current_round then
			local idol = G.GAME.current_round.idol_card
			if idol then o.idol = { rank = idol.id, suit = SUITS[idol.suit] } end
			local anc = G.GAME.current_round.ancient_card
			if anc then o.ancient_suit = SUITS[anc.suit] end
		end
		if extra then for k, v in pairs(extra) do o[k] = v end end
		local ctx = P.context(o)
		ctx.jokers_live = jokers
		return ctx
	end

	-- ---------------------------------------------------------------------------------------------
	-- poker-hand classification of a played set
	-- ---------------------------------------------------------------------------------------------
	local function suit_match(c, s, ctx)
		if c.stone then return false end
		if c.wild then return true end
		if ctx.flags.smeared then return SMEAR[c.suit] == SMEAR[s] end
		return c.suit == s
	end

	-- best straight inside a set of non-stone cards (given in the order the caller prefers); returns the chosen
	-- cards (one per rank, `need` of them) or nil. Ace counts high or low; Shortcut lets a run skip one rank.
	local function find_straight(cards, ctx)
		local need = ctx.flags.four and 4 or 5
		if #cards < need then return nil end
		local by = {}
		for _, c in ipairs(cards) do
			if not c.stone and not by[c.rank] then by[c.rank] = c end
		end
		if by[14] then by[1] = by[14] end
		local gap = ctx.flags.shortcut and 2 or 1
		for hi = 14, 2, -1 do
			if by[hi] then
				local pick, last = { by[hi] }, hi
				local r = hi - 1
				while r >= 1 and #pick < need and last - r <= gap do
					if by[r] then
						pick[#pick + 1] = by[r]
						last = r
					end
					r = r - 1
				end
				if #pick >= need then return pick end
			end
		end
		return nil
	end

	local function group_ranks(cards)
		local by, order = {}, {}
		for _, c in ipairs(cards) do
			local g = by[c.rank]
			if not g then
				g = { r = c.rank, n = 0, cards = {} }
				by[c.rank] = g
				order[#order + 1] = g
			end
			g.n = g.n + 1
			g.cards[g.n] = c
		end
		table.sort(order, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.r > b.r end)
		return order
	end

	-- -> name, scoring cards (list). Stone cards always score; with Splash every played card scores.
	function P.classify(played, ctx)
		local plain, stones = {}, {}
		for _, c in ipairs(played) do
			if c.stone then stones[#stones + 1] = c else plain[#plain + 1] = c end
		end
		local need = ctx.flags.four and 4 or 5
		local groups = group_ranks(plain)
		local g1, g2 = groups[1], groups[2]
		local flush
		if #plain >= need then
			for s = 1, 4 do
				local m = {}
				for _, c in ipairs(plain) do if suit_match(c, s, ctx) then m[#m + 1] = c end end
				if #m >= need and (not flush or #m > #flush) then flush = m end
			end
		end
		local straight = find_straight(plain, ctx)
		local sf
		if straight and flush then
			-- a straight made only of flush cards
			local in_flush = {}
			for _, c in ipairs(flush) do in_flush[#in_flush + 1] = c end
			sf = find_straight(in_flush, ctx)
		end
		local name, sc
		local n1, n2 = g1 and g1.n or 0, g2 and g2.n or 0
		local fh = n1 >= 3 and n2 >= 2
		if n1 >= 5 and flush then name, sc = "Flush Five", plain
		elseif fh and flush then name, sc = "Flush House", plain
		elseif n1 >= 5 then name, sc = "Five of a Kind", plain
		elseif sf then name, sc = "Straight Flush", sf
		elseif n1 >= 4 then
			name, sc = "Four of a Kind", { g1.cards[1], g1.cards[2], g1.cards[3], g1.cards[4] }
		elseif fh then
			name, sc = "Full House", plain
		elseif flush then name, sc = "Flush", flush
		elseif straight then name, sc = "Straight", straight
		elseif n1 >= 3 then name, sc = "Three of a Kind", { g1.cards[1], g1.cards[2], g1.cards[3] }
		elseif n1 >= 2 and n2 >= 2 then
			name, sc = "Two Pair", { g1.cards[1], g1.cards[2], g2.cards[1], g2.cards[2] }
		elseif n1 >= 2 then name, sc = "Pair", { g1.cards[1], g1.cards[2] }
		elseif #plain >= 1 then
			local hi = plain[1]
			for _, c in ipairs(plain) do if c.rank > hi.rank then hi = c end end
			name, sc = "High Card", { hi }
		elseif #stones >= 1 then
			name, sc = "High Card", {}
		else
			return "NULL", {}
		end
		local out = {}
		if ctx.flags.splash then
			for _, c in ipairs(played) do out[#out + 1] = c end
			return name, out
		end
		for _, c in ipairs(sc) do out[#out + 1] = c end
		for _, c in ipairs(stones) do out[#out + 1] = c end
		return name, out
	end

	-- ---------------------------------------------------------------------------------------------
	-- scoring with jokers
	-- ---------------------------------------------------------------------------------------------
	local function is_face(c, ctx) return c.face or ctx.flags.pareidolia end
	local function even_rank(r) return r >= 2 and r <= 10 and r % 2 == 0 end
	local function odd_rank(r) return r == 14 or (r >= 3 and r <= 9 and r % 2 == 1) end

	-- number of extra repetitions a scoring card gets
	local function retriggers(c, idx, ctx, first)
		local r = c.retrig or 0
		for _, jd in ipairs(ctx.jd) do
			if not jd.debuff then
				local n = jd.copy and jd.copy.name or jd.name
				local ab = jd.copy and jd.copy.ab or jd.ab
				if n == "Hack" and c.rank >= 2 and c.rank <= 5 and not c.stone then r = r + 1
				elseif n == "Sock and Buskin" and is_face(c, ctx) and not c.stone then r = r + 1
				elseif n == "Hanging Chad" and first then r = r + num(ab.extra, 2)
				elseif n == "MP Hanging Chad" and idx <= 2 then r = r + num(ab.extra, 1)
				elseif n == "Dusk" and ctx.hands_left <= 1 then r = r + 1
				elseif n == "Seltzer" then r = r + 1 end
			end
		end
		return r
	end

	-- one scoring card's contribution including the jokers' per-card effects (returns new chips, mult)
	local function card_phase(chips, mult, c, ctx, photo_used)
		-- the card itself
		chips = chips + c.chips + c.e_chips
		mult = mult + c.mult + c.e_mult
		if c.x ~= 1 then mult = mult * c.x end
		if c.e_x ~= 1 then mult = mult * c.e_x end
		-- per-card joker effects
		for _, jd in ipairs(ctx.jd) do
			if not jd.debuff then
				local n = jd.copy and jd.copy.name or jd.name
				local ab = jd.copy and jd.copy.ab or jd.ab
				local ex = ab.extra
				if not c.stone then
					local sname = (n == "Greedy Joker" and 4) or (n == "Lusty Joker" and 2) or (n == "Wrathful Joker" and 1) or (n == "Gluttonous Joker" and 3)
					if sname then
						if suit_match(c, sname, ctx) then mult = mult + num(type(ex) == "table" and ex.s_mult, 3) end
					elseif n == "Onyx Agate" then
						if suit_match(c, 3, ctx) then mult = mult + num(ex, 7) end
					elseif n == "Arrowhead" then
						if suit_match(c, 1, ctx) then chips = chips + num(ex, 50) end
					elseif n == "Bloodstone" then
						if suit_match(c, 2, ctx) then mult = mult * (1 + 0.5 * (num(type(ex) == "table" and ex.Xmult, 1.5) - 1)) end
					elseif n == "Fibonacci" then
						local r = c.rank
						if r == 14 or r == 2 or r == 3 or r == 5 or r == 8 then mult = mult + num(ex, 8) end
					elseif n == "Scholar" then
						if c.rank == 14 then chips = chips + num(type(ex) == "table" and ex.chips, 20); mult = mult + num(type(ex) == "table" and ex.mult, 4) end
					elseif n == "Even Steven" then
						if even_rank(c.rank) then mult = mult + num(ex, 4) end
					elseif n == "Odd Todd" then
						if odd_rank(c.rank) then chips = chips + num(ex, 31) end
					elseif n == "Walkie Talkie" then
						if c.rank == 10 or c.rank == 4 then chips = chips + num(type(ex) == "table" and ex.chips, 10); mult = mult + num(type(ex) == "table" and ex.mult, 4) end
					elseif n == "Smiley Face" then
						if is_face(c, ctx) then mult = mult + num(ex, 5) end
					elseif n == "Scary Face" then
						if is_face(c, ctx) then chips = chips + num(ex, 30) end
					elseif n == "Photograph" then
						if is_face(c, ctx) and not photo_used.v then mult = mult * num(ex, 2); photo_used.v = true end
					elseif n == "Triboulet" then
						if c.rank == 12 or c.rank == 13 then mult = mult * num(ex, 2) end
					elseif n == "Ancient Joker" then
						if ctx.ancient_suit and suit_match(c, ctx.ancient_suit, ctx) then mult = mult * num(ex, 1.5) end
					elseif n == "The Idol" then
						if ctx.idol and c.rank == ctx.idol.rank and suit_match(c, ctx.idol.suit or 0, ctx) then mult = mult * num(ex, 2) end
					end
				end
			end
		end
		return chips, mult
	end

	-- score of a played set. `held` = cards still in hand (list or nil). Returns score, name.
	function P.score(played, held, ctx, name, scoring)
		if not name then name, scoring = P.classify(played, ctx) end
		if name == "NULL" then return 0, name end
		local lv = ctx.lvl[name] or { chips = 5, mult = 1 }
		local chips, mult = lv.chips, lv.mult
		local contains = CONTAINS_SET[name] or {}
		local n_played = #played
		-- scoring cards, left to right
		local photo = {}
		for idx, c in ipairs(scoring) do
			local reps = 1 + retriggers(c, idx, ctx, idx == 1)
			for _ = 1, reps do
				chips, mult = card_phase(chips, mult, c, ctx, photo)
			end
		end
		-- held-in-hand effects
		if held and (ctx.has_held or ctx.held_effects) then
			local mime = 0
			local lowest
			local all_dark = true
			for _, jd in ipairs(ctx.jd) do
				local n = jd.copy and jd.copy.name or jd.name
				if not jd.debuff and n == "Mime" then mime = mime + 1 end
			end
			for _, c in ipairs(held) do
				if not c.stone then
					if not lowest or c.rank < lowest.rank then lowest = c end
					if not (suit_match(c, 1, ctx) or suit_match(c, 3, ctx)) then all_dark = false end
				end
			end
			for _, c in ipairs(held) do
				local reps = 1 + mime + (c.retrig or 0)
				for _ = 1, reps do
					if c.hm ~= 0 then mult = mult + c.hm end
					if c.hx ~= 1 then mult = mult * c.hx end
					for _, jd in ipairs(ctx.jd) do
						if not jd.debuff and not c.stone then
							local n = jd.copy and jd.copy.name or jd.name
							local ab = jd.copy and jd.copy.ab or jd.ab
							if n == "Baron" and c.rank == 13 then mult = mult * num(ab.extra, 1.5)
							elseif n == "Shoot the Moon" and c.rank == 12 then mult = mult + num(ab.extra, 13) end
						end
					end
				end
			end
			for _, jd in ipairs(ctx.jd) do
				local n = jd.copy and jd.copy.name or jd.name
				local ab = jd.copy and jd.copy.ab or jd.ab
				if not jd.debuff then
					if n == "Raised Fist" and lowest then mult = mult + 2 * math.min(lowest.rank, 10)
					elseif n == "Blackboard" and all_dark then mult = mult * num(ab.extra, 3) end
				end
			end
		end
		-- jokers, left to right (edition first, then the effect, polychrome last)
		for _, jd in ipairs(ctx.jd) do
			if not jd.debuff then
				local n = jd.copy and jd.copy.name or jd.name
				local ab = jd.copy and jd.copy.ab or jd.ab
				local ex = ab.extra
				chips = chips + jd.e_chips
				mult = mult + jd.e_mult
				if MULT_FIELD[n] then
					local m = num(ab.mult, 0)
					if m > 0 then mult = mult + m end
				elseif CHIPS_EXTRA[n] then
					chips = chips + num(type(ex) == "table" and ex.chips, 0)
				elseif n == "Half Joker" then
					if n_played <= num(type(ex) == "table" and ex.size, 3) then mult = mult + num(type(ex) == "table" and ex.mult, 20) end
				elseif n == "Banner" then chips = chips + num(ex, 30) * ctx.discards_left
				elseif n == "Mystic Summit" then
					if ctx.discards_left == 0 then mult = mult + num(type(ex) == "table" and ex.mult, 15) end
				elseif n == "Gros Michel" then mult = mult + num(type(ex) == "table" and ex.mult, 15)
				elseif n == "Cavendish" then mult = mult * num(type(ex) == "table" and ex.Xmult, 3)
				elseif n == "Supernova" then mult = mult + ((ctx.lvl[name] and ctx.lvl[name].played or 0) + 1)
				elseif n == "Abstract Joker" then mult = mult + num(ex, 3) * ctx.n_jokers
				elseif n == "Fortune Teller" then mult = mult + ctx.consumeable_tarots
				elseif n == "Blue Joker" then chips = chips + num(ex, 2) * ctx.deck_n
				elseif n == "Bull" then chips = chips + num(ex, 2) * math.max(0, ctx.dollars)
				elseif n == "Bootstraps" then
					local per = num(type(ex) == "table" and ex.dollars, 5)
					mult = mult + num(type(ex) == "table" and ex.mult, 2) * math.floor(math.max(0, ctx.dollars) / math.max(1, per))
				elseif n == "Erosion" then mult = mult + num(ex, 4) * math.max(0, ctx.start_deck - 52)
				elseif n == "Stone Joker" then chips = chips + num(ex, 25) * num(ab.stone_tally, ctx.stone_tally)
				elseif n == "Misprint" then
					if type(ex) == "table" then mult = mult + (num(ex.min, 0) + num(ex.max, 23)) / 2 end
				elseif n == "Acrobat" then
					if ctx.hands_left <= 1 then mult = mult * num(ex, 3) end
				elseif n == "Card Sharp" then
					if (ctx.lvl[name] and ctx.lvl[name].played_this_round or 0) > 0 then mult = mult * num(type(ex) == "table" and ex.Xmult, 3) end
				elseif n == "Flower Pot" then
					local seen, k = {}, 0
					for _, c in ipairs(scoring) do
						for s = 1, 4 do
							if not seen[s] and suit_match(c, s, ctx) then seen[s] = true; k = k + 1; break end
						end
					end
					if k >= 4 then mult = mult * num(ex, 3) end
				elseif n == "Seeing Double" then
					local club, other = false, false
					for _, c in ipairs(scoring) do
						if suit_match(c, 3, ctx) then club = true else other = true end
					end
					if club and other then mult = mult * num(ex, 2) end
				elseif n == "Stuntman" then chips = chips + num(type(ex) == "table" and ex.chip_mod, 250)
				elseif n == "Baseball Card" then
					local k = 0
					for _, o in ipairs(ctx.jd) do if o ~= jd and not o.debuff and o.rarity == 2 then k = k + 1 end end
					if k > 0 then mult = mult * num(ex, 1.5) ^ k end
				elseif n == "Steel Joker" then
					-- x(1 + extra per Steel card in the whole deck); the game keeps the tally in ability.steel_tally
					mult = mult * (1 + num(ex, 0.2) * num(ab.steel_tally, ctx.steel_tally or 0))
				elseif n == "Driver's License" then
					if num(ab.driver_tally, 0) >= 16 then mult = mult * num(ex, 3) end
				elseif n == "Loyalty Card" then
					-- x(Xmult) on every (every+1)-th hand played; the game's own formula (hands_played is incremented AFTER scoring)
					local ev = type(ex) == "table" and ex or {}
					local every = num(ev.every, 5)
					local rem = (every - 1 - (ctx.game_hands_played - num(ab.hands_played_at_create, 0))) % (every + 1)
					if rem == every then mult = mult * num(ev.Xmult, 4) end
				elseif n == "Caino" then
					local cx = num(ab.caino_xmult, 1)
					if cx > 1 then mult = mult * cx end
				elseif n == "Pacifist" then
					if not ctx.pvp then mult = mult * num(type(ex) == "table" and ex.x_mult, 10) end
				elseif n == "Taxes" then
					mult = mult + num(type(ex) == "table" and ex.mult, 0)
				elseif n == "Defensive Joker" then
					chips = chips + num(ab.t_chips, 0)
				elseif n == "Conjoined Joker" then
					mult = mult * num(type(ex) == "table" and ex.x_mult, 1)
				elseif n == "Lets Go Gambling" then
					-- 1 in `odds` for x(xmult): plan with the expected multiplier
					local ev = type(ex) == "table" and ex or {}
					local odds = math.max(1, num(ev.odds, 4))
					mult = mult * (1 + (num(ev.xmult, 4) - 1) / odds)
				end
				-- the generic rules the game applies to every joker (type-conditional t_mult / t_chips / x_mult)
				local jtype = ab.type
				local cond = (type(jtype) ~= "string" or jtype == "" or contains[jtype])
				if n ~= "Seeing Double" then
					local xm = num(ab.x_mult, 1)
					if xm > 1 and cond then mult = mult * xm end
				end
				if type(jtype) == "string" and jtype ~= "" and contains[jtype] then
					local tm, tc = num(ab.t_mult, 0), num(ab.t_chips, 0)
					if tm > 0 then mult = mult + tm end
					if tc > 0 then chips = chips + tc end
				end
				if jd.e_x ~= 1 then mult = mult * jd.e_x end
			end
		end
		local s = chips * mult
		-- Plasma Deck: after every joker has acted, chips and mult are both set to floor((chips + mult) / 2)
		if ctx.plasma then
			local half = math.floor((chips + mult) / 2)
			s = half * half
		end
		-- learned correction (real score / predicted score), per hand type, else a damped global one
		local k = ctx.calib and ctx.calib[name]
		if not k and ctx.calib_all then k = math.sqrt(ctx.calib_all) end
		if k then s = s * k end
		return s, name
	end

	-- ---------------------------------------------------------------------------------------------
	-- candidate plays from a hand (structural generation instead of trying every subset)
	-- ---------------------------------------------------------------------------------------------
	local function by_chips(a, b)
		if a.chips ~= b.chips then return a.chips > b.chips end
		return a.rank > b.rank
	end

	local function key_of(list)
		local ids = {}
		for i, c in ipairs(list) do ids[i] = c.uid end
		table.sort(ids)
		return table.concat(ids, ",")
	end

	-- hand: list of descriptors with .uid set. fast = fewer candidates (rollouts). Returns list of
	-- { score, name, played, scoring } best-first.
	local function candidates(hand, ctx, play_limit, fast)
		local plain, stones = {}, {}
		for _, c in ipairs(hand) do
			if c.stone then stones[#stones + 1] = c else plain[#plain + 1] = c end
		end
		table.sort(stones, by_chips)
		local sorted = {}
		for i, c in ipairs(plain) do sorted[i] = c end
		table.sort(sorted, by_chips)
		local groups = group_ranks(plain)
		local out, seen = {}, {}
		local held_cache
		local function add(played)
			if #played == 0 then return end
			-- stones always add 50 chips: use spare play slots for them
			if #stones > 0 and #played < play_limit then
				local p2 = {}
				for i, c in ipairs(played) do p2[i] = c end
				for _, s in ipairs(stones) do
					if #p2 < play_limit then p2[#p2 + 1] = s end
				end
				played = p2
			end
			local key = key_of(played)
			if seen[key] then return end
			seen[key] = true
			local name, sc = P.classify(played, ctx)
			if name == "NULL" then return end
			local held
			if ctx.has_held or ctx.held_effects then
				held = {}
				local inplay = {}
				for _, c in ipairs(played) do inplay[c] = true end
				for _, c in ipairs(hand) do if not inplay[c] then held[#held + 1] = c end end
			end
			local s = P.score(played, held, ctx, name, sc)
			out[#out + 1] = { score = s, name = name, played = played, scoring = sc }
		end

		-- High Card / singles
		local singles = fast and 2 or 5
		for i = 1, math.min(singles, #sorted) do add({ sorted[i] }) end
		if not fast then
			for _, c in ipairs(sorted) do
				if c.e_x ~= 1 or c.x ~= 1 or c.mult ~= 0 or c.e_mult ~= 0 or c.e_chips ~= 0 then add({ c }) end
			end
		end
		-- n of a kind, two pair, full house
		local function take(g, k)
			local t = {}
			for i = 1, k do t[i] = g.cards[i] end
			return t
		end
		for gi, g in ipairs(groups) do
			if g.n >= 2 then
				-- keep the best-chips cards of the rank first
				table.sort(g.cards, by_chips)
				add(take(g, math.min(g.n, 5)))
				if g.n > 2 and not fast then add(take(g, 2)) end
			end
		end
		local multi = {}
		for _, g in ipairs(groups) do if g.n >= 2 then multi[#multi + 1] = g end end
		for a = 1, #multi do
			for b = a + 1, #multi do
				local ga, gb = multi[a], multi[b]
				local p = {}
				local ka, kb = math.min(ga.n, 3), math.min(gb.n, 3)
				if ga.n >= 3 then -- full house: trips + pair
					for i = 1, 3 do p[#p + 1] = ga.cards[i] end
					for i = 1, 2 do p[#p + 1] = gb.cards[i] end
					add(p)
				elseif gb.n >= 3 then
					p = {}
					for i = 1, 3 do p[#p + 1] = gb.cards[i] end
					for i = 1, 2 do p[#p + 1] = ga.cards[i] end
					add(p)
				end
				p = {}
				for i = 1, 2 do p[#p + 1] = ga.cards[i] end
				for i = 1, 2 do p[#p + 1] = gb.cards[i] end
				add(p)
				if fast and a >= 2 then break end
			end
			if fast and a >= 2 then break end
		end
		-- flush / straight flush
		local need = ctx.flags.four and 4 or 5
		for s = 1, 4 do
			local m = {}
			for _, c in ipairs(sorted) do if suit_match(c, s, ctx) then m[#m + 1] = c end end
			if #m >= need then
				local pick = {}
				for i = 1, math.min(5, #m) do pick[i] = m[i] end
				add(pick)
				local sf = find_straight(m, ctx)
				if sf then add(sf) end
			end
		end
		-- straight
		local st = find_straight(sorted, ctx)
		if st then add(st) end
		if not fast and st then
			-- also the straight built from the highest-chip card of every rank (already first) - and the lowest window
			local low = {}
			for i = #sorted, 1, -1 do low[#low + 1] = sorted[i] end
			local st2 = find_straight(low, ctx)
			if st2 then add(st2) end
		end
		table.sort(out, function(a, b) return a.score > b.score end)
		return out
	end
	P._candidates = candidates

	-- ---------------------------------------------------------------------------------------------
	-- discard options ("keep these, throw the rest")
	-- ---------------------------------------------------------------------------------------------
	-- A card that earns its keep by being HELD (Steel x-mult, held-mult cards, Kings with Baron, Queens with Shoot the
	-- Moon) is never thrown away while something else can go: "high card + steel in hand" builds get stronger every
	-- discard because every discard digs for more steel.
	local function held_value(c, ctx)
		if c.stone then return false end
		return c.hx ~= 1 or c.hm ~= 0 or (ctx.keep_kings and c.rank == 13) or (ctx.keep_queens and c.rank == 12)
	end

	local function discards_for(hand, keep, discard_limit, ctx)
		local kept = {}
		for _, c in ipairs(keep) do kept[c] = true end
		local rest = {}
		for _, c in ipairs(hand) do if not kept[c] then rest[#rest + 1] = c end end
		local prot = {}
		if ctx and (ctx.has_held or ctx.held_effects) then
			for _, c in ipairs(rest) do prot[c] = held_value(c, ctx) end
		end
		table.sort(rest, function(a, b)
			if (prot[a] or false) ~= (prot[b] or false) then return not prot[a] end
			if a.chips ~= b.chips then return a.chips < b.chips end
			return a.rank < b.rank
		end)
		if next(prot) then
			-- do not discard protected cards at all (only throw away what is not protected)
			local only = {}
			for _, c in ipairs(rest) do if not prot[c] then only[#only + 1] = c end end
			rest = only
		end
		local out = {}
		for i = 1, math.min(discard_limit, #rest) do out[i] = rest[i] end
		return out
	end

	-- a handful of sensible keep-sets from this hand
	local function keep_sets(hand, plays, ctx, fast)
		local sets, seen = {}, {}
		local function add(keep, tag)
			local key = key_of(keep) .. "|" .. tag
			local k2 = key_of(keep)
			if seen[k2] then return end
			seen[k2] = true
			sets[#sets + 1] = { keep = keep, tag = tag }
		end
		local plain = {}
		for _, c in ipairs(hand) do if not c.stone then plain[#plain + 1] = c end end
		table.sort(plain, by_chips)
		-- the best made hands
		local made_seen = {}
		for i = 1, math.min(fast and 1 or 3, #plays) do
			local p = plays[i]
			if not made_seen[p.name] then
				made_seen[p.name] = true
				add(p.scoring, "made " .. p.name)
			end
		end
		-- flush draws
		local need = ctx.flags.four and 4 or 5
		for s = 1, 4 do
			local m = {}
			for _, c in ipairs(plain) do if suit_match(c, s, ctx) then m[#m + 1] = c end end
			if #m >= need - 2 and #m < need then
				local keep = {}
				for i = 1, #m do keep[i] = m[i] end
				add(keep, "flush draw")
			end
		end
		-- straight draws: windows with at least 3 (4 with Four Fingers: 3) distinct ranks present
		local by = {}
		for _, c in ipairs(plain) do if not by[c.rank] then by[c.rank] = c end end
		if by[14] then by[1] = by[14] end
		local best_w, best_c = nil, 2
		local win = need
		for hi = 14, win, -1 do
			local cnt, keep = 0, {}
			for r = hi, hi - win + 1, -1 do
				if by[r] then cnt = cnt + 1; keep[#keep + 1] = by[r] end
			end
			if cnt >= win - 2 and cnt < win and (cnt > best_c or (cnt == best_c and false)) then best_w, best_c = keep, cnt end
		end
		if best_w then add(best_w, "straight draw") end
		-- pairs / trips as a group
		local groups = group_ranks(plain)
		local multi = {}
		for _, g in ipairs(groups) do
			if g.n >= 2 then for _, c in ipairs(g.cards) do multi[#multi + 1] = c end end
		end
		if #multi > 0 then add(multi, "keep groups") end
		if not fast then
			local top = {}
			for i = 1, math.min(3, #plain) do top[i] = plain[i] end
			if #top > 0 then add(top, "keep high") end
			if #groups > 0 and groups[1].n >= 2 then
				local best_pair = {}
				for i = 1, groups[1].n do best_pair[i] = groups[1].cards[i] end
				if #plain > #best_pair then
					local kicker = nil
					for _, c in ipairs(plain) do
						if c.rank ~= groups[1].r then kicker = c; break end
					end
					if kicker then best_pair[#best_pair + 1] = kicker end
				end
				add(best_pair, "keep pair+kicker")
			end
			if #plain > 0 then add({ plain[1] }, "keep one") end
		end
		return sets
	end

	-- ---------------------------------------------------------------------------------------------
	-- Monte Carlo rollouts
	-- ---------------------------------------------------------------------------------------------
	-- state: { hand (list), top (next index into perm), hands_left, discards_left, chips }
	local function draw_to(hand, perm, top, limit)
		while #hand < limit and perm[top] do
			hand[#hand + 1] = perm[top]
			top = top + 1
		end
		return top
	end

	local function remove_cards(hand, cards)
		local gone = {}
		for _, c in ipairs(cards) do gone[c] = true end
		local out = {}
		for _, c in ipairs(hand) do if not gone[c] then out[#out + 1] = c end end
		return out
	end

	-- PvP "save the best hand for the last hand" (strategy, docs/HANDOFF.md G.11): when jokers pay extra on the LAST hand (Dusk,
	-- Acrobat ...), the hand that scores most on the final play is kept in hand (its cards are reserved) while the other hands
	-- are played from the remaining cards. Returns the reserved played-card set, or nil when it makes no difference.
	local function reserve_for_last(hand, ctx, play_limit, hl)
		if hl <= 1 then return nil end
		local saved = ctx.hands_left
		ctx.hands_left = hl
		local now = candidates(hand, ctx, play_limit, true)
		ctx.hands_left = 1
		local last = candidates(hand, ctx, play_limit, true)
		ctx.hands_left = saved
		local a, b = now[1], last[1]
		if not (a and b) or b.score < a.score * 1.12 then return nil end
		local set = {}
		for _, c in ipairs(b.played) do set[c] = true end
		return set, b
	end

	local function disjoint_best(cands, reserved)
		for _, c in ipairs(cands) do
			local ok = true
			for _, x in ipairs(c.played) do
				if reserved[x] then ok = false; break end
			end
			if ok then return c end
		end
		return nil
	end

	-- plays the rest of the blind with a simple policy. need == nil -> maximise score ("max" mode).
	-- returns cleared (bool), unused hands, final chips
	local function rollout(S, perm, ctx, cfg)
		local hand, top, hl, dl, chips = S.hand, S.top, S.hands_left, S.discards_left, S.chips
		local need = cfg.need
		local par_fixed = cfg.par
		local steps = 0
		while steps < 24 do
			steps = steps + 1
			if #hand == 0 then break end
			ctx.hands_left, ctx.discards_left = hl, dl
			local cands = candidates(hand, ctx, cfg.play_limit, true)
			local b = cands[1]
			if not b then break end
			if cfg.save_last and hl > 1 then
				local reserved = reserve_for_last(hand, ctx, cfg.play_limit, hl)
				if reserved then
					local alt = disjoint_best(cands, reserved)
					if alt then b = alt end
				end
			end
			local total = chips + b.score
			if need and total >= need then return true, hl - 1, total end
			if hl <= 1 then return false, 0, total end
			local par = need and ((need - chips) / hl) or par_fixed
			local discard = false
			if dl > 0 and par and b.score < par then discard = true end
			if discard then
				local sets = keep_sets(hand, cands, ctx, true)
				-- policy: keep the made hand, unless a flush / straight draw is on and the made hand is weak
				local pick = sets[1]
				if (b.name == "High Card" or b.name == "Pair") then
					for _, s in ipairs(sets) do
						if s.tag == "flush draw" then pick = s; break end
					end
					if pick.tag ~= "flush draw" then
						for _, s in ipairs(sets) do
							if s.tag == "straight draw" then pick = s; break end
						end
					end
				end
				local dis = discards_for(hand, pick.keep, cfg.discard_limit, ctx)
				if #dis == 0 then
					discard = false
				else
					hand = remove_cards(hand, dis)
					top = draw_to(hand, perm, top, cfg.hand_limit)
					dl = dl - 1
				end
			end
			if not discard then
				chips = total
				hand = remove_cards(hand, b.played)
				top = draw_to(hand, perm, top, cfg.hand_limit)
				hl = hl - 1
				if hl <= 0 then break end
			end
		end
		return (need ~= nil and chips >= need), 0, chips
	end

	local function shuffled(pool)
		local n = #pool
		local perm = {}
		for i = 1, n do perm[i] = pool[i] end
		for i = n, 2, -1 do
			local j = math.floor(rnd() * i) + 1
			perm[i], perm[j] = perm[j], perm[i]
		end
		return perm
	end

	-- ---------------------------------------------------------------------------------------------
	-- the decision
	-- ---------------------------------------------------------------------------------------------
	-- st = {
	--   hand = {descriptors}, deck = {descriptors} (unordered draw pile), ctx = context,
	--   hands_left, discards_left, hand_limit, play_limit, discard_limit,
	--   need = chips still needed to clear (nil = maximise score), chips = chips so far (for "max" mode reporting),
	--   budget_ms, weights = { hands = 1.5, fail = 30, short = 8 }
	-- }
	-- -> { action = "play"|"discard", cards = {descriptors}, p_clear, util, name, score, tag, options = n }
	function P.plan(st)
		local ctx = st.ctx
		local hand = st.hand
		for i, c in ipairs(hand) do c.uid = i end
		for i, c in ipairs(st.deck) do c.uid = 1000 + i end
		for _, list in ipairs({ hand, st.deck }) do
			for _, c in ipairs(list) do
				if c.hx ~= 1 or c.hm ~= 0 then ctx.held_effects = true; break end
			end
		end
		local play_limit = st.play_limit or 5
		local discard_limit = st.discard_limit or 5
		local hand_limit = st.hand_limit or math.max(#hand, 8)
		local hands_left, discards_left = st.hands_left or 1, st.discards_left or 0
		local need = st.need
		local W = st.weights or { hands = 1.5, fail = 30, short = 8 }
		ctx.hands_left, ctx.discards_left = hands_left, discards_left
		ctx.deck_n = #st.deck
		local cfg = { need = need, play_limit = play_limit, discard_limit = discard_limit, hand_limit = hand_limit }
		cfg.save_last = ctx.pvp and hands_left > 1 and true or false

		-- SEALS (user 2026-10-06 22:58: "they keep playing purple seals even though discarding generates a tarot"):
		--   Purple  a Tarot when the card is DISCARDED (needs a free consumable slot) -> worth W.tarot, lost when the card is played
		--   Gold    $3 when the card is played
		-- A discard costs no hand, so Purple cards that are not part of the play are discarded first while a slot is free.
		local W_tarot, W_gold = W.tarot or st.tarot_w or 4.0, W.gold or 3.0
		local tarot_room = (discards_left > 0 and #st.deck > 0) and math.max(0, math.floor(st.tarot_slots or 0)) or 0
		local function count_seal(list, seal)
			local n = 0
			for _, c in ipairs(list) do if c.seal == seal then n = n + 1 end end
			return n
		end
		-- value of playing these cards beyond their score: Gold money, minus the Tarots the Purple ones would have given
		-- Retriggers repeat the money too (user 2026-10-06 23:27): a Gold Seal card pays $3 per trigger, a Lucky card $20 at 1 in 15 per trigger
		local W_lucky = W.lucky or (20 / 15)
		local function play_seal_value(cards)
			local v = 0
			for i, c in ipairs(cards) do
				if not c.debuff and (c.seal == "Gold" or c.lucky) then
					local reps = 1 + retriggers(c, i, ctx, i == 1)
					if c.seal == "Gold" then v = v + W_gold * reps end
					if c.lucky then v = v + W_lucky * reps end
				end
			end
			if tarot_room > 0 then v = v - W_tarot * math.min(tarot_room, count_seal(cards, "Purple")) end
			return v
		end
		-- the Purple cards of the hand that a discard could still turn into Tarots, never the ones in `keep_in` (the play we want)
		local function purple_to_discard(keep_in)
			if tarot_room <= 0 then return {} end
			local inp = {}
			for _, c in ipairs(keep_in or {}) do inp[c] = true end
			local out = {}
			for _, c in ipairs(hand) do
				if c.seal == "Purple" and not inp[c] and not c.debuff then out[#out + 1] = c end
			end
			table.sort(out, function(a, b) return (a.chips + 6 * a.mult) < (b.chips + 6 * b.mult) end)
			while #out > math.min(tarot_room, discard_limit) do table.remove(out) end
			return out
		end

		local plays = candidates(hand, ctx, play_limit, false)
		local best = plays[1]
		if not best then return nil end
		local info = { plays = #plays }
		-- a play that clears the blind right now is a sure thing (and keeps the most hands)
		if need and best.score >= need then
			local pick = best
			-- among the plays that clear, prefer the one that keeps Purple cards for a discard / plays Gold ones
			local top = -math.huge
			for k, p in ipairs(plays) do
				if k > 12 or p.score < need then break end
				local v = play_seal_value(p.played)
				if v > top + 1e-9 then top, pick = v, p end
			end
			local pd = purple_to_discard(pick.played)
			if #pd > 0 then
				return { action = "discard", cards = pd, p_clear = 1, util = W.hands * (hands_left - 1), name = nil,
					score = pick.score, tag = "purple seal: discard for a Tarot (clearing play stays)", options = 1, info = info }
			end
			return { action = "play", cards = pick.played, p_clear = 1, util = W.hands * (hands_left - 1), name = pick.name,
				score = pick.score, tag = "clears now", options = 1, info = info }
		end
		-- nothing to decide: last hand and no discard left
		if hands_left <= 1 and discards_left <= 0 then
			return { action = "play", cards = best.played, p_clear = 0, util = 0, name = best.name, score = best.score, tag = "last hand", options = 1, info = info }
		end

		-- candidate actions
		local cands = {}
		local nplays = 0
		local seen_name = {}
		-- PvP: never waste a hand on a lone card that is clearly weaker than the best play (user 2026-10-06 15:27: "the bot in pvp keeps playing
		-- a single card at the start ... they shouldn't just waste a hand like that"). Single-card hands that are (almost) the best play
		-- (Half Joker, Raised Fist, high-card builds) stay allowed.
		local function wasted_single(p)
			return ctx.pvp and hands_left > 1 and #p.played == 1 and p.score < best.score * 0.9
		end
		for _, p in ipairs(plays) do
			if nplays >= 5 then break end
			if wasted_single(p) then
				-- skipped
			elseif not seen_name[p.name] or nplays < 2 then
				seen_name[p.name] = true
				nplays = nplays + 1
				cands[#cands + 1] = { action = "play", cards = p.played, name = p.name, score = p.score, tag = "play " .. p.name,
					bonus = play_seal_value(p.played) }
			end
		end
		if cfg.save_last then
			-- PvP: also try the best hand that leaves the "last hand" cards in hand
			local reserved = reserve_for_last(hand, ctx, play_limit, hands_left)
			if reserved then
				local alt = disjoint_best(plays, reserved)
				if alt and not wasted_single(alt) then
					local dup = false
					for _, c in ipairs(cands) do if c.cards == alt.played then dup = true end end
					if not dup then cands[#cands + 1] = { action = "play", cards = alt.played, name = alt.name, score = alt.score, tag = "play " .. alt.name .. " (saving best for last)" } end
				end
			end
		end
		if discards_left > 0 and #st.deck > 0 then
			for _, ks in ipairs(keep_sets(hand, plays, ctx, false)) do
				local dis = discards_for(hand, ks.keep, discard_limit, ctx)
				if #dis > 0 then
					cands[#cands + 1] = { action = "discard", cards = dis, tag = "discard (" .. ks.tag .. ")",
						bonus = W_tarot * math.min(tarot_room, count_seal(dis, "Purple")) }
				end
			end
			-- a discard of nothing but the Purple Seal cards: a free Tarot, every other card stays
			local pd = purple_to_discard(nil)
			if #pd > 0 then
				cands[#cands + 1] = { action = "discard", cards = pd, tag = "discard (purple seals for Tarots)", bonus = W_tarot * #pd }
			end
		end
		if #cands == 1 then
			local c = cands[1]
			return { action = c.action, cards = c.cards, p_clear = 0, util = 0, name = c.name, score = c.score, tag = c.tag, options = 1, info = info }
		end
		info.candidates = #cands

		-- max mode: the par a hand has to hold in rollouts (no clear target): a bit above today's best play
		if not need then cfg.par = best.score * 1.15 end

		local clock = os.clock
		local t_end = clock() + (st.budget_ms or 80) / 1000
		local stats = {}
		for i = 1, #cands do stats[i] = { n = 0, sum = 0, sq = 0, clears = 0, unused = 0, active = true } end
		local active = #cands
		local sample = 0
		local max_samples = st.max_samples or 400
		local min_samples = st.min_samples or 12
		local W_hands, W_fail, W_short = W.hands or 1.5, W.fail or 30, W.short or 8
		local scale = 1
		if not need then scale = math.max(1, best.score) end

		while sample < max_samples do
			sample = sample + 1
			local perm = shuffled(st.deck)
			for ci, c in ipairs(cands) do
				local s = stats[ci]
				if s.active then
					local newhand, top, hl, dl, chips = {}, 1, hands_left, discards_left, 0
					for i, x in ipairs(hand) do newhand[i] = x end
					local util_cleared, cleared, unused, total
					if c.action == "play" then
						chips = c.score
						hl = hl - 1
						if need and chips >= need then
							cleared, unused, total = true, hl, chips
						else
							newhand = remove_cards(newhand, c.cards)
							top = draw_to(newhand, perm, top, hand_limit)
						end
					else
						newhand = remove_cards(newhand, c.cards)
						top = draw_to(newhand, perm, top, hand_limit)
						dl = dl - 1
					end
					if cleared == nil then
						if hl <= 0 then
							cleared, unused, total = (need ~= nil and chips >= need), 0, chips
						else
							cleared, unused, total = rollout({ hand = newhand, top = top, hands_left = hl, discards_left = dl, chips = chips }, perm, ctx, cfg)
						end
					end
					local u
					if need then
						if cleared then
							u = W_hands * unused
							s.clears = s.clears + 1
							s.unused = s.unused + unused
						else
							u = -W_fail - W_short * math.max(0, math.min(1, (need - total) / math.max(need, 1)))
						end
					else
						u = total / scale
					end
					if c.bonus and c.bonus ~= 0 then u = u + (need and c.bonus or 0.04 * c.bonus) end
					s.n = s.n + 1
					s.sum = s.sum + u
					s.sq = s.sq + u * u
				end
			end
			-- successive elimination once every active candidate has enough samples
			if sample >= min_samples and sample % 6 == 0 then
				local best_mean, best_i = -math.huge, 0
				for ci, s in ipairs(stats) do
					if s.active and s.sum / s.n > best_mean then best_mean, best_i = s.sum / s.n, ci end
				end
				for ci, s in ipairs(stats) do
					if s.active and ci ~= best_i then
						local m = s.sum / s.n
						local var = math.max(0, s.sq / s.n - m * m)
						local se = math.sqrt(var / s.n + 1e-9)
						local b = stats[best_i]
						local bm = b.sum / b.n
						local bse = math.sqrt(math.max(0, b.sq / b.n - bm * bm) / b.n + 1e-9)
						if m + 2.5 * se < bm - 2.5 * bse and active > 1 then
							s.active = false
							active = active - 1
						end
					end
				end
				if active <= 1 then break end
			end
			if sample >= min_samples and clock() > t_end then break end
		end
		info.samples = sample
		info.scale = scale
		info.table = {}
		for ci, c in ipairs(cands) do
			local s2 = stats[ci]
			local ix = {}
			for _, cd in ipairs(c.cards) do if cd.i then ix[#ix + 1] = cd.i end end
			table.sort(ix)
			info.table[ci] = { tag = c.tag, action = c.action, idx = ix, n = s2.n, util = s2.n > 0 and s2.sum / s2.n or nil, p_clear = (need and s2.n > 0) and s2.clears / s2.n or nil }
		end

		local pick, pick_u = 1, -math.huge
		for ci, s in ipairs(stats) do
			if s.n > 0 then
				local m = s.sum / s.n
				-- tie-break toward actually scoring something now
				local c = cands[ci]
				if c.action == "play" and best.score > 0 then m = m + 1e-6 * (c.score / best.score) end
				if m > pick_u then pick, pick_u = ci, m end
			end
		end
		local c, s = cands[pick], stats[pick]
		local res = { action = c.action, cards = c.cards, name = c.name, score = c.score, tag = c.tag, options = #cands, info = info,
			util = pick_u, samples = s.n }
		if need then
			res.p_clear = s.n > 0 and s.clears / s.n or 0
			res.exp_unused = s.clears > 0 and s.unused / s.clears or 0
		else
			res.exp_score = pick_u * scale
		end
		return res
	end

	-- ---------------------------------------------------------------------------------------------
	-- live-game entry point
	-- ---------------------------------------------------------------------------------------------
	-- Returns the plan table above with `.idx` = positions in G.hand.cards, or nil when it cannot plan.
	function P.decide(opts)
		opts = opts or {}
		if not (G and G.hand and G.GAME and G.GAME.current_round) then return nil end
		local cards = U.cards(G.hand)
		if #cards == 0 then return nil end
		local hand = {}
		for i, c in ipairs(cards) do hand[i] = P.describe(c, i) end
		local deck = {}
		for _, c in ipairs(U.cards(G.deck)) do deck[#deck + 1] = P.describe(c) end
		local cr = G.GAME.current_round
		local ctx = P.live_context()
		ctx.has_held = ctx.has_held
		for _, c in ipairs(hand) do
			if c.hx ~= 1 or c.hm ~= 0 then ctx.held_effects = true; break end
		end
		local C = A.cfg or {}
		local st = {
			hand = hand, deck = deck, ctx = ctx,
			hands_left = cr.hands_left or 1, discards_left = cr.discards_left or 0,
			hand_limit = num(G.hand.config and G.hand.config.card_limit, #hand), -- cards the game refills the hand to
			play_limit = math.max(1, math.min(num(G.GAME.starting_params and G.GAME.starting_params.play_limit, 5), 5)),
			discard_limit = math.max(1, math.min(num(G.GAME.starting_params and G.GAME.starting_params.discard_limit, 5), 5)),
			need = opts.need, budget_ms = opts.budget_ms or C.plan_ms or 80,
		}
		if st.hand_limit < #hand then st.hand_limit = #hand end
		-- free consumable slots (a Purple Seal discard needs one); the reward weight of a Tarot comes from the reward module
		do
			local cons = G.consumeables
			local limit = cons and cons.config and num(cons.config.card_limit, 0) or 0
			local used = #U.cards(cons) + num(G.GAME.consumeable_buffer, 0)
			st.tarot_slots = opts.tarot_slots or math.max(0, limit - used)
			local rw = A.reward and A.reward.W
			st.tarot_w = rw and rw.tarot or nil
		end
		-- The Hook (ante-1 boss) discards two random cards from your hand after every play: get out of the blind with as few hands as possible
		-- (strategy G.17). Clearing early is worth more than usual.
		local bl = G.GAME.blind
		if bl and (bl.name == "The Hook" or (bl.config and bl.config.blind and bl.config.blind.key == "bl_hook")) and not opts.weights then
			st.weights = { hands = 4.5, fail = 30, short = 8 }
			st.hook = true
		end
		local res = P.plan(st)
		if not res then return nil end
		res.idx = {}
		for _, c in ipairs(res.cards) do
			if c.i then res.idx[#res.idx + 1] = c.i end
		end
		table.sort(res.idx)
		P.stats.decisions = P.stats.decisions + 1
		P.last = {
			action = res.action, tag = res.tag, name = res.name, score = res.score and math.floor(res.score),
			p_clear = res.p_clear and math.floor(res.p_clear * 1000) / 1000, exp_unused = res.exp_unused,
			need = opts.need, hands_left = st.hands_left, discards_left = st.discards_left,
			deck = #deck, options = res.options, samples = res.samples,
		}
		return res
	end

	-- ---------------------------------------------------------------------------------------------
	-- joker-set potential (used by the decision layer to value shop / pack choices)
	-- ---------------------------------------------------------------------------------------------
	-- P.sample_hands(k, n): k random n-card hands drawn from the WHOLE deck (G.playing_cards) as descriptors; build once per
	-- decision and reuse across candidates so differences between joker sets are not sampling noise.
	function P.sample_hands(k, n)
		local pool = {}
		for i, c in ipairs((G and G.playing_cards) or {}) do pool[i] = P.describe(c, i) end
		if #pool == 0 then return {} end
		local out = {}
		n = math.min(n or 8, #pool)
		for s = 1, k or 8 do
			local idx = {}
			for i = 1, #pool do idx[i] = i end
			local hand = {}
			for j = 1, n do
				local r = j + math.floor(rnd() * (#idx - j + 1))
				idx[j], idx[r] = idx[r], idx[j]
				local d = {}
				for kk, v in pairs(pool[idx[j]]) do d[kk] = v end
				d.uid = j
				hand[j] = d
			end
			out[s] = hand
		end
		return out
	end

	-- Mean over the sampled hands of the best single-hand score with `jokers` (list of joker card objects), plus mean log10.
	-- Hand levels, hand sizes and play limits come from the live game, so planets show up here too.
	function P.potential(samples, jokers, extra)
		if not samples or #samples == 0 then return 0, 0 end
		local ctx = P.live_context({ jokers = jokers })
		if type(extra) == "function" then extra(ctx)
		elseif extra then for k, v in pairs(extra) do ctx[k] = v end end
		ctx.hands_left = ctx.hands_left or 4
		local play_limit = math.max(1, math.min(num(G and G.GAME and G.GAME.starting_params and G.GAME.starting_params.play_limit, 5), 5))
		local sum, slog = 0, 0
		for _, hand in ipairs(samples) do
			ctx.held_effects = nil
			for _, c in ipairs(hand) do
				if c.hx ~= 1 or c.hm ~= 0 then ctx.held_effects = true; break end
			end
			local list = candidates(hand, ctx, play_limit, true)
			local best = list[1] and list[1].score or 0
			sum = sum + best
			slog = slog + math.log10(best + 1)
		end
		return sum / #samples, slog / #samples
	end

	-- ---------------------------------------------------------------------------------------------
	-- calibration: compare the predicted score of the hand we played with what the game awarded
	-- ---------------------------------------------------------------------------------------------
	function P.expect(name, predicted)
		local cr = G and G.GAME and G.GAME.current_round
		P.pending = { name = name, predicted = predicted, chips = num(G and G.GAME and G.GAME.chips, 0), hp = cr and cr.hands_played or 0 }
	end

	-- called every tick during a run (cheap)
	function P.observe()
		local p = P.pending
		if not p or not (G and G.GAME and G.GAME.current_round) then return end
		local hp = G.GAME.current_round.hands_played or 0
		if hp <= p.hp then return end
		local st = G.STATE
		local S = G.STATES or {}
		local final = (st == S.SELECTING_HAND and A.obs.settled()) or st == S.ROUND_EVAL or st == S.SHOP
		if not final then return end
		P.pending = nil
		local delta = num(G.GAME.chips, 0) - p.chips
		if delta > 0 and p.predicted and p.predicted > 0 then
			local ratio = math.max(0.25, math.min(6, delta / p.predicted))
			local old = P.calib[p.name]
			-- the prediction already contains the old factor: fold the new evidence in multiplicatively
			local new = (old or 1) * ratio
			P.calib[p.name] = old and (old * 0.6 + new * 0.4) or new
			P.calib[p.name] = math.max(0.25, math.min(6, P.calib[p.name]))
			local all = P.calib_all or 1
			P.calib_all = math.max(0.25, math.min(6, all * 0.7 + (all * ratio) * 0.3))
			P.stats.observed = (P.stats.observed or 0) + 1
		end
	end

	function P.reset()
		P.calib, P.calib_all, P.pending, P.last = {}, nil, nil, nil
	end

	return P
end
