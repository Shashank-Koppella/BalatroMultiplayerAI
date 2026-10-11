'use strict';
// Configuration: defaults <- arena.config.json <- command-line flags. Paths may use %APPDATA%, $VARS and ~.
const { path, os, fs, isWin, expand, exists, isDir, isFile, readJson, readText, fwd } = require('./util');
const cp = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const CONFIG_PATH = process.env.ARENA_CONFIG ? path.resolve(process.env.ARENA_CONFIG) : path.join(ROOT, 'arena.config.json');

function appDataDir() {
  if (process.env.APPDATA) return process.env.APPDATA;
  if (process.platform === 'darwin') return path.join(os.homedir(), 'Library', 'Application Support');
  return process.env.XDG_DATA_HOME || path.join(os.homedir(), '.local', 'share');
}

// ---- Steam / game folder detection ------------------------------------------------------------------
function steamLibraries() {
  const libs = [];
  const roots = [];
  if (isWin) {
    try {
      const out = cp.execSync('reg query "HKCU\\Software\\Valve\\Steam" /v SteamPath', { stdio: ['ignore', 'pipe', 'ignore'] }).toString();
      const m = out.match(/SteamPath\s+REG_SZ\s+(.+)/);
      if (m) roots.push(m[1].trim());
    } catch {
      /* not installed / no reg */
    }
    roots.push('C:\\Program Files (x86)\\Steam', 'C:\\Program Files\\Steam');
  } else {
    roots.push(path.join(os.homedir(), '.steam', 'steam'), path.join(os.homedir(), '.local', 'share', 'Steam'));
  }
  for (const r of roots) {
    if (!isDir(r)) continue;
    libs.push(r);
    const vdf = readText(path.join(r, 'steamapps', 'libraryfolders.vdf'));
    if (vdf) {
      for (const m of vdf.matchAll(/"path"\s+"([^"]+)"/g)) libs.push(m[1].replace(/\\\\/g, '\\'));
    }
  }
  return [...new Set(libs)];
}

function detectGameDir() {
  for (const lib of steamLibraries()) {
    const d = path.join(lib, 'steamapps', 'common', 'Balatro');
    if (isDir(d)) return d;
  }
  return null;
}

// ---- defaults ---------------------------------------------------------------------------------------
function defaults() {
  const appData = appDataDir();
  return {
    // --- where things are
    gameDir: detectGameDir() || (isWin ? 'C:\\Program Files (x86)\\Steam\\steamapps\\common\\Balatro' : ''),
    exeName: isWin ? 'Balatro.exe' : 'Balatro',
    appData,
    sourceModsDir: path.join(appData, 'Balatro', 'Mods'), // your normal Mods folder (Steamodded + Multiplayer are copied from here)
    sourceProfileDir: path.join(appData, 'Balatro'), // used once to seed each instance's profile (unlocks, settings)
    instancesDir: path.join(ROOT, 'instances'), // full game copies live here (~one Balatro install each)
    extraMods: [], // names of additional folders inside sourceModsDir to copy into every instance

    // --- what to run
    _schema: 2, // config file format; files without it come from the first release (see load())
    pairs: 2, // pair = two instances that play each other. 2 pairs = 4 game windows = 2 matches at once.
    ruleset: 'standard_ranked', // standard_ranked | blitz | legacy_ranked | vanilla | ... (see Multiplayer/rulesets)
    gamemode: 'attrition',
    lobbyOptions: '', // "key=value,key=value" extra lobby options, e.g. "starting_lives=3"
    driver: 'baseline', // baseline | random | external | path\to\your_driver.lua
    pvpTurn: true, // PvP blinds: after both players have played a hand, the one with the LOWER score plays next (leader waits)
    plan: true, // baseline bot: joker-aware hand planner with draw odds from the remaining deck (lib/plan.lua)
    planMs: 60, // thinking budget per hand decision, real milliseconds
    decideHeuristic: true, // baseline bot: shop / pack / blind-select choices from the value model in lib/decide.lua (false = the old simple rules)
    decideSkips: true, // baseline value model skips blinds by the strategy rules (ante-1 Investment / Rare tag, lined-up jokers); false = never skip
    decideEps: 0, // baseline: chance (0..1) of a random strategic choice per decision - set ~0.15 to collect varied training data
    externalHands: 'learned', // external driver: 'learned' = hand candidates go to the trainer's hand model (lib/handdec.lua), 'planner' = built-in planner plays the hands, 'agent' = raw bridge (your program picks card indices)
    handDecisions: true, // baseline bot: log every hand decision (candidate plays / discards + the planner's pick) for the trainer
    handEps: 0, // baseline: chance of a random hand candidate instead of the planner's pick (data diversity, costs score) - keep 0 unless you want it
    handMaxOpts: 44, // candidates offered per hand decision
    handPlanFeat: true, // offer the planner's Monte-Carlo verdict as candidate features; false = pure learning from game mechanics only
    randomLoadout: true, // every lobby plays a random vanilla deck on a random stake (lib/rules.lua); false = whatever lobbyOptions / the lobby says (Red Deck, White Stake)
    loadoutDecks: '', // limit the random decks, e.g. 'plasma,ghost' (short names); '' = all 15 vanilla decks
    loadoutStakes: '', // limit the random stakes, e.g. 'gold,spectralplus'; '' = white, green, black, purple, gold, spectralplus
    jokerOrder: true, // re-order the joker row automatically (+mult left of x-mult, Brainstorm / Blueprint placement, Dagger rightmost); lib/order.lua
    turnTimeout: 45, // real seconds a waiting bot sits idle before it plays anyway (deadlock failsafe)
    reward: {}, // reward weights, e.g. { "money": 1, "tarot": 3, "fail": 30 } - see README "Rewards"
    matches: 0, // matches per instance before it exits; 0 = endless
    seedBase: 0, // 0 = per-instance default; otherwise instance seed = seedBase + id
    names: {}, // { "1": "Alice" } display names; default Bot<id>

    // --- speed / looks
    speed: 16, // game speed multiplier (G.SETTINGS.GAMESPEED)
    boost: 4, // extra animation passes per frame on top of that
    fpsCap: 0,
    drawEvery: 1, // 1 = draw every frame. 2-4 skips frames (experimental, saves GPU)
    mute: true,
    vsyncOff: true,
    window: { width: 640, height: 360, screenWidth: 1920, screenHeight: 1080, x0: 0, y0: 0 },
    hideConsole: true, // pass --disable-console to Lovely so each instance doesn't open a console window

    // --- server
    server: { spawn: true, host: '127.0.0.1', port: 18788, adminPort: 18789 },

    // --- supervision
    staggerSec: 6, // delay between starting instances
    matchTimeout: 3600, // seconds before the arena aborts a match (e.g. endless ties)
    stallTimeout: 240, // seconds without game progress before in-game recovery kicks in
    hangSec: 120, // seconds without a status heartbeat before the launcher kills a frozen process
    startGraceSec: 300, // heartbeat grace period after process start (first boot is slow)
    restart: { max: 12, windowSec: 900, backoffSec: 5 },
    steamAppId: false, // true = write steam_appid.txt into the copies (usually NOT needed, see README)
    seedProfile: true,

    // --- advanced
    perInstance: {}, // { "2": { "driver": "random", "speed": 8, "env": { "BOTARENA_SKIP_RATE": "0.3" } } }
    extraEnv: {},
    runDir: path.join(ROOT, 'run'),
  };
}

function deepMerge(base, over) {
  if (over == null || typeof over !== 'object' || Array.isArray(over)) return over === undefined ? base : over;
  const out = Array.isArray(base) ? [...base] : { ...base };
  for (const [k, v] of Object.entries(over)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && base && typeof base[k] === 'object' && !Array.isArray(base[k])) out[k] = deepMerge(base[k], v);
    else out[k] = v;
  }
  return out;
}

const PATH_KEYS = ['gameDir', 'appData', 'sourceModsDir', 'sourceProfileDir', 'instancesDir', 'runDir'];

function load(cliOpts = {}) {
  let cfg = defaults();
  const file = readJson(CONFIG_PATH, null);
  const hadFile = !!file;
  const notes = [];
  if (file && file._schema == null && file.pairs === 1) {
    // `setup` of the first release froze every default into the file, including pairs: 1. The default is now
    // 2 pairs (4 windows, 2 simultaneous matches); an unversioned file's pairs: 1 is that old default, not a choice.
    delete file.pairs;
    notes.push('arena.config.json predates the 2-match default: using pairs=2 (add "_schema": 2 and "pairs": 1 to keep a single match)');
  }
  if (file) cfg = deepMerge(cfg, file);
  // a custom appData in the file should also move the defaults that were derived from it
  if (file && file.appData) {
    if (!file.sourceModsDir) cfg.sourceModsDir = path.join(file.appData, 'Balatro', 'Mods');
    if (!file.sourceProfileDir) cfg.sourceProfileDir = path.join(file.appData, 'Balatro');
  }
  const map = {
    pairs: Number, speed: Number, boost: Number, matches: Number, matchTimeout: Number, stallTimeout: Number,
    ruleset: String, gamemode: String, driver: String, gameDir: String, exeName: String, instancesDir: String,
    sourceModsDir: String, lobbyOptions: String, fpsCap: Number, drawEvery: Number, staggerSec: Number,
  };
  for (const [k, conv] of Object.entries(map)) if (cliOpts[k] !== undefined && cliOpts[k] !== true) cfg[k] = conv(cliOpts[k]);
  if (cliOpts.port) cfg.server.port = Number(cliOpts.port);
  if (cliOpts.adminPort) cfg.server.adminPort = Number(cliOpts.adminPort);
  if (cliOpts.noServer) cfg.server.spawn = false;
  if (cliOpts.noPvpTurn) cfg.pvpTurn = false;
  if (cliOpts.reward && cliOpts.reward !== true) {
    for (const kv of String(cliOpts.reward).split(/[,;]/)) {
      const m = /^\s*([\w.]+)\s*=\s*(-?[\d.]+)\s*$/.exec(kv);
      if (m) cfg.reward = { ...(cfg.reward || {}), [m[1]]: Number(m[2]) };
    }
  }
  if (cliOpts.visible) cfg.hideConsole = false;
  if (cliOpts.unmute) cfg.mute = false;
  for (const k of PATH_KEYS) cfg[k] = path.resolve(expand(cfg[k] || ''));
  if (!cfg.gameDir || cfg.gameDir === path.resolve('')) cfg.gameDir = '';
  cfg.pairs = Math.max(1, Math.floor(cfg.pairs || 1));
  cfg._hadFile = hadFile;
  cfg._notes = notes;
  cfg._root = ROOT;
  cfg._configPath = CONFIG_PATH;
  return cfg;
}

// ---- instances --------------------------------------------------------------------------------------
const identityOf = (id) => `BalatroArena_${id}`;

function windowFor(cfg, index, total) {
  const w = cfg.window;
  const cols = Math.max(1, Math.floor(w.screenWidth / w.width));
  const rows = Math.max(1, Math.floor(w.screenHeight / w.height));
  if (cols >= 2) {
    // the two players of a pair sit side by side on one row, so each ROW of windows is one match;
    // when the rows are used up the next pair starts a new block of columns (wrapping if the screen is full)
    const pair = Math.floor(index / 2);
    const side = index % 2;
    const row = pair % rows;
    const block = Math.floor(pair / rows);
    const col = (block * 2 + side) % cols;
    return { x: w.x0 + col * w.width, y: w.y0 + row * w.height, w: w.width, h: w.height };
  }
  const slot = index % (cols * rows);
  return { x: w.x0 + (slot % cols) * w.width, y: w.y0 + Math.floor(slot / cols) * w.height, w: w.width, h: w.height };
}

function planInstances(cfg) {
  const out = [];
  const total = cfg.pairs * 2;
  const ext = path.extname(cfg.exeName);
  for (let id = 1; id <= total; id++) {
    const per = cfg.perInstance[String(id)] || {};
    const identity = identityOf(id);
    const dir = path.join(cfg.instancesDir, `inst${id}`);
    const gameRoot = path.join(dir, 'game');
    const win = windowFor(cfg, id - 1, total);
    const inst = {
      id,
      pair: Math.ceil(id / 2),
      role: id % 2 === 1 ? 'primary' : 'secondary',
      name: per.name || cfg.names[String(id)] || `Bot${id}`,
      driver: per.driver || cfg.driver,
      speed: per.speed ?? cfg.speed,
      identity,
      dir,
      gameRoot,
      exe: path.join(gameRoot, identity + ext),
      saveDir: path.join(cfg.appData, identity),
      modsDir: path.join(cfg.appData, identity, 'Mods'),
      window: win,
      perEnv: per.env || {},
      perOpts: per,
    };
    inst.env = instanceEnv(cfg, inst);
    out.push(inst);
  }
  return out;
}

function instanceEnv(cfg, inst) {
  const per = inst.perOpts;
  const e = {
    LOVELY_MOD_DIR: inst.modsDir,
    BOTARENA_ID: String(inst.id),
    BOTARENA_PAIR: String(inst.pair),
    BOTARENA_ROLE: inst.role,
    BOTARENA_NAME: inst.name,
    BOTARENA_IDENTITY: inst.identity,
    BOTARENA_SHARED: fwd(cfg.runDir),
    BOTARENA_RULESET: cfg.ruleset,
    BOTARENA_GAMEMODE: cfg.gamemode,
    BOTARENA_LOBBY_OPTS: cfg.lobbyOptions || '',
    BOTARENA_MATCHES: String(per.matches ?? cfg.matches),
    BOTARENA_SPEED: String(inst.speed),
    BOTARENA_BOOST: String(per.boost ?? cfg.boost),
    BOTARENA_FPS_CAP: String(cfg.fpsCap),
    BOTARENA_DRAW_EVERY: String(cfg.drawEvery),
    BOTARENA_MUTE: cfg.mute ? '1' : '0',
    BOTARENA_VSYNC_OFF: cfg.vsyncOff ? '1' : '0',
    BOTARENA_WINDOW: `${inst.window.x},${inst.window.y},${inst.window.w},${inst.window.h}`,
    BOTARENA_DRIVER: /[\\/]/.test(inst.driver) ? fwd(path.resolve(expand(inst.driver))) : inst.driver,
    BOTARENA_MATCH_TIMEOUT: String(cfg.matchTimeout),
    BOTARENA_STALL_TIMEOUT: String(cfg.stallTimeout),
    BOTARENA_REQUIRE_ISOLATION: '1',
    BOTARENA_PVP_TURN: (per.pvpTurn ?? cfg.pvpTurn) ? '1' : '0',
    BOTARENA_TURN_TIMEOUT: String(per.turnTimeout ?? cfg.turnTimeout),
    BOTARENA_PLAN: (per.plan ?? cfg.plan) ? '1' : '0',
    BOTARENA_PLAN_MS: String(per.planMs ?? cfg.planMs),
    BOTARENA_DECIDE_HEURISTIC: (per.decideHeuristic ?? cfg.decideHeuristic) ? '1' : '0',
    BOTARENA_DECIDE_SKIPS: (per.decideSkips ?? cfg.decideSkips) ? '1' : '0',
    BOTARENA_DECIDE_EPS: String(per.decideEps ?? cfg.decideEps),
    BOTARENA_EXTERNAL_HANDS: String(per.externalHands ?? cfg.externalHands),
    BOTARENA_HAND_DECISIONS: (per.handDecisions ?? cfg.handDecisions) ? '1' : '0',
    BOTARENA_HAND_EPS: String(per.handEps ?? cfg.handEps),
    BOTARENA_HAND_MAX_OPTS: String(per.handMaxOpts ?? cfg.handMaxOpts),
    BOTARENA_HAND_PLANFEAT: (per.handPlanFeat ?? cfg.handPlanFeat) ? '1' : '0',
    BOTARENA_RANDOM_LOADOUT: (per.randomLoadout ?? cfg.randomLoadout) ? '1' : '0',
    BOTARENA_DECKS: String(per.loadoutDecks ?? cfg.loadoutDecks ?? ''),
    BOTARENA_STAKES: String(per.loadoutStakes ?? cfg.loadoutStakes ?? ''),
    BOTARENA_JOKER_ORDER: (per.jokerOrder ?? cfg.jokerOrder) ? '1' : '0',
  };
  const weights = { ...(cfg.reward || {}), ...(per.reward || {}) };
  if (Object.keys(weights).length) e.BOTARENA_REWARD = Object.entries(weights).map(([k, v]) => `${k}=${v}`).join(',');
  if (cfg.seedBase) e.BOTARENA_SEED = String(cfg.seedBase + inst.id);
  Object.assign(e, cfg.extraEnv || {}, inst.perEnv || {});
  for (const k of Object.keys(e)) e[k] = String(e[k]);
  return e;
}

module.exports = { ROOT, CONFIG_PATH, load, defaults, planInstances, identityOf, detectGameDir, appDataDir, steamLibraries };
