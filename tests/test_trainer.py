#!/usr/bin/env python3
"""
Tests for the numpy trainer (trainer/). Pure numpy except test_integration_with_mock_game, which drives the real Lua mod
inside the mock Balatro (needs lupa, like tests/run_tests.py).

    python3 tests/test_trainer.py
"""
import json
import os
import random
import shutil
import sys
import tempfile
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)
sys.path.insert(0, HERE)

from trainer import features as F  # noqa: E402
from trainer.agent import Agent, Bridge, Live  # noqa: E402
from trainer.algo import behaviour_clone, loss_value, policy_value_step, ppo_update  # noqa: E402
from trainer.data import Store, Tail, load_all  # noqa: E402
from trainer.model import Adam, Model, pad_batch  # noqa: E402

failures = []


def check(cond, msg):
    print(("  ok   " if cond else "  FAIL ") + msg)
    if not cond:
        failures.append(msg)


# --------------------------------------------------------------------------------------------------
# synthetic decisions
# --------------------------------------------------------------------------------------------------
KEYS = ["j_joker", "j_greedy_joker", "j_banner", "j_egg", "j_cavendish", "j_golden", "c_pair", "c_high_card", "v_overstock", "p_celestial"]


def synth_row(rng, with_choice=True):
    n = int(rng.integers(3, 8))
    dollars = float(rng.integers(0, 40))
    opts = []
    for i in range(n - 1):
        kind = rng.choice(["buy_joker", "buy_planet", "buy_voucher", "open_pack"])
        fx = {"cost": float(rng.integers(2, 10)), "d_pot": float(rng.normal(0.1, 0.2)) if kind == "buy_joker" else 0.0,
              "rarity": float(rng.integers(1, 4)), "interest_loss": float(rng.integers(0, 2)), "hand_aimed": float(rng.integers(0, 2)) if kind == "buy_planet" else 0.0}
        fx["money_after"] = dollars - fx["cost"]
        opts.append({"id": "o%d" % i, "kind": str(kind), "key": str(rng.choice(KEYS)), "pos": i, "fx": fx})
    opts.append({"id": "leave", "kind": "leave", "key": None, "pos": 0, "fx": {"money": dollars}})
    row = {"kind": "shop", "bidx": 0, "sx": {"ante": float(rng.integers(1, 6)), "dollars": dollars, "lives": 4.0, "enemy_lives": 4.0, "n_jokers": 1.0},
           "jokers": [str(rng.choice(KEYS))], "options": opts}
    return row


def teacher(row):
    """a known rule: the best option by 4*d_pot + aimed planet bonus - cost/4 (or leave at 0.2)"""
    best, bi = -1e9, 0
    for i, o in enumerate(row["options"]):
        fx = o["fx"]
        v = 0.2 if o["kind"] == "leave" else 4 * fx.get("d_pot", 0) + 2 * fx.get("hand_aimed", 0) - fx.get("cost", 0) / 4
        if v > best:
            best, bi = v, i
    return bi


def make_rows(n, seed=0, chooser=None, G=None):
    rng = np.random.default_rng(seed)
    out = []
    for _ in range(n):
        r = synth_row(rng)
        r["chosen"] = (chooser or teacher)(r)
        r["G"] = 0.0 if G is None else G(r, r["chosen"], rng)
        r["src"] = "baseline"
        r["_f"] = F.featurize(r)
        out.append(r)
    return out


# --------------------------------------------------------------------------------------------------
def test_features():
    print("test: features")
    rng = np.random.default_rng(1)
    r = synth_row(rng)
    s, X = F.featurize(r)
    check(s.shape == (F.S_DIM,) and X.shape == (len(r["options"]), F.X_DIM), "shapes (%s, %s)" % (s.shape, X.shape))
    check(np.isfinite(s).all() and np.isfinite(X).all() and np.abs(X).max() <= 5 and np.abs(s).max() <= 5, "finite and bounded")
    s2, X2 = F.featurize(r)
    check((s == s2).all() and (X == X2).all(), "deterministic (hashing is stable across calls)")
    check(F.bucket("j_joker", 48) == F.bucket("j_joker", 48) and F.bucket(None, 48) is None, "key hashing")
    r["options"][0]["fx"]["brand_new_feature"] = 3.0
    F.featurize(r)
    check(F.UNKNOWN.get("brand_new_feature") == 1, "unknown mod features are ignored and counted, not fatal")
    kinds = [o["kind"] for o in r["options"]]
    check(all(X[i, len(F.OPT_NAMES) + F.KINDS.index(k)] == 1 for i, k in enumerate(kinds)), "option kind one-hot")
    # the strategy-relevant state features are present
    for name in ("lives", "enemy_lives", "life_diff", "life_factor", "ante", "blinds_to_pvp", "interest_room", "jk_held", "deck_steel", "pot_gap"):
        check(name in F.STATE_SPEC, "state feature available: %s" % name)


def test_gradients():
    print("test: backprop matches finite differences (policy BC + PPO + entropy + value)")
    m = Model(hidden=7, seed=3)
    m.p = {k: v.astype(np.float64) for k, v in m.p.items()}
    rows = make_rows(6, seed=5, G=lambda r, a, rng: float(rng.normal()))
    rng = np.random.default_rng(9)
    for r in rows:
        r["p"] = float(rng.uniform(0.15, 0.9))
        r["chosen"] = int(rng.integers(0, len(r["options"])))
    adv = rng.normal(size=len(rows))
    bc_w = np.array([1.0, 0.5, 0.0, 1.0, 0.0, 0.7])
    ppo_w = np.array([0.0, 1.0, 1.0, 0.0, 1.0, 1.0])
    kw = dict(bc_w=bc_w, ppo_w=ppo_w, adv=adv, clip=0.2, ent=0.02, vcoef=0.5)

    # analytic gradient: run the real step with a dummy optimizer that captures the grads
    class Grab:
        def step(self, g):
            self.g = g
            return 0.0

    grab = Grab()
    snap = {k: v.copy() for k, v in m.p.items()}
    policy_value_step(m, grab, rows, **kw)
    check(all((m.p[k] == snap[k]).all() for k in snap), "the capturing optimizer leaves the weights untouched")
    worst = 0.0
    eps = 1e-5
    rng = np.random.default_rng(2)
    for k in Model.PARAMS:
        arr = m.p[k]
        flat = arr.reshape(-1) if arr.ndim else arr.reshape(1)
        idxs = rng.choice(flat.size, size=min(12, flat.size), replace=False)
        for ix in idxs:
            old = float(flat[ix])
            flat[ix] = old + eps
            if arr.ndim == 0:
                m.p[k] = np.asarray(flat[0])
            lp = loss_value(m, rows, **kw)
            flat[ix] = old - eps
            if arr.ndim == 0:
                m.p[k] = np.asarray(flat[0])
            lm = loss_value(m, rows, **kw)
            flat[ix] = old
            if arr.ndim == 0:
                m.p[k] = np.asarray(flat[0])
            num = (lp - lm) / (2 * eps)
            ana = float(np.asarray(grab.g[k]).reshape(-1)[ix])
            err = abs(num - ana) / max(1e-6, abs(num) + abs(ana))
            worst = max(worst, err if abs(num) + abs(ana) > 1e-7 else 0.0)
    check(worst < 1e-4, "max relative gradient error over all parameter tensors = %.2e" % worst)


def test_returns_and_files():
    print("test: reading logs, discounted returns per match, partial lines, aborted matches")
    tmp = tempfile.mkdtemp(prefix="trn_data_")
    os.makedirs(os.path.join(tmp, "decisions"))
    os.makedirs(os.path.join(tmp, "results"))
    rng = np.random.default_rng(0)

    def dec(sess, match, bidx):
        r = synth_row(rng)
        r.update({"inst": 1, "sess": sess, "match": match, "bidx": bidx, "chosen": 0, "src": "baseline"})
        return r

    def rew(sess, match, ridx, reward):
        return {"inst": 1, "sess": sess, "match": match, "ridx": ridx, "reward": reward, "kind": "small"}

    with open(os.path.join(tmp, "decisions", "inst1.jsonl"), "w") as f:
        for r in (dec("A", 1, 0), dec("A", 1, 1), dec("A", 1, 2), dec("B", 1, 0), dec("A", 2, 0), dec("C", 1, 0)):
            f.write(json.dumps(r) + "\n")
    with open(os.path.join(tmp, "results", "rewards1.jsonl"), "w") as f:
        for r in (rew("A", 1, 0, 10), rew("A", 1, 1, -30), rew("A", 1, 2, 60), rew("B", 1, 0, 5), rew("A", 2, 0, 1)):
            f.write(json.dumps(r) + "\n")
    with open(os.path.join(tmp, "results", "inst1.jsonl"), "w") as f:
        f.write(json.dumps({"inst": 1, "sess": "A", "match": 1, "result": "win"}) + "\n")
        f.write(json.dumps({"inst": 1, "sess": "B", "match": 1, "result": "aborted"}) + "\n")
        # (A,2) has no result yet and (C,1) has none: both must stay out
    rows, st = load_all(tmp, gamma=0.5, reward_scale=10.0)
    byb = {r["bidx"]: r for r in rows}
    check(len(rows) == 3, "only the finished, non-aborted match is used (%d rows)" % len(rows))
    check(abs(byb[0]["G"] - (10 + 0.5 * -30 + 0.25 * 60) / 10) < 1e-9, "G(0) = 10 - 15 + 15 = 10 -> 1.0 (%.3f)" % byb[0]["G"])
    check(abs(byb[1]["G"] - (-30 + 0.5 * 60) / 10) < 1e-9, "G(1) = -30 + 30 = 0")
    check(abs(byb[2]["G"] - 6.0) < 1e-9, "G(2) = 60 -> 6.0")
    check(byb[0]["won"] is True, "match outcome attached")
    # same (inst, match) number but another process session does not mix
    check(all(r["sess"] == "A" for r in rows), "rows of session B (aborted) did not leak in")
    # match bonus
    rows2, _ = load_all(tmp, gamma=0.5, reward_scale=10.0, match_bonus=20.0)
    b2 = {r["bidx"]: r for r in rows2}
    check(abs(b2[2]["G"] - (60 + 0.5 * 20) / 10) < 1e-9, "match bonus is paid after the last reward row (discounted)")
    # incremental tail with a half-written line
    p = os.path.join(tmp, "t.jsonl")
    t = Tail(p)
    check(t.read() == [], "missing file reads as empty")
    with open(p, "w") as f:
        f.write('{"a": 1}\n{"a": 2')
    check(t.read() == [{"a": 1}], "incomplete last line is held back")
    with open(p, "a") as f:
        f.write('}\n{"a": 3}\n')
    check(t.read() == [{"a": 2}, {"a": 3}], "…and delivered once it is complete")
    check(t.read() == [], "nothing is delivered twice")
    shutil.rmtree(tmp, ignore_errors=True)


def test_bc_learns_rule():
    print("test: behaviour cloning recovers a known decision rule")
    rows = make_rows(1500, seed=11)
    held = make_rows(300, seed=12)
    m = Model(hidden=64, seed=0)
    behaviour_clone(m, rows, epochs=25, batch=64, lr=2e-3, log=lambda *_: None)
    ok = 0
    for r in held:
        probs, _ = m.probs_value(*r["_f"])
        ok += int(np.argmax(probs)) == r["chosen"]
    acc = ok / len(held)
    check(acc > 0.85, "held-out agreement with the rule %.1f%% (chance would be ~%.0f%%)" % (100 * acc, 100 / 5))
    # exploration rows (eps) are not imitated
    rows2 = make_rows(200, seed=13)
    for r in rows2:
        r["eps"] = 0.2
        r["chosen"] = 0
    m2 = Model(hidden=16, seed=1)
    behaviour_clone(m2, rows2, epochs=1, batch=64, log=lambda *_: None)
    pre = {k: v.copy() for k, v in m2.p.items()}
    opt = Adam(m2, lr=1e-2)
    policy_value_step(m2, opt, rows2[:32], bc_w=0.0, ent=0.0)
    check(not np.allclose(pre["vw"], m2.p["vw"]) and np.allclose(pre["w3"], m2.p["w3"]), "with zero policy weight only the value head moves")


def test_value_regression():
    print("test: value head regresses the return")
    rows = make_rows(800, seed=21, G=lambda r, a, rng: 0.3 * r["sx"]["ante"] - 0.02 * r["sx"]["dollars"] + 0.05 * rng.normal())
    m = Model(hidden=32, seed=2)
    opt = Adam(m, lr=3e-3)
    rng = np.random.default_rng(0)
    first = last = None
    for ep in range(30):
        idx = rng.permutation(len(rows))
        for i in range(0, len(rows), 64):
            d = policy_value_step(m, opt, [rows[j] for j in idx[i:i + 64]], bc_w=0.0, ent=0.0)
        if ep == 0:
            first = d["vloss"]
        last = d["vloss"]
    check(last < 0.25 * first and last < 0.2, "value MSE %.3f -> %.3f" % (first, last))


def test_ppo_improves_policy():
    print("test: PPO finds the better option in a noisy bandit (returns only, no teacher)")
    rng = np.random.default_rng(5)
    qual_key = {k: float(rng.normal()) for k in KEYS}
    m = Model(hidden=32, seed=4)
    opt = Adam(m, lr=3e-3)
    agent = Agent(m.copy(), seed=1)

    def episode_batch(n, seed):
        r2 = np.random.default_rng(seed)
        rows = []
        for _ in range(n):
            r = synth_row(r2)
            c = agent.choose(r)
            r["chosen"], r["p"], r["v"] = c["i"], c["p"], c["v"]
            q = qual_key.get(r["options"][r["chosen"]]["key"], 0.0)
            r["G"] = q + 0.3 * float(r2.normal())
            r["src"] = "agent"
            r["_f"] = F.featurize(r)
            rows.append(r)
        return rows

    def mean_quality(n=600, seed=999):
        a2 = Agent(agent.model, greedy=True)
        r2 = np.random.default_rng(seed)
        tot = 0.0
        for _ in range(n):
            r = synth_row(r2)
            c = a2.choose(r)
            tot += qual_key.get(r["options"][c["i"]]["key"], 0.0)
        return tot / n

    before = mean_quality()
    for it in range(60):
        rows = episode_batch(256, seed=100 + it)
        ppo_update(m, opt, rows, epochs=4, batch=64, ent=0.003, seed=it)
        agent.model = m.copy()
    after = mean_quality()
    best_possible = np.mean([max(qual_key.get(o["key"], 0.0) for o in synth_row(np.random.default_rng(900 + i))["options"]) for i in range(300)])
    check(after > before + 0.4, "greedy quality of the chosen option %.2f -> %.2f (an oracle gets about %.2f)" % (before, after, best_possible))


def test_agent_and_bridge():
    print("test: agent answers the file bridge (choose / noop / bad observation)")
    tmp = tempfile.mkdtemp(prefix="trn_bridge_")
    os.makedirs(os.path.join(tmp, "bridge"))
    m = Model(hidden=16, seed=0)
    ag = Agent(m, seed=0)
    br = Bridge(tmp, [1, 2], ag, log=lambda *_: None)
    rng = np.random.default_rng(0)
    dec = synth_row(rng)
    with open(os.path.join(tmp, "bridge", "inst1.obs.json"), "w") as f:
        json.dump({"seq": 7, "snap": {"state": "SHOP", "dec": dec}}, f)
    with open(os.path.join(tmp, "bridge", "inst2.obs.json"), "w") as f:
        json.dump({"seq": 3, "snap": {"state": "SELECTING_HAND"}}, f)
    n = br.poll_once()
    a1 = json.load(open(os.path.join(tmp, "bridge", "inst1.act.json")))
    a2 = json.load(open(os.path.join(tmp, "bridge", "inst2.act.json")))
    check(n == 2, "both observations answered")
    check(a1["seq"] == 7 and a1["action"] == "choose" and 0 <= a1["i"] < len(dec["options"]) and 0 < a1["p"] <= 1 and "v" in a1, "choose with seq, index, p, v (%s)" % a1)
    check(a2["seq"] == 3 and a2["action"] == "noop", "an observation without a decision gets noop")
    check(br.poll_once() == 0, "the same observation is not answered twice")
    only = {"kind": "shop", "sx": {}, "jokers": [], "options": [{"id": "leave", "kind": "leave", "fx": {}}]}
    c = Agent(m).choose(only)
    check(c["i"] == 0 and c["p"] == 1.0, "a single legal option is taken without a coin toss")
    g1 = Agent(m, greedy=True).choose(dec)
    g2 = Agent(m, greedy=True).choose(dec)
    check(g1["i"] == g2["i"], "greedy mode is deterministic")
    shutil.rmtree(tmp, ignore_errors=True)


def test_checkpoint_roundtrip():
    print("test: checkpoints")
    tmp = tempfile.mkdtemp(prefix="trn_ck_")
    m = Model(hidden=12, seed=1)
    path = os.path.join(tmp, "m.npz")
    m.save(path, {"note": "x"})
    m2 = Model.load(path)
    r = synth_row(np.random.default_rng(0))
    s, X = F.featurize(r)
    p1, v1 = m.probs_value(s, X)
    p2, v2 = m2.probs_value(s, X)
    check(np.allclose(p1, p2) and abs(v1 - v2) < 1e-6 and m2.meta["note"] == "x", "save/load keeps the function")
    # mismatching feature tables must be refused loudly
    z = dict(np.load(path))
    meta = json.loads(str(z["__meta__"]))
    meta["S_DIM"] += 1
    z["__meta__"] = np.array(json.dumps(meta))
    np.savez(os.path.join(tmp, "bad.npz"), **z)
    try:
        Model.load(os.path.join(tmp, "bad.npz"))
        check(False, "feature-table mismatch is detected")
    except ValueError:
        check(True, "feature-table mismatch is detected")
    shutil.rmtree(tmp, ignore_errors=True)


def test_integration_with_mock_game():
    print("test: end to end on the mock game - collect baseline data, behaviour-clone, then play live and learn")
    try:
        import run_tests as T
    except Exception as e:  # noqa
        print("  skip (lupa not available: %s)" % e)
        return
    random.seed(77)
    F.UNKNOWN.clear()
    tmp = tempfile.mkdtemp(prefix="trn_int_")
    lua = "MOCK.rich_shop = true; MOCK.pack_joker = true; MOCK.pack_choices = 2; MOCK.hand_money = 6"
    env = {"BOTARENA_PLAN_MS": "10", "BOTARENA_DECIDE_EPS": "0.15"}
    sim, a, b = T.make_pair(tmp, env_a=env, env_b=env, lua_a=lua, lua_b=lua)
    T.run(sim, [a, b], 120000, until=lambda: len(T.results(tmp, 1)) >= 8 and len(T.results(tmp, 2)) >= 8)
    rows, st = load_all(tmp)
    check(len(rows) > 150, "collected %d decisions with returns from %d matches" % (len(rows), st.stats["matches"]))
    check(all(isinstance(r["G"], float) for r in rows), "every row has a return")
    unk = dict(F.UNKNOWN)
    check(not unk, "the feature tables know every feature the mod emits (unknown: %s)" % unk)
    m = Model(hidden=64, seed=0)
    hist = behaviour_clone(m, [r for r in rows if r.get("src") == "baseline"], epochs=25, batch=64, lr=2e-3, log=lambda *_: None)
    check(hist[-1]["top1"] > 0.75, "behaviour cloning reproduces the heuristic teacher (top-1 %.1f%%)" % (100 * hist[-1]["top1"]))
    ckpt = os.path.join(tmp, "ck", "model.npz")
    os.makedirs(os.path.dirname(ckpt))
    m.save(ckpt)

    # live: instance 1 is driven by the agent through the bridge, instance 2 stays baseline
    tmp2 = tempfile.mkdtemp(prefix="trn_int2_")
    sim, a, b = T.make_pair(tmp2, env_a={"BOTARENA_DRIVER": "external", "BOTARENA_BRIDGE_TIMEOUT": "1000", "BOTARENA_PLAN_MS": "10"},
                            env_b={"BOTARENA_PLAN_MS": "10"}, lua_a=lua, lua_b=lua)
    live = Live(tmp2, [1], Model.load(ckpt), os.path.join(tmp2, "live.npz"), min_rows=40, epochs=2, log=lambda *_: None)
    tick = 0
    for i in range(150000):
        for inst in (a, b):
            inst.frame(0.05)
        sim.tick()
        live.bridge.poll_once()
        tick += 1
        if tick % 200 == 0:
            live.step()
        if live.updates >= 2 and len(T.results(tmp2, 1)) >= 6:
            break
    live.step()
    res = T.results(tmp2, 1)
    check(len(res) >= 6, "agent-driven instance finished matches (%d)" % len(res))
    check(live.updates >= 2, "online PPO updates ran (%d)" % live.updates)
    check(os.path.exists(os.path.join(tmp2, "live.npz")), "checkpoint written during live play")
    ag_rows = [r for r in T.read_jsonl(os.path.join(tmp2, "decisions", "inst1.jsonl")) if r["src"] == "agent"]
    check(len(ag_rows) >= 40 and all(0 < r["p"] <= 1 for r in ag_rows), "agent decisions logged with behaviour probabilities (%d)" % len(ag_rows))
    check(live.bridge.stats["errors"] == 0, "no bridge errors")
    errs = [e for inst in (a, b) for e in inst.log() if e.startswith("E ")]
    check(not errs, "no Lua errors (%s)" % errs[:2])
    shutil.rmtree(tmp, ignore_errors=True)
    shutil.rmtree(tmp2, ignore_errors=True)


def synth_hand_row(rng):
    """a hand decision: plays with a score, discards with a redraw estimate; the 'right' answer is the best expected-score candidate"""
    opts = []
    n_play, n_dis = int(rng.integers(3, 8)), int(rng.integers(0, 6))
    for i in range(n_play):
        sc = float(rng.uniform(1.5, 4.5))
        ht = int(rng.integers(1, 7))
        fx = {"n_sel": float(rng.integers(1, 6)), "sc_log": sc, "n_scoring": float(rng.integers(1, 6)), "rest_log": float(rng.uniform(1, 4)), "ht_%d" % ht: 1.0}
        opts.append({"id": "play:%d" % i, "kind": "play", "key": "Pair", "fx": fx, "_v": sc})
    for i in range(n_dis):
        ev = float(rng.uniform(1.5, 4.5))
        fx = {"n_sel": float(rng.integers(1, 6)), "draw_n": float(rng.integers(1, 6)), "kept_log": float(rng.uniform(1, 4)), "ev_log": ev, "k_suit": float(rng.integers(1, 5))}
        opts.append({"id": "discard:%d" % i, "kind": "discard", "key": "discard", "fx": fx, "_v": ev - 0.3})
    best = int(np.argmax([o.pop("_v") for o in opts]))
    return {"kind": "hand", "bidx": 0, "sx": {"ante": 2.0, "h_hl": float(rng.integers(1, 5)), "h_dl": float(rng.integers(0, 4)), "h_has_need": 0.0}, "jokers": [],
            "options": opts, "chosen": best}


def test_hand_features_and_learning():
    print("test: hand decisions - features and behaviour cloning of a known rule (best expected score among plays and discards)")
    rng = np.random.default_rng(5)
    F.UNKNOWN.clear()
    rows = []
    for _ in range(1500):
        r = synth_hand_row(rng)
        r["_f"] = F.featurize(r)
        r["G"] = 0.0
        rows.append(r)
    check(not F.UNKNOWN, "the feature tables know the hand features (unknown: %s)" % dict(F.UNKNOWN))
    s, X = rows[0]["_f"]
    check(s.shape == (F.S_DIM,) and X.shape == (len(rows[0]["options"]), F.X_DIM), "feature shapes")
    check(s[F.STATE_NAMES.index("h_hl")] != 0 and s[len(F.STATE_NAMES) + F.SCREENS.index("hand")] == 1.0, "the hand screen flag and h_* state features are set")
    train, test = rows[:1200], rows[1200:]
    m = Model(hidden=64, seed=1)
    behaviour_clone(m, train, epochs=30, batch=64, lr=2e-3, log=lambda *_: None)
    hit = np.mean([int(np.argmax(m.probs_value(r["_f"][0], r["_f"][1])[0]) == r["chosen"]) for r in test])
    check(hit > 0.85, "held-out agreement with the rule %.1f%%" % (100 * hit))

    # the agent routes hand decisions to the hand model, and echoes the planner's pick (teacher) while there is none
    dec = {k: v for k, v in rows[0].items() if k != "_f"}
    dec["pl"] = 1
    ag = Agent(Model(hidden=16, seed=0), hand_model=None)
    c = ag.choose(dec)
    check(c["i"] == 1 and c.get("teacher"), "without a hand model the planner's pick is answered and flagged teacher (%s)" % c)
    ag2 = Agent(Model(hidden=16, seed=0), greedy=True, hand_model=m)
    c2 = ag2.choose(dec)
    check(c2["i"] == int(np.argmax(m.probs_value(rows[0]["_f"][0], rows[0]["_f"][1])[0])) and not c2.get("teacher"), "with a hand model it answers the model's choice")


def test_hand_learning_on_mock_game():
    print("test: hand play end to end on the mock game - collect planner hands, clone, play with the model, learn")
    try:
        import run_tests as T
    except Exception as e:  # noqa
        print("  skip (lupa not available: %s)" % e)
        return
    random.seed(78)
    F.UNKNOWN.clear()
    tmp = tempfile.mkdtemp(prefix="trn_hand_")
    lua = "MOCK.with_deck = true; MOCK.rich_shop = true; MOCK.pack_joker = true; MOCK.pack_choices = 2; MOCK.hand_money = 6"
    env = {"BOTARENA_PLAN_MS": "10"}
    sim, a, b = T.make_pair(tmp, env_a=env, env_b=env, lua_a=lua, lua_b=lua)
    T.run(sim, [a, b], 160000, until=lambda: len(T.results(tmp, 1)) >= 10 and len(T.results(tmp, 2)) >= 10)
    rows, st = load_all(tmp)
    hand = [r for r in rows if r.get("kind") == "hand"]
    check(len(hand) > 300, "collected %d hand decisions with returns (%d strategic)" % (len(hand), len(rows) - len(hand)))
    unk = dict(F.UNKNOWN)
    check(not unk, "feature tables know every feature the mod emits (unknown: %s)" % unk)
    check(all(isinstance(r["G"], float) for r in hand), "hand rows carry returns")
    hm = Model(hidden=64, seed=0)
    hist = behaviour_clone(hm, [r for r in hand if r.get("src") == "baseline"], epochs=20, batch=64, lr=2e-3, log=lambda *_: None)
    check(hist[-1]["top1"] > 0.8, "the hand model reproduces the planner's choice (top-1 %.1f%%)" % (100 * hist[-1]["top1"]))
    sm = Model(hidden=64, seed=0)
    ck = os.path.join(tmp, "ck")
    os.makedirs(ck)
    sm.save(os.path.join(ck, "model.npz"))
    hm.save(os.path.join(ck, "model_hand.npz"))

    # live: instance 1 driven through the bridge (strategic AND hand decisions), instance 2 plain baseline
    tmp2 = tempfile.mkdtemp(prefix="trn_hand2_")
    sim, a, b = T.make_pair(tmp2, env_a={"BOTARENA_DRIVER": "external", "BOTARENA_BRIDGE_TIMEOUT": "1000", "BOTARENA_PLAN_MS": "10"},
                            env_b={"BOTARENA_PLAN_MS": "10"}, lua_a=lua, lua_b=lua)
    live = Live(tmp2, [1], Model.load(os.path.join(ck, "model.npz")), os.path.join(tmp2, "live.npz"), min_rows=40, epochs=2, log=lambda *_: None,
                hand_model=Model.load(os.path.join(ck, "model_hand.npz")), hand_ckpt=os.path.join(tmp2, "live_hand.npz"), hand_min_rows=120)
    tick = 0
    for i in range(200000):
        for inst in (a, b):
            inst.frame(0.05)
        sim.tick()
        live.bridge.poll_once()
        tick += 1
        if tick % 200 == 0:
            live.step()
        if live.hand_updates >= 2 and len(T.results(tmp2, 1)) >= 6:
            break
    live.step()
    res = T.results(tmp2, 1)
    check(len(res) >= 6, "the model-driven instance finished matches (%d)" % len(res))
    check(live.hand_updates >= 2, "online PPO updates of the hand model ran (%d)" % live.hand_updates)
    check(os.path.exists(os.path.join(tmp2, "live_hand.npz")), "hand checkpoint written")
    hrows = [r for r in T.read_jsonl(os.path.join(tmp2, "decisions", "inst1.hand.jsonl"))]
    ag = [r for r in hrows if r["src"] == "agent"]
    check(len(ag) >= 120 and all(0 < r["p"] <= 1 for r in ag), "agent hand decisions logged with behaviour probabilities (%d)" % len(ag))
    check(live.bridge.stats["errors"] == 0, "no bridge errors")
    errs = [e for inst in (a, b) for e in inst.log() if e.startswith("E ")]
    check(not errs, "no Lua errors (%s)" % errs[:2])

    # no hand model yet: the planner plays through the bridge and the rows are teacher data
    tmp3 = tempfile.mkdtemp(prefix="trn_hand3_")
    sim, a, b = T.make_pair(tmp3, env_a={"BOTARENA_DRIVER": "external", "BOTARENA_BRIDGE_TIMEOUT": "1000", "BOTARENA_PLAN_MS": "10"},
                            env_b={"BOTARENA_PLAN_MS": "10"}, lua_a=lua, lua_b=lua)
    live3 = Live(tmp3, [1], Model(hidden=32, seed=0), os.path.join(tmp3, "l3.npz"), min_rows=10 ** 9, log=lambda *_: None)
    for i in range(120000):
        for inst in (a, b):
            inst.frame(0.05)
        sim.tick()
        live3.bridge.poll_once()
        if len(T.results(tmp3, 1)) >= 3:
            break
    h3 = T.read_jsonl(os.path.join(tmp3, "decisions", "inst1.hand.jsonl"))
    check(len(T.results(tmp3, 1)) >= 3 and len(h3) > 20 and all(r["src"] == "baseline" for r in h3),
          "without a hand model the planner plays and the rows are teacher data (%d rows, matches %d)" % (len(h3), len(T.results(tmp3, 1))))
    for d in (tmp, tmp2, tmp3):
        shutil.rmtree(d, ignore_errors=True)


def test_rule_features_and_old_checkpoints():
    print("test: deck / stake features sit at the END of the vectors; checkpoints from before them still load (zero-padded) and act the same")
    import tempfile
    rng = np.random.default_rng(5)
    r = synth_row(rng)
    r["sx"].update({"dk_plasma": 1, "sk_gold": 1, "r_plasma": 1, "r_no_interest": 0, "r_rental_cost": 6, "r_scaling": 3})
    r["options"][0]["fx"].update({"perish_left": 3, "dead_econ": 1})
    s, X = F.featurize(r)
    check(F.S_DIM == F.S_BASE + len(F.EXTRA_STATE_NAMES) and F.X_DIM == F.X_BASE + len(F.EXTRA_OPT_NAMES), "dims = first-release layout + appended extras")
    i = F.S_BASE + F.EXTRA_STATE_NAMES.index("dk_plasma")
    check(s[i] == 1.0 and s[F.S_BASE + F.EXTRA_STATE_NAMES.index("dk_red")] == 0.0, "deck one-hot lands in the appended block")
    check(s[F.S_BASE + F.EXTRA_STATE_NAMES.index("sk_gold")] == 1.0, "stake one-hot too")
    check(X[0, F.X_BASE + F.EXTRA_OPT_NAMES.index("perish_left")] > 0, "option extras land after the key hash block")
    check(not {"dk_plasma", "sk_gold", "r_plasma", "perish_left", "dead_econ", "r_rental_cost", "r_scaling"} & set(F.UNKNOWN), "the new names are known to the tables")
    for k in ("red", "blue", "yellow", "green", "black", "magic", "nebula", "ghost", "abandoned", "checkered", "zodiac", "painted", "anaglyph", "plasma", "erratic"):
        check("dk_" + k in F.STATE_EXTRA, "deck feature dk_%s" % k) if k in ("red", "erratic") else None
    check(all("sk_" + k in F.STATE_EXTRA for k in ("white", "green", "black", "purple", "gold", "spectralplus")), "all six stakes have a feature")
    # a model saved with the old layout
    m = Model(hidden=16, seed=3)
    old = {k: v.copy() for k, v in m.p.items()}
    old["Ws"], old["Vs"], old["Wx"] = old["Ws"][:F.S_BASE], old["Vs"][:F.S_BASE], old["Wx"][:F.X_BASE]
    tmp = tempfile.mkdtemp(prefix="trainer_old_")
    path = os.path.join(tmp, "old.npz")
    np.savez(path, **old, __meta__=np.array(json.dumps({"hidden": 16, "S_DIM": F.S_BASE, "X_DIM": F.X_BASE})))
    m2 = Model.load(path)
    check(m2.p["Ws"].shape[0] == F.S_DIM and m2.p["Wx"].shape[0] == F.X_DIM and m2.p["Vs"].shape[0] == F.S_DIM, "old checkpoint grows to the new input size")
    check(m2.meta.get("grown_from") == [F.S_BASE, F.X_BASE], "...and says so")
    S = np.random.default_rng(1).standard_normal((3, F.S_DIM)).astype(np.float32)
    Xo = np.random.default_rng(2).standard_normal((3, 4, F.X_DIM)).astype(np.float32)
    mask = np.ones((3, 4), np.float32)
    l1, v1, _ = m2.forward(S, Xo, mask)
    S2, X2 = S.copy(), Xo.copy()
    S2[:, F.S_BASE:], X2[:, :, F.X_BASE:] = 3.0, 3.0
    l2, v2, _ = m2.forward(S2, X2, mask)
    check(np.abs(l1 - l2).max() == 0 and np.abs(v1 - v2).max() == 0, "the padded model ignores the new inputs until it is trained")
    l0, v0, _ = m.forward(S, Xo, mask)
    S0, X0 = S.copy(), Xo.copy()
    S0[:, F.S_BASE:], X0[:, :, F.X_BASE:] = 0.0, 0.0
    l3, v3, _ = m2.forward(S0, X0, mask)
    check(np.abs(l3 - m.forward(S0, X0, mask)[0]).max() < 1e-4, "...and equals the original model on old-layout inputs")
    # new -> save -> load round trip keeps working
    m2.save(os.path.join(tmp, "new.npz"))
    m3 = Model.load(os.path.join(tmp, "new.npz"))
    check(m3.p["Ws"].shape == m2.p["Ws"].shape and "grown_from" not in m3.meta, "a re-saved checkpoint loads without padding")
    # a checkpoint from some other layout is still refused
    bad = os.path.join(tmp, "bad.npz")
    np.savez(bad, **old, __meta__=np.array(json.dumps({"hidden": 16, "S_DIM": F.S_BASE - 3, "X_DIM": F.X_BASE})))
    try:
        Model.load(bad)
        check(False, "a checkpoint with a smaller, unknown layout is refused")
    except ValueError:
        check(True, "a checkpoint with an unknown layout is still refused")


def run():
    t0 = time.time()
    for fn in (test_features, test_gradients, test_returns_and_files, test_bc_learns_rule, test_value_regression,
               test_ppo_improves_policy, test_agent_and_bridge, test_checkpoint_roundtrip, test_integration_with_mock_game,
               test_hand_features_and_learning, test_hand_learning_on_mock_game, test_rule_features_and_old_checkpoints):
        try:
            fn()
        except Exception as e:  # noqa
            import traceback
            traceback.print_exc()
            failures.append("%s crashed: %s" % (fn.__name__, e))
    print("\ntrainer tests: %d failure(s) in %.1fs" % (len(failures), time.time() - t0))
    return failures


if __name__ == "__main__":
    sys.exit(1 if run() else 0)
