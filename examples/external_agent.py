#!/usr/bin/env python3
"""
Minimal external agent for BotArena's file bridge.

Start the arena with the external driver for the instance(s) you want to control:

    node arena.js up --driver external            (all instances)
or  "perInstance": { "1": { "driver": "external" } }   in arena.config.json   (just instance 1)

Then run this script (pure standard library):

    python examples/external_agent.py --run-dir run --inst 1

The game writes run/bridge/inst<ID>.obs.json whenever it needs a decision; reply by writing
run/bridge/inst<ID>.act.json with the SAME "seq". If no answer arrives within BOTARENA_BRIDGE_TIMEOUT
seconds (default 60) the built-in baseline bot plays that move, so a crashed agent never stalls a match.

Replace `decide()` with your model. `snap` is exactly what BotArena's obs.snapshot() returns:
  snap["state"]        BLIND_SELECT | SELECTING_HAND | ROUND_EVAL | SHOP | TAROT_PACK | PLANET_PACK | ...
  snap["run"]          ante, round, dollars, hands_left, discards_left, blind, pvp_on_deck, skips, chips, reroll_cost
  snap["hand"]         [{i, key, rank, rank_id, suit, enh, edition, seal, debuff}, ...]  (i is 1-based)
  snap["jokers"], snap["consumables"], snap["shop_jokers"], snap["shop_vouchers"], snap["shop_boosters"], snap["pack"]
  snap["mp"]           lives, enemy_lives, enemy_score, enemy_hands, enemy_skips, ready_blind, timer
  snap["pvp"]          (PvP blinds only) my_turn, why, my_score, enemy_score, enemy_hands, enforced
                       The arena already holds the bot back while it is ahead (BOTARENA_PVP_TURN), so you only
                       get asked to move when it is your turn; the fields tell you why.
  snap["reward"]       total, blinds, match_total, live{money,tarots,spectrals,best_hand,hopeless,...}, last{...}
                       delta   = sum of the rewards of the blinds that finished since the previous observation
                       events  = those finished blinds (kind, outcome, beaten, money, tarots, spectrals,
                                 unused_hands, hopeless, parts{...}, reward); each one is delivered exactly once
  snap["dec"]          (strategic screens: blind select / shop / pack) the legal options with features:
                       { seq, kind, bidx, sx{...}, jokers[], options: [ {id, kind, key, fx{...}}, ... ] }
                       Answer it with {"action": "choose", "i": <0-based option index>}. The built-in planner plays the
                       hands unless BOTARENA_EXTERNAL_HANDS=agent. For a real learner see `python -m trainer live` (trainer/).
Actions: see lib/../mod/BotArena/drivers/external.lua (play, discard, select_blind, skip_blind, cash_out,
         leave_shop, reroll, buy, use_shop_card, sell, use_consumable, pick_pack, skip_pack, noop).
"""
import argparse
import json
import os
import time


def decide(snap):
    """Toy policy: play the five highest-ranked cards, buy nothing, never skip."""
    state = snap.get("state")
    dec = snap.get("dec")
    if dec and dec.get("options"):
        # toy strategic policy: take the first option that is not a purchase/reroll (i.e. leave / skip / select), else option 0
        for i, o in enumerate(dec["options"]):
            if o.get("kind") in ("leave", "select", "skip_pack"):
                return {"action": "choose", "i": i}
        return {"action": "choose", "i": 0}
    if state == "BLIND_SELECT":
        return {"action": "select_blind"}          # on the PvP blind this presses "Ready"
    if state == "SELECTING_HAND":
        hand = sorted(snap.get("hand", []), key=lambda c: c.get("rank_id") or 0, reverse=True)
        return {"action": "play", "cards": [c["i"] for c in hand[:5]]}
    if state == "ROUND_EVAL":
        return {"action": "cash_out"}
    if state == "SHOP":
        return {"action": "leave_shop"}
    if "PACK" in str(state) or state == "SMODS_BOOSTER_OPENED":
        return {"action": "skip_pack"}
    return {"action": "noop"}


def read_json(path):
    try:
        with open(path, "r", encoding="utf8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-dir", default="run")
    ap.add_argument("--inst", type=int, default=1)
    ap.add_argument("--poll", type=float, default=0.005, help="seconds between checks of the obs file")
    args = ap.parse_args()

    bridge = os.path.join(args.run_dir, "bridge")
    obs_path = os.path.join(bridge, f"inst{args.inst}.obs.json")
    act_path = os.path.join(bridge, f"inst{args.inst}.act.json")
    res_path = os.path.join(bridge, f"inst{args.inst}.res.json")
    last = -1
    n = 0
    print(f"external agent for instance {args.inst}, watching {obs_path}")
    while True:
        obs = read_json(obs_path)
        if obs and obs.get("seq") != last:
            last = obs["seq"]
            rw = (obs["snap"].get("reward") or {})
            for ev in rw.get("events") or []:      # finished blinds, delivered exactly once
                print(f"blind finished: {ev.get('kind')} ante {ev.get('ante')} -> reward {ev.get('reward')} {ev.get('parts')}")
            action = decide(obs["snap"])
            action["seq"] = last
            tmp = act_path + ".tmp"
            with open(tmp, "w", encoding="utf8") as f:
                json.dump(action, f)
            os.replace(tmp, act_path)          # atomic: the game never reads half a file
            n += 1
            if n % 200 == 0:
                res = read_json(res_path) or {}
                print(f"{n} decisions, last result: {res}")
        time.sleep(args.poll)


if __name__ == "__main__":
    main()
