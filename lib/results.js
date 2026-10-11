'use strict';
// Reads the per-instance result files the BotArena mod appends to (run/results/inst<ID>.jsonl) and
// summarises them: per instance, per driver, per pair, plus an Elo table.
const { path, fs, readJsonl, table, c, fmtDuration } = require('./util');

function loadRows(cfg, { since = 0 } = {}) {
  const dir = path.join(cfg.runDir, 'results');
  let files = [];
  try {
    files = fs.readdirSync(dir).filter((f) => /^inst\d+\.jsonl$/.test(f));
  } catch {
    return [];
  }
  const rows = [];
  for (const f of files) for (const r of readJsonl(path.join(dir, f))) if (!since || r.t >= since) rows.push(r);
  rows.sort((a, b) => a.t - b.t);
  return rows;
}

// Each finished match produces one row per player; both rows share the server-chosen seed (+ pair).
function pairUp(rows) {
  const by = new Map();
  const singles = [];
  for (const r of rows) {
    if (!r.seed) {
      singles.push(r);
      continue;
    }
    const key = `${r.pair}|${r.seed}`;
    if (!by.has(key)) by.set(key, []);
    by.get(key).push(r);
  }
  const matches = [];
  for (const group of by.values()) {
    const wins = group.filter((r) => r.result === 'win');
    const losses = group.filter((r) => r.result === 'loss');
    if (wins.length && losses.length) matches.push({ winner: wins[0], loser: losses[0], t: Math.max(...group.map((g) => g.t)) });
    else matches.push({ aborted: true, rows: group, t: Math.max(...group.map((g) => g.t)) });
  }
  matches.sort((a, b) => a.t - b.t);
  return { matches, singles };
}

function elo(matches, k = 24) {
  const R = new Map();
  const get = (n) => R.get(n) || (R.set(n, { rating: 1500, games: 0 }), R.get(n));
  for (const m of matches) {
    if (!m.winner) continue;
    const w = get(m.winner.name);
    const l = get(m.loser.name);
    const exp = 1 / (1 + 10 ** ((l.rating - w.rating) / 400));
    w.rating += k * (1 - exp);
    l.rating -= k * (1 - exp);
    w.games++;
    l.games++;
  }
  return R;
}

function summarize(cfg, opts = {}) {
  const rows = loadRows(cfg, opts);
  const { matches } = pairUp(rows);
  const byInst = new Map();
  for (const r of rows) {
    const k = r.inst;
    if (!byInst.has(k)) byInst.set(k, { inst: k, name: r.name, driver: r.driver, w: 0, l: 0, a: 0, secs: 0, ante: 0, n: 0 });
    const s = byInst.get(k);
    if (r.result === 'win') s.w++;
    else if (r.result === 'loss') s.l++;
    else s.a++;
    s.n++;
    s.secs += r.secs || 0;
    s.ante += r.ante || 0;
  }
  const byDriver = new Map();
  for (const s of byInst.values()) {
    const d = s.driver || '?';
    if (!byDriver.has(d)) byDriver.set(d, { driver: d, w: 0, l: 0, a: 0, n: 0 });
    const x = byDriver.get(d);
    x.w += s.w;
    x.l += s.l;
    x.a += s.a;
    x.n += s.n;
  }
  const span = rows.length > 1 ? rows[rows.length - 1].t - rows[0].t : 0;
  // per deck / per stake (one count per finished match; the winner's row carries both)
  const tally = (key) => {
    const m = new Map();
    for (const x of matches) {
      if (!x.winner) continue;
      const k = x.winner[key];
      if (!k) continue;
      if (!m.has(k)) m.set(k, { name: k, n: 0, ante: 0, secs: 0 });
      const g = m.get(k);
      g.n++;
      g.ante += Math.max(x.winner.ante || 0, x.loser.ante || 0);
      g.secs += x.winner.secs || 0;
    }
    return [...m.values()].sort((a, b) => b.n - a.n);
  };
  return { rows, matches, byDeck: tally('deck'), byStake: tally('stake'), byInst: [...byInst.values()], byDriver: [...byDriver.values()], elo: elo(matches), spanSec: span };
}

function render(sum) {
  if (!sum.rows.length) return 'No finished matches yet.';
  const pct = (w, l) => (w + l ? `${Math.round((100 * w) / (w + l))}%` : '-');
  const out = [];
  const finished = sum.matches.filter((m) => m.winner).length;
  out.push(c.bold(`${finished} finished matches` + (sum.matches.length - finished ? `, ${sum.matches.length - finished} aborted/incomplete` : '') + (sum.spanSec ? ` over ${fmtDuration(sum.spanSec)} (${(finished / Math.max(sum.spanSec / 3600, 0.01)).toFixed(1)} matches/hour)` : '')));
  out.push('');
  out.push(table(
    sum.byInst.sort((a, b) => a.inst - b.inst).map((s) => [`inst${s.inst}`, s.name, s.driver, s.w, s.l, s.a, pct(s.w, s.l), s.n ? `${Math.round(s.secs / s.n)}s` : '', s.n ? (s.ante / s.n).toFixed(1) : '']),
    ['inst', 'name', 'driver', 'wins', 'losses', 'aborted', 'win%', 'avg match', 'avg ante'],
  ));
  if (sum.byDriver.length > 1) {
    out.push('');
    out.push(table(sum.byDriver.map((d) => [d.driver, d.w, d.l, d.a, pct(d.w, d.l)]), ['driver', 'wins', 'losses', 'aborted', 'win%']));
  }
  const loadoutTable = (list, label) => table(list.map((g) => [g.name.replace(/^stake_(mp_)?/, ''), g.n, (g.ante / g.n).toFixed(1), `${Math.round(g.secs / g.n)}s`]), [label, 'matches', 'avg ante reached', 'avg match']);
  if (sum.byDeck && sum.byDeck.length > 1) {
    out.push('');
    out.push(loadoutTable(sum.byDeck, 'deck'));
  }
  if (sum.byStake && sum.byStake.length > 1) {
    out.push('');
    out.push(loadoutTable(sum.byStake, 'stake'));
  }
  if (sum.elo.size > 1) {
    out.push('');
    out.push(table([...sum.elo.entries()].sort((a, b) => b[1].rating - a[1].rating).map(([n, e]) => [n, Math.round(e.rating), e.games]), ['name', 'elo', 'games']));
  }
  return out.join('\n');
}


// ---- rewards -------------------------------------------------------------------------------------
// run/results/rewards<ID>.jsonl: one row per finished blind (written by the mod's lib/reward.lua)
function loadRewards(cfg, { since = 0 } = {}) {
  const dir = path.join(cfg.runDir, 'results');
  let files = [];
  try {
    files = fs.readdirSync(dir).filter((f) => /^rewards\d+\.jsonl$/.test(f));
  } catch {
    return [];
  }
  const rows = [];
  for (const f of files) for (const r of readJsonl(path.join(dir, f))) if (!since || r.t >= since) rows.push(r);
  rows.sort((a, b) => a.t - b.t);
  return rows;
}

function summarizeRewards(rows) {
  const mk = () => ({ n: 0, sum: 0, credit: 0, beaten: 0, wins: 0, losses: 0, ties: 0, hopeless: 0, money: 0, tarots: 0, spectrals: 0, hands: 0 });
  const acc = (g, r) => {
    g.n++;
    g.sum += r.reward || 0;
    g.money += r.money || 0;
    g.tarots += r.tarots || 0;
    g.spectrals += r.spectrals || 0;
    g.hands += r.unused_hands || 0;
    g.credit += (r.parts && r.parts.skip_credit) || 0;
    if (r.kind === 'pvp') {
      if (r.outcome === 'win') g.wins++;
      else if (r.outcome === 'loss') g.losses++;
      else g.ties++;
      if (r.hopeless) g.hopeless++;
    } else if (r.beaten) g.beaten++;
  };
  const byKind = new Map();
  const byInst = new Map();
  for (const r of rows) {
    if (!byKind.has(r.kind)) byKind.set(r.kind, mk());
    acc(byKind.get(r.kind), r);
    if (!byInst.has(r.inst)) byInst.set(r.inst, { total: 0, n: 0 });
    const i = byInst.get(r.inst);
    i.total += r.reward || 0;
    i.n++;
  }
  return { rows, byKind, byInst };
}

function renderRewards(sum) {
  if (!sum.rows.length) return 'No finished blinds yet (rewards are written when a blind is cashed out).';
  const f = (x, d = 2) => (Number.isFinite(x) ? x.toFixed(d) : '-');
  const out = [];
  out.push(c.bold(`${sum.rows.length} scored blinds`) + (sum.rows.some((r) => r.kind === 'skip') ? ` (skips included: ${sum.rows.filter((r) => r.kind === 'skip').length})` : ''));
  out.push('');
  const order = ['small', 'big', 'boss', 'pvp', 'skip', 'rel', 'match'];
  const kinds = [...sum.byKind.keys()].sort((a, b) => (order.indexOf(a) + 99) % 99 - (order.indexOf(b) + 99) % 99);
  out.push(table(
    kinds.map((k) => {
      const g = sum.byKind.get(k);
      if (k === 'skip') return [k, g.n, f(g.sum / g.n), `${g.n} blinds skipped`, '-', '-', '-', '-'];
      if (k === 'rel') return [k, g.n, f(g.sum / g.n), `${g.n} blinds with less value than the opponent`, '-', '-', '-', '-'];
      if (k === 'match') return [k, g.n, f(g.sum / g.n), `${g.n} matches won by 0 lives`, '-', '-', '-', '-'];
      const outcome = k === 'pvp' ? `${g.wins}W ${g.losses}L ${g.ties}T, ${g.hopeless} hopeless${g.credit ? `, skip credit ${f(g.credit, 1)}` : ''}` : `${g.beaten}/${g.n} beaten`;
      return [k, g.n, f(g.sum / g.n), outcome, f(g.money / g.n, 1), f(g.tarots / g.n, 2), f(g.spectrals / g.n, 2), k === 'pvp' ? '-' : f(g.hands / g.n, 2)];
    }),
    ['blind', 'count', 'avg reward', 'result', 'avg $ gen.', 'avg tarots', 'avg spectrals', 'avg unused hands'],
  ));
  out.push('');
  out.push(table(
    [...sum.byInst.entries()].sort((a, b) => a[0] - b[0]).map(([id, v]) => [`inst${id}`, v.n, f(v.total, 1), f(v.total / v.n)]),
    ['inst', 'blinds', 'total reward', 'avg per blind'],
  ));
  return out.join('\n');
}

module.exports = { loadRows, summarize, render, pairUp, elo, loadRewards, summarizeRewards, renderRewards };
