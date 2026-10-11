-- Template for your own driver. Point the arena at it with  BOTARENA_DRIVER=C:/path/to/my_driver.lua
-- (or set "driver" in arena.config.json). The file must return a function(A) that returns a driver table.
--
-- `A` gives you:
--   A.cfg            instance configuration (A.cfg.id, A.cfg.name, A.cfg.ruleset_key, ...)
--   A.obs            O.snapshot() (JSON-friendly view of the game), O.settled(), O.pvp_on_deck(), O.in_pvp_blind()
--   A.act            action primitives:
--                      select_blind()            press Select (or Ready on the PvP blind)
--                      skip_blind() / can_skip_blind()
--                      play(indices) / discard(indices)      indices are positions in G.hand.cards
--                      cash_out()
--                      buy(card) / use_shop_card(card) / reroll() / sell(card) / leave_shop()
--                      use_consumable(card)
--                      pick_pack_card(card) / skip_pack()
--   A.util           logging + helpers
-- Every primitive returns (ok, info). They call the same G.FUNCS the UI buttons call, so Multiplayer's
-- own hooks (ready-up, location, skip tracking) run exactly as for a human.
--
-- step() is only called while the game is idle ("settled"). Do at most ONE action per call.
return function(A)
	local D = { name = "template" }

	function D.on_match_start(match) end

	function D.on_match_end(result) end

	function D.step(memo)
		local snap = A.obs.snapshot()
		-- snap.state is one of: BLIND_SELECT, SELECTING_HAND, ROUND_EVAL, SHOP, *_PACK, SMODS_BOOSTER_OPENED ...
		-- snap.hand / snap.jokers / snap.shop_jokers / snap.pack are lists of {i, key, rank, suit, cost, ...}
		-- snap.run has ante, dollars, hands_left, discards_left, blind, pvp_on_deck
		-- snap.mp  has lives, enemy_lives, enemy_score, ready_blind
		return false
	end

	return D
end
