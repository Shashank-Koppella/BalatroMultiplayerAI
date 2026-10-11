'use strict';
// Runs the bundled local relay server (server/arena-server.mjs = the official Balatro Multiplayer server,
// GPL-3.0, with SQLite stores swapped for in-memory stubs and the listener bound to loopback).
const cp = require('child_process');
const { path, fs, mkdirp, isFile, portFree, waitForPort, log } = require('./util');
const config = require('./config');

const BUNDLE = path.join(config.ROOT, 'server', 'arena-server.mjs');

// Bots send far more messages per second than humans do, so the relay's anti-abuse limiter is relaxed
// (and set to log-only). The server only ever listens on 127.0.0.1 unless you change server.host yourself.
function serverEnv(srv) {
  return {
    ...process.env,
    PORT: String(srv.port),
    ADMIN_PORT: String(srv.adminPort),
    HOST: srv.host,
    ABUSE_ENFORCE: 'false',
    ABUSE_MSG_RATE_PER_SEC: '5000',
    ABUSE_MSG_BURST: '50000',
    ABUSE_BYTE_RATE_PER_SEC: String(64 * 1024 * 1024),
    ABUSE_BYTE_BURST: String(256 * 1024 * 1024),
    ABUSE_STRIKE_LIMIT: '100000',
  };
}

class LocalServer {
  constructor(srvCfg, logPath) {
    this.cfg = srvCfg;
    this.logPath = logPath;
    this.proc = null;
    this.stopping = false;
    this.restarts = 0;
  }

  async start() {
    if (!isFile(BUNDLE)) throw new Error(`server bundle missing: ${BUNDLE}`);
    if (!(await portFree(this.cfg.port, this.cfg.host))) {
      throw new Error(`port ${this.cfg.port} is already in use (is another arena running? use --port N or "server.port" in arena.config.json)`);
    }
    this._spawn();
    const up = await waitForPort(this.cfg.port, this.cfg.host, 15000);
    if (!up) throw new Error(`server did not start listening on ${this.cfg.host}:${this.cfg.port} (see ${this.logPath})`);
    return this;
  }

  _spawn() {
    mkdirp(path.dirname(this.logPath));
    const out = fs.openSync(this.logPath, 'a');
    fs.writeSync(out, `\n--- server start ${new Date().toISOString()} ---\n`);
    this.proc = cp.spawn(process.execPath, [BUNDLE], { env: serverEnv(this.cfg), stdio: ['ignore', out, out], windowsHide: true });
    fs.closeSync(out);
    this.proc.on('exit', (code, sig) => {
      if (this.stopping) return;
      log.warn(`server exited (code ${code} ${sig || ''}); restarting in 2s - running matches will be stopped by the instances' recovery`);
      this.restarts++;
      setTimeout(() => {
        if (!this.stopping) this._spawn();
      }, 2000);
    });
  }

  stop() {
    this.stopping = true;
    if (this.proc && !this.proc.killed) {
      try {
        this.proc.kill();
      } catch {
        /* already gone */
      }
    }
  }
}

module.exports = { LocalServer, BUNDLE, serverEnv };
