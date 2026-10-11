-- External driver: lets a separate program (e.g. your Python AI) play the match through plain files.
--
--   run/bridge/inst<ID>.obs.json   written by the game whenever it needs a decision:
--                                    { "seq": 17, "t": 1790000000, "snap": { ...obs.snapshot()... } }
--   run/bridge/inst<ID>.act.json   written by your program in reply (must carry the same seq):
--                                    { "seq": 17, "action": "play", "cards": [1,3,4] }
--   run/bridge/inst<ID>.res.json   written by the game after executing: { "seq": 17, "ok": true, "info": "..." }
--
-- Strategic screens (blind select / shop / booster pack): snap.dec carries the legal options with features
--   { seq, kind, bidx, sx{...}, jokers[], options: [ {id, act, kind, key, pos, fx{...}}, ... ] }
-- and you answer { "seq": n, "action": "choose", "i": <0-based option index>, "p": <prob>, "v": <value> } (p/v optional; they are
-- stored in the decision log for the trainer). Hands: BOTARENA_EXTERNAL_HANDS=learned (default) sends a dec of kind "hand" (candidate
-- plays / discards with features, lib/handdec.lua; same {"action":"choose","i":..} reply, add "teacher":true when you just echo dec.pl),
-- "planner" = the built-in planner plays them, "agent" = raw card-index actions.
-- Raw actions below still work (they are not logged as decisions).
-- Actions: play{cards[]}, discard{cards[]}, select_blind, skip_blind, cash_out, leave_shop, reroll,
--          buy{i}            buy shop joker/consumable slot i
--          use_shop_card{area:"vouchers"|"boosters", i}
--          sell{area:"jokers"|"consumables", i}, use_consumable{i}
--          pick_pack{i}, skip_pack, noop
-- If no valid reply arrives within BOTARENA_BRIDGE_TIMEOUT seconds (default 60) the built-in baseline bot
-- makes the move so the match never stalls. Polling is cheap, but file latency (~ms) bounds decisions/sec.
return function(A)
	local U, O, X, C = A.util, A.obs, A.act, A.cfg
	local D = { name = "external" }

	local dir = U.join(C.run_dir or ".", "bridge")
	U.mkdirs(dir)
	local obs_path = U.join(dir, "inst" .. C.id .. ".obs.json")
	local act_path = U.join(dir, "inst" .. C.id .. ".act.json")
	local res_path = U.join(dir, "inst" .. C.id .. ".res.json")
	local timeout = U.env_num("BOTARENA_BRIDGE_TIMEOUT", 60)

	local fallback = nil
	local function get_fallback()
		if not fallback then fallback = A.load_driver("baseline") end
		return fallback
	end

	local seq, pending_since, pending_dec = 0, nil, nil

	local function area_cards(name)
		if name == "jokers" then return G.jokers and G.jokers.cards end
		if name == "consumables" then return G.consumeables and G.consumeables.cards end
		if name == "vouchers" then return G.shop_vouchers and G.shop_vouchers.cards end
		if name == "boosters" then return G.shop_booster and G.shop_booster.cards end
		if name == "shop_jokers" then return G.shop_jokers and G.shop_jokers.cards end
		if name == "pack" then return U.cards(G.pack_cards) end
		return nil
	end

	local function execute(a)
		local act = a.action
		if act == "play" then return X.play(a.cards or {})
		elseif act == "discard" then return X.discard(a.cards or {})
		elseif act == "select_blind" then return X.select_blind()
		elseif act == "skip_blind" then return X.skip_blind()
		elseif act == "cash_out" then return X.cash_out()
		elseif act == "leave_shop" then return X.leave_shop()
		elseif act == "reroll" then return X.reroll()
		elseif act == "buy" then return X.buy((area_cards("shop_jokers") or {})[a.i or 0])
		elseif act == "use_shop_card" then return X.use_shop_card((area_cards(a.area or "vouchers") or {})[a.i or 0])
		elseif act == "sell" then return X.sell((area_cards(a.area or "jokers") or {})[a.i or 0])
		elseif act == "use_consumable" then return X.use_consumable((area_cards("consumables") or {})[a.i or 0])
		elseif act == "pick_pack" then return X.pick_pack_card((area_cards("pack") or {})[a.i or 0])
		elseif act == "skip_pack" then return X.skip_pack()
		elseif act == "noop" then return true, "noop"
		end
		return false, "unknown action"
	end

	function D.on_match_start()
		seq, pending_since, pending_dec = 0, nil, nil
		U.remove(obs_path); U.remove(act_path); U.remove(res_path)
	end

	function D.step(memo)
		local n = U.now()
		if not pending_since then
			-- what is on screen? Hands go to the planner unless BOTARENA_EXTERNAL_HANDS=agent; the screens without a
			-- decision to make (round end ...) go to the baseline; strategic screens get the option list.
			local dec
			local S = G.STATES
			if G.STATE == S.SELECTING_HAND then
				if C.external_hands ~= "agent" and A.decide and A.decide.make_room then
					-- Purple Seal cards in hand and every consumable slot taken: use / sell one first (a rule, not a model decision)
					local okr, acted = pcall(A.decide.make_room)
					if okr and acted then return true end
				end
				if C.external_hands == "learned" and A.handdec and not memo.hand_failed then
					-- the hand model chooses among candidate plays / discards (lib/handdec.lua); the planner supplies the teacher pick
					local need, ginfo = A.handdec.goal()
					local okh, d = pcall(A.handdec.begin, { need = need, ginfo = ginfo })
					if okh and d and #d.options > 0 and d.forced and d.options[d.pl] then
						-- Purple Seal discard (plan.lua): a rule, played without asking the model; logged as a teacher decision
						local opt = d.options[d.pl]
						local okx, res = pcall(A.handdec.execute, opt, d)
						if okx and res then
							A.handdec.commit(d, d.pl, "baseline", nil)
							return true
						end
						A.handdec.ban(opt.id)
						return get_fallback().step(memo)
					elseif okh and d and #d.options > 0 then
						dec = d
					else
						if not okh then
							U.err("handdec.begin failed: " .. tostring(d))
							memo.hand_errors = (memo.hand_errors or 0) + 1
							if memo.hand_errors >= 5 then memo.hand_failed = true end
						end
						return get_fallback().step(memo)
					end
				elseif C.external_hands ~= "agent" then
					return get_fallback().step(memo)
				end
			elseif A.decide and A.decide.kind_of_state() then
				local ok, d = pcall(A.decide.begin)
				if ok then dec = d else U.err("decide.begin failed: " .. tostring(d)) end
				if not dec then return get_fallback().step(memo) end -- nothing legal / layer unavailable
			elseif G.STATE == S.ROUND_EVAL then
				return get_fallback().step(memo)
			end
			seq = seq + 1
			pending_dec = dec
			local snap = O.snapshot()
			if dec then snap.dec = (dec.kind == "hand") and A.handdec.serialize(dec) or A.decide.serialize(dec) end
			-- rewards of the blinds that finished since the previous observation (each is delivered exactly once)
			if A.reward and C.reward_enabled then
				local ok, popped = pcall(A.reward.pop)
				if ok and popped then
					snap.reward = snap.reward or {}
					snap.reward.delta = popped.sum
					snap.reward.events = popped.blinds
				end
			end
			U.write_json(obs_path, { seq = seq, t = U.wall(), snap = snap })
			pending_since = n
			return false
		end
		if D.last_poll and n - D.last_poll < 0.01 then return false end
		D.last_poll = n
		local a = U.read_json(act_path)
		if type(a) == "table" and a.seq == seq then
			U.remove(act_path)
			local dec = pending_dec
			pending_dec = nil
			local ok, res, info
			if a.action == "choose" then
				-- pick option `i` (0-based) of the list that came with this observation (snap.dec.options)
				local idx = math.floor(tonumber(a.i) or -1) + 1
				local opt = dec and dec.options[idx]
				if not opt then
					ok, res, info = true, false, "no such option (or this observation had no decision)"
				elseif dec.kind == "hand" then
					ok, res, info = pcall(A.handdec.execute, opt, dec)
					if ok and res then
						A.handdec.commit(dec, idx, a.teacher and "baseline" or "agent", { p = tonumber(a.p), v = tonumber(a.v), ts = tonumber(a.ts) })
					elseif ok then
						A.handdec.ban(opt.id) -- failed: do not offer it again in this hand state
					end
				else
					ok, res, info = pcall(A.decide.execute, opt)
					if ok and res then
						A.decide.commit(dec, idx, "agent", { p = tonumber(a.p), v = tonumber(a.v), ts = tonumber(a.ts) })
					elseif ok then
						A.decide.ban(opt.id) -- failed: do not offer it again during this visit
					end
				end
			else
				ok, res, info = pcall(execute, a)
			end
			U.write_json(res_path, { seq = seq, ok = ok and res or false, info = ok and info or tostring(res) })
			pending_since = nil
			return ok and res or false
		end
		if n - pending_since > timeout then
			U.warn("external driver timed out; baseline plays this move")
			pending_since, pending_dec = nil, nil
			return get_fallback().step(memo)
		end
		return false
	end

	function D.unstick()
		pending_since, pending_dec = nil, nil
		local fb = get_fallback()
		if fb.unstick then fb.unstick() end
	end

	return D
end
