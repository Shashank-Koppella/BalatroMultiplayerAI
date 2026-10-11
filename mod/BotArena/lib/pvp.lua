-- BotArena PvP awareness: whose turn is it on the PvP blind?
--
-- Multiplayer rule being modelled (see server src/actionHandlers.ts `isHostTurn` and the client's
-- `pvp_timer` layer): once both players have played a hand, the player with the LOWER score is the one who
-- has to play next; the player who is ahead waits (in the real game they may start a timer on the laggard).
-- On an exact tie the player who readied first for the blind holds the "timer" role, so the other one plays.
-- Before a player's own first hand of the blind the opponent's score is hidden and nobody waits.
--
-- The arena applies this gate before every driver step in a PvP blind, so every driver (baseline, random,
-- external, yours) obeys it without extra code. Set BOTARENA_PVP_TURN=0 to switch it off.
--
-- Safety: a waiting bot never waits forever. If nothing about the opponent (score / hands) changes for
-- BOTARENA_TURN_TIMEOUT real seconds it plays anyway, so a lost message or a crashed peer cannot deadlock a match.
return function(A)
	local U, O, C = A.util, A.obs, A.cfg
	local P = { last = nil, timeouts = 0, waited = 0 }

	local function enemy()
		return MP and MP.GAME and MP.GAME.enemy or nil
	end

	-- my cumulative score on this blind, as a plain number
	function P.my_score()
		return U.num(G and G.GAME and G.GAME.chips) or 0
	end

	-- the opponent's last known cumulative score on this blind (nil if unknown). `real_score` is the true
	-- value; `score` is an animated copy used for the HUD.
	function P.enemy_score()
		local e = enemy()
		if not e then return nil end
		local v = e.real_score
		if v == nil then v = e.score end
		return U.num(v)
	end

	-- false while the opponent's score is still masked (we have not played a hand yet this blind)
	function P.enemy_known()
		local e = enemy()
		if not e then return false end
		if e.info_received ~= nil then return e.info_received == true end
		return e.real_score ~= nil or e.score ~= nil
	end

	-- -> my_turn (bool), why (string), info (table with the numbers the decision used)
	function P.turn()
		local info = {}
		if not (O.in_pvp_blind() and G and G.GAME and G.GAME.current_round) then return true, "not_pvp", info end
		local cr = G.GAME.current_round
		local hands_left = cr.hands_left or 0
		local played = cr.hands_played or 0
		local e = enemy()
		local mine, theirs = P.my_score(), P.enemy_score()
		info.mine, info.theirs = mine, theirs
		info.hands_left = hands_left
		info.enemy_hands = e and tonumber(e.hands) or nil
		info.hands_played = played
		if hands_left <= 0 then return false, "no_hands", info end
		if played == 0 then return true, "first_hand", info end
		if not P.enemy_known() or theirs == nil then return true, "no_info", info end
		if info.enemy_hands ~= nil and info.enemy_hands <= 0 then return true, "enemy_done", info end
		if mine < theirs then return true, "behind", info end
		if mine > theirs then return false, "ahead", info end
		-- exact tie: the first player to ready is the one who may put the timer on the other
		if MP.GAME.pvp_reached_first then return false, "tie_first", info end
		return true, "tie_second", info
	end

	-- Called by the arena before each driver step while a hand is being chosen. Returns (go, why).
	function P.gate()
		local go, why, info = P.turn()
		P.last = { my_turn = go, why = why, info = info }
		if go or not C.pvp_turn then
			P.wait_since, P.wait_sig = nil, nil
			return true, why
		end
		if why == "no_hands" then return false, why end
		local n = U.now()
		local sig = tostring(info.theirs) .. "|" .. tostring(info.enemy_hands) .. "|" .. tostring(info.mine)
		if P.wait_sig ~= sig or not P.wait_since then P.wait_sig, P.wait_since = sig, n end
		if n - P.wait_since > (C.turn_timeout or 45) then
			P.timeouts = P.timeouts + 1
			P.wait_since = n
			U.warn(string.format("PvP turn wait timed out after %.0fs (%s); playing anyway", C.turn_timeout or 45, why))
			if A.fsm and A.fsm.event then A.fsm.event("turn_timeout", { why = why }) end
			return true, "timeout"
		end
		P.waited = P.waited + 1
		return false, why
	end

	-- compact view for the observation snapshot
	function P.snapshot()
		if not O.in_pvp_blind() then return nil end
		local go, why, info = P.turn()
		return {
			my_turn = go,
			why = why,
			my_score = info.mine,
			enemy_score = info.theirs,
			enemy_hands = info.enemy_hands,
			enforced = C.pvp_turn and true or false,
		}
	end

	return P
end
