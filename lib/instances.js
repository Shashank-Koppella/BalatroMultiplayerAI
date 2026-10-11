'use strict';
// Builds the private, isolated folders each arena instance runs from:
//
//   <instancesDir>/inst<N>/game/        full copy of the Balatro install, exe renamed to BalatroArena_<N>(.exe)
//   %APPDATA%/BalatroArena_<N>/         that copy's own LOVE save folder (profile, settings, saves)
//   %APPDATA%/BalatroArena_<N>/Mods/    ONLY smods + Multiplayer + BotArena (copied from your normal Mods folder)
//
// Nothing here ever writes into your normal %APPDATA%/Balatro folder or into the Steam install.
const { path, fs, isDir, isFile, mkdirp, readJson, readText, syncDir, exists, rmrf, log } = require('./util');
const config = require('./config');

const MP_ENV_KEYS = ['server_url', 'server_port', 'suppress_dev_warning'];

function listDirs(p) {
  try {
    return fs.readdirSync(p, { withFileTypes: true }).filter((e) => e.isDirectory()).map((e) => e.name);
  } catch {
    return [];
  }
}

function cmpVersion(a, b) {
  const pa = String(a || '0').split(/[.\-~]/).map((x) => parseInt(x, 10) || 0);
  const pb = String(b || '0').split(/[.\-~]/).map((x) => parseInt(x, 10) || 0);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const d = (pa[i] || 0) - (pb[i] || 0);
    if (d) return d;
  }
  return 0;
}

// Locate Steamodded and the Multiplayer mod inside the user's normal Mods folder.
function inspectSource(cfg) {
  const root = cfg.sourceModsDir;
  const res = { root, smods: null, multiplayer: null, multiplayerVersion: null, extras: [], problems: [], notes: [] };
  if (!isDir(root)) {
    res.problems.push(`Mods folder not found: ${root}`);
    return res;
  }
  const dirs = listDirs(root);
  const smodsCandidates = dirs.filter((d) => /^(smods|steamodded)/i.test(d) && (isDir(path.join(root, d, 'src')) || isFile(path.join(root, d, 'version.lua'))));
  if (smodsCandidates.length) res.smods = path.join(root, smodsCandidates[0]);
  else res.problems.push('Steamodded (folder "smods") not found in the Mods folder');
  if (smodsCandidates.length > 1) res.notes.push(`multiple Steamodded folders (${smodsCandidates.join(', ')}); using ${smodsCandidates[0]}`);

  const mp = [];
  for (const d of dirs) {
    const dir = path.join(root, d);
    const man = readJson(path.join(dir, 'Multiplayer.json'), null);
    if (man && String(man.id) === 'Multiplayer') mp.push({ dir, version: man.version || '0' });
  }
  mp.sort((a, b) => cmpVersion(b.version, a.version));
  if (mp.length) {
    res.multiplayer = mp[0].dir;
    res.multiplayerVersion = mp[0].version;
    if (mp.length > 1) res.notes.push(`multiple Multiplayer folders (${mp.map((m) => path.basename(m.dir) + '@' + m.version).join(', ')}); using the newest`);
  } else res.problems.push('Multiplayer mod (Multiplayer.json with id "Multiplayer") not found in the Mods folder');

  for (const name of cfg.extraMods || []) {
    const d = path.join(root, name);
    if (isDir(d)) res.extras.push(d);
    else res.problems.push(`extraMods entry "${name}" not found in the Mods folder`);
  }
  return res;
}

function inspectGame(cfg) {
  const res = { problems: [], notes: [] };
  if (!cfg.gameDir || !isDir(cfg.gameDir)) {
    res.problems.push(`Balatro folder not found: ${cfg.gameDir || '(not set)'} - set "gameDir" in arena.config.json`);
    return res;
  }
  if (!isFile(path.join(cfg.gameDir, cfg.exeName))) res.problems.push(`${cfg.exeName} not found in ${cfg.gameDir}`);
  const lovelyDll = ['version.dll', 'liblovely.so', 'liblovely.dylib'].find((f) => isFile(path.join(cfg.gameDir, f)));
  if (!lovelyDll && process.platform === 'win32') res.problems.push('version.dll (Lovely) not found next to the exe - install Lovely into the game folder first');
  else if (!lovelyDll) res.notes.push('no Lovely library next to the exe (ok for a fake/test game folder)');
  res.exe = path.join(cfg.gameDir, cfg.exeName);
  return res;
}

function writeMpEnv(modDir, cfg) {
  const lines = [
    '# written by arena.js - points this copy of Multiplayer at the local arena server',
    `server_url=${cfg.server.host === '0.0.0.0' ? '127.0.0.1' : cfg.server.host}`,
    `server_port=${cfg.server.port}`,
    'suppress_dev_warning=true',
    '',
  ];
  fs.writeFileSync(path.join(modDir, '.env'), lines.join('\n'));
}

// Copy (or refresh) one instance. Returns a list of human-readable notes.
function buildInstance(cfg, inst, { rebuild = false, source, quiet = false } = {}) {
  const notes = [];
  const say = (m) => {
    notes.push(m);
    if (!quiet) log.info(`  inst${inst.id}: ${m}`);
  };

  // hard safety: never operate inside the real Balatro save folder or the Steam install
  const realSave = path.join(cfg.appData, 'Balatro');
  for (const p of [inst.saveDir, inst.modsDir, inst.gameRoot]) {
    const rp = path.resolve(p).toLowerCase();
    if (rp === path.resolve(realSave).toLowerCase() || rp.startsWith(path.resolve(realSave).toLowerCase() + path.sep) ||
        (cfg.gameDir && (rp === path.resolve(cfg.gameDir).toLowerCase() || rp.startsWith(path.resolve(cfg.gameDir).toLowerCase() + path.sep)))) {
      throw new Error(`refusing to build instance ${inst.id} inside ${realSave} or the game install (${p})`);
    }
  }

  // 1) game copy with renamed exe
  if (rebuild && isDir(inst.gameRoot)) rmrf(inst.gameRoot);
  const exeSrc = path.join(cfg.gameDir, cfg.exeName);
  const stampPath = path.join(inst.dir, 'build.json');
  const st = fs.statSync(exeSrc);
  const stamp = { exeSize: st.size, exeMtime: Math.round(st.mtimeMs), identity: inst.identity };
  const old = readJson(stampPath, null);
  const stale = !old || old.exeSize !== stamp.exeSize || old.exeMtime !== stamp.exeMtime || old.identity !== stamp.identity || !isFile(inst.exe);
  mkdirp(inst.gameRoot);
  const r = syncDir(cfg.gameDir, inst.gameRoot, {
    skip: (name, full, ent) => name === cfg.exeName || /^Mods$/i.test(name) || name === 'steam_appid.txt',
  });
  if (stale) {
    fs.copyFileSync(exeSrc, inst.exe);
    try {
      fs.chmodSync(inst.exe, 0o755);
    } catch {
      /* windows */
    }
    fs.writeFileSync(stampPath, JSON.stringify(stamp));
    say(`game copy ready (${r.copied + 1} files copied, exe -> ${path.basename(inst.exe)})`);
  } else if (r.copied) say(`game copy refreshed (${r.copied} files)`);
  if (cfg.steamAppId) fs.writeFileSync(path.join(inst.gameRoot, 'steam_appid.txt'), '2379780');
  else if (isFile(path.join(inst.gameRoot, 'steam_appid.txt'))) fs.rmSync(path.join(inst.gameRoot, 'steam_appid.txt'));

  // 2) mods: only what an arena instance needs
  mkdirp(inst.modsDir);
  const src = source || inspectSource(cfg);
  if (src.problems.length) throw new Error(src.problems.join('; '));
  syncDir(src.smods, path.join(inst.modsDir, path.basename(src.smods)), { mirror: true });
  const mpDst = path.join(inst.modsDir, path.basename(src.multiplayer));
  syncDir(src.multiplayer, mpDst, { mirror: true, skip: (n) => n === '.git' || n === '.github' || n === 'tests' || n === '.env' });
  writeMpEnv(mpDst, cfg);
  for (const d of src.extras) syncDir(d, path.join(inst.modsDir, path.basename(d)), { mirror: true });
  syncDir(path.join(config.ROOT, 'mod', 'BotArena'), path.join(inst.modsDir, 'BotArena'), { mirror: true });
  // drop anything else that might have been put here by hand (e.g. old copies) so the instance stays minimal
  const wanted = new Set([path.basename(src.smods), path.basename(src.multiplayer), 'BotArena', 'lovely', ...src.extras.map((d) => path.basename(d))]);
  for (const d of listDirs(inst.modsDir)) {
    if (!wanted.has(d) && !d.startsWith('.')) {
      rmrf(path.join(inst.modsDir, d));
      say(`removed stray mod folder ${d}`);
    }
  }

  // 3) profile seed (first run only): same unlocks/settings as your real profile, but a private copy
  const settingsDst = path.join(inst.saveDir, 'settings.jkr');
  if (cfg.seedProfile && !isFile(settingsDst)) {
    const sp = cfg.sourceProfileDir;
    let n = 0;
    for (const rel of ['settings.jkr', path.join('1', 'profile.jkr'), path.join('1', 'meta.jkr')]) {
      const s = path.join(sp, rel);
      if (isFile(s)) {
        mkdirp(path.dirname(path.join(inst.saveDir, rel)));
        fs.copyFileSync(s, path.join(inst.saveDir, rel));
        n++;
      }
    }
    say(n ? `profile seeded from your Balatro profile (${n} files)` : 'no source profile found; the instance starts with a fresh profile');
  }
  return notes;
}

function buildAll(cfg, insts, opts = {}) {
  const source = inspectSource(cfg);
  if (source.problems.length) throw new Error(source.problems.join('\n'));
  for (const n of source.notes) log.info(n);
  const game = inspectGame(cfg);
  if (game.problems.length) throw new Error(game.problems.join('\n'));
  for (const inst of insts) {
    mkdirp(inst.dir);
    buildInstance(cfg, inst, { ...opts, source });
  }
}

module.exports = { inspectSource, inspectGame, buildInstance, buildAll, writeMpEnv, MP_ENV_KEYS };
