'use strict';
// Supervisor: starts the local server and every game instance, restarts instances that crash or freeze,
// stops cleanly on Ctrl+C / `arena.js down`, and prints a status board while running.
const cp = require('child_process');
const { path, fs, mkdirp, readJson, writeJson, isFile, rmrf, log, c, sleep, pidAlive, fmtDuration, table, isWin } = require('./util');
const { LocalServer } = require('./server');

const SUBDIRS = ['status', 'lobby', 'commands', 'bridge', 'results', 'logs', 'decisions'];

function runPaths(cfg) {
  const d = cfg.runDir;
  return {
    dir: d,
    status: (id) => path.join(d, 'status', `inst${id}.json`),
    command: (id) => path.join(d, 'commands', `inst${id}.json`),
    procLog: (id) => path.join(d, 'logs', `inst${id}.proc.log`),
    serverLog: path.join(d, 'logs', 'server.log'),
    state: path.join(d, 'arena.json'),
    stopFlag: path.join(d, 'stop.flag'),
  };
}

function prepareRunDir(cfg, { fresh = false } = {}) {
  const P = runPaths(cfg);
  mkdirp(P.dir);
  if (fresh) for (const s of ['results', 'logs', 'decisions']) rmrf(path.join(P.dir, s));
  for (const s of SUBDIRS) mkdirp(path.join(P.dir, s));
  // transient coordination files must not leak between runs (a stale lobby file would point at a dead lobby)
  for (const s of ['status', 'lobby', 'commands', 'bridge']) {
    for (const f of fs.readdirSync(path.join(P.dir, s))) rmrf(path.join(P.dir, s, f));
  }
  rmrf(P.stopFlag);
  return P;
}

function killTree(proc) {
  if (!proc || proc.exitCode !== null) return;
  try {
    if (isWin) cp.spawnSync('taskkill', ['/PID', String(proc.pid), '/T', '/F'], { stdio: 'ignore' });
    else proc.kill('SIGKILL');
  } catch {
    /* already gone */
  }
}

function statusLine(inst, st, rec) {
  const wl = st ? `${st.wins ?? 0}W ${st.losses ?? 0}L${st.aborted ? ` ${st.aborted}A` : ''}` : '-';
  const m = st && st.match ? `ante ${st.match.ante ?? '?'} r${st.match.round ?? '?'} ${st.match.lives ?? '?'}-${st.match.enemy_lives ?? '?'}hp` : '';
  let phase = st ? (st.fatal ? 'FATAL' : st.phase || '?') : '-';
  if (st && st.waiting) phase += ` (waits: ${st.waiting})`; // PvP: the leader waits for the player who is behind
  const rw = st && st.reward ? `${Number(st.reward.total || 0).toFixed(1)} (${st.reward.blinds || 0})` : '';
  return [
    `inst${inst.id}`,
    `${inst.pair}`,
    inst.name,
    rec ? rec.state : '-',
    phase,
    wl,
    m,
    rw,
    st && st.fps ? `${Math.round(st.fps)}fps` : '',
    rec && rec.startedAt && rec.state === 'running' ? fmtDuration((Date.now() - rec.startedAt) / 1000) : '',
    rec && rec.restarts.length ? `${rec.restarts.length} restarts` : '',
  ];
}
const STATUS_HEADERS = ['inst', 'pair', 'name', 'process', 'phase', 'record', 'match', 'reward', 'fps', 'up', 'restarts'];

class Supervisor {
  constructor(cfg, insts, opts = {}) {
    this.cfg = cfg;
    this.insts = insts;
    this.P = runPaths(cfg);
    this.opts = opts;
    this.server = null;
    this.stopping = false;
    this.recs = new Map(insts.map((inst, i) => [inst.id, { inst, proc: null, state: 'pending', startedAt: 0, armed: false, restarts: [], nextStart: 0, exitCode: null, order: i }]));
    this.t0 = Date.now();
    this.lastPrint = 0;
  }

  async run() {
    const { cfg, P } = this;
    prepareRunDir(cfg, { fresh: this.opts.fresh });
    if (cfg.server.spawn) {
      this.server = new LocalServer(cfg.server, P.serverLog);
      await this.server.start();
      log.ok(`local relay server listening on ${cfg.server.host}:${cfg.server.port} (log: ${path.relative(process.cwd(), P.serverLog) || P.serverLog})`);
    } else {
      log.info(`not starting a server; instances connect to ${cfg.server.host}:${cfg.server.port}`);
    }
    const onSignal = () => {
      if (this.stopping) {
        // second Ctrl+C: stop waiting politely
        for (const r of this.recs.values()) killTree(r.proc);
        if (this.server) this.server.stop();
        process.exit(1);
      }
      log.info('stopping (Ctrl+C again to force)...');
      this.stopping = true;
    };
    process.on('SIGINT', onSignal);
    process.on('SIGTERM', onSignal);
    this.writeState();

    // stagger starts so primaries create their lobbies before their secondaries look for them
    let delay = 0;
    for (const rec of this.recs.values()) {
      rec.nextStart = Date.now() + delay;
      delay += cfg.staggerSec * 1000;
    }

    for (;;) {
      await sleep(1000);
      if (isFile(P.stopFlag)) this.stopping = true;
      if (this.stopping) break;
      const now = Date.now();
      for (const rec of this.recs.values()) this.tickInstance(rec, now);
      if (now - this.lastPrint >= (this.opts.printEverySec || 15) * 1000) {
        this.lastPrint = now;
        this.print();
      }
      this.writeState();
      if ([...this.recs.values()].every((r) => ['finished', 'fatal', 'failed', 'closed'].includes(r.state))) {
        log.info('all instances are done');
        break;
      }
      if (this.opts.maxRuntimeSec && (now - this.t0) / 1000 > this.opts.maxRuntimeSec) {
        log.info('--for time limit reached');
        break;
      }
    }
    await this.shutdown();
  }

  tickInstance(rec, now) {
    const { cfg, P } = this;
    if (rec.state === 'pending' || rec.state === 'backoff') {
      if (now >= rec.nextStart) this.spawn(rec);
      return;
    }
    if (rec.state !== 'running') return;
    // frozen / error-screen detection: the mod rewrites the status file about once a second
    const st = readJson(P.status(rec.inst.id), null);
    const hb = st && typeof st.t === 'number' ? st.t * 1000 : 0;
    if (hb >= rec.startedAt - 2000) rec.armed = true;
    const sinceStart = now - rec.startedAt;
    if (rec.armed && now - hb > cfg.hangSec * 1000) {
      log.warn(`inst${rec.inst.id} stopped responding for ${Math.round((now - hb) / 1000)}s; killing it`);
      rec.killedBy = 'hang';
      killTree(rec.proc);
    } else if (!rec.armed && sinceStart > cfg.startGraceSec * 1000) {
      log.warn(`inst${rec.inst.id} never reported in after ${Math.round(sinceStart / 1000)}s (is BotArena loading? check the Lovely log in ${rec.inst.modsDir}/lovely/log); killing it`);
      rec.killedBy = 'no-heartbeat';
      killTree(rec.proc);
    }
  }

  spawn(rec) {
    const { cfg, P } = this;
    const inst = rec.inst;
    mkdirp(path.dirname(P.procLog(inst.id)));
    const out = fs.openSync(P.procLog(inst.id), 'a');
    fs.writeSync(out, `\n--- start ${new Date().toISOString()} ---\n`);
    const args = cfg.hideConsole ? ['--disable-console'] : [];
    let proc;
    try {
      proc = cp.spawn(inst.exe, args, { cwd: inst.gameRoot, env: { ...process.env, ...inst.env }, stdio: ['ignore', out, out], windowsHide: false });
    } catch (e) {
      log.error(`inst${inst.id}: could not start ${inst.exe}: ${e.message}`);
      rec.state = 'failed';
      fs.closeSync(out);
      return;
    }
    fs.closeSync(out);
    rec.proc = proc;
    rec.state = 'running';
    rec.startedAt = Date.now();
    rec.armed = false;
    rec.killedBy = null;
    log.info(`inst${inst.id} (${inst.name}, pair ${inst.pair}, ${inst.role}) started, pid ${proc.pid}`);
    proc.on('error', (e) => {
      log.error(`inst${inst.id}: process error ${e.message}`);
      if (rec.proc === proc && rec.state === 'running') this.onExit(rec, -1, null);
    });
    proc.on('exit', (code, sig) => this.onExit(rec, code, sig));
  }

  onExit(rec, code, sig) {
    if (rec.state !== 'running') return;
    const inst = rec.inst;
    rec.exitCode = code;
    rec.proc = null;
    if (this.stopping) {
      rec.state = 'stopped';
      return;
    }
    const st = readJson(this.P.status(inst.id), null) || {};
    if (code === 2 || st.fatal) {
      rec.state = 'fatal';
      log.error(`inst${inst.id} refused to run: ${st.fatal || 'fatal error (exit code 2)'}. Not restarting.`);
      return;
    }
    if (st.finished || st.phase === 'finished') {
      rec.state = 'finished';
      log.ok(`inst${inst.id} finished (${st.matches ?? '?'} matches, ${st.wins ?? 0}W ${st.losses ?? 0}L)`);
      return;
    }
    const intentional = st.quit_reason && !rec.killedBy; // the mod asked to be restarted (stall recovery)
    if (code === 0 && !st.quit_reason && !rec.killedBy) {
      rec.state = 'closed';
      log.info(`inst${inst.id} was closed (exit code 0); not restarting it. Run \`node arena.js up\` again to bring it back.`);
      return;
    }
    // crash, freeze-kill or requested restart: restart with back-off, give up if it keeps failing
    const now = Date.now();
    const rs = this.cfg.restart;
    rec.restarts = rec.restarts.filter((t) => now - t < rs.windowSec * 1000);
    rec.restarts.push(now);
    if (rec.restarts.length > rs.max) {
      rec.state = 'failed';
      log.error(`inst${inst.id} failed ${rec.restarts.length} times within ${rs.windowSec}s; giving up on it (see ${path.relative(process.cwd(), this.P.procLog(inst.id))})`);
      return;
    }
    const wait = Math.min(60, rs.backoffSec * 2 ** Math.max(0, rec.restarts.length - 1));
    rec.state = 'backoff';
    rec.nextStart = now + wait * 1000;
    const why = rec.killedBy ? `killed (${rec.killedBy})` : intentional ? `restart requested (${st.quit_reason})` : `exit code ${code}${sig ? ' ' + sig : ''}`;
    log.warn(`inst${inst.id}: ${why}; restarting in ${wait}s (restart #${rec.restarts.length})`);
  }

  boardRows() {
    return [...this.recs.values()].map((rec) => statusLine(rec.inst, readJson(this.P.status(rec.inst.id), null), rec));
  }

  print() {
    console.log('\n' + table(this.boardRows(), STATUS_HEADERS) + '\n');
  }

  writeState() {
    try {
      writeJson(this.P.state, {
        pid: process.pid,
        started: this.t0,
        server: this.cfg.server,
        instances: [...this.recs.values()].map((r) => ({ id: r.inst.id, pid: r.proc ? r.proc.pid : null, state: r.state, restarts: r.restarts.length })),
      });
    } catch {
      /* non-fatal */
    }
  }

  async shutdown() {
    this.stopping = true;
    const live = [...this.recs.values()].filter((r) => r.proc && r.proc.exitCode === null);
    for (const rec of live) {
      try {
        writeJson(this.P.command(rec.inst.id), { cmd: 'quit' });
      } catch {
        /* ignore */
      }
    }
    if (live.length) log.info(`asking ${live.length} instance(s) to quit...`);
    const end = Date.now() + 12000;
    while (Date.now() < end && live.some((r) => r.proc && r.proc.exitCode === null)) await sleep(250);
    for (const rec of live) {
      if (rec.proc && rec.proc.exitCode === null) {
        log.warn(`inst${rec.inst.id} did not quit; killing it`);
        killTree(rec.proc);
      }
    }
    if (this.server) this.server.stop();
    try {
      rmrf(this.P.state);
      rmrf(this.P.stopFlag);
    } catch {
      /* ignore */
    }
    log.info('arena stopped');
  }
}

// `status` without a running supervisor: just read the files the game instances write.
function readBoard(cfg, insts) {
  const P = runPaths(cfg);
  const state = readJson(P.state, null);
  const running = state && pidAlive(state.pid);
  const rows = insts.map((inst) => {
    const st = readJson(P.status(inst.id), null);
    const rec = state ? (state.instances || []).find((x) => x.id === inst.id) : null;
    const age = st && st.t ? Math.round(Date.now() / 1000 - st.t) : null;
    const row = statusLine(inst, st, rec ? { state: running ? rec.state : 'stopped', startedAt: 0, restarts: new Array(rec.restarts || 0) } : null);
    if (age != null) row[8] = age > 20 ? `(last heartbeat ${fmtDuration(age)} ago)` : row[8];
    return row;
  });
  return { running: !!running, pid: state && state.pid, rows };
}

function requestStop(cfg) {
  const P = runPaths(cfg);
  mkdirp(P.dir);
  fs.writeFileSync(P.stopFlag, String(Date.now()));
}

module.exports = { Supervisor, runPaths, prepareRunDir, readBoard, requestStop, STATUS_HEADERS, killTree };
