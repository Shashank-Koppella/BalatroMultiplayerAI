#!/usr/bin/env node
'use strict';
// End-to-end test of arena.js (config, instance building, local server, supervision, restart rules, shutdown)
// using a fake "Balatro" executable (tests/fake_game.js). Runs on Linux/macOS/Windows with plain Node.
//   node tests/launcher_test.js
const cp = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');

const ROOT = path.resolve(__dirname, '..');
const ARENA = path.join(ROOT, 'arena.js');
const FAKE = path.join(__dirname, 'fake_game.js');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failures = 0;
const check = (ok, msg) => {
  console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${msg}`);
  if (!ok) failures++;
};
const readJson = (p) => {
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch {
    return null;
  }
};
function freePort() {
  return new Promise((res) => {
    const s = net.createServer();
    s.listen(0, '127.0.0.1', () => {
      const p = s.address().port;
      s.close(() => res(p));
    });
  });
}
async function waitFor(fn, ms, step = 200) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    try {
      if (await fn()) return true;
    } catch {
      /* keep waiting */
    }
    await sleep(step);
  }
  return false;
}

function makeSandbox(tag) {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), `arena_l_${tag}_`));
  const gameDir = path.join(base, 'steam', 'Balatro');
  const appData = path.join(base, 'AppData');
  const realSave = path.join(appData, 'Balatro');
  fs.mkdirSync(gameDir, { recursive: true });
  fs.writeFileSync(path.join(gameDir, 'Balatro'), fs.readFileSync(FAKE));
  fs.chmodSync(path.join(gameDir, 'Balatro'), 0o755);
  fs.writeFileSync(path.join(gameDir, 'version.dll'), 'lovely');
  fs.writeFileSync(path.join(gameDir, 'SDL2.dll'), 'sdl');
  const mods = path.join(realSave, 'Mods');
  fs.mkdirSync(path.join(mods, 'smods', 'src'), { recursive: true });
  fs.writeFileSync(path.join(mods, 'smods', 'version.lua'), 'return "1.0.0"');
  fs.writeFileSync(path.join(mods, 'smods', 'src', 'core.lua'), '--smods');
  fs.mkdirSync(path.join(mods, 'multiplayer-0.5.5'), { recursive: true });
  fs.writeFileSync(path.join(mods, 'multiplayer-0.5.5', 'Multiplayer.json'), JSON.stringify({ id: 'Multiplayer', version: '0.5.5' }));
  fs.writeFileSync(path.join(mods, 'multiplayer-0.5.5', 'core.lua'), '--mp');
  fs.writeFileSync(path.join(mods, 'multiplayer-0.5.5', '.env'), 'server_url=balatro.virtualized.dev\n'); // must be overwritten, not copied
  fs.mkdirSync(path.join(mods, 'HandyBalatro'), { recursive: true }); // must NOT end up in instances
  fs.writeFileSync(path.join(mods, 'HandyBalatro', 'index.lua'), '--handy');
  fs.mkdirSync(path.join(mods, 'lovely'), { recursive: true });
  fs.mkdirSync(path.join(realSave, '1'), { recursive: true });
  fs.writeFileSync(path.join(realSave, 'settings.jkr'), 'SETTINGS');
  fs.writeFileSync(path.join(realSave, '1', 'profile.jkr'), 'PROFILE');
  fs.writeFileSync(path.join(realSave, '1', 'meta.jkr'), 'META');
  return { base, gameDir, appData, realSave };
}

function snapshotTree(dir) {
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) walk(f);
      else out.push(`${path.relative(dir, f)}:${fs.statSync(f).size}:${Math.round(fs.statSync(f).mtimeMs)}`);
    }
  };
  walk(dir);
  return out.sort().join('\n');
}

async function writeConfig(sb, over = {}) {
  const port = await freePort();
  const adminPort = await freePort();
  const cfg = {
    gameDir: sb.gameDir,
    exeName: 'Balatro',
    appData: sb.appData,
    sourceModsDir: path.join(sb.realSave, 'Mods'),
    sourceProfileDir: sb.realSave,
    instancesDir: path.join(sb.base, 'instances'),
    runDir: path.join(sb.base, 'run'),
    _schema: 2, // without it the launcher treats the file as a first-release one and migrates pairs: 1 -> 2
    pairs: 1,
    staggerSec: 0.2,
    hangSec: 4,
    startGraceSec: 30,
    restart: { max: 5, windowSec: 600, backoffSec: 1 },
    server: { spawn: true, host: '127.0.0.1', port, adminPort },
    ...over,
  };
  const p = path.join(sb.base, 'arena.config.json');
  fs.writeFileSync(p, JSON.stringify(cfg, null, 2));
  return { cfgPath: p, cfg };
}

function arena(sb, cfgPath, args, opts = {}) {
  const child = cp.spawn(process.execPath, [ARENA, ...args], { env: { ...process.env, ARENA_CONFIG: cfgPath, NO_COLOR: '1' }, stdio: ['ignore', 'pipe', 'pipe'], ...opts });
  const h = { child, out: '', code: null };
  child.stdout.on('data', (d) => (h.out += d));
  child.stderr.on('data', (d) => (h.out += d));
  h.done = new Promise((r) => child.on('exit', (c) => ((h.code = c), r(c))));
  return h;
}
function runOnce(sb, cfgPath, args) {
  const h = arena(sb, cfgPath, args);
  return h.done.then(() => h);
}

// -----------------------------------------------------------------------------------------------------
async function testBasic() {
  console.log('test: build instances, start server + 2 games, status, graceful down');
  const sb = makeSandbox('basic');
  const { cfgPath, cfg } = await writeConfig(sb, { perInstance: { 1: { env: { FAKE_MODE: 'normal' } }, 2: { env: { FAKE_MODE: 'normal' } } }, driver: 'random', speed: 7 });
  const before = snapshotTree(sb.realSave);
  const gameBefore = snapshotTree(sb.gameDir);

  const d = await runOnce(sb, cfgPath, ['doctor']);
  check(d.code === 0, 'doctor passes on a valid setup');

  const h = arena(sb, cfgPath, ['up']);
  const up = await waitFor(() => [1, 2].every((i) => { const s = readJson(path.join(cfg.runDir, 'status', `inst${i}.json`)); return s && Date.now() / 1000 - s.t < 3; }), 25000);
  check(up, 'both instances report heartbeats');
  const e1 = readJson(path.join(cfg.runDir, 'envdump', 'inst1.json'));
  const e2 = readJson(path.join(cfg.runDir, 'envdump', 'inst2.json'));
  check(!!e1 && !!e2, 'environment dumps written by both fake games');
  if (e1 && e2) {
    check(e1.env.LOVELY_MOD_DIR === path.join(sb.appData, 'BalatroArena_1', 'Mods'), 'LOVELY_MOD_DIR points at the instance Mods folder');
    check(e1.env.BOTARENA_IDENTITY === 'BalatroArena_1' && e2.env.BOTARENA_IDENTITY === 'BalatroArena_2', 'per-instance save identity');
    check(e1.env.BOTARENA_ROLE === 'primary' && e2.env.BOTARENA_ROLE === 'secondary' && e1.env.BOTARENA_PAIR === '1' && e2.env.BOTARENA_PAIR === '1', 'roles and pair numbers');
    check(e1.env.BOTARENA_SPEED === '7' && e1.env.BOTARENA_DRIVER === 'random', 'config values reach the instance');
    check(e1.env.BOTARENA_WINDOW !== e2.env.BOTARENA_WINDOW, 'instances get different window slots');
    check(e1.argv.includes('--disable-console'), 'Lovely console disabled');
    check(fs.realpathSync(e1.cwd) === fs.realpathSync(path.join(cfg.instancesDir, 'inst1', 'game')), 'runs from its own game copy');
    check(e1.mpEnv.server_url === '127.0.0.1' && Number(e1.mpEnv.server_port) === cfg.server.port && e1.mpEnv.suppress_dev_warning === 'true', 'Multiplayer .env points at the local server');
    check(JSON.stringify(e1.mods.sort()) === JSON.stringify(['BotArena', 'multiplayer-0.5.5', 'smods']), `instance Mods = smods + Multiplayer + BotArena only (${e1.mods})`);
  }
  check(fs.existsSync(path.join(cfg.instancesDir, 'inst2', 'game', 'BalatroArena_2')), 'game exe copied under a unique name');
  check(fs.existsSync(path.join(cfg.instancesDir, 'inst2', 'game', 'version.dll')), 'Lovely dll copied alongside');
  check(fs.readFileSync(path.join(sb.appData, 'BalatroArena_1', 'settings.jkr'), 'utf8') === 'SETTINGS', 'profile seeded into the instance save folder');
  check(fs.existsSync(path.join(sb.appData, 'BalatroArena_1', 'Mods', 'BotArena', 'main.lua')), 'BotArena mod installed into the instance');
  const slog = fs.existsSync(path.join(cfg.runDir, 'logs', 'server.log')) ? fs.readFileSync(path.join(cfg.runDir, 'logs', 'server.log'), 'utf8') : '';
  check((slog.match(/Received action username/g) || []).length >= 2, 'both games connected to the local server');

  const st = await runOnce(sb, cfgPath, ['status']);
  check(st.code === 0 && /inst1/.test(st.out) && /arena running/.test(st.out), 'status shows the running arena');
  const dn = await runOnce(sb, cfgPath, ['down']);
  check(dn.code === 0, 'down returns once the arena stopped');
  await Promise.race([h.done, sleep(15000)]);
  check(h.code === 0, `arena exited cleanly (code ${h.code})`);
  const t1 = (readJson(path.join(cfg.runDir, 'status', 'inst1.json')) || {}).t;
  await sleep(1500);
  const t2 = (readJson(path.join(cfg.runDir, 'status', 'inst1.json')) || {}).t;
  check(t1 === t2 && (readJson(path.join(cfg.runDir, 'status', 'inst1.json')) || {}).finished === true, 'games stopped (status frozen, marked finished)');
  check(snapshotTree(sb.realSave) === before, 'your real Balatro save folder was not touched');
  check(snapshotTree(sb.gameDir) === gameBefore, 'the original game install was not touched');
}

async function testSupervision() {
  console.log('test: restart rules (crash, freeze, requested restart) and no-restart rules (fatal)');
  const sb = makeSandbox('sup');
  const modes = { 1: 'crash_once', 2: 'fatal', 3: 'hang_once', 4: 'stall_quit' };
  const per = {};
  for (const [i, m] of Object.entries(modes)) per[i] = { env: { FAKE_MODE: m } };
  const { cfgPath, cfg } = await writeConfig(sb, { pairs: 2, perInstance: per });
  const h = arena(sb, cfgPath, ['up']);
  const runs = (i) => { try { return Number(fs.readFileSync(path.join(cfg.runDir, 'envdump', `runs_${i}`), 'utf8')); } catch { return 0; } };
  const ok = await waitFor(() => runs(1) >= 2 && runs(3) >= 2 && runs(4) >= 2, 40000);
  check(ok, `crashed, frozen and stall-requested instances were restarted (runs: ${[1, 2, 3, 4].map(runs)})`);
  await sleep(2500);
  check(runs(2) === 1, 'fatal instance (exit code 2) was NOT restarted');
  check(/refused to run: fake fatal/.test(h.out), 'fatal reason shown to the user');
  check(/killing it/.test(h.out) || /stopped responding/.test(h.out), 'frozen instance detected by missing heartbeat');
  await runOnce(sb, cfgPath, ['down']);
  await Promise.race([h.done, sleep(15000)]);
  check(h.code === 0, 'arena stopped cleanly after down');
}

async function testFinishAndClose() {
  console.log('test: finished instances end the arena; manually closed windows are not relaunched');
  const sb = makeSandbox('fin');
  const { cfgPath, cfg } = await writeConfig(sb, { perInstance: { 1: { env: { FAKE_MODE: 'finish' } }, 2: { env: { FAKE_MODE: 'close' } } } });
  const h = arena(sb, cfgPath, ['up']);
  await Promise.race([h.done, sleep(30000)]);
  check(h.code === 0, `arena exits on its own when everything is done (code ${h.code})`);
  check(/inst1 finished/.test(h.out), 'finish reported');
  check(/inst2 was closed/.test(h.out), 'closed window not restarted');
  const runs2 = Number(fs.readFileSync(path.join(cfg.runDir, 'envdump', 'runs_2'), 'utf8'));
  check(runs2 === 1, 'closed instance ran exactly once');
}

async function testSafety() {
  console.log('test: refuses to build inside the real save folder or the game install');
  const sb = makeSandbox('safe');
  let { cfgPath } = await writeConfig(sb, { instancesDir: path.join(sb.realSave, 'inst') });
  let r = await runOnce(sb, cfgPath, ['up']);
  check(r.code !== 0 && /refusing|inside/.test(r.out), 'instancesDir inside the real save folder is rejected');
  const d = await runOnce(sb, cfgPath, ['doctor']);
  check(d.code !== 0 && /real Balatro save folder/.test(d.out), 'doctor flags it too');
  ({ cfgPath } = await writeConfig(sb, { instancesDir: path.join(sb.gameDir, 'x') }));
  r = await runOnce(sb, cfgPath, ['up']);
  check(r.code !== 0, 'instancesDir inside the Steam game folder is rejected');
  ({ cfgPath } = await writeConfig(sb, { sourceModsDir: path.join(sb.base, 'nope') }));
  r = await runOnce(sb, cfgPath, ['doctor']);
  check(r.code !== 0 && /Mods folder not found/.test(r.out), 'missing Mods folder is reported');
}

async function testResults() {
  console.log('test: results summary pairs up both players\' rows and computes Elo');
  const sb = makeSandbox('res');
  const { cfgPath, cfg } = await writeConfig(sb);
  const dir = path.join(cfg.runDir, 'results');
  fs.mkdirSync(dir, { recursive: true });
  const row = (inst, name, driver, result, seed, t) => JSON.stringify({ t, inst, pair: 1, name, driver, result, seed, secs: 100, ante: 5 });
  fs.writeFileSync(path.join(dir, 'inst1.jsonl'), [row(1, 'Bot1', 'baseline', 'win', 'S1', 1000), row(1, 'Bot1', 'baseline', 'win', 'S2', 2000), row(1, 'Bot1', 'baseline', 'loss', 'S3', 3000), row(1, 'Bot1', 'baseline', 'aborted', 'S4', 4000)].join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'inst2.jsonl'), [row(2, 'Bot2', 'random', 'loss', 'S1', 1001), row(2, 'Bot2', 'random', 'loss', 'S2', 2001), row(2, 'Bot2', 'random', 'win', 'S3', 3001), row(2, 'Bot2', 'random', 'aborted', 'S4', 4001)].join('\n') + '\n');
  const r = await runOnce(sb, cfgPath, ['results']);
  check(r.code === 0 && /3 finished matches/.test(r.out) && /1 aborted/.test(r.out), 'finished/aborted counts');
  check(/Bot1\s+1\d\d\d/.test(r.out) && /Bot2/.test(r.out) && /elo/.test(r.out), 'Elo table printed');
  const j = await runOnce(sb, cfgPath, ['results', '--json']);
  let parsed = null;
  try { parsed = JSON.parse(j.out); } catch {}
  check(parsed && parsed.elo.Bot1 && parsed.elo.Bot1.rating > parsed.elo.Bot2.rating, 'json output with Bot1 ahead of Bot2');
}

// Run config.load() + planInstances() in a fresh process (config.js reads ARENA_CONFIG at require time).
function planIn(cfgFile, cliOpts = {}) {
  const code = `const c=require(${JSON.stringify(path.join(ROOT, 'lib', 'config'))});const cfg=c.load(JSON.parse(process.env.OPTS||'{}'));` +
    `console.log(JSON.stringify({pairs:cfg.pairs,notes:cfg._notes,pvpTurn:cfg.pvpTurn,turnTimeout:cfg.turnTimeout,reward:cfg.reward,` +
    `insts:c.planInstances(cfg).map(i=>({id:i.id,pair:i.pair,role:i.role,win:i.window,env:i.env}))}))`;
  const r = cp.spawnSync(process.execPath, ['-e', code], { env: { ...process.env, ARENA_CONFIG: cfgFile, OPTS: JSON.stringify(cliOpts) }, encoding: 'utf8' });
  try {
    return JSON.parse(r.stdout);
  } catch {
    return { error: (r.stderr || r.stdout || '').slice(0, 500) };
  }
}

async function testPlanDefaults() {
  console.log('test: default plan = 2 pairs = 4 windows = 2 matches, config migration, flags -> env');
  const sb = makeSandbox('plan');
  // 1) no config file at all
  let p = planIn(path.join(sb.base, 'does-not-exist.json'));
  check(!p.error && p.pairs === 2 && p.insts.length === 4, `no config file -> 2 pairs / 4 instances (${p.error || p.insts.length})`);
  if (!p.error) {
    check(JSON.stringify(p.insts.map((i) => i.pair)) === '[1,1,2,2]', 'pair numbers 1,1,2,2');
    check(JSON.stringify(p.insts.map((i) => i.role)) === '["primary","secondary","primary","secondary"]', 'primary/secondary roles alternate');
    const w = p.insts.map((i) => `${i.win.x},${i.win.y}`);
    check(JSON.stringify(w) === JSON.stringify(['0,0', '640,0', '0,360', '640,360']), `2x2 window grid, one match per row (${w.join(' ')})`);
    check(p.insts.every((i) => i.env.BOTARENA_PVP_TURN === '1' && i.env.BOTARENA_TURN_TIMEOUT === '45'), 'PvP turn order on by default (45s failsafe)');
    check(p.insts.every((i) => i.env.BOTARENA_REWARD === undefined), 'no reward override unless asked for');
  }

  // 2) a file written by the first release (no _schema, pairs: 1) is migrated and says so
  const write = (name, obj) => { const f = path.join(sb.base, name); fs.writeFileSync(f, JSON.stringify(obj)); return f; };
  p = planIn(write('old.json', { pairs: 1, speed: 9 }));
  check(p.pairs === 2 && p.insts.length === 4 && (p.notes || []).some((n) => /pairs=2/.test(n)), 'unversioned pairs:1 file -> 2 pairs + a note explaining why');
  p = planIn(write('keep1.json', { _schema: 2, pairs: 1 }));
  check(p.pairs === 1 && p.insts.length === 2 && (p.notes || []).length === 0, '"_schema": 2 with pairs: 1 is respected (single match)');
  p = planIn(write('old3.json', { pairs: 3 }));
  check(p.pairs === 3 && p.insts.length === 6 && (p.notes || []).length === 0, 'an unversioned file that chose pairs: 3 keeps it');
  if (p.insts) {
    const w = p.insts.map((i) => `${i.win.x},${i.win.y}`);
    check(w[4] === '0,720' && w[5] === '640,720', `third match gets the third row (${w.slice(4).join(' ')})`);
  }
  p = planIn(write('cli.json', { _schema: 2 }), { pairs: '1' });
  check(p.pairs === 1 && p.insts.length === 2, '--pairs 1 on the command line wins');

  // 3) flags / config keys -> environment of each game
  p = planIn(write('flags.json', { _schema: 2, turnTimeout: 20, reward: { money: 2 }, perInstance: { 2: { pvpTurn: false, reward: { fail: 50 } } } }), { noPvpTurn: true, reward: 'tarot=5,spectral=6' });
  if (p.insts) {
    check(p.insts.every((i) => i.env.BOTARENA_PVP_TURN === '0'), '--no-pvp-turn reaches every instance');
    check(p.insts.every((i) => i.env.BOTARENA_TURN_TIMEOUT === '20'), 'turnTimeout from the config file reaches the instances');
    check(p.insts.every((i) => i.env.BOTARENA_PLAN === '1' && i.env.BOTARENA_PLAN_MS === '60'), 'planner enabled with a 60 ms budget by default');
    check(p.insts.every((i) => i.env.BOTARENA_DECIDE_HEURISTIC === '1' && i.env.BOTARENA_DECIDE_EPS === '0' && i.env.BOTARENA_EXTERNAL_HANDS === 'learned' && i.env.BOTARENA_HAND_DECISIONS === '1' && i.env.BOTARENA_HAND_PLANFEAT === '1'), 'decision-layer defaults reach the instances');
    const r1 = p.insts[0].env.BOTARENA_REWARD || '';
    check(/money=2/.test(r1) && /tarot=5/.test(r1) && /spectral=6/.test(r1) && !/fail=/.test(r1), `--reward merges over the file's weights (${r1})`);
    check(/fail=50/.test(p.insts[1].env.BOTARENA_REWARD || ''), 'per-instance reward weights are added for that instance only');
  } else check(false, 'flags plan failed: ' + p.error);
  p = planIn(write('pervp.json', { _schema: 2, perInstance: { 3: { pvpTurn: false } } }));
  check(p.insts && p.insts[2].env.BOTARENA_PVP_TURN === '0' && p.insts[0].env.BOTARENA_PVP_TURN === '1', 'per-instance pvpTurn override');
}

async function testFourInstances() {
  console.log('test: default "up" starts 4 games (2 matches), flags reach the games, status board shows pairs/rewards');
  const sb = makeSandbox('four');
  const per = {};
  for (const i of [1, 2, 3, 4]) per[i] = { env: { FAKE_MODE: 'normal' } };
  per[1].env.FAKE_STATUS = JSON.stringify({ reward: { total: 12.34, blinds: 5 }, waiting: 'ahead' });
  // pairs is deliberately absent: the built-in default (2) must apply
  const { cfgPath, cfg } = await writeConfig(sb, { pairs: undefined, perInstance: per });
  const h = arena(sb, cfgPath, ['up', '--no-pvp-turn', '--reward', 'money=2,tarot=5']);
  const fresh = (i) => { const s = readJson(path.join(cfg.runDir, 'status', `inst${i}.json`)); return s && Date.now() / 1000 - s.t < 3; };
  const up = await waitFor(() => [1, 2, 3, 4].every(fresh), 30000);
  check(up, 'all four instances report heartbeats');
  const env = [1, 2, 3, 4].map((i) => readJson(path.join(cfg.runDir, 'envdump', `inst${i}.json`)));
  if (env.every(Boolean)) {
    check(env.map((e) => e.env.BOTARENA_PAIR).join() === '1,1,2,2', 'two pairs (two simultaneous matches)');
    check(env.map((e) => e.env.BOTARENA_ROLE).join() === 'primary,secondary,primary,secondary', 'each pair has a host and a guest');
    check(new Set(env.map((e) => e.env.BOTARENA_WINDOW)).size === 4, 'four different window slots');
    check(new Set(env.map((e) => e.env.BOTARENA_IDENTITY)).size === 4, 'four separate save identities');
    check(env.every((e) => e.env.BOTARENA_PVP_TURN === '0'), '--no-pvp-turn reached all games');
    check(env.every((e) => /money=2/.test(e.env.BOTARENA_REWARD || '') && /tarot=5/.test(e.env.BOTARENA_REWARD || '')), '--reward weights reached all games');
  } else check(false, 'env dumps missing: ' + env.map(Boolean));
  const slog = fs.existsSync(path.join(cfg.runDir, 'logs', 'server.log')) ? fs.readFileSync(path.join(cfg.runDir, 'logs', 'server.log'), 'utf8') : '';
  check((slog.match(/Received action username/g) || []).length >= 4, 'all four games connected to the local server');
  const st = await runOnce(sb, cfgPath, ['status']);
  const rows = st.out.split('\n').filter((l) => /^inst\d/.test(l.trim()));
  check(rows.length === 4, `status lists 4 instances (${rows.length})`);
  check(/pair/.test(st.out) && /reward/.test(st.out), 'status board has pair and reward columns');
  check(/12\.3 \(5\)/.test(st.out) && /waits: ahead/.test(st.out), 'status board shows the running reward total and "waits" info');
  const dn = await runOnce(sb, cfgPath, ['down']);
  await Promise.race([h.done, sleep(20000)]);
  check(dn.code === 0 && h.code === 0, `clean shutdown of all four (down ${dn.code}, up ${h.code})`);
}

async function testRewardsCli() {
  console.log('test: `rewards` command summarises run/results/rewards<N>.jsonl');
  const sb = makeSandbox('rew');
  const { cfgPath, cfg } = await writeConfig(sb);
  const dir = path.join(cfg.runDir, 'results');
  fs.mkdirSync(dir, { recursive: true });
  let t = 1000;
  const row = (inst, kind, extra) => JSON.stringify({ t: t++, inst, pair: 1, ante: 2, kind, reward: 0, ...extra });
  fs.writeFileSync(path.join(dir, 'rewards1.jsonl'), [
    row(1, 'small', { beaten: true, money: 6, tarots: 1, spectrals: 0, unused_hands: 2, reward: 14.5, parts: { money: 6, hands: 3, tarot: 3 } }),
    row(1, 'big', { beaten: false, money: 0, tarots: 0, spectrals: 0, unused_hands: 0, reward: -40, parts: { fail: -30, fail_shortfall: -10 } }),
    row(1, 'pvp', { outcome: 'win', hopeless: false, money: 2, tarots: 0, spectrals: 1, reward: 31, parts: { pvp_win: 20, spectral: 2 } }),
    '{not json',
  ].join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'rewards2.jsonl'), [
    row(2, 'small', { beaten: true, money: 4, tarots: 0, spectrals: 0, unused_hands: 1, reward: 5.5, parts: { money: 4, hands: 1.5 } }),
    row(2, 'pvp', { outcome: 'loss', hopeless: true, money: 5, tarots: 2, spectrals: 0, reward: 9, parts: { pvp_hopeless_value: 9 } }),
    row(2, 'skip', { blind: 'small', tag: 'tag_investment', reward: -10, parts: { skip: -10 } }),
  ].join('\n') + '\n');
  fs.writeFileSync(path.join(dir, 'inst1.jsonl'), ''); // a results file must not be mistaken for a rewards file
  const r = await runOnce(sb, cfgPath, ['rewards']);
  check(r.code === 0 && /6 scored blinds/.test(r.out), `counts the 6 valid rows, skips the broken line (${r.out.split('\n')[0]})`);
  check(/skip\s+1\s+-10\.00\s+1 blinds skipped/.test(r.out), 'skip rows are summarised on their own line');
  check(/small\s+2\s+/.test(r.out) && /2\/2 beaten/.test(r.out), 'small blinds: 2 beaten of 2');
  check(/big\s+1\s+/.test(r.out) && /0\/1 beaten/.test(r.out), 'big blind failure counted');
  const merged = r.out.match(/pvp\s+2\s+\S+\s+(\d+W \d+L \d+T, \d+ hopeless)/);
  check(merged && merged[1] === '1W 1L 0T, 1 hopeless', `pvp: 1 win, 1 loss, 1 hopeless (${merged && merged[1]})`);
  check(/inst1\s+3\s+5\.5\s+1\.83/.test(r.out) && /inst2\s+3\s+4\.5\s+1\.5/.test(r.out), 'per-instance totals (skip penalty included)');
  const last = await runOnce(sb, cfgPath, ['rewards', '--last', '2']);
  check(/last 2 blinds/.test(last.out) && /hopeless/.test(last.out) && /pvp_hopeless_value/.test(last.out) && /skipped small \(tag_investment\)/.test(last.out), '--last N prints the per-blind parts (and skips with their tag)');
  const j = await runOnce(sb, cfgPath, ['rewards', '--json', '--last', '3']);
  let parsed = null;
  try { parsed = JSON.parse(j.out); } catch {}
  check(Array.isArray(parsed) && parsed.length === 3 && parsed[2].kind === 'skip', '--json returns the last rows as JSON');
  const none = await runOnce(sb, cfgPath, ['rewards', '--since', '0.0001']);
  check(none.code === 0 && /No finished blinds/.test(none.out), 'empty window -> friendly message');
}

async function testTrainCli() {
  console.log('test: `train` hands over to the python trainer with the run folder');
  const sb = makeSandbox('train');
  const cfgPath = path.join(sb.base, 'arena.config.json');
  fs.writeFileSync(cfgPath, JSON.stringify({ _schema: 2, runDir: path.join(sb.base, 'run') }));
  const u = await runOnce(sb, cfgPath, ['train']);
  check(u.code === 1 && /usage: node arena.js train/.test(u.out), 'no sub-command -> usage');
  const e = await runOnce(sb, cfgPath, ['train', 'eval']);
  check(e.code === 0 && /no finished matches/.test(e.out) && /decisions by source/.test(e.out), `train eval runs python -m trainer on the run folder (${e.out.split('\n')[0].slice(0, 60)})`);
}

(async () => {
  const t0 = Date.now();
  for (const t of [testBasic, testPlanDefaults, testFourInstances, testSupervision, testFinishAndClose, testSafety, testResults, testRewardsCli, testTrainCli]) {
    try {
      await t();
    } catch (e) {
      failures++;
      console.log(`  FAIL ${t.name} crashed: ${e.stack || e}`);
    }
  }
  console.log(`\n${failures} failure(s) in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
  process.exit(failures ? 1 : 0);
})();
