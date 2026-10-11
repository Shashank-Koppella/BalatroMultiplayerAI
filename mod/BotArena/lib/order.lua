-- BotArena joker order: jokers score left to right, so the ORDER of the joker row is part of the build.
--   * +chips / +mult jokers belong LEFT of the x-mult jokers (an x-mult multiplies everything to its left),
--   * Brainstorm copies the LEFTMOST joker, Blueprint the joker to its RIGHT - their value depends entirely on where they stand,
--   * editions apply in order (polychrome after its own joker), retrigger / copy chains too.
-- The planner (lib/plan.lua) already scores a hand with the jokers in the order it is given, so the best order is found by search:
-- score the same sampled hands with every order (all permutations up to 5 jokers, hill-climbing by insertion beyond that) and
-- move the cards to the best one when it is clearly (>= 1 %) better than the current order. Nothing is learned here: with the scoring
-- model fixed this is an optimisation problem, and the model's per-hand calibration (plan.lua P.observe) keeps it honest.
-- Constraints: pinned jokers stay at the left; Ceremonial Dagger stays rightmost (it destroys the joker to its right).
-- The arena tick calls O.tick() when the game is idle (shop, blind select, first hand) and the joker set / hand levels changed.
return function(A)
	local U, C, P = A.util, A.cfg, A.plan
	local O = { stats = { runs = 0, moves = 0, errors = 0, evals = 0 }, sig = nil, last = nil, t_run = 0 }

	local function jokers()
		return U.cards(G and G.jokers)
	end

	local function name_of(j)
		return (j.ability and j.ability.name) or (j.config and j.config.center and j.config.center.name) or "?"
	end

	local function pinned(j)
		return (j.pinned and not j.ignore_pinned) and true or false
	end

	-- identity of the joker SET (order independent) + hand levels: the order is searched again only when this changes
	local function signature(list)
		local ids = {}
		for i, j in ipairs(list) do
			local ed = type(j.edition) == "table" and j.edition.type or ""
			ids[i] = tostring(j.sort_id or j.unique_val or i) .. ed .. (j.debuff and "d" or "")
		end
		table.sort(ids)
		local lv = 0
		for _, h in pairs((G.GAME and G.GAME.hands) or {}) do
			if type(h) == "table" then lv = lv + (tonumber(h.level) or 0) end
		end
		return table.concat(ids, ",") .. "|" .. lv
	end

	local function perms(n, fn)
		local a = {}
		for i = 1, n do a[i] = i end
		local function rec(k)
			if k > n then fn(a); return end
			for i = k, n do
				a[k], a[i] = a[i], a[k]
				rec(k + 1)
				a[k], a[i] = a[i], a[k]
			end
		end
		rec(1)
	end

	-- list of joker objects for an index order over `movable` after the fixed (pinned) ones
	local function build(fixed, movable, order)
		local out = {}
		for _, j in ipairs(fixed) do out[#out + 1] = j end
		for _, i in ipairs(order) do out[#out + 1] = movable[i] end
		return out
	end

	local function value(samples, list)
		O.stats.evals = O.stats.evals + 1
		local m = P.potential(samples, list)
		-- Ceremonial Dagger eats the joker on its right: never leave one there
		for i, j in ipairs(list) do
			if name_of(j) == "Ceremonial Dagger" and list[i + 1] and not (list[i + 1].ability and list[i + 1].ability.eternal) then
				m = m * 0.6
			end
		end
		return m
	end

	-- -> best list of joker objects, its value, the value of the current order, number of orders tried
	function O.search(budget_ms)
		local cur = jokers()
		local n = #cur
		if n < 2 then return nil end
		local fixed, movable = {}, {}
		for _, j in ipairs(cur) do
			if pinned(j) and #movable == 0 then fixed[#fixed + 1] = j else movable[#movable + 1] = j end
		end
		if #movable < 2 then return nil end
		local size = tonumber(G.hand and G.hand.config and G.hand.config.card_limit) or 8
		if size < 5 then size = 8 end
		local samples = P.sample_hands(C.joker_order_samples or 14, size)
		if not samples or #samples == 0 then return nil end
		local t_end = os.clock() + (budget_ms or 400) / 1000
		local ident = {}
		for i = 1, #movable do ident[i] = i end
		local cur_v = value(samples, build(fixed, movable, ident))
		local best_v, best_order = cur_v, ident
		local tried = 1
		local m = #movable
		if m <= 5 then
			perms(m, function(a)
				if os.clock() > t_end and tried > 6 then return end
				tried = tried + 1
				local v = value(samples, build(fixed, movable, a))
				if v > best_v * (1 + 1e-9) then
					best_v = v
					best_order = {}
					for i = 1, m do best_order[i] = a[i] end
				end
			end)
		else
			-- hill-climb by insertion from the current order and from a few shuffles
			local function climb(start)
				local order = {}
				for i = 1, m do order[i] = start[i] end
				local v = value(samples, build(fixed, movable, order))
				local improved = true
				while improved and os.clock() < t_end do
					improved = false
					local bi, bj, bv = nil, nil, v
					for i = 1, m do
						for j = 1, m do
							if i ~= j then
								local o2 = {}
								for k = 1, m do o2[k] = order[k] end
								local x = table.remove(o2, i)
								table.insert(o2, j, x)
								tried = tried + 1
								local v2 = value(samples, build(fixed, movable, o2))
								if v2 > bv * (1 + 1e-9) then bi, bj, bv = i, j, v2 end
							end
						end
					end
					if bi then
						local x = table.remove(order, bi)
						table.insert(order, bj, x)
						v = bv
						improved = true
					end
				end
				return order, v
			end
			local o1, v1 = climb(ident)
			if v1 > best_v then best_v, best_order = v1, o1 end
			for _ = 1, 3 do
				if os.clock() > t_end then break end
				local sh = {}
				for i = 1, m do sh[i] = i end
				for i = m, 2, -1 do
					local j = 1 + math.floor(math.random() * i)
					sh[i], sh[j] = sh[j], sh[i]
				end
				local o2, v2 = climb(sh)
				if v2 > best_v then best_v, best_order = v2, o2 end
			end
		end
		return build(fixed, movable, best_order), best_v, cur_v, tried
	end

	-- put the joker objects in `list` order (in place: other code keeps references to G.jokers.cards)
	function O.apply(list)
		local cards = G.jokers.cards
		for i, j in ipairs(list) do cards[i] = j end
		if G.jokers.set_ranks then pcall(G.jokers.set_ranks, G.jokers) end
		for i, j in ipairs(list) do j.rank = i end
		return true
	end

	local function names(list)
		local t = {}
		for i, j in ipairs(list) do t[i] = name_of(j) end
		return table.concat(t, " > ")
	end

	-- one optimisation pass; returns true when the row was changed
	function O.optimise(force)
		local list = jokers()
		if #list < 2 then O.sig = signature(list); return false end
		O.stats.runs = O.stats.runs + 1
		local ok, best, bv, cv, tried = pcall(O.search, C.joker_order_ms or 400)
		if not ok then
			O.stats.errors = O.stats.errors + 1
			U.err("joker order search failed: " .. tostring(best))
			O.sig = signature(list)
			return false
		end
		if not best then O.sig = signature(list); return false end
		local thr = C.joker_order_gain or 0.01
		local changed = false
		if bv > cv * (1 + thr) then
			local before = names(list)
			O.apply(best)
			changed = true
			O.stats.moves = O.stats.moves + 1
			O.last = { before = before, after = names(best), gain = bv / math.max(cv, 1e-9), tried = tried }
			U.info(string.format("joker order: %s  ->  %s  (x%.2f over %d orders)", before, O.last.after, O.last.gain, tried))
			if A.fsm and A.fsm.event then pcall(A.fsm.event, "joker_order", { before = before, after = O.last.after, gain = math.floor(O.last.gain * 1000) / 1000 }) end
		end
		O.sig = signature(jokers())
		return changed
	end

	-- called by the arena when the game is idle. Returns true when it moved cards (the caller skips the driver this tick).
	function O.tick()
		if not (G and G.jokers and G.STATES and G.GAME) then return false end
		local S = G.STATES
		local st = G.STATE
		if not (st == S.SHOP or st == S.BLIND_SELECT or st == S.SELECTING_HAND) then return false end
		local list = jokers()
		if #list < 2 then O.sig = nil; return false end
		local now = U.now()
		if now - O.t_run < (C.joker_order_gap or 1.0) then return false end
		local sig = signature(list)
		if sig == O.sig then return false end
		O.t_run = now
		return O.optimise()
	end

	function O.reset()
		O.sig, O.last = nil, nil
	end

	return O
end
