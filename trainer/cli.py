"""python -m trainer <command> ... (run from the BalatroArena folder)"""
import argparse
import os
import sys
import time

import numpy as np

from . import features as F
from .agent import Agent, Live
from .algo import behaviour_clone
from .data import Store, load_all
from .evaluate import decisions_by_src, format_table, summarize
from .model import Model

DEFAULT_CKPT = os.path.join("trainer_ckpt", "model.npz")
DEFAULT_HAND_CKPT = os.path.join("trainer_ckpt", "model_hand.npz")


def _ints(s):
    return [int(x) for x in str(s).split(",") if x.strip()]


def _bc_kind(rows, kind, ckpt, a, init=""):
    teach = [r for r in rows if r.get("src") == "baseline"]
    if a.all_sources:
        teach = list(rows)
    if len(teach) < (50 if kind == "strategy" else 100):
        print("[%s] not enough decisions to learn from (%d). Run the arena for a while first:  node arena.js up --fresh" % (kind, len(teach)))
        return False
    hidden = a.hand_hidden if kind == "hand" else a.hidden
    model = Model.load(init) if init and os.path.exists(init) else Model(hidden=hidden, seed=a.seed)
    print("[%s] behaviour cloning on %d teacher decisions" % (kind, len(teach)))
    hist = behaviour_clone(model, teach, epochs=a.epochs, batch=a.batch, lr=a.lr, seed=a.seed)
    os.makedirs(os.path.dirname(ckpt) or ".", exist_ok=True)
    model.save(ckpt, {"bc_rows": len(teach), "top1": hist[-1]["top1"], "kind": kind})
    print("[%s] saved %s  (teacher agreement %.1f%%)" % (kind, ckpt, 100 * hist[-1]["top1"]))
    return True


def cmd_bc(a):
    rows, st = load_all(a.run_dir, gamma=a.gamma, reward_scale=a.reward_scale, match_bonus=a.match_bonus, gamma_hand=a.gamma_hand)
    strat = [r for r in rows if r.get("kind") != "hand"]
    hand = [r for r in rows if r.get("kind") == "hand"]
    print("loaded %d strategic + %d hand decisions from finished matches (%s)" % (len(strat), len(hand), st.stats))
    done = False
    if a.only in ("both", "strategy"):
        done = _bc_kind(strat, "strategy", a.ckpt, a, a.init) or done
    if a.only in ("both", "hand"):
        done = _bc_kind(hand, "hand", a.hand_ckpt, a, a.hand_init) or done
    return 0 if done else 1


def cmd_live(a, learn=True):
    if os.path.exists(a.ckpt):
        model = Model.load(a.ckpt)
        print("strategy model: loaded %s" % a.ckpt)
    else:
        print("strategy model: no checkpoint at %s: starting from a random policy (run `bc` first for a sensible start)" % a.ckpt)
        model = Model(hidden=a.hidden, seed=a.seed)
    hand_model = None
    if a.hands != "planner":
        if os.path.exists(a.hand_ckpt):
            hand_model = Model.load(a.hand_ckpt)
            print("hand model: loaded %s  -> the model plays and %s the hands" % (a.hand_ckpt, "learns" if learn and "hand" in a.learn else "keeps"))
        else:
            print("hand model: no checkpoint at %s -> the PLANNER plays the hands (logged as teacher data). Collect data with a baseline run, then `bc`." % a.hand_ckpt)
    else:
        print("hand model: off (--hands planner)")
    live = Live(a.run_dir, _ints(a.insts), model, a.ckpt, lr=a.lr, min_rows=a.min_rows, gamma=a.gamma, reward_scale=a.reward_scale,
                match_bonus=a.match_bonus, epochs=a.ppo_epochs, clip=a.clip, ent=a.entropy, bc_coef=a.bc_coef,
                learn=learn, greedy=a.greedy, seed=a.seed, hand_model=hand_model, hand_ckpt=a.hand_ckpt, hand_lr=a.hand_lr,
                hand_min_rows=a.hand_min_rows, gamma_hand=a.gamma_hand, learn_kinds=[k for k in a.learn.split(",") if k])
    print("playing instances %s through %s/bridge (%s). Ctrl-C to stop." % (a.insts, a.run_dir, "learning: " + a.learn if learn else "not learning"))
    live.run(seconds=a.seconds)
    return 0


def cmd_agent(a):
    return cmd_live(a, learn=False)


def cmd_eval(a):
    rows = summarize(a.run_dir, last=a.last)
    print(format_table(rows) if rows else "no finished matches in %s/results yet" % a.run_dir)
    print("decisions by source:", decisions_by_src(a.run_dir))
    return 0


def cmd_inspect(a):
    rows, st = load_all(a.run_dir)
    need = a.hand_ckpt if a.kind == "hand" else a.ckpt
    if not os.path.exists(need):
        print("no checkpoint at", need)
        return 1
    model = Model.load(a.ckpt) if os.path.exists(a.ckpt) else None
    hand_model = Model.load(a.hand_ckpt) if os.path.exists(a.hand_ckpt) else None
    shown = 0
    sel = [r for r in rows if (r.get("kind") == "hand") == (a.kind == "hand")]
    for r in sel[-a.n:]:
        s, X = r["_f"]
        m = hand_model if r.get("kind") == "hand" else model
        if m is None:
            continue
        probs, v = m.probs_value(s, X.astype(np.float32))
        top = int(np.argmax(probs))
        mark = "  " if top == r["chosen"] else "!!"
        print("%s %-5s ante %-2s $%-3s  logged %-22s model %-22s (p=%.2f)  V=%.2f  G=%.2f  src=%s" % (
            mark, r["kind"], r["sx"].get("ante"), r["sx"].get("dollars"), r["options"][r["chosen"]]["id"][:22], r["options"][top]["id"][:22],
            probs[top], v, r["G"], r.get("src")))
        shown += 1
    return 0


def build_parser():
    p = argparse.ArgumentParser(prog="trainer", description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    def common(sp):
        sp.add_argument("--run-dir", default="run")
        sp.add_argument("--ckpt", default=DEFAULT_CKPT)
        sp.add_argument("--gamma", type=float, default=0.9, help="discount per reward row (blind)")
        sp.add_argument("--reward-scale", type=float, default=30.0, help="rewards are divided by this before learning")
        sp.add_argument("--match-bonus", type=float, default=0.0, help="extra reward at the end of a match: +win / -loss (0 = only the arena's rewards)")
        sp.add_argument("--hand-ckpt", default=DEFAULT_HAND_CKPT, help="checkpoint of the hand-play model")
        sp.add_argument("--gamma-hand", type=float, default=0.6, help="discount per reward row for hand decisions")
        sp.add_argument("--hand-hidden", type=int, default=128)
        sp.add_argument("--hidden", type=int, default=96)
        sp.add_argument("--seed", type=int, default=0)

    sp = sub.add_parser("bc", help="behaviour-clone the baseline's logged decisions")
    common(sp)
    sp.add_argument("--epochs", type=int, default=20)
    sp.add_argument("--batch", type=int, default=128)
    sp.add_argument("--lr", type=float, default=1e-3)
    sp.add_argument("--init", default="")
    sp.add_argument("--all-sources", action="store_true", help="also imitate agent decisions")
    sp.add_argument("--only", choices=["both", "strategy", "hand"], default="both", help="which model to clone")
    sp.add_argument("--hand-init", default="", help="continue from this hand checkpoint")
    sp.set_defaults(fn=cmd_bc)

    for name, fn, h in (("live", cmd_live, "answer the bridge and learn online (PPO)"), ("agent", cmd_agent, "answer the bridge, no learning")):
        sp = sub.add_parser(name, help=h)
        common(sp)
        sp.add_argument("--insts", default="1", help="comma separated instance ids that run the external driver")
        sp.add_argument("--seconds", type=float, default=0, help="stop after this long (0 = until Ctrl-C)")
        sp.add_argument("--lr", type=float, default=3e-4)
        sp.add_argument("--min-rows", type=int, default=256, help="agent decisions (with returns) per update")
        sp.add_argument("--ppo-epochs", type=int, default=4)
        sp.add_argument("--clip", type=float, default=0.2)
        sp.add_argument("--entropy", type=float, default=0.01)
        sp.add_argument("--bc-coef", type=float, default=0.3, help="weight of the teacher regulariser during PPO")
        sp.add_argument("--greedy", action="store_true", help="take the arg-max instead of sampling (evaluation)")
        sp.add_argument("--hands", choices=["learned", "planner"], default="learned", help="learned = the hand model plays hands once `bc` made one; planner = never")
        sp.add_argument("--learn", default="strategy,hand", help="which models update online (comma list; empty = none)")
        sp.add_argument("--hand-lr", type=float, default=1e-4)
        sp.add_argument("--hand-min-rows", type=int, default=768, help="agent hand decisions (with returns) per hand update")
        sp.set_defaults(fn=fn)

    sp = sub.add_parser("eval", help="win rate / reward per driver")
    sp.add_argument("--run-dir", default="run")
    sp.add_argument("--last", type=int, default=0, help="only the last N matches per instance")
    sp.set_defaults(fn=cmd_eval)

    sp = sub.add_parser("inspect", help="show recent decisions: what was logged vs what the model would do (!! = disagreement)")
    common(sp)
    sp.add_argument("-n", type=int, default=30)
    sp.add_argument("--kind", choices=["strategy", "hand"], default="strategy")
    sp.set_defaults(fn=cmd_inspect)
    return p


def main(argv=None):
    a = build_parser().parse_args(argv)
    return a.fn(a) or 0


if __name__ == "__main__":
    sys.exit(main())
