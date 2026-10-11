-- BotArena observation helpers: game phase names, "is the game ready for input", JSON-friendly snapshots.
return function(A)
	local U = A.util
	local O = {}

	local state_names = nil
	local function build_state_names()
		state_names = {}
		if G and G.STATES then
			for name, id in pairs(G.STATES) do
				state_names[id] = name
			end
		end
	end

	function O.state_name()
		if not G then return "none" end
		if not state_names then build_state_names() end
		return state_names[G.STATE] or tostring(G.STATE)
	end

	-- "boot" | "menu" | "run" | "other"
	function O.stage()
		if not G or not G.STAGES or not G.STAGE then return "boot" end
		if G.STAGE == G.STAGES.RUN then return "run" end
		if G.STAGE == G.STAGES.MAIN_MENU then
			-- SPLASH state = intro still playing
			if G.STATE == G.STATES.SPLASH then return "boot" end
			return "menu"
		end
		return "other"
	end

	function O.in_lobby()
		return MP and MP.LOBBY and MP.LOBBY.code ~= nil
	end

	function O.connected()
		return MP and MP.LOBBY and MP.LOBBY.connected == true
	end

	function O.is_host()
		return MP and MP.LOBBY and MP.LOBBY.is_host == true
	end

	function O.opponent_present()
		local L = MP and MP.LOBBY
		if not L then return false end
		if L.is_host then return L.guest ~= nil and L.guest.username ~= nil end
		return L.host ~= nil and L.host.username ~= nil
	end

	function O.opponent_name()
		local L = MP and MP.LOBBY
		if not L then return nil end
		if L.is_host then return L.guest and L.guest.username or nil end
		return L.host and L.host.username or nil
	end

	-- True when no blocking events are queued (animations / scoring finished).
	function O.queue_idle()
		if not (G and G.E_MANAGER and G.E_MANAGER.queues) then return true end
		for _, queue in pairs(G.E_MANAGER.queues) do
			for _, ev in ipairs(queue) do
				if ev.blocking ~= false then return false end
			end
		end
		return true
	end

	-- True when the game would accept a button press right now.
	function O.settled()
		if not G then return false end
		if G.SETTINGS and G.SETTINGS.paused then return false end
		if G.screenwipe then return false end
		if G.CONTROLLER and G.CONTROLLER.locked then return false end
		if G.GAME and G.GAME.STOP_USE and G.GAME.STOP_USE > 0 then return false end
		if G.SCORING_COROUTINE then return false end
		if not G.STATE_COMPLETE then return false end
		return O.queue_idle()
	end

	-- ---------------------------------------------------------------------------------------------
	-- PvP awareness
	-- ---------------------------------------------------------------------------------------------
	-- Is the blind currently *on deck* (blind-select screen) the PvP blind?
	function O.pvp_on_deck()
		if not (G and G.GAME and G.GAME.round_resets) then return false end
		local deck = G.GAME.blind_on_deck
		if not deck then return false end
		local rr = G.GAME.round_resets
		if rr.blind_choices and rr.blind_choices[deck] == "bl_mp_nemesis" then return true end
		if rr.pvp_blind_choices and rr.pvp_blind_choices[deck] then return true end
		return false
	end

	function O.in_pvp_blind()
		return MP and MP.is_pvp_boss and MP.is_pvp_boss() or false
	end

	-- ---------------------------------------------------------------------------------------------
	-- card / area summaries
	-- ---------------------------------------------------------------------------------------------
	local function edition_name(card)
		if card.edition and card.edition.type then return card.edition.type end
		return nil
	end

	function O.card(card, idx)
		if not card then return nil end
		local c = {
			i = idx,
			key = card.config and card.config.center and card.config.center.key or nil,
			set = card.ability and card.ability.set or nil,
			name = card.ability and card.ability.name or nil,
			cost = card.cost,
			sell = card.sell_cost,
			debuff = card.debuff and true or false,
			edition = edition_name(card),
			seal = card.seal,
		}
		if card.base and card.base.suit then
			c.rank = card.base.value
			c.rank_id = card.base.id
			c.suit = card.base.suit
			c.enh = card.config and card.config.center and card.config.center.key ~= "c_base"
					and card.config.center.key
				or nil
		end
		if card.ability then
			if card.ability.eternal then c.eternal = true end
			if card.ability.perishable then c.perishable = true end
			if card.ability.rental then c.rental = true end
		end
		return c
	end

	function O.area(area)
		local out = {}
		for i, card in ipairs(U.cards(area)) do
			out[i] = O.card(card, i)
		end
		return out
	end

	function O.score_text(s)
		return U.fmt_score(s)
	end

	-- json.lua refuses NaN/inf (scores can overflow a double late in a run) and non-number values.
	local function fin(x)
		if type(x) == "number" then
			if x ~= x then return nil end
			if x == math.huge then return 1.7976931348623157e308 end
			if x == -math.huge then return -1.7976931348623157e308 end
			return x
		end
		if x == nil then return nil end
		local n = tonumber(x)
		if n then return fin(n) end
		return tostring(x)
	end

	-- JSON-friendly snapshot of everything a driver (or a status file) might want.
	function O.snapshot()
		local snap = {
			stage = O.stage(),
			state = O.state_name(),
			settled = O.settled(),
			in_lobby = O.in_lobby() and true or false,
			connected = O.connected() and true or false,
		}
		if MP and MP.LOBBY then
			snap.lobby = {
				code = MP.LOBBY.code,
				is_host = MP.LOBBY.is_host and true or false,
				ready = MP.LOBBY.ready_to_start and true or false,
				opponent = O.opponent_name(),
				ruleset = MP.LOBBY.config and MP.LOBBY.config.ruleset or nil,
				gamemode = MP.LOBBY.config and MP.LOBBY.config.gamemode or nil,
			}
		end
		if G and G.GAME and snap.stage == "run" then
			local g = G.GAME
			snap.run = {
				ante = g.round_resets and g.round_resets.ante or nil,
				round = g.round,
				dollars = fin(g.dollars),
				hands_left = g.current_round and g.current_round.hands_left or nil,
				discards_left = g.current_round and g.current_round.discards_left or nil,
				blind_on_deck = g.blind_on_deck,
				pvp_on_deck = O.pvp_on_deck(),
				skips = g.skips,
				chips = fin(g.chips),
				reroll_cost = g.current_round and fin(g.current_round.reroll_cost) or nil,
			}
			if g.blind and g.blind.config and g.blind.config.blind then
				snap.run.blind = {
					key = g.blind.config.blind.key,
					name = g.blind.name,
					chips = fin(g.blind.chips),
					is_boss = g.blind.boss and true or false,
					pvp = O.in_pvp_blind() and true or false,
				}
			end
			snap.hand = O.area(G.hand)
			snap.jokers = O.area(G.jokers)
			snap.consumables = O.area(G.consumeables)
			if G.shop_jokers then snap.shop_jokers = O.area(G.shop_jokers) end
			if G.shop_vouchers then snap.shop_vouchers = O.area(G.shop_vouchers) end
			if G.shop_booster then snap.shop_boosters = O.area(G.shop_booster) end
			snap.pack = O.area(G.pack_cards) -- {} when no pack / stale area
		end
		if MP and MP.GAME and snap.stage == "run" then
			local m = MP.GAME
			snap.mp = {
				lives = m.lives,
				ready_blind = m.ready_blind and true or false,
				enemy_lives = m.enemy and m.enemy.lives or nil,
				enemy_skips = m.enemy and m.enemy.skips or nil,
				enemy_hands = m.enemy and m.enemy.hands or nil,
				enemy_score = m.enemy and U.fmt_score(m.enemy.score) or nil,
				my_score = m.score and U.fmt_score(m.score) or nil,
				enemy_location = m.enemy and m.enemy.location or nil,
				timer = fin(m.timer),
			}
		end
		-- PvP turn order (only inside a PvP blind): whose hand is next and why
		if snap.stage == "run" and A.pvp and O.in_pvp_blind() then
			local ok, t = pcall(A.pvp.snapshot)
			if ok and t then
				t.my_score, t.enemy_score = fin(t.my_score), fin(t.enemy_score)
				snap.pvp = t
			end
		end
		if snap.stage == "run" and A.plan and A.plan.last then snap.plan = A.plan.last end
		-- reward counters (see lib/reward.lua)
		if snap.stage == "run" and A.reward and A.cfg.reward_enabled then
			local ok, r = pcall(A.reward.snapshot)
			if ok then snap.reward = r end
		end
		return snap
	end

	-- Compact signature used by the stall watchdog: changes whenever the game visibly progresses.
	function O.progress_signature()
		if not G then return "none" end
		local parts = { O.stage(), O.state_name() }
		if G.GAME and O.stage() == "run" then
			local g = G.GAME
			parts[#parts + 1] = tostring(g.round_resets and g.round_resets.ante)
			parts[#parts + 1] = tostring(g.round)
			parts[#parts + 1] = tostring(g.dollars)
			parts[#parts + 1] = tostring(g.current_round and g.current_round.hands_left)
			parts[#parts + 1] = tostring(g.current_round and g.current_round.discards_left)
			parts[#parts + 1] = tostring(g.blind_on_deck)
			parts[#parts + 1] = tostring(U.count(G.hand))
			parts[#parts + 1] = tostring(U.count(G.jokers))
			parts[#parts + 1] = tostring(U.count(G.pack_cards))
		end
		if MP and MP.GAME and O.stage() == "run" then
			parts[#parts + 1] = tostring(MP.GAME.ready_blind)
			parts[#parts + 1] = tostring(MP.GAME.lives)
			parts[#parts + 1] = tostring(MP.GAME.enemy and MP.GAME.enemy.lives)
		end
		return table.concat(parts, "|")
	end

	return O
end
