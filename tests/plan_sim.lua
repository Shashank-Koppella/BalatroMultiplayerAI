-- Offline blind simulator for the hand planner (lib/plan.lua): plays many 4-hand / 3-discard blinds from a
-- real 52-card deck with a given joker lineup under a policy, and reports the clear rate.
--   PLAN_SIM.run{ blinds=, need=, jokers={ {name=, ab={...}} }, policy="plan"|"greedy"|"keep", budget_ms=, seed= }
-- Used by tests/run_tests.py (planner tests) and for tuning; it never touches the game.
PLAN_SIM = {}

local LEVELS = {
	["High Card"] = { chips = 5, mult = 1 }, ["Pair"] = { chips = 10, mult = 2 }, ["Two Pair"] = { chips = 20, mult = 2 },
	["Three of a Kind"] = { chips = 30, mult = 3 }, ["Straight"] = { chips = 30, mult = 4 }, ["Flush"] = { chips = 35, mult = 4 },
	["Full House"] = { chips = 40, mult = 4 }, ["Four of a Kind"] = { chips = 60, mult = 7 }, ["Straight Flush"] = { chips = 100, mult = 8 },
	["Five of a Kind"] = { chips = 120, mult = 12 }, ["Flush House"] = { chips = 140, mult = 14 }, ["Flush Five"] = { chips = 160, mult = 16 },
}
PLAN_SIM.LEVELS = LEVELS

local function joker(spec)
	local j = { name = spec.name, ab = spec.ab or {}, debuff = false, e_chips = 0, e_mult = 0, e_x = 1 }
	j.ab.name = spec.name
	return j
end
PLAN_SIM.joker = joker

function PLAN_SIM.deck()
	local d = {}
	for r = 2, 14 do for s = 1, 4 do d[#d + 1] = BotArena.plan.card(r, s) end end
	return d
end

local function shuffle(t)
	for i = #t, 2, -1 do
		local j = math.random(i)
		t[i], t[j] = t[j], t[i]
	end
end

function PLAN_SIM.run(o)
	local P = BotArena.plan
	math.randomseed(o.seed or 1)
	P.seed(o.seed or 1)
	local jokers = {}
	for i, s in ipairs(o.jokers or {}) do jokers[i] = joker(s) end
	local clears, unused_total, blinds = 0, 0, o.blinds or 100
	local hand_size = o.hand_size or 8
	for _ = 1, blinds do
		local deck = PLAN_SIM.deck()
		shuffle(deck)
		local hand = {}
		local function draw()
			while #hand < hand_size and #deck > 0 do hand[#hand + 1] = table.remove(deck) end
		end
		draw()
		local hands, discards, chips = o.hands or 4, o.discards or 3, 0
		local ctx = P.context({ jokers = jokers, lvl = LEVELS })
		local cleared = false
		local guard = 0
		while hands > 0 and guard < 30 do
			guard = guard + 1
			for i, c in ipairs(hand) do c.uid = i end
			ctx.hands_left, ctx.discards_left, ctx.deck_n = hands, discards, #deck
			local action, cards
			if o.policy == "plan" then
				local pool = {}
				for i, c in ipairs(deck) do pool[i] = c end
				local res = P.plan({ hand = hand, deck = pool, ctx = ctx, hands_left = hands, discards_left = discards,
					hand_limit = hand_size, need = o.need - chips, budget_ms = o.budget_ms or 25 })
				action, cards = res.action, res.cards
			else
				local cands = P._candidates(hand, ctx, 5, false)
				local best = cands[1]
				action, cards = "play", best.played
				if o.policy == "keep" and discards > 0 and hands > 1 and best.score < (o.need - chips) / hands then
					local keep = {}
					for _, c in ipairs(best.scoring) do keep[c] = true end
					local rest = {}
					for _, c in ipairs(hand) do if not keep[c] then rest[#rest + 1] = c end end
					table.sort(rest, function(a, b) return a.rank < b.rank end)
					if #rest > 0 then
						action, cards = "discard", {}
						for i = 1, math.min(5, #rest) do cards[i] = rest[i] end
					end
				end
			end
			local gone = {}
			for _, c in ipairs(cards) do gone[c] = true end
			local nh = {}
			for _, c in ipairs(hand) do if not gone[c] then nh[#nh + 1] = c end end
			hand = nh
			if action == "play" then
				local score = P.score(cards, hand, ctx)
				chips = chips + score
				hands = hands - 1
				if chips >= o.need then cleared = true; unused_total = unused_total + hands; break end
			else
				discards = discards - 1
			end
			draw()
		end
		if cleared then clears = clears + 1 end
	end
	return clears / blinds, unused_total / math.max(1, clears)
end
