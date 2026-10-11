"""Training algorithms on top of Model: behaviour cloning, PPO-style policy gradient, value regression."""
import numpy as np

from .model import Adam, Model, NEG, pad_batch


def batches(rows, size, rng):
    idx = rng.permutation(len(rows))
    for i in range(0, len(idx), size):
        yield [rows[j] for j in idx[i:i + size]]


def _items(rows):
    return [r["_f"] for r in rows]


def policy_value_step(model, opt, rows, *, bc_w=0.0, ppo_w=0.0, adv=None, clip=0.2, ent=0.01, vcoef=0.5):
    """One gradient step over `rows` (a minibatch).

    bc_w[B]   per-row weight of the cross-entropy to the logged choice (behaviour cloning)
    ppo_w[B]  per-row 0/1: apply the PPO clipped surrogate to this row (needs logged p and `adv`)
    Value regression to the discounted return `G` runs on every row.
    Returns a dict of diagnostics.
    """
    S, X, mask = pad_batch(_items(rows))
    B, N = mask.shape
    a = np.array([r["chosen"] for r in rows], dtype=np.int64)
    G = np.array([r["G"] for r in rows], dtype=np.float32)
    logits, V, cache = model.forward(S, X, mask)
    lp = model.log_softmax(logits)
    pi = np.exp(lp) * mask
    onehot = np.zeros((B, N), np.float32)
    onehot[np.arange(B), a] = 1.0
    c = np.zeros(B, np.float32)               # per-row coefficient on d(-logp)
    diag = {}
    bc_w = np.broadcast_to(np.asarray(bc_w, np.float32), (B,))
    ppo_w = np.broadcast_to(np.asarray(ppo_w, np.float32), (B,))
    c += bc_w
    logp_a = lp[np.arange(B), a]
    if ppo_w.any():
        p_old = np.array([r.get("p") or 1.0 for r in rows], np.float32)
        ratio = np.exp(logp_a - np.log(np.clip(p_old, 1e-6, 1.0)))
        A = np.asarray(adv, np.float32)
        active = ((A >= 0) & (ratio < 1 + clip)) | ((A < 0) & (ratio > 1 - clip))
        c += ppo_w * np.where(active, A * ratio, 0.0)
        diag["clipfrac"] = float(((~active) & (ppo_w > 0)).sum() / max(1.0, ppo_w.sum()))
        diag["ratio"] = float((ratio * ppo_w).sum() / max(1.0, ppo_w.sum()))
    dlog = c[:, None] * (pi - onehot)
    # entropy bonus (maximise): loss -= ent * H ;  dH/dz_j = -pi_j (log pi_j + H)
    if ent:
        H = -(pi * np.where(mask > 0, lp, 0)).sum(axis=1)
        dlog += ent * pi * (np.where(mask > 0, lp, 0) + H[:, None])
        diag["entropy"] = float(H.mean())
    dlog = dlog * mask / B
    dV = vcoef * 2.0 * (V - G) / B
    g = model.backward(cache, dlog.astype(np.float32), dV.astype(np.float32))
    diag["grad_norm"] = opt.step(g)
    diag["vloss"] = float(((V - G) ** 2).mean())
    # report on the rows the policy loss actually trains on (behaviour cloning skips random-exploration rows: counting them made the
    # nll look like it was getting worse while the model got better)
    sel = (bc_w > 0) | (ppo_w > 0)
    if not sel.any():
        sel = np.ones(B, bool)
    diag["nll"] = float(-(logp_a[sel]).mean())
    diag["top1"] = float((logits.argmax(axis=1) == a)[sel].mean())
    return diag


def behaviour_clone(model, rows, epochs=15, batch=128, lr=1e-3, seed=0, log=print, weight_fn=None):
    """Imitate the logged choices (the baseline's teacher). Rows flagged `eps` are random exploration and are skipped for the
    policy loss (they still train the value head)."""
    rng = np.random.default_rng(seed)
    opt = Adam(model, lr=lr)
    teach = [r for r in rows if not r.get("eps")]
    hist = []
    for ep in range(epochs):
        agg = {"nll": 0.0, "top1": 0.0, "vloss": 0.0}
        n = 0
        for mb in batches(rows, batch, rng):
            w = np.array([0.0 if r.get("eps") else (weight_fn(r) if weight_fn else 1.0) for r in mb], np.float32)
            d = policy_value_step(model, opt, mb, bc_w=w, ent=0.0)
            for k in agg:
                agg[k] += d[k] * len(mb)
            n += len(mb)
        agg = {k: v / max(1, n) for k, v in agg.items()}
        hist.append(agg)
        log("bc epoch %2d/%d  nll %.4f  top1 %.3f  value-mse %.4f  (%d rows, %d teacher)" % (ep + 1, epochs, agg["nll"], agg["top1"], agg["vloss"], len(rows), len(teach)))
    return hist


def ppo_update(model, opt, rows, *, epochs=4, batch=128, clip=0.2, ent=0.01, vcoef=0.5, bc_rows=None, bc_coef=0.3, seed=0, log=None):
    """PPO-style update. `rows` = decisions made by the live agent (they carry p = probability under the behaviour policy and
    G = discounted return). Advantage = G - V(s) with V from the CURRENT model before the update, normalised over the batch.
    `bc_rows` (teacher decisions) are mixed in as a regulariser that keeps the policy near sensible play."""
    if not rows:
        return {}
    rng = np.random.default_rng(seed)
    S, X, mask = pad_batch(_items(rows))
    _, V0, _ = model.forward(S, X, mask)
    G = np.array([r["G"] for r in rows], np.float32)
    A = G - V0
    A = (A - A.mean()) / (A.std() + 1e-6)
    for r, a in zip(rows, A):
        r["_adv"] = float(a)
    diag = {}
    pool = list(rows)
    for ep in range(epochs):
        for mb in batches(pool, batch, rng):
            adv = np.array([r["_adv"] for r in mb], np.float32)
            diag = policy_value_step(model, opt, mb, ppo_w=1.0, adv=adv, clip=clip, ent=ent, vcoef=vcoef)
        if bc_rows:
            for mb in batches(bc_rows, batch, rng):
                w = np.array([0.0 if r.get("eps") else bc_coef for r in mb], np.float32)
                policy_value_step(model, opt, mb, bc_w=w, ent=0.0, vcoef=vcoef)
                break  # one teacher minibatch per epoch is enough for regularisation
    diag["adv_mean_abs"] = float(np.abs(A).mean())
    return diag


def loss_value(model, rows, *, bc_w=0.0, ppo_w=0.0, adv=None, clip=0.2, ent=0.01, vcoef=0.5):
    """The scalar loss that policy_value_step takes the gradient of (used by the gradient-check test)."""
    S, X, mask = pad_batch(_items(rows))
    B = len(rows)
    a = np.array([r["chosen"] for r in rows], dtype=np.int64)
    G = np.array([r["G"] for r in rows], dtype=np.float64)
    logits, V, _ = model.forward(S, X, mask)
    lp = model.log_softmax(logits.astype(np.float64))
    logp_a = lp[np.arange(B), a]
    bc_w = np.broadcast_to(np.asarray(bc_w, np.float64), (B,))
    ppo_w = np.broadcast_to(np.asarray(ppo_w, np.float64), (B,))
    loss = -(bc_w * logp_a).sum()
    if ppo_w.any():
        p_old = np.array([r.get("p") or 1.0 for r in rows], np.float64)
        ratio = np.exp(logp_a - np.log(np.clip(p_old, 1e-6, 1.0)))
        A = np.asarray(adv, np.float64)
        surr = np.minimum(ratio * A, np.clip(ratio, 1 - clip, 1 + clip) * A)
        loss += -(ppo_w * surr).sum()
    if ent:
        pi = np.exp(lp) * mask
        H = -(pi * np.where(mask > 0, lp, 0)).sum(axis=1)
        loss += -ent * H.sum()
    loss = loss / B + vcoef * ((V - G) ** 2).mean()
    return float(loss)
