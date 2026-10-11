"""Decision rows (written by mod/BotArena/lib/decide.lua) -> numpy features.

A decision row looks like
    {kind: "shop", bidx, sx: {state features}, jokers: [keys], cons: [keys],
     options: [{id, act, kind, key, pos, fx: {option features}}, ...], chosen, src, p?, v?}
and becomes  s[S]  (state vector)  and  X[n, F]  (one row per legal option).

Every raw number gets a fixed transform (below) so values sit roughly in [-3, 3]. Names the mod adds later are ignored
(and counted in `UNKNOWN`) - extend the tables to use them; the model is retrained from the logs, nothing else changes.
Strategy facts that the features make available (see docs/HANDOFF.md, Strategy): lives of both players, ante and distance to
the next PvP, comeback-money asymmetry (life_diff / life_factor), interest room, joker families (economy / scaling / held-card
builds / x-mult), deck composition (steel share etc.) and how much each option adds to the build's best-hand score (d_pot).
"""
import math
import zlib

import numpy as np

KEY_BINS = 48      # hashed identity of an option's card key (joker / planet / pack / voucher ...)
JOKER_BINS = 48    # multi-hot hash of the jokers we own

# ("lin", scale): x / scale        ("log", scale): log1p(max(x, 0)) / scale        ("sgn", scale): sign(x) * log1p(|x|) / scale
STATE_SPEC = {
    "ante": ("lin", 8), "round": ("lin", 24), "dollars": ("log", 4), "dollars_avail": ("log", 4),
    "interest_now": ("lin", 5), "interest_room": ("lin", 25), "reroll_cost": ("lin", 10), "skips": ("lin", 4),
    "on_deck_small": ("lin", 1), "on_deck_big": ("lin", 1), "on_deck_boss": ("lin", 1), "pvp_on_deck": ("lin", 1),
    "lives": ("lin", 4), "enemy_lives": ("lin", 4), "life_diff": ("lin", 3), "life_factor": ("lin", 2),
    "blinds_to_pvp": ("lin", 5),
    "n_jokers": ("lin", 5), "joker_limit": ("lin", 5), "joker_free": ("lin", 5), "n_cons": ("lin", 2), "cons_limit": ("lin", 2),
    "jk_econ": ("lin", 2), "jk_scaling": ("lin", 2), "jk_retrigger": ("lin", 2), "jk_held": ("lin", 2), "jk_xmult": ("lin", 3), "jk_mp": ("lin", 2),
    "deck_n": ("lin", 52), "deck_steel": ("lin", 0.2), "deck_faces": ("lin", 0.4), "deck_suit_max": ("lin", 0.5),
    "deck_rank_max": ("lin", 0.15), "deck_enh": ("lin", 0.3), "deck_glass": ("lin", 0.2), "deck_gold": ("lin", 0.2),
    "hand_size": ("lin", 8), "hands": ("lin", 4), "discards": ("lin", 4),
    "income_est": ("lin", 10), "comfort": ("lin", 2), "voucher_strong": ("lin", 1), "jk_econ_strong": ("lin", 2),
    "swap_v": ("sgn", 3), "idol_hit": ("lin", 1), "ancient_ok": ("lin", 1), "held_build": ("lin", 1), "stake": ("lin", 8), "voucher_cost": ("lin", 10),
    "need_log": ("lin", 6), "pot_log": ("lin", 6), "pot_pvp_log": ("lin", 6), "pot_gap": ("lin", 2), "aim_level": ("lin", 8),
    # hand decisions (lib/handdec.lua)
    "h_hl": ("lin", 4), "h_dl": ("lin", 4), "h_last": ("lin", 1), "h_deck_n": ("lin", 52), "h_hand_n": ("lin", 8), "h_pvp": ("lin", 1),
    "h_chips_log": ("lin", 6), "h_best_log": ("lin", 6), "h_has_need": ("lin", 1), "h_need_log": ("lin", 6), "h_per_hand": ("lin", 6),
    "h_best_frac": ("lin", 1.5), "h_blind_log": ("lin", 6), "h_prog": ("lin", 1), "h_enemy_done": ("lin", 1), "h_enemy_hands": ("lin", 4),
    "h_theirs_log": ("lin", 6), "h_lead": ("sgn", 2), "h_boss": ("lin", 1), "h_hook": ("lin", 1), "h_hand_suit": ("lin", 5),
    "h_hand_run": ("lin", 5), "h_hand_grp": ("lin", 4), "h_deck_suit_max": ("lin", 0.5),
}
OPT_SPEC = {
    "cost": ("lin", 10), "money_after": ("log", 4), "interest_loss": ("lin", 2), "sell": ("lin", 5),
    "rarity": ("lin", 3), "ed_foil": ("lin", 1), "ed_holo": ("lin", 1), "ed_polychrome": ("lin", 1), "ed_negative": ("lin", 1),
    "eternal": ("lin", 1), "perishable": ("lin", 1), "rental": ("lin", 1),
    "cat_econ": ("lin", 1), "cat_scaling": ("lin", 1), "cat_retrigger": ("lin", 1), "cat_held": ("lin", 1), "cat_xmult": ("lin", 1),
    "cat_copy": ("lin", 1), "cat_slots": ("lin", 1), "cat_mp": ("lin", 1),
    "ab_mult": ("log", 3), "ab_chips": ("log", 5), "ab_x": ("lin", 3),
    "d_pot": ("lin", 0.5), "d_pot_pvp": ("lin", 0.5), "slot": ("lin", 5),
    "is_planet": ("lin", 1), "hand_level": ("lin", 8), "hand_played": ("log", 3), "hand_aimed": ("lin", 1),
    "is_tarot": ("lin", 1), "is_spectral": ("lin", 1),
    "pk_celestial": ("lin", 1), "pk_arcana": ("lin", 1), "pk_spectral": ("lin", 1), "pk_standard": ("lin", 1),
    "pk_buffoon": ("lin", 1), "pk_jumbo": ("lin", 1), "pk_mega": ("lin", 1),
    "is_playing": ("lin", 1), "rank": ("lin", 14), "face": ("lin", 1), "enh": ("lin", 1), "seal": ("lin", 1),
    "choices_left": ("lin", 3), "n_cards": ("lin", 5), "rerolls_done": ("lin", 6), "money": ("log", 4), "interest": ("lin", 5),
    "pvp": ("lin", 1), "skips": ("lin", 4),
    "h": ("sgn", 3), "noslot": ("lin", 1), "mp_strong": ("lin", 1), "tgt": ("lin", 2), "blue_seal": ("lin", 1), "lucky": ("lin", 1), "steel": ("lin", 1),
    # hand candidates (lib/handdec.lua): plays
    "n_sel": ("lin", 5), "sc_log": ("lin", 6), "sc_rel": ("lin", 1), "is_max": ("lin", 1), "sc_frac": ("lin", 1.5), "clears": ("lin", 1),
    "n_scoring": ("lin", 5), "n_junk": ("lin", 4), "play_special": ("lin", 3), "rest_log": ("lin", 6), "rest_gain": ("sgn", 2),
    # discards
    "draw_n": ("lin", 5), "kept_log": ("lin", 6), "k_grp": ("lin", 4), "k_pairs": ("lin", 2), "k_suit": ("lin", 5), "k_run": ("lin", 5),
    "o_suit": ("lin", 13), "o_rank": ("lin", 12), "disc_chips": ("lin", 30), "disc_worth": ("lin", 30), "disc_special": ("lin", 3),
    "ev_log": ("lin", 6), "ev_gain": ("sgn", 2), "ev_max": ("lin", 6), "ev_pclear": ("lin", 1),
    # planner verdict (only when BOTARENA_HAND_PLANFEAT=1)
    "pl_has": ("lin", 1), "pl_u": ("sgn", 3), "pl_pc": ("lin", 1),
}
for _i in range(1, 13):
    OPT_SPEC["ht_%d" % _i] = ("lin", 1)
# Added 2026-10-06 (random deck + stake per lobby, lib/rules.lua). They live at the END of the vectors, so a checkpoint trained before
# them still loads (Model.load zero-pads the new input rows) and behaves exactly as before until it is trained further.
STATE_EXTRA = {
    "r_scaling": ("lin", 5), "r_small_pays": ("lin", 1), "r_no_interest": ("lin", 1), "r_mph": ("lin", 2), "r_mpd": ("lin", 1),
    "r_eternals": ("lin", 1), "r_perishables": ("lin", 1), "r_rentals": ("lin", 1), "r_rental_cost": ("lin", 9), "r_perished": ("lin", 2),
    "r_double_tags": ("lin", 2), "r_eternal_n": ("lin", 3), "r_rental_rate": ("lin", 3), "r_plasma": ("lin", 1), "hex_others": ("lin", 3), "n_destroyable": ("lin", 5),
}
STATE_EXTRA.update({"rt_support": ("lin", 3), "jk_retrig_card": ("lin", 2), "jk_on_card": ("lin", 3),
                    "deck_goldseal": ("lin", 0.2), "deck_redseal": ("lin", 0.2), "deck_lucky": ("lin", 0.2)})
for _k in ("red", "blue", "yellow", "green", "black", "magic", "nebula", "ghost", "abandoned", "checkered", "zodiac", "painted", "anaglyph", "plasma", "erratic"):
    STATE_EXTRA["dk_" + _k] = ("lin", 1)
for _k in ("white", "green", "black", "purple", "gold", "spectralplus"):
    STATE_EXTRA["sk_" + _k] = ("lin", 1)
OPT_EXTRA = {"perish_left": ("lin", 5), "dead_econ": ("lin", 1), "deck_bonus": ("lin", 4),
             # seals in a hand option (Purple: Tarot on discard, Gold: $3 on play, Blue: Planet if held) + free consumable slots
             "seal_purple": ("lin", 3), "seal_gold": ("lin", 3), "seal_blue": ("lin", 3), "tarot_room": ("lin", 2),
             # card-retrigger jokers (Hack, Dusk, Sock and Buskin, Seltzer, Hanging Chad): is it one, and how much support the board / deck gives it
             "retrig_card": ("lin", 1), "rt_synergy": ("lin", 3)}
KINDS = [
    "select", "skip", "use_planet", "buy_joker", "buy_planet", "buy_tarot", "buy_spectral", "buy_card", "buy_voucher",
    "open_pack", "reroll", "sell_joker", "use_consumable", "leave", "pick_joker", "pick_planet", "pick_tarot", "pick_spectral",
    "pick_card", "skip_pack", "play", "discard",
]
SCREENS = ["blind", "shop", "pack", "hand"]
HANDS = ["High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush", "Full House", "Four of a Kind", "Straight Flush",
         "Five of a Kind", "Flush House", "Flush Five"]

STATE_NAMES = list(STATE_SPEC)
OPT_NAMES = list(OPT_SPEC)
EXTRA_STATE_NAMES = list(STATE_EXTRA)
EXTRA_OPT_NAMES = list(OPT_EXTRA)
S_BASE = len(STATE_NAMES) + len(SCREENS) + len(HANDS) + JOKER_BINS   # layout of the first release (before STATE_EXTRA)
X_BASE = len(OPT_NAMES) + len(KINDS) + KEY_BINS
S_DIM = S_BASE + len(EXTRA_STATE_NAMES)
X_DIM = X_BASE + len(EXTRA_OPT_NAMES)

UNKNOWN = {}   # name -> count, fills up when a log carries features this table does not know


def _tf(kind, scale, x):
    if kind == "lin":
        v = x / scale
    elif kind == "log":
        v = math.log1p(max(x, 0.0)) / scale
    else:
        v = math.copysign(math.log1p(abs(x)), x) / scale
    return max(-5.0, min(5.0, v))


def bucket(key, bins):
    if key is None:
        return None
    return zlib.crc32(str(key).encode("utf8")) % bins


def state_vector(row):
    sx = row.get("sx") or {}
    v = np.zeros(S_DIM, dtype=np.float32)
    for i, name in enumerate(STATE_NAMES):
        x = sx.get(name)
        if isinstance(x, (int, float)):
            kind, scale = STATE_SPEC[name]
            v[i] = _tf(kind, scale, float(x))
    for k in sx:
        if k not in STATE_SPEC and k not in STATE_EXTRA and k != "aim":
            UNKNOWN[k] = UNKNOWN.get(k, 0) + 1
    o = len(STATE_NAMES)
    if row.get("kind") in SCREENS:
        v[o + SCREENS.index(row["kind"])] = 1.0
    o += len(SCREENS)
    aim = sx.get("aim")
    if aim in HANDS:
        v[o + HANDS.index(aim)] = 1.0
    o += len(HANDS)
    for j in row.get("jokers") or []:
        b = bucket(j, JOKER_BINS)
        if b is not None:
            v[o + b] += 1.0
    v[o:o + JOKER_BINS] = np.minimum(v[o:o + JOKER_BINS], 2.0)
    o += JOKER_BINS
    for i, name in enumerate(EXTRA_STATE_NAMES):
        x = sx.get(name)
        if isinstance(x, (int, float)):
            kind, scale = STATE_EXTRA[name]
            v[o + i] = _tf(kind, scale, float(x))
    return v


def option_matrix(row):
    opts = row.get("options") or []
    X = np.zeros((len(opts), X_DIM), dtype=np.float32)
    nk = len(OPT_NAMES)
    for r, op in enumerate(opts):
        fx = op.get("fx") or {}
        for i, name in enumerate(OPT_NAMES):
            x = fx.get(name)
            if isinstance(x, (int, float)):
                kind, scale = OPT_SPEC[name]
                X[r, i] = _tf(kind, scale, float(x))
        for i, name in enumerate(EXTRA_OPT_NAMES):
            x = fx.get(name)
            if isinstance(x, (int, float)):
                kind, scale = OPT_EXTRA[name]
                X[r, X_BASE + i] = _tf(kind, scale, float(x))
        for k in fx:
            if k not in OPT_SPEC and k not in OPT_EXTRA:
                UNKNOWN[k] = UNKNOWN.get(k, 0) + 1
        kd = op.get("kind")
        if kd in KINDS:
            X[r, nk + KINDS.index(kd)] = 1.0
        b = bucket(op.get("key"), KEY_BINS)
        if b is not None:
            X[r, nk + len(KINDS) + b] = 1.0
    return X


def featurize(row):
    """-> (s[S_DIM], X[n, X_DIM])"""
    return state_vector(row), option_matrix(row)
