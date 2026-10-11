'use strict';
// `node arena.js doctor` - checks that everything the arena needs is where it should be, before you launch anything.
const { path, fs, os, isDir, isFile, exists, portFree, c } = require('./util');
const config = require('./config');
const { inspectSource, inspectGame } = require('./instances');
const { BUNDLE } = require('./server');

function dirSize(p, limit = 2e9) {
  let total = 0;
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const f = path.join(d, e.name);
      if (e.isDirectory()) walk(f);
      else if (e.isFile()) total += fs.statSync(f).size;
      if (total > limit) return;
    }
  };
  try {
    walk(p);
  } catch {
    /* ignore */
  }
  return total;
}

async function run(cfg) {
  const checks = [];
  const add = (level, msg, hint) => checks.push({ level, msg, hint });

  const major = Number(process.versions.node.split('.')[0]);
  if (major >= 18) add('ok', `Node ${process.versions.node}`);
  else add('fail', `Node ${process.versions.node} is too old`, 'install Node 18 or newer (the bundled server needs it)');

  // game install
  const game = inspectGame(cfg);
  if (game.problems.length) for (const p of game.problems) add('fail', p);
  else {
    add('ok', `Balatro install: ${cfg.gameDir}`);
    for (const n of game.notes) add('warn', n);
  }

  // mods
  const src = inspectSource(cfg);
  if (src.problems.length) for (const p of src.problems) add('fail', p, `looked in ${cfg.sourceModsDir} (set "sourceModsDir" in arena.config.json if your Mods folder is elsewhere)`);
  else {
    add('ok', `Steamodded: ${src.smods}`);
    add('ok', `Multiplayer ${src.multiplayerVersion}: ${src.multiplayer}`);
    if (!/^0\.5\./.test(String(src.multiplayerVersion))) add('warn', `Multiplayer ${src.multiplayerVersion} - BotArena was written against 0.5.5; newer versions may change internals`);
  }
  for (const n of src.notes) add('warn', n);

  // our own files
  if (isFile(path.join(config.ROOT, 'mod', 'BotArena', 'BotArena.json'))) add('ok', 'BotArena mod files present');
  else add('fail', 'mod/BotArena/BotArena.json missing - the arena folder is incomplete');
  if (isFile(BUNDLE)) add('ok', 'local relay server bundle present');
  else add('fail', 'server/arena-server.mjs missing - the arena folder is incomplete');

  // placement
  const inside = (child, parent) => {
    if (!child || !parent) return false;
    const a = path.resolve(child).toLowerCase();
    const b = path.resolve(parent).toLowerCase();
    return a === b || a.startsWith(b + path.sep);
  };
  if (inside(cfg.instancesDir, cfg.gameDir) || inside(config.ROOT, cfg.gameDir)) add('fail', 'the arena folder is inside the Steam Balatro folder', 'move BalatroArena somewhere else (e.g. Documents)');
  if (inside(cfg.instancesDir, path.join(cfg.appData, 'Balatro'))) add('fail', 'instancesDir is inside your real Balatro save folder');
  add('ok', `instances will be built in ${cfg.instancesDir}`);

  // disk
  if (game.exe && isDir(cfg.gameDir)) {
    const gameBytes = dirSize(cfg.gameDir);
    const need = gameBytes * cfg.pairs * 2;
    let free = null;
    try {
      const s = fs.statfsSync(cfg.instancesDir && exists(cfg.instancesDir) ? cfg.instancesDir : path.dirname(cfg.instancesDir));
      free = s.bavail * s.bsize;
    } catch {
      /* statfs unavailable */
    }
    const mb = (n) => `${Math.round(n / 1048576)} MB`;
    if (free != null && free < need + 1e9) add('fail', `not enough free disk: need about ${mb(need)} for ${cfg.pairs * 2} game copies, ${mb(free)} free`);
    else add('ok', `disk: ${cfg.pairs * 2} game copies need about ${mb(need)}${free != null ? ` (${mb(free)} free)` : ''}`);
  }

  // ports
  for (const [label, port] of [['game server', cfg.server.port], ['admin', cfg.server.adminPort]]) {
    if (!cfg.server.spawn && label === 'admin') continue;
    const free = await portFree(port, cfg.server.host);
    if (free) add('ok', `${label} port ${port} is free`);
    else add(cfg.server.spawn ? 'fail' : 'ok', `${label} port ${port} is in use`, cfg.server.spawn ? 'is another arena already running? (node arena.js down) or choose another port with --port' : 'expected, you disabled the local server');
  }

  // profile
  if (cfg.seedProfile) {
    if (isFile(path.join(cfg.sourceProfileDir, 'settings.jkr'))) add('ok', 'your Balatro profile will be copied once into each instance (unlocks + settings)');
    else add('warn', `no Balatro profile at ${cfg.sourceProfileDir}; instances start with a fresh profile (first-run overlays/locked content)`);
  }

  // load estimate
  const cores = os.cpus().length;
  if (cfg.pairs * 2 > Math.max(2, cores - 2)) add('warn', `${cfg.pairs * 2} instances on ${cores} CPU threads: each Balatro at high speed uses about one core - expect slower matches`);

  if (!cfg._hadFile) add('warn', 'no arena.config.json yet (using auto-detected defaults)', 'run `node arena.js setup` to write one you can edit');

  let bad = 0;
  for (const k of checks) {
    const tag = k.level === 'ok' ? c.green(' ok ') : k.level === 'warn' ? c.yellow('warn') : c.red('FAIL');
    console.log(`[${tag}] ${k.msg}`);
    if (k.hint && k.level !== 'ok') console.log(`       ${c.dim(k.hint)}`);
    if (k.level === 'fail') bad++;
  }
  console.log(bad ? c.red(`\n${bad} problem(s) to fix first.`) : c.green('\nLooks good. Next: node arena.js selftest, then node arena.js up'));
  return bad === 0;
}

module.exports = { run };
