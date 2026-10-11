#!/usr/bin/env node
'use strict';
// BalatroArena launcher - runs several isolated Balatro instances that play Multiplayer matches against
// each other through a local relay server. See README.md.
const { path, fs, isDir, isFile, readText, readJson, writeJson, mkdirp, rmrf, log, c, sleep, parseArgs, table, exists } = require('./lib/util');
const config = require('./lib/config');

const HELP = `
BalatroArena - local Balatro Multiplayer simulator

  node arena.js doctor             check your install (game folder, Lovely, Steamodded, Multiplayer, ports, disk)
  node arena.js setup              write arena.config.json with auto-detected paths, then run doctor
  node arena.js selftest           test the bundled local server with two scripted clients (no game needed)
  node arena.js up [options]       build the instances, start the server and every game, keep them playing
  node arena.js down               ask a running arena to shut down cleanly
  node arena.js status             show what every instance is doing right now
  node arena.js results [--json]   win/loss table, matches per hour, Elo between the instances
  node arena.js rewards [--json] [--last N]   per-blind reward audit (what each blind paid and why)
  node arena.js train <cmd> [...]  trainer (needs Python + numpy): bc | live | agent | eval | inspect - see README "Trainer"
  node arena.js logs [what]        tail logs: server | inst1 | inst1 proc | inst1 lovely  (default: server)
  node arena.js build [--rebuild]  only (re)build the instance folders
  node arena.js clean --yes        delete the instance copies and the run folder

options for up:
  --pairs N         pairs of instances (default 2 = 4 windows, 2 matches at once)   --speed X   game speed (default 16)
  --driver D        baseline | random | external | file.lua --matches N   stop each instance after N matches
  --ruleset R       standard_ranked | blitz | vanilla ...   --for MIN     stop the whole arena after MIN minutes
  --fresh           wipe old results/logs first             --rebuild     recreate the game copies
  --no-build        skip refreshing the instance folders    --visible     show Lovely's console windows
  --no-server       use an already-running server           --port N      relay server port
  --no-pvp-turn     let both bots play whenever they like in PvP (default: the player behind plays next)
  --reward k=v,...  override reward weights, e.g. --reward money=2,tarot=5,fail=40
`;

function lines(text, n) {
  const all = (text || '').split(/\r?\n/);
  return all.slice(-n).join('\n');
}

async function main() {
  const args = parseArgs(process.argv.slice(2), ['rebuild', 'fresh', 'noBuild', 'noServer', 'noPvpTurn', 'visible', 'json', 'yes', 'force', 'unmute', 'verbose']);
  const cmd = args._[0] || 'help';
  const cfg = config.load(args);

  switch (cmd) {
    case 'help':
    case '--help':
    case '-h':
      console.log(HELP);
      return 0;

    case 'doctor': {
      const ok = await require('./lib/doctor').run(cfg);
      return ok ? 0 : 1;
    }

    case 'setup': {
      if (isFile(config.CONFIG_PATH) && !args.force) {
        console.log(`${config.CONFIG_PATH} already exists (use --force to overwrite).`);
      } else {
        const d = config.defaults();
        const out = { ...d, gameDir: cfg.gameDir || d.gameDir };
        delete out.runDir;
        writeJson(config.CONFIG_PATH, out);
        console.log(`wrote ${config.CONFIG_PATH}`);
      }
      const ok = await require('./lib/doctor').run(config.load(args));
      return ok ? 0 : 1;
    }

    case 'selftest': {
      const ok = await require('./lib/selftest').run({ verbose: !!args.verbose });
      return ok ? 0 : 1;
    }

    case 'build': {
      const insts = config.planInstances(cfg);
      log.info(`building ${insts.length} instance(s) in ${cfg.instancesDir}`);
      require('./lib/instances').buildAll(cfg, insts, { rebuild: !!args.rebuild });
      log.ok('instances ready');
      return 0;
    }

    case 'up': {
      const { buildAll } = require('./lib/instances');
      const { Supervisor } = require('./lib/runner');
      const results = require('./lib/results');
      const insts = config.planInstances(cfg);
      const { runPaths } = require('./lib/runner');
      const P = runPaths(cfg);
      const state = readJson(P.state, null);
      if (state && require('./lib/util').pidAlive(state.pid) && state.pid !== process.pid) {
        log.error(`an arena is already running (pid ${state.pid}). Use \`node arena.js down\` first.`);
        return 1;
      }
      for (const note of cfg._notes || []) log.info(note);
      if (!args.noBuild) {
        log.info(`preparing ${insts.length} instance(s) (${cfg.pairs} pair${cfg.pairs > 1 ? 's' : ''}) in ${cfg.instancesDir}`);
        try {
          buildAll(cfg, insts, { rebuild: !!args.rebuild });
        } catch (e) {
          log.error(e.message);
          log.info('run `node arena.js doctor` for details');
          return 1;
        }
      }
      console.log(
        `\nruleset ${cfg.ruleset}/${cfg.gamemode} | speed x${cfg.speed} | driver ${cfg.driver} | ` +
          `${cfg.matches ? cfg.matches + ' matches each' : 'endless'} | Ctrl+C to stop\n`,
      );
      const sup = new Supervisor(cfg, insts, { fresh: !!args.fresh, maxRuntimeSec: args.for ? Number(args.for) * 60 : 0 });
      try {
        await sup.run();
      } catch (e) {
        log.error(e.message);
        sup.server && sup.server.stop();
        return 1;
      }
      console.log('\n' + results.render(results.summarize(cfg)));
      return 0;
    }

    case 'down': {
      const { runPaths, requestStop } = require('./lib/runner');
      const P = runPaths(cfg);
      const state = readJson(P.state, null);
      if (!state || !require('./lib/util').pidAlive(state.pid)) {
        // nothing supervising: still ask any orphaned instance to quit
        for (const inst of config.planInstances(cfg)) {
          try {
            writeJson(P.command(inst.id), { cmd: 'quit' });
          } catch {
            /* ignore */
          }
        }
        console.log('no running arena found (sent a quit command to any stray instances).');
        return 0;
      }
      requestStop(cfg);
      console.log(`asked arena (pid ${state.pid}) to stop...`);
      for (let i = 0; i < 40; i++) {
        await sleep(500);
        if (!require('./lib/util').pidAlive(state.pid)) {
          console.log('stopped.');
          return 0;
        }
      }
      console.log('still shutting down; check the arena window.');
      return 1;
    }

    case 'status': {
      const { readBoard, STATUS_HEADERS } = require('./lib/runner');
      const b = readBoard(cfg, config.planInstances(cfg));
      console.log(b.running ? `arena running (pid ${b.pid})` : 'arena is not running (showing last known status)');
      console.log('\n' + table(b.rows, STATUS_HEADERS));
      return 0;
    }

    case 'results': {
      const results = require('./lib/results');
      const since = args.since ? Date.now() / 1000 - Number(args.since) * 60 : 0;
      const sum = results.summarize(cfg, { since });
      if (args.json) console.log(JSON.stringify({ matches: sum.matches.length, byInstance: sum.byInstance || sum.byInst, byDriver: sum.byDriver, elo: Object.fromEntries(sum.elo) }, null, 2));
      else console.log(results.render(sum));
      return 0;
    }

    case 'rewards': {
      const results = require('./lib/results');
      const since = args.since ? Date.now() / 1000 - Number(args.since) * 60 : 0;
      const rows = results.loadRewards(cfg, { since });
      if (args.json) {
        console.log(JSON.stringify(rows.slice(-Number(args.last || 100)), null, 2));
        return 0;
      }
      console.log(results.renderRewards(results.summarizeRewards(rows)));
      const n = Number(args.last || 0);
      if (n > 0 && rows.length) {
        console.log('\nlast ' + Math.min(n, rows.length) + ' blinds:');
        console.log(table(rows.slice(-n).map((r) => [
          `inst${r.inst}`, `ante ${r.ante ?? '?'}`, r.kind,
          r.kind === 'skip' ? `skipped ${r.blind || ''} (${r.tag || 'no tag'})` : r.kind === 'pvp' ? `${r.outcome}${r.hopeless ? ' (hopeless)' : ''}` : (r.beaten ? 'beaten' : 'FAILED'),
          r.kind === 'skip' ? '-' : `$${r.money ?? 0}`, r.kind === 'skip' ? '-' : `${r.tarots ?? 0}T ${r.spectrals ?? 0}S ${r.planets ?? 0}P${r.planets_aimed ? `(${r.planets_aimed} aimed)` : ''}`, r.kind === 'pvp' || r.kind === 'skip' ? '-' : `${r.unused_hands ?? 0}h`,
          JSON.stringify(r.parts || {}), r.reward,
        ]), ['inst', 'ante', 'blind', 'result', 'money', 'cards', 'hands', 'parts', 'reward']));
      }
      return 0;
    }

    case 'train': {
      // thin wrapper around `python -m trainer <cmd> --run-dir <run folder> ...`
      const { spawnSync } = require('child_process');
      const raw = process.argv.slice(process.argv.indexOf('train') + 1);
      if (!raw.length) {
        console.log('usage: node arena.js train <bc|live|agent|eval|inspect> [options]   (python -m trainer --help for all options)');
        return 1;
      }
      if (!raw.includes('--run-dir')) raw.push('--run-dir', cfg.runDir);
      const candidates = process.platform === 'win32' ? [['python'], ['py', '-3'], ['python3']] : [['python3'], ['python']];
      for (const cand of candidates) {
        const probe = spawnSync(cand[0], [...cand.slice(1), '-c', 'import numpy'], { stdio: 'ignore' });
        if (probe.status === 0) {
          const r = spawnSync(cand[0], [...cand.slice(1), '-m', 'trainer', ...raw], { stdio: 'inherit', cwd: __dirname });
          return r.status === null ? 1 : r.status;
        }
      }
      log.error('no Python with numpy found. Install Python 3.9+ and run:  pip install numpy');
      return 1;
    }

    case 'logs': {
      const what = args._[1] || 'server';
      const n = Number(args.lines || 40);
      const dir = path.join(cfg.runDir, 'logs');
      let file;
      const m = /^inst(\d+)$/.exec(what);
      if (what === 'server') file = path.join(dir, 'server.log');
      else if (m) {
        const sub = args._[2] || 'arena';
        if (sub === 'lovely') {
          const inst = config.planInstances(cfg).find((i) => i.id === Number(m[1]));
          const ld = inst && path.join(inst.modsDir, 'lovely', 'log');
          const files = ld && isDir(ld) ? fs.readdirSync(ld).filter((f) => f.endsWith('.log')).sort() : [];
          file = files.length ? path.join(ld, files[files.length - 1]) : null;
        } else file = path.join(dir, `inst${m[1]}.${sub === 'proc' ? 'proc' : 'arena'}.log`);
      } else {
        console.log('usage: node arena.js logs [server | instN [arena|proc|lovely]]');
        return 1;
      }
      const t = file && readText(file);
      if (!t) {
        console.log(`no log at ${file || '(unknown)'}`);
        return 1;
      }
      console.log(`--- ${file}\n${lines(t, n)}`);
      return 0;
    }

    case 'clean': {
      if (!args.yes) {
        console.log('This deletes the game copies in:\n  ' + cfg.instancesDir + '\nthe run folder (results, logs):\n  ' + cfg.runDir + '\nand the arena save folders (BalatroArena_N) in your AppData.\nYour real Balatro install and profile are never touched. Re-run with --yes.');
        return 1;
      }
      rmrf(cfg.instancesDir);
      rmrf(cfg.runDir);
      let n = 0;
      for (const d of fs.existsSync(cfg.appData) ? fs.readdirSync(cfg.appData) : []) {
        if (/^BalatroArena_\d+$/.test(d)) {
          rmrf(path.join(cfg.appData, d));
          n++;
        }
      }
      console.log(`removed instance copies, run folder and ${n} arena save folder(s).`);
      return 0;
    }

    default:
      console.log(`unknown command "${cmd}"\n${HELP}`);
      return 1;
  }
}

main().then(
  (code) => process.exit(code || 0),
  (e) => {
    console.error(c.red('arena.js crashed: ') + (e && e.stack ? e.stack : e));
    process.exit(1);
  },
);
