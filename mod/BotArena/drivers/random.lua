-- Random driver: legal-but-silly play. Useful for stress-testing the arena plumbing and as a weak sparring
-- partner. Always progresses (never loops) because every screen has a default "move on" action.
return function(A)
	local U, O, X, C = A.util, A.obs, A.act, A.cfg
	local D = { name = "random" }

	local state = (C.driver_seed or 1) % 2147483647
	local function rand()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	local function pick(n) return math.floor(rand() * n) + 1 end

	local sig, tries = nil, {}
	local function tried(key, limit)
		tries[key] = (tries[key] or 0) + 1
		return tries[key] > (limit or 1)
	end

	function D.step(memo)
		local s = tostring(G.STATE) .. tostring(G.GAME.round)
		if s ~= sig then sig, tries = s, {} end
		local S = G.STATES
		local st = G.STATE

		if st == S.BLIND_SELECT then
			if C.skip_blinds > 0 and X.can_skip_blind() and rand() < C.skip_blinds and not tried("skip") then
				if X.skip_blind() then return true end
			end
			if tried("select", 6) then return false end
			return X.select_blind()
		elseif st == S.SELECTING_HAND then
			local n = #G.hand.cards
			if n == 0 then return false end
			local k = math.min(n, pick(5))
			local idx, used = {}, {}
			while #idx < k do
				local i = pick(n)
				if not used[i] then used[i] = true; idx[#idx + 1] = i end
			end
			if X.can_discard() and (G.GAME.current_round.hands_left or 0) > 1 and rand() < 0.3 and not tried("d", 3) then
				if X.discard(idx) then tries = {}; return true end
			end
			if X.play(idx) then tries = {}; return true end
			return X.play({ 1 })
		elseif st == S.ROUND_EVAL then
			return X.cash_out()
		elseif st == S.SHOP then
			local jokers = G.shop_jokers and G.shop_jokers.cards or {}
			if #jokers > 0 and rand() < 0.5 then
				local card = jokers[pick(#jokers)]
				if not tried("buy" .. tostring(card.sort_id)) and X.buy(card) then return true end
			end
			if not tried("leave", 5) then return X.leave_shop() end
		elseif U.pack_open() or st == S.TAROT_PACK or st == S.PLANET_PACK or st == S.SPECTRAL_PACK
			or st == S.STANDARD_PACK or st == S.BUFFOON_PACK or st == (S.SMODS_BOOSTER_OPENED or -1) then
			if not tried("skip_pack", 5) then return X.skip_pack() end
		end
		return false
	end

	function D.unstick()
		local S = G.STATES
		if G.STATE == S.SHOP then X.leave_shop()
		elseif G.STATE == S.ROUND_EVAL then X.cash_out()
		elseif U.pack_open() then X.skip_pack() end
	end

	return D
end
