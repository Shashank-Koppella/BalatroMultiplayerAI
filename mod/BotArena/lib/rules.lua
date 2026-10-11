-- BotArena deck / stake rules.
--
-- 1. THE LOADOUT: every lobby plays a random vanilla deck on a random stake (user 2026-10-06 16:32).
--      decks   the 15 base-game decks (Red ... Erratic). Nothing modded, no Multiplayer cocktail / challenge decks.
--      stakes  White, Green, Black, Purple, Gold and Spectral+ (the Multiplayer mod's top stake). Nothing else.
--    The host rolls both right before it presses Start, writes them into MP.LOBBY.config.back / .stake and sends them with
--    lobbyOptions. Both players use the host's deck and stake (different_decks is off), so the match is symmetric.
--
-- 2. THE RULES THE BOTS KNOW: every rule is read LIVE from the game (G.GAME.modifiers, the selected deck, the stickers on the
--    cards), never from a table of "what stake N does", so a rule can not drift from the game. This module turns them into
--      R.live()    one table of facts the planner, the shop logic and the reward module use
--      R.sx(sx)    the same facts as numbers for the decision log / trainer (state features: deck + stake one-hot, no_interest, ...)
--
--    Stakes (each includes the ones before it, Multiplayer's Spectral+ includes Planet and Spectral):
--      White      nothing
--      Green      Small Blind pays $0 (Red's rule), scaling 2 (blind targets grow faster)
--      Black      + Eternal jokers appear in the shop (30 %): cannot be sold, destroyed or swapped away
--      Purple     + one discard fewer (Blue's rule), scaling 3
--      Gold       + Perishable jokers (debuffed after 5 rounds) and Rental jokers ($3 at the end of every round)
--      Spectral+  Green + Black + Purple (no discard loss) + Gold's stickers, scaling 5
--    Decks (what the bots must account for):
--      Red +1 discard, Blue +1 hand, Yellow +$10, Black -1 hand +1 joker slot, Painted +2 hand size -1 joker slot,
--      Magic Crystal Ball + 2 Fool, Nebula Telescope -1 consumable slot, Zodiac Tarot / Planet Merchant + Overstock,
--      Ghost Spectral cards twice as common + starts with Hex (destroys every other joker!), Abandoned no face cards,
--      Checkered only Spades and Hearts, Erratic random ranks and suits, Anaglyph a Double Tag after every boss blind,
--      Plasma balances chips and mult after the jokers (floor((chips + mult) / 2) each) and blinds are 2x,
--      Green $2 per unused hand + $1 per unused discard and NO interest.
return function(A)
	local U, C = A.util, A.cfg
	local R = {}

	R.DECKS = {
		"b_red", "b_blue", "b_yellow", "b_green", "b_black", "b_magic", "b_nebula", "b_ghost",
		"b_abandoned", "b_checkered", "b_zodiac", "b_painted", "b_anaglyph", "b_plasma", "b_erratic",
	}
	R.DECK_SHORT = {
		b_red = "red", b_blue = "blue", b_yellow = "yellow", b_green = "green", b_black = "black", b_magic = "magic",
		b_nebula = "nebula", b_ghost = "ghost", b_abandoned = "abandoned", b_checkered = "checkered", b_zodiac = "zodiac",
		b_painted = "painted", b_anaglyph = "anaglyph", b_plasma = "plasma", b_erratic = "erratic",
	}
	R.STAKES = { "stake_white", "stake_green", "stake_black", "stake_purple", "stake_gold", "stake_mp_spectralplus" }
	R.STAKE_SHORT = {
		stake_white = "white", stake_green = "green", stake_black = "black", stake_purple = "purple", stake_gold = "gold",
		stake_mp_spectralplus = "spectralplus",
	}
	-- fixed feature columns (the trainer's state vector has one slot for each; never reorder)
	R.DECK_ORDER = R.DECKS
	R.STAKE_ORDER = R.STAKES

	local function in_list(list, x)
		for _, v in ipairs(list) do if v == x then return true end end
		return false
	end

	-- BOTARENA_DECKS / BOTARENA_STAKES accept short names ("plasma", "gold") or keys, comma separated; unknown names are ignored
	local function parse_filter(str, all, short)
		if not str or str == "" then return nil end
		local out = {}
		for tok in tostring(str):gmatch("[^,%s]+") do
			tok = tok:lower()
			for _, key in ipairs(all) do
				if key:lower() == tok or short[key] == tok or short[key] .. "deck" == tok or short[key] .. "stake" == tok then
					if not in_list(out, key) then out[#out + 1] = key end
				end
			end
		end
		return #out > 0 and out or nil
	end

	-- ---------------------------------------------------------------------------------------------
	-- the random loadout
	-- ---------------------------------------------------------------------------------------------
	local state
	local function rnd()
		if not state then
			state = math.floor((U.wall() * 1000) % 2147483647) + (C.id or 0) * 7919 + 17
			state = state % 2147483647
			if state == 0 then state = 1 end
		end
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	local function pick(list)
		return list[1 + math.floor(rnd() * #list) % #list]
	end

	function R.deck_pool()
		local filt = parse_filter(C.loadout_decks, R.DECKS, R.DECK_SHORT)
		local out = {}
		for _, key in ipairs(filt or R.DECKS) do
			if G and G.P_CENTERS and G.P_CENTERS[key] then out[#out + 1] = key end
		end
		return out
	end

	-- stake keys -> index in the stake list the game starts runs with (G.P_CENTER_POOLS.Stake order)
	function R.stake_index(key)
		if G and G.P_CENTER_POOLS and G.P_CENTER_POOLS.Stake then
			for i, s in ipairs(G.P_CENTER_POOLS.Stake) do
				if s.key == key then return i end
			end
		end
		local s = G and G.P_STAKES and G.P_STAKES[key]
		return s and s.order or nil
	end

	function R.stake_pool()
		local filt = parse_filter(C.loadout_stakes, R.STAKES, R.STAKE_SHORT)
		local out = {}
		for _, key in ipairs(filt or R.STAKES) do
			if R.stake_index(key) then out[#out + 1] = key end
		end
		return out
	end

	-- -> { deck_key, deck, stake_key, stake } or nil when no deck / stake of the pools exists in this game
	function R.roll()
		local decks, stakes = R.deck_pool(), R.stake_pool()
		if #decks == 0 or #stakes == 0 then return nil end
		local dk, sk = pick(decks), pick(stakes)
		return { deck_key = dk, deck = G.P_CENTERS[dk].name, stake_key = sk, stake = R.stake_index(sk) }
	end

	-- write the roll into the lobby options and tell the guest (the host only)
	function R.apply_roll(roll)
		if not roll or not (MP and MP.LOBBY and MP.LOBBY.config) then return false end
		MP.LOBBY.config.back = roll.deck
		MP.LOBBY.config.stake = roll.stake
		MP.LOBBY.config.challenge = ""
		if MP.LOBBY.config.different_decks ~= nil then MP.LOBBY.config.different_decks = false end
		if MP.ACTIONS and MP.ACTIONS.lobby_options then MP.ACTIONS.lobby_options() end
		return true
	end

	-- ---------------------------------------------------------------------------------------------
	-- the live rules
	-- ---------------------------------------------------------------------------------------------
	local function num(x, d)
		x = tonumber(x)
		if x == nil or x ~= x then return d end
		return x
	end

	function R.deck_name()
		local b = G and G.GAME and G.GAME.selected_back
		if not b then return nil end
		return b.name or (b.effect and b.effect.center and b.effect.center.name)
	end

	function R.deck_key()
		local b = G and G.GAME and G.GAME.selected_back
		local k = b and b.effect and b.effect.center and b.effect.center.key
		if k then return k end
		local nm = R.deck_name()
		for _, key in ipairs(R.DECKS) do
			if G and G.P_CENTERS and G.P_CENTERS[key] and G.P_CENTERS[key].name == nm then return key end
		end
		return nil
	end

	function R.stake_key()
		local i = G and G.GAME and G.GAME.stake
		local s = i and G.P_CENTER_POOLS and G.P_CENTER_POOLS.Stake and G.P_CENTER_POOLS.Stake[i]
		return s and s.key or nil
	end

	local function count_tag(key)
		local n = 0
		for _, t in ipairs((G and G.GAME and G.GAME.tags) or {}) do
			if t and t.key == key then n = n + 1 end
		end
		return n
	end

	-- one table with every rule the bots act on. Cheap; call it freely (the shop logic calls it per decision).
	function R.live()
		local g = (G and G.GAME) or {}
		local m = g.modifiers or {}
		local nbr = m.no_blind_reward or {}
		local o = {
			deck_key = R.deck_key(), deck = R.deck_name(), stake = num(g.stake, 1), stake_key = R.stake_key(),
			scaling = num(m.scaling, 1),
			small_pays = not nbr.Small, big_pays = not nbr.Big, boss_pays = not nbr.Boss,
			no_interest = m.no_interest and true or false,
			money_per_hand = num(m.money_per_hand, 1), money_per_discard = num(m.money_per_discard, 0),
			eternals = m.enable_eternals_in_shop and true or false,
			perishables = m.enable_perishables_in_shop and true or false,
			rentals = m.enable_rentals_in_shop and true or false,
			rental_rate = num(g.rental_rate, 3), perish_rounds = num(g.perishable_rounds, 5),
		}
		local dn = o.deck
		o.plasma = dn == "Plasma Deck"
		o.ghost = dn == "Ghost Deck"
		o.anaglyph = dn == "Anaglyph Deck"
		o.abandoned = dn == "Abandoned Deck"
		o.checkered = dn == "Checkered Deck"
		o.double_tags = count_tag("tag_double")
		-- stickers on the jokers we own
		local rentals, perished, perishing, eternal = 0, 0, 0, 0
		for _, j in ipairs(U.cards(G and G.jokers)) do
			local ab = j.ability or {}
			if ab.rental then rentals = rentals + 1 end
			if ab.eternal then eternal = eternal + 1 end
			if ab.perishable then
				if num(ab.perish_tally, 1) <= 0 then perished = perished + 1 else perishing = perishing + 1 end
			end
		end
		o.n_rental, o.n_perished, o.n_perishing, o.n_eternal = rentals, perished, perishing, eternal
		o.rental_cost = rentals * o.rental_rate -- paid at the end of every round
		return o
	end

	-- Small / Big / Boss base payout the game gives for the blind on deck (0 when the stake removes it)
	local BASE_PAY = { Small = 3, Big = 4, Boss = 5 }
	function R.blind_pay(which, live)
		live = live or R.live()
		if which == "Small" and not live.small_pays then return 0 end
		if which == "Big" and not live.big_pays then return 0 end
		if which == "Boss" and not live.boss_pays then return 0 end
		return BASE_PAY[which] or 3
	end

	-- state features for the decision log (all numbers; the trainer appends them at the END of its state vector)
	function R.sx(sx, live)
		local o = live or R.live()
		-- zeros are left out (the trainer reads a missing feature as 0): the log stays small, the hand log has one row per hand played
		local function put(k, v)
			if v ~= 0 and v ~= nil then sx[k] = v end
		end
		sx.r_scaling = o.scaling
		sx.r_small_pays = o.small_pays and 1 or 0
		sx.r_mph = o.money_per_hand
		put("r_rental_rate", o.rentals and o.rental_rate or 0)
		put("r_eternal_n", o.n_eternal)
		put("r_no_interest", o.no_interest and 1 or 0)
		put("r_mpd", o.money_per_discard)
		put("r_eternals", o.eternals and 1 or 0)
		put("r_perishables", o.perishables and 1 or 0)
		put("r_rentals", o.rentals and 1 or 0)
		put("r_rental_cost", o.rental_cost)
		put("r_perished", o.n_perished)
		put("r_double_tags", o.double_tags)
		put("r_plasma", o.plasma and 1 or 0)
		for _, key in ipairs(R.DECK_ORDER) do put("dk_" .. R.DECK_SHORT[key], (o.deck_key == key) and 1 or 0) end
		for _, key in ipairs(R.STAKE_ORDER) do put("sk_" .. R.STAKE_SHORT[key], (o.stake_key == key) and 1 or 0) end
		return sx
	end

	return R
end
