-- BotArena action primitives. Every function returns (ok, info). They only press buttons through the
-- game's own G.FUNCS callbacks (the same ones the UI buttons call), so MP's hooks (ready-up, location
-- updates, skip tracking, ...) run exactly as they do for a human player.
return function(A)
	local U, O = A.util, A.obs
	local X = {}

	local function fake_event(card, extra)
		local e = { config = { ref_table = card } }
		if extra then
			for k, v in pairs(extra) do e.config[k] = v end
		end
		return e
	end

	-- ---------------------------------------------------------------------------------------------
	-- overlays / menus
	-- ---------------------------------------------------------------------------------------------
	function X.dismiss_overlay()
		if G and G.OVERLAY_MENU and G.FUNCS.exit_overlay_menu then
			G.FUNCS.exit_overlay_menu()
			return true
		end
		return false
	end

	-- ---------------------------------------------------------------------------------------------
	-- blind select
	-- ---------------------------------------------------------------------------------------------
	local function blind_opts()
		if not (G and G.GAME and G.GAME.blind_on_deck and G.blind_select_opts) then return nil end
		return G.blind_select_opts[string.lower(G.GAME.blind_on_deck)]
	end

	function X.blind_select_button()
		local opts = blind_opts()
		if not opts then return nil end
		return opts:get_UIE_by_ID("select_blind_button")
	end

	-- Press "Select" on a normal blind, or "Ready" on the PvP blind. Returns (true, "ready"|"select").
	function X.select_blind()
		local btn = X.blind_select_button()
		if not btn then return false, "no select button" end
		if O.pvp_on_deck() then
			if MP.GAME.ready_blind then return false, "already ready" end
			G.FUNCS.mp_toggle_ready(btn)
			return true, "ready"
		end
		if not (btn.config and btn.config.button and G.FUNCS[btn.config.button]) then
			return false, "select button inactive"
		end
		G.FUNCS[btn.config.button](btn)
		return true, "select"
	end

	function X.can_skip_blind()
		if O.pvp_on_deck() then return false end
		local deck = G.GAME and G.GAME.blind_on_deck
		if deck ~= "Small" and deck ~= "Big" then return false end
		local opts = blind_opts()
		return opts ~= nil and U.find_button(opts, "skip_blind") ~= nil
	end

	function X.skip_blind()
		local opts = blind_opts()
		if not opts then return false, "no blind ui" end
		local btn = U.find_button(opts, "skip_blind")
		if not btn then return false, "no skip button" end
		G.FUNCS.skip_blind(btn)
		return true
	end

	-- ---------------------------------------------------------------------------------------------
	-- playing / discarding
	-- ---------------------------------------------------------------------------------------------
	local function highlight(indices)
		G.hand:unhighlight_all()
		local n = 0
		for _, i in ipairs(indices) do
			local card = G.hand.cards[i]
			if card then
				G.hand:add_to_highlighted(card, true)
				n = n + 1
			end
		end
		return n
	end

	function X.can_play()
		local e = { config = {} }
		G.FUNCS.can_play(e)
		return e.config.button ~= nil
	end

	function X.can_discard()
		local e = { config = {} }
		G.FUNCS.can_discard(e)
		return e.config.button ~= nil
	end

	function X.play(indices)
		if #indices == 0 then return false, "no cards" end
		highlight(indices)
		if not X.can_play() then
			G.hand:unhighlight_all()
			return false, "cannot play"
		end
		G.FUNCS.play_cards_from_highlighted({ config = {} })
		return true
	end

	function X.discard(indices)
		if #indices == 0 then return false, "no cards" end
		highlight(indices)
		if not X.can_discard() then
			G.hand:unhighlight_all()
			return false, "cannot discard"
		end
		G.FUNCS.discard_cards_from_highlighted({ config = {} })
		return true
	end

	-- ---------------------------------------------------------------------------------------------
	-- round end / shop
	-- ---------------------------------------------------------------------------------------------
	-- The "Cash Out: $N" button is NOT a child of G.round_eval. The game builds it as its own UIBox
	-- (id 'cash_out_button', one_press = true, major = G.round_eval) after the last result row has been
	-- added (common_events.lua, add_round_eval_row 'bottom'). Searching G.round_eval therefore never finds
	-- it - that was the "bots can't press cash out" bug. Look through every live UIBox instead.
	-- IMPORTANT (the real "bots never cash out after the first round" bug): the game never removes a used Cash Out UIBox. After the
	-- button was pressed its row stays in G.I.UIBOX with config.button = nil (sliding off-screen with G.round_eval, then orphaned), and
	-- every later round adds ANOTHER box with the same id behind it. The old code returned the FIRST box with that id = the oldest,
	-- dead one, so from round 2 on "cash out is not ready" forever (only a human click on the visible, newest button worked).
	-- So: list every box, look from the NEWEST to the oldest, and take the first one that is still pressable.
	function X.cash_out_buttons()
		local out = {}
		local boxes = G and G.I and G.I.UIBOX
		if type(boxes) == "table" then
			local idx = {}
			for k, box in pairs(boxes) do
				if type(box) == "table" and box.get_UIE_by_ID and box.UIRoot then idx[#idx + 1] = { k = k, box = box } end
			end
			table.sort(idx, function(a, b)
				if type(a.k) == "number" and type(b.k) == "number" then return a.k > b.k end
				return tostring(a.k) > tostring(b.k)
			end)
			for _, e in ipairs(idx) do
				local ok, node = pcall(e.box.get_UIE_by_ID, e.box, "cash_out_button")
				if ok and node then out[#out + 1] = { node = node, box = e.box } end
			end
		end
		return out
	end

	local function pressable(node)
		return node and node.config and node.config.button == "cash_out" and not node.disable_button
	end

	-- newest pressable button; failing that the newest one of any kind (for diagnostics); returns node, box
	function X.find_cash_out_button()
		local list = X.cash_out_buttons()
		for _, e in ipairs(list) do
			if pressable(e.node) then return e.node, e.box end
		end
		for _, e in ipairs(list) do
			if e.node.config and e.node.config.button == "cash_out" then return e.node, e.box end
		end
		if list[1] then return list[1].node, list[1].box end
		-- older layouts / mocks: button inside the round_eval box itself
		if G and G.round_eval then
			local node = U.find_button(G.round_eval, "cash_out")
			if node then return node, G.round_eval end
		end
		return nil
	end

	-- used Cash Out boxes are dead weight (the game keeps updating and drawing every one of them): remove them once their round is over
	function X.prune_cash_out_boxes()
		local n = 0
		for _, e in ipairs(X.cash_out_buttons()) do
			local cfg = e.node.config
			if cfg and cfg.button == nil and type(e.box.remove) == "function" then
				if pcall(e.box.remove, e.box) then n = n + 1 end
			end
		end
		return n
	end

	-- true once the Cash Out button exists and can still be pressed
	function X.cash_out_ready()
		local btn = X.find_cash_out_button()
		return btn ~= nil and btn.config ~= nil and btn.config.button == "cash_out"
	end

	-- Press Cash Out exactly once. Uses UIElement:click() (what a mouse click calls: it applies the
	-- one_press / debounce rules and plays the click sound) and falls back to calling the callback
	-- directly if the click was refused. G.FUNCS.cash_out clears config.button, so a second call in the
	-- same state is a no-op ("already pressed") instead of a double cash-out.
	function X.cash_out()
		if not (G and G.GAME) then return false, "no game" end
		local btn = X.find_cash_out_button()
		if not btn then
			return false, G.round_eval and "no cash out button yet" or "no round_eval"
		end
		if not (btn.config and btn.config.button == "cash_out") then return false, "cash out already pressed" end
		local clicked = false
		if type(btn.click) == "function" and not btn.disable_button and not (btn.states and btn.states.visible == false) then
			local ok = pcall(btn.click, btn)
			-- success = the callback ran (it nils config.button) or the element flagged the click
			clicked = ok and (btn.config.button ~= "cash_out" or btn.button_clicked == true)
		end
		if not clicked then
			if not (G.FUNCS and G.FUNCS.cash_out) then return false, "no cash_out callback" end
			G.FUNCS.cash_out(btn)
		end
		return true
	end

	function X.leave_shop()
		if not G.shop then return false, "no shop" end
		local btn = U.find_button(G.shop, "toggle_shop") or U.find_uie(G.shop, function(n)
			return n.config and n.config.id == "next_round_button"
		end)
		G.FUNCS.toggle_shop(btn or { config = {} })
		return true
	end

	function X.dollars_available()
		return (G.GAME.dollars or 0) - (G.GAME.bankrupt_at or 0)
	end

	local function joker_space_for(card)
		if not card.ability then return true end
		local extra = card.ability.extra_slots_used or 0
		local lim = card.ability.card_limit or 0
		if card.ability.set == "Joker" then
			return #G.jokers.cards + (1 + extra) <= G.jokers.config.card_limit + lim
		end
		if card.ability.consumeable then
			return #G.consumeables.cards + (1 + extra) <= G.consumeables.config.card_limit + lim
		end
		return true
	end

	X.has_space = function(card) return joker_space_for(card) end

	function X.can_afford(card)
		return not (card.cost > X.dollars_available() and card.cost > 0)
	end

	-- Buy a card from the shop's joker / consumable row.
	function X.buy(card)
		if not card then return false, "no card" end
		if not X.can_afford(card) then return false, "cannot afford" end
		if card.ability and card.ability.set ~= "Voucher" and not joker_space_for(card) then
			return false, "no space"
		end
		G.FUNCS.buy_from_shop(fake_event(card))
		return true
	end

	-- Redeem a voucher or open a booster pack from the shop.
	function X.use_shop_card(card)
		if not card then return false, "no card" end
		if not X.can_afford(card) then return false, "cannot afford" end
		G.FUNCS.use_card(fake_event(card))
		return true
	end

	function X.can_reroll()
		local e = { config = {} }
		G.FUNCS.can_reroll(e)
		return e.config.button ~= nil
	end

	function X.reroll()
		if not X.can_reroll() then return false, "cannot reroll" end
		G.FUNCS.reroll_shop({ config = {} })
		return true
	end

	function X.sell(card)
		if not card or not card.can_sell_card or not card:can_sell_card() then return false, "cannot sell" end
		G.FUNCS.sell_card(fake_event(card))
		return true
	end

	function X.use_consumable(card)
		if not card or not card.can_use_consumeable or not card:can_use_consumeable() then
			return false, "cannot use"
		end
		G.FUNCS.use_card(fake_event(card))
		return true
	end

	-- ---------------------------------------------------------------------------------------------
	-- booster packs
	-- ---------------------------------------------------------------------------------------------
	function X.pick_pack_card(card)
		if not card then return false, "no card" end
		local e = fake_event(card)
		G.FUNCS.can_select_card(e)
		if not e.config.button then return false, "cannot select" end
		G.FUNCS.use_card(fake_event(card))
		return true
	end

	function X.skip_pack()
		if not U.pack_open() then return false, "no pack open" end
		G.FUNCS.skip_booster({ config = {} })
		return true
	end

	return X
end
