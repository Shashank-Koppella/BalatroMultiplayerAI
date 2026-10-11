-- BotArena hand helpers shared by the drivers and the reward module: a cheap score estimate for a set of
-- cards and a bounded search for the best play in the current hand.
--
-- The estimate uses the hand type's base chips x mult plus the scoring cards' chip bonuses. It does NOT know
-- about jokers, so on a joker-heavy board it under-estimates; callers that need a bound should combine it
-- with scores that were actually observed (see reward.lua).
return function(A)
	local U = A.util
	local H = {}

	-- estimate(cards) -> score, hand_text, scoring_cards
	function H.estimate(cards)
		local ok, text, _, _, scoring = pcall(G.FUNCS.get_poker_hand_info, cards)
		if not ok or not text or text == "NULL" then return 0, "NULL", {} end
		local h = G.GAME.hands[text]
		if not h then return 0, text, {} end
		local chips, mult = h.chips or 0, h.mult or 1
		for _, c in ipairs(scoring or {}) do
			if not c.debuff then
				local okc, bonus = pcall(c.get_chip_bonus, c)
				if okc and type(bonus) == "number" then chips = chips + bonus end
			end
		end
		return chips * mult, text, scoring or {}
	end

	-- Enumerate subsets of size 1..play_limit of G.hand.cards (capped at `cap` evaluations) and return the
	-- best one: { score, idx = {indices into G.hand.cards}, text, scoring }.
	function H.best_play(cap)
		local hand = (G and G.hand and G.hand.cards) or {}
		local n = #hand
		local limit = math.max(1, math.min(G.GAME.starting_params and G.GAME.starting_params.play_limit or 5, 5))
		local best = { score = -1, idx = {}, text = "NULL", scoring = {} }
		local evals, max_evals = 0, cap or 320

		local function consider(idx)
			evals = evals + 1
			local cards = {}
			for i, k in ipairs(idx) do cards[i] = hand[k] end
			local score, text, scoring = H.estimate(cards)
			-- prefer fewer cards on ties (keeps the rest of the hand for later draws)
			if score > best.score or (score == best.score and #idx < #best.idx) then
				best = { score = score, idx = U.shallow_copy(idx), text = text, scoring = scoring }
			end
		end

		local function rec(start, idx, size)
			if #idx == size then
				consider(idx)
				return
			end
			for k = start, n do
				if evals >= max_evals then return end
				idx[#idx + 1] = k
				rec(k + 1, idx, size)
				idx[#idx] = nil
			end
		end
		for size = math.min(limit, n), 1, -1 do
			rec(1, {}, size)
			if evals >= max_evals then break end
		end
		return best
	end

	-- Score estimate of the best play available right now (0 when there is no hand).
	function H.best_estimate()
		if not (G and G.hand and G.hand.cards and #G.hand.cards > 0) then return 0 end
		local ok, best = pcall(H.best_play, 120)
		if ok and best and best.score and best.score > 0 then return best.score end
		return 0
	end

	return H
end
