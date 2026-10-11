"""Reading the arena's logs and attaching returns.

Files (all under <run-dir>/):
    decisions/inst<N>.jsonl   one row per strategic decision (mod/BotArena/lib/decide.lua)
    results/rewards<N>.jsonl  one row per finished blind / skip, `ridx` = its index in the match (lib/reward.lua)
    results/inst<N>.jsonl     one row per finished match (win / loss / aborted)

A decision made when the next reward row to be booked has index `bidx` is paid by every reward row with ridx >= bidx of the same
match:   G = sum_k gamma^(k - bidx) * r_k.   (inst, sess, match) identifies a match; `sess` is unique per game process.
Only matches that have a result row are used, so a half-played match never contributes a truncated return.
"""
import glob
import json
import os

import numpy as np

from . import features as F


class Tail:
    """Incremental JSONL reader: returns only complete lines added since the previous call (survives truncation)."""

    def __init__(self, path):
        self.path, self.pos, self.buf = path, 0, b""

    def read(self):
        try:
            size = os.path.getsize(self.path)
        except OSError:
            return []
        if size < self.pos:  # file was recreated (arena --fresh)
            self.pos, self.buf = 0, b""
        if size == self.pos:
            return []
        with open(self.path, "rb") as f:
            f.seek(self.pos)
            chunk = f.read()
        self.pos += len(chunk)
        data = self.buf + chunk
        lines = data.split(b"\n")
        self.buf = lines.pop()  # incomplete tail
        out = []
        for ln in lines:
            ln = ln.strip()
            if not ln:
                continue
            try:
                out.append(json.loads(ln))
            except ValueError:
                pass
        return out


def wasted_pvp_single(row):
    """True for a hand decision in PvP (hands left > 1) whose chosen play is a single card scoring < 90 % of the best offered play."""
    try:
        sx = row.get("sx") or {}
        if sx.get("h_pvp") != 1 or (sx.get("h_hl") or 0) <= 1:
            return False
        i = row.get("chosen")
        opts = row.get("options") or []
        if i is None or not (0 <= i < len(opts)):
            return False
        o = opts[i]
        if o.get("kind") != "play" or (o.get("fx") or {}).get("n_sel") != 1:
            return False
        best = max((x.get("fx") or {}).get("sc_log", 0.0) for x in opts if x.get("kind") == "play")
        return best - (o.get("fx") or {}).get("sc_log", 0.0) > 0.0458
    except Exception:  # noqa
        return False


def match_key(row):
    return (row.get("inst"), row.get("sess"), row.get("match"))


class Store:
    """Accumulates decisions / rewards / results from a run dir and hands out finished, return-annotated rows."""

    def __init__(self, run_dir, gamma=0.9, reward_scale=30.0, match_bonus=0.0, max_rows=100000, gamma_hand=0.6, max_hand_rows=15000):
        # hand decisions (kind "hand") are ~10x more frequent than the strategic ones: they get their own (shorter) discount and row cap
        self.run_dir, self.gamma, self.scale, self.match_bonus, self.max_rows = run_dir, gamma, reward_scale, match_bonus, max_rows
        self.gamma_hand, self.max_hand_rows = gamma_hand, max_hand_rows
        self.tails = {}
        self.pending = {}   # match key -> list of decision rows (not yet matched with a finished match)
        self.rewards = {}   # match key -> {ridx: reward}
        self.finished = {}  # match key -> result row
        self.ready = []     # rows with returns, not yet taken by take()
        self.stats = {"decisions": 0, "rewards": 0, "matches": 0, "used": 0, "dropped": 0}

    def _tail(self, path):
        t = self.tails.get(path)
        if t is None:
            t = self.tails[path] = Tail(path)
        return t

    def poll(self):
        """Read new lines; returns how many decision rows became ready."""
        d = self.run_dir
        for path in sorted(glob.glob(os.path.join(d, "decisions", "inst*.jsonl"))):
            for row in self._tail(path).read():
                self.stats["decisions"] += 1
                self.pending.setdefault(match_key(row), []).append(row)
        for path in sorted(glob.glob(os.path.join(d, "results", "rewards*.jsonl"))):
            for row in self._tail(path).read():
                if not isinstance(row.get("ridx"), int):
                    continue
                self.stats["rewards"] += 1
                rv = float(row.get("reward") or 0.0)
                # rows written before 2026-10-06 13:37 carry a score-dependent shortfall penalty on failed Small/Big blinds: a blind is cleared or it is not
                parts = row.get("parts")
                if isinstance(parts, dict):
                    for k in ("shortfall", "fail_shortfall"):
                        if isinstance(parts.get(k), (int, float)):
                            rv -= float(parts[k])
                self.rewards.setdefault(match_key(row), {})[row.get("ridx")] = rv
        new_ready = 0
        for path in sorted(glob.glob(os.path.join(d, "results", "inst*.jsonl"))):
            for row in self._tail(path).read():
                if row.get("result") not in ("win", "loss"):
                    # aborted matches carry no clean outcome: forget them
                    k = match_key(row)
                    self.pending.pop(k, None)
                    self.rewards.pop(k, None)
                    continue
                self.stats["matches"] += 1
                k = match_key(row)
                self.finished[k] = row
        for k in list(self.finished):
            if k in self.pending:
                new_ready += self._finish(k)
        return new_ready

    def _finish(self, k):
        res = self.finished[k]
        rew = self.rewards.get(k, {})
        rows = self.pending.pop(k, [])
        if res.get("result") == "win":
            term = self.match_bonus
        else:
            term = -self.match_bonus
        last = max(rew) if rew else -1
        out = 0
        for r in rows:
            b = r.get("bidx")
            if not isinstance(b, int) or r.get("chosen") is None:
                self.stats["dropped"] += 1
                continue
            if r.get("kind") == "hand" and wasted_pvp_single(r):
                # rows from before 2026-10-06 15:27: a lone card played in PvP although a clearly better play existed (old "save the best for last" opener)
                self.stats["dropped"] += 1
                continue
            gam = self.gamma_hand if r.get("kind") == "hand" else self.gamma
            G = 0.0
            for j, rv in rew.items():
                if j >= b:
                    G += (gam ** (j - b)) * rv
            if term:
                G += (gam ** (max(last, b - 1) + 1 - b)) * term
            r["G"] = G / self.scale
            r["won"] = res.get("result") == "win"
            try:
                sv, Xm = F.featurize(r)
                r["_f"] = (sv, Xm.astype(np.float16))  # float16: hand decisions carry ~44 candidates each
            except Exception:  # noqa - a malformed row must never stop training
                self.stats["dropped"] += 1
                continue
            self.ready.append(r)
            out += 1
        self.stats["used"] += out
        self._cap()
        return out

    def _cap(self):
        hand = [r for r in self.ready if r.get("kind") == "hand"]
        other = [r for r in self.ready if r.get("kind") != "hand"]
        if len(hand) > self.max_hand_rows or len(other) > self.max_rows:
            keep = set(map(id, hand[-self.max_hand_rows:])) | set(map(id, other[-self.max_rows:]))
            self.ready = [r for r in self.ready if id(r) in keep]

    def take(self):
        """Rows that became ready since the last take()."""
        out, self.ready = self.ready, []
        return out


def load_all(run_dir, **kw):
    """One-shot: every finished decision in the run dir."""
    st = Store(run_dir, **kw)
    st.poll()
    return st.take(), st
