"""Policy + value network in plain numpy (no torch needed), with hand-written backprop and Adam.

Policy   logit_i = MLP([s ; x_i])     for every legal option i of a decision; softmax over the options of ONE decision
Value    V(s)    = MLP(s)             expected discounted blind-level return from the state

The first layer of the policy is computed as  s @ Ws + x_i @ Wx  (identical to a concatenation, but s is only multiplied once).
tests/test_trainer.py checks every gradient against finite differences.
"""
import json

import numpy as np

from . import features as F

NEG = -1e9


def _init(rng, fan_in, shape):
    return (rng.standard_normal(shape) * np.sqrt(2.0 / fan_in)).astype(np.float32)


class Model:
    PARAMS = ["Ws", "Wx", "b1", "W2", "b2", "w3", "b3", "Vs", "vb1", "Vh", "vb2", "vw", "vb"]

    def __init__(self, hidden=96, seed=0, params=None):
        self.hidden = hidden
        if params is not None:
            self.p = {k: v.astype(np.float32).copy() for k, v in params.items()}
            return
        rng = np.random.default_rng(seed)
        H = hidden
        self.p = {
            "Ws": _init(rng, F.S_DIM + F.X_DIM, (F.S_DIM, H)),
            "Wx": _init(rng, F.S_DIM + F.X_DIM, (F.X_DIM, H)),
            "b1": np.zeros(H, np.float32),
            "W2": _init(rng, H, (H, H)),
            "b2": np.zeros(H, np.float32),
            "w3": (rng.standard_normal(H) * 0.01).astype(np.float32),
            "b3": np.zeros((), np.float32),
            "Vs": _init(rng, F.S_DIM, (F.S_DIM, H)),
            "vb1": np.zeros(H, np.float32),
            "Vh": _init(rng, H, (H, H)),
            "vb2": np.zeros(H, np.float32),
            "vw": (rng.standard_normal(H) * 0.01).astype(np.float32),
            "vb": np.zeros((), np.float32),
        }

    # ------------------------------------------------------------------ forward
    def forward(self, S, X, mask):
        """S[B,Ds], X[B,N,Dx], mask[B,N] (1 = real option). -> logits[B,N], V[B], cache"""
        p = self.p
        pre1 = (S @ p["Ws"])[:, None, :] + X @ p["Wx"] + p["b1"]
        a1 = np.maximum(pre1, 0)
        pre2 = a1 @ p["W2"] + p["b2"]
        a2 = np.maximum(pre2, 0)
        logits = a2 @ p["w3"] + p["b3"]
        logits = np.where(mask > 0, logits, NEG)
        vpre1 = S @ p["Vs"] + p["vb1"]
        va1 = np.maximum(vpre1, 0)
        vpre2 = va1 @ p["Vh"] + p["vb2"]
        va2 = np.maximum(vpre2, 0)
        V = va2 @ p["vw"] + p["vb"]
        return logits, V, (S, X, pre1, a1, pre2, a2, vpre1, va1, vpre2, va2)

    @staticmethod
    def log_softmax(logits):
        m = logits.max(axis=1, keepdims=True)
        z = logits - m
        return z - np.log(np.exp(z).sum(axis=1, keepdims=True))

    # ------------------------------------------------------------------ backward
    def backward(self, cache, dlogits, dV):
        """Gradients of a loss given dL/dlogits [B,N] (already zero on padded options) and dL/dV [B]."""
        p = self.p
        S, X, pre1, a1, pre2, a2, vpre1, va1, vpre2, va2 = cache
        g = {}
        g["w3"] = np.einsum("bnh,bn->h", a2, dlogits)
        g["b3"] = np.asarray(dlogits.sum(), np.float32)
        da2 = dlogits[:, :, None] * p["w3"]
        dpre2 = da2 * (pre2 > 0)
        g["W2"] = np.einsum("bnh,bnk->hk", a1, dpre2)
        g["b2"] = dpre2.sum(axis=(0, 1))
        da1 = dpre2 @ p["W2"].T
        dpre1 = da1 * (pre1 > 0)
        g["Wx"] = np.einsum("bnd,bnh->dh", X, dpre1)
        g["Ws"] = S.T @ dpre1.sum(axis=1)
        g["b1"] = dpre1.sum(axis=(0, 1))
        # value head
        g["vw"] = va2.T @ dV
        g["vb"] = np.asarray(dV.sum(), np.float32)
        dva2 = dV[:, None] * p["vw"]
        dvpre2 = dva2 * (vpre2 > 0)
        g["Vh"] = va1.T @ dvpre2
        g["vb2"] = dvpre2.sum(axis=0)
        dva1 = dvpre2 @ p["Vh"].T
        dvpre1 = dva1 * (vpre1 > 0)
        g["Vs"] = S.T @ dvpre1
        g["vb1"] = dvpre1.sum(axis=0)
        return g

    # ------------------------------------------------------------------ inference helpers
    def probs_value(self, s, X):
        """One decision: s[Ds], X[n,Dx] -> (probs[n], V)"""
        logits, V, _ = self.forward(s[None, :], X[None, :, :], np.ones((1, len(X)), np.float32))
        lp = self.log_softmax(logits)
        return np.exp(lp[0]), float(V[0])

    # ------------------------------------------------------------------ persistence
    def copy(self):
        return Model(self.hidden, params=self.p)

    def save(self, path, meta=None):
        import os
        tmp = path + ".tmp.npz"
        np.savez(tmp, **{k: v for k, v in self.p.items()}, __meta__=np.array(json.dumps({
            "hidden": self.hidden, "S_DIM": F.S_DIM, "X_DIM": F.X_DIM, **(meta or {})})))
        os.replace(tmp, path)

    @staticmethod
    def load(path):
        z = np.load(path, allow_pickle=False)
        meta = json.loads(str(z["__meta__"]))
        params = {k: z[k] for k in Model.PARAMS}
        s_old, x_old = meta.get("S_DIM"), meta.get("X_DIM")
        if (s_old, x_old) != (F.S_DIM, F.X_DIM):
            # a checkpoint from before features were appended at the END of the vectors (features.py STATE_EXTRA / OPT_EXTRA):
            # the new inputs get zero weights, so the model behaves exactly as it did until it is trained further
            if not (isinstance(s_old, int) and isinstance(x_old, int) and F.S_BASE <= s_old <= F.S_DIM and F.X_BASE <= x_old <= F.X_DIM):
                raise ValueError("checkpoint was trained with different feature tables (%s/%s vs %s/%s); retrain with `bc`"
                                 % (s_old, x_old, F.S_DIM, F.X_DIM))
            def grow(w, rows):
                if w.shape[0] >= rows:
                    return w
                return np.concatenate([w, np.zeros((rows - w.shape[0],) + w.shape[1:], w.dtype)], axis=0)
            for k in ("Ws", "Vs"):
                params[k] = grow(params[k], F.S_DIM)
            params["Wx"] = grow(params["Wx"], F.X_DIM)
            meta = dict(meta, S_DIM=F.S_DIM, X_DIM=F.X_DIM, grown_from=[s_old, x_old])
        m = Model(meta["hidden"], params=params)
        m.meta = meta
        return m


class Adam:
    def __init__(self, model, lr=1e-3, b1=0.9, b2=0.999, eps=1e-8, clip=1.0):
        self.m, self.lr, self.b1, self.b2, self.eps, self.clip = model, lr, b1, b2, eps, clip
        self.t = 0
        self.mom = {k: np.zeros_like(v) for k, v in model.p.items()}
        self.var = {k: np.zeros_like(v) for k, v in model.p.items()}

    def step(self, grads):
        norm = float(np.sqrt(sum(float((g.astype(np.float64) ** 2).sum()) for g in grads.values())))
        scale = min(1.0, self.clip / (norm + 1e-12)) if self.clip else 1.0
        self.t += 1
        for k, g in grads.items():
            g = g * scale
            self.mom[k] = self.b1 * self.mom[k] + (1 - self.b1) * g
            self.var[k] = self.b2 * self.var[k] + (1 - self.b2) * g * g
            mh = self.mom[k] / (1 - self.b1 ** self.t)
            vh = self.var[k] / (1 - self.b2 ** self.t)
            self.m.p[k] = (self.m.p[k] - self.lr * mh / (np.sqrt(vh) + self.eps)).astype(np.float32)
        return norm


def pad_batch(items):
    """items: list of (s, X, ...) -> S[B,Ds], X[B,N,Dx], mask[B,N]"""
    B = len(items)
    N = max(len(it[1]) for it in items)
    S = np.stack([it[0] for it in items]).astype(np.float32)
    X = np.zeros((B, N, F.X_DIM), np.float32)
    mask = np.zeros((B, N), np.float32)
    for i, it in enumerate(items):
        n = len(it[1])
        X[i, :n] = it[1]
        mask[i, :n] = 1
    return S, X, mask
