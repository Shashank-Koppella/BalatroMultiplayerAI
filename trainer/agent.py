"""Live play: answers the arena's file bridge with the model's choices (and, in Live, learns from what happens)."""
import json
import os
import threading
import time

import numpy as np

from . import features as F
from .algo import behaviour_clone, ppo_update
from .data import Store
from .model import Adam, Model


class Agent:
    """Picks an option for a decision row (snap["dec"]). Sampling from the policy keeps exploration and makes the logged
    probability p the true behaviour probability that PPO needs; `greedy` takes the arg-max instead (evaluation).

    Two models: `model` for the strategic screens (blind / shop / pack) and `hand_model` for hand decisions (kind "hand": which
    cards to play or discard). Without a hand model the planner's own pick (dec["pl"], the teacher) is answered and flagged
    `teacher` so the arena logs it as baseline data instead of agent data."""

    def __init__(self, model, greedy=False, seed=0, temperature=1.0, hand_model=None):
        self.model, self.hand_model, self.greedy, self.temperature = model, hand_model, greedy, temperature
        self.rng = np.random.default_rng(seed)
        self.calls = 0

    def choose(self, dec):
        opts = dec.get("options") or []
        if not opts:
            return None
        is_hand = dec.get("kind") == "hand"
        model = self.hand_model if is_hand else self.model
        if is_hand and model is None:
            pl = dec.get("pl")
            if pl is None:
                pl = 0
            return {"i": int(pl), "p": 1.0, "v": 0.0, "teacher": True}
        if len(opts) == 1:
            return {"i": 0, "p": 1.0, "v": 0.0}
        s, X = F.featurize(dec)
        probs, v = model.probs_value(s, X)
        if self.temperature != 1.0:
            logp = np.log(np.clip(probs, 1e-12, 1)) / self.temperature
            probs = np.exp(logp - logp.max())
            probs /= probs.sum()
        probs = probs / probs.sum()
        i = int(np.argmax(probs)) if self.greedy else int(self.rng.choice(len(probs), p=probs))
        self.calls += 1
        return {"i": i, "p": float(probs[i]), "v": float(v)}


def _read_json(path):
    try:
        with open(path, "r", encoding="utf8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def _write_json_atomic(path, obj):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf8") as f:
        json.dump(obj, f)
    os.replace(tmp, path)


class Bridge:
    """Watches run/bridge/inst<N>.obs.json for the given instances and answers every new observation."""

    def __init__(self, run_dir, insts, agent, log=print):
        self.dir = os.path.join(run_dir, "bridge")
        self.insts, self.agent, self.log = list(insts), agent, log
        self.last = {i: -1 for i in self.insts}
        self.stats = {"answered": 0, "no_dec": 0, "errors": 0}

    def poll_once(self):
        n = 0
        for i in self.insts:
            obs = _read_json(os.path.join(self.dir, "inst%d.obs.json" % i))
            if not obs or obs.get("seq") == self.last[i]:
                continue
            self.last[i] = obs["seq"]
            snap = obs.get("snap") or {}
            dec = snap.get("dec")
            act = {"seq": obs["seq"], "action": "noop"}
            if dec:
                try:
                    c = self.agent.choose(dec)
                    if c:
                        act = {"seq": obs["seq"], "action": "choose", "i": c["i"], "p": round(c["p"], 6), "v": round(c["v"], 5)}
                        if c.get("teacher"):
                            act["teacher"] = True
                except Exception as e:  # noqa - never let one bad observation kill the bridge
                    self.stats["errors"] += 1
                    self.log("agent error on inst %d: %r" % (i, e))
            else:
                self.stats["no_dec"] += 1
            _write_json_atomic(os.path.join(self.dir, "inst%d.act.json" % i), act)
            self.stats["answered"] += 1
            n += 1
        return n

    def run(self, stop, poll=0.003):
        while not stop.is_set():
            if not self.poll_once():
                time.sleep(poll)


class Live:
    """Bridge in a thread + PPO learners in the calling thread: one for the strategic screens, one for hand decisions.

    The hand learner exists only when a hand model is given (train it first with `bc`: a random hand policy would throw whole
    matches away). Without one, the planner plays the hands (answered as teacher data) and only the strategic model learns."""

    def __init__(self, run_dir, insts, model, ckpt, *, lr=3e-4, min_rows=256, gamma=0.9, reward_scale=30.0, match_bonus=0.0,
                 epochs=4, clip=0.2, ent=0.01, bc_coef=0.3, learn=True, greedy=False, log=print, seed=0,
                 hand_model=None, hand_ckpt=None, hand_lr=1e-4, hand_min_rows=768, gamma_hand=0.6, hand_ent=0.003,
                 learn_kinds=("strategy", "hand")):
        self.run_dir, self.ckpt, self.hand_ckpt, self.log = run_dir, ckpt, hand_ckpt, log
        self.learner, self.hand_learner = model, hand_model
        self.opt = Adam(self.learner, lr=lr)
        self.hand_opt = Adam(self.hand_learner, lr=hand_lr) if hand_model is not None else None
        self.agent = Agent(self.learner.copy(), greedy=greedy, seed=seed, hand_model=hand_model.copy() if hand_model is not None else None)
        self.bridge = Bridge(run_dir, insts, self.agent, log=log)
        self.store = Store(run_dir, gamma=gamma, reward_scale=reward_scale, match_bonus=match_bonus, gamma_hand=gamma_hand)
        self.min_rows, self.hand_min_rows = min_rows, hand_min_rows
        self.epochs, self.clip, self.ent, self.hand_ent, self.bc_coef, self.learn = epochs, clip, ent, hand_ent, bc_coef, learn
        self.learn_kinds = tuple(learn_kinds)
        self.agent_rows, self.teacher_rows = [], []
        self.hand_agent_rows, self.hand_teacher_rows = [], []
        self.updates, self.hand_updates = 0, 0
        self.stop = threading.Event()
        self.thread = None

    def start(self):
        self.thread = threading.Thread(target=self.bridge.run, args=(self.stop,), daemon=True)
        self.thread.start()

    def close(self):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=2)

    def _summ(self, name, n, diag, rows):
        won = [1.0 if r["won"] else 0.0 for r in rows]
        diag.update({"rows": len(rows), "mean_G": float(np.mean([r["G"] for r in rows])), "win_rate": float(np.mean(won)) if won else 0.0})
        self.log("%s update %d: %s" % (name, n, ", ".join("%s=%.4g" % (k, v) for k, v in sorted(diag.items()))))

    def step(self):
        """Ingest new logs; maybe run one update per model. Returns the strategic update's diagnostics (or the hand one) or None."""
        self.store.poll()
        for r in self.store.take():
            hand = r.get("kind") == "hand"
            agent = r.get("src") == "agent"
            (self.hand_agent_rows if hand and agent else self.hand_teacher_rows if hand else self.agent_rows if agent else self.teacher_rows).append(r)
        self.teacher_rows = self.teacher_rows[-20000:]
        self.hand_teacher_rows = self.hand_teacher_rows[-6000:]
        out = None
        if self.learn and "strategy" in self.learn_kinds and len(self.agent_rows) >= self.min_rows:
            rows, self.agent_rows = self.agent_rows, []
            diag = ppo_update(self.learner, self.opt, rows, epochs=self.epochs, clip=self.clip, ent=self.ent,
                              bc_rows=self.teacher_rows[-2000:] or None, bc_coef=self.bc_coef, seed=self.updates)
            self.updates += 1
            self.agent.model = self.learner.copy()          # atomic swap: the bridge thread picks it up on its next decision
            self.learner.save(self.ckpt, {"updates": self.updates, "agent_rows": len(rows)})
            self._summ("strategy", self.updates, diag, rows)
            out = diag
        if (self.learn and "hand" in self.learn_kinds and self.hand_learner is not None and len(self.hand_agent_rows) >= self.hand_min_rows):
            rows, self.hand_agent_rows = self.hand_agent_rows, []
            diag = ppo_update(self.hand_learner, self.hand_opt, rows, epochs=self.epochs, clip=self.clip, ent=self.hand_ent,
                              bc_rows=self.hand_teacher_rows[-2000:] or None, bc_coef=self.bc_coef, seed=self.hand_updates)
            self.hand_updates += 1
            self.agent.hand_model = self.hand_learner.copy()
            if self.hand_ckpt:
                self.hand_learner.save(self.hand_ckpt, {"updates": self.hand_updates, "agent_rows": len(rows), "kind": "hand"})
            self._summ("hand", self.hand_updates, diag, rows)
            out = out or diag
        return out

    def run(self, seconds=0, poll=1.0):
        self.start()
        t0 = time.time()
        try:
            while not seconds or time.time() - t0 < seconds:
                self.step()
                time.sleep(poll)
        except KeyboardInterrupt:
            pass
        finally:
            self.close()
            self.learner.save(self.ckpt, {"updates": self.updates, "final": True})
            if self.hand_learner is not None and self.hand_ckpt:
                self.hand_learner.save(self.hand_ckpt, {"updates": self.hand_updates, "final": True, "kind": "hand"})
