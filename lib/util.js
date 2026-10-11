'use strict';
// Small dependency-free helpers shared by the arena launcher.
const fs = require('fs');
const os = require('os');
const path = require('path');
const net = require('net');

const isWin = process.platform === 'win32';
const useColor = !!process.stdout.isTTY && !process.env.NO_COLOR;
const paint = (code) => (s) => (useColor ? `\x1b[${code}m${s}\x1b[0m` : String(s));
const c = { red: paint(31), green: paint(32), yellow: paint(33), cyan: paint(36), dim: paint(2), bold: paint(1) };

function stamp() {
  return new Date().toISOString().replace('T', ' ').slice(11, 19);
}
const log = {
  info: (m) => console.log(`${c.dim(stamp())} ${m}`),
  warn: (m) => console.log(`${c.dim(stamp())} ${c.yellow('WARN')} ${m}`),
  error: (m) => console.log(`${c.dim(stamp())} ${c.red('ERROR')} ${m}`),
  ok: (m) => console.log(`${c.dim(stamp())} ${c.green('OK')} ${m}`),
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function exists(p) {
  try {
    fs.accessSync(p);
    return true;
  } catch {
    return false;
  }
}
function isDir(p) {
  try {
    return fs.statSync(p).isDirectory();
  } catch {
    return false;
  }
}
function isFile(p) {
  try {
    return fs.statSync(p).isFile();
  } catch {
    return false;
  }
}
function mkdirp(p) {
  fs.mkdirSync(p, { recursive: true });
}
function readText(p) {
  try {
    return fs.readFileSync(p, 'utf8');
  } catch {
    return null;
  }
}
function readJson(p, fallback = null) {
  const t = readText(p);
  if (t == null) return fallback;
  try {
    return JSON.parse(t.replace(/^﻿/, ''));
  } catch {
    return fallback;
  }
}
// Write via temp file + rename so readers (the game, other tools) never see half a file.
function writeJson(p, obj) {
  mkdirp(path.dirname(p));
  const tmp = `${p}.tmp${process.pid}`;
  fs.writeFileSync(tmp, JSON.stringify(obj, null, 2));
  fs.renameSync(tmp, p);
}
function readJsonl(p) {
  const t = readText(p);
  if (!t) return [];
  const rows = [];
  for (const line of t.split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      rows.push(JSON.parse(line));
    } catch {
      /* partial last line while the game is writing */
    }
  }
  return rows;
}

// Replace %VAR%, $VAR and a leading ~ so config files can be written portably.
function expand(s) {
  if (typeof s !== 'string') return s;
  let out = s.replace(/%([^%]+)%/g, (m, k) => process.env[k] ?? process.env[k.toUpperCase()] ?? m);
  out = out.replace(/\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?/g, (m, k) => process.env[k] ?? m);
  if (out === '~' || out.startsWith('~/') || out.startsWith('~\\')) out = path.join(os.homedir(), out.slice(1));
  return out;
}
const fwd = (p) => String(p).replace(/\\/g, '/');

// Copy `src` into `dst`, only touching files whose size or mtime differ. With mirror=true files that no
// longer exist in `src` are removed from `dst` (except names in `keep`). Returns {copied, removed}.
function syncDir(src, dst, { mirror = false, keep = [], skip = () => false } = {}) {
  let copied = 0;
  let removed = 0;
  mkdirp(dst);
  const names = new Set();
  for (const ent of fs.readdirSync(src, { withFileTypes: true })) {
    if (skip(ent.name, path.join(src, ent.name), ent)) continue;
    names.add(ent.name);
    const s = path.join(src, ent.name);
    const d = path.join(dst, ent.name);
    if (ent.isDirectory()) {
      const r = syncDir(s, d, { mirror, keep: [], skip });
      copied += r.copied;
      removed += r.removed;
    } else if (ent.isFile()) {
      let same = false;
      try {
        const a = fs.statSync(s);
        const b = fs.statSync(d);
        same = a.size === b.size && Math.abs(a.mtimeMs - b.mtimeMs) < 2000;
      } catch {
        /* missing */
      }
      if (!same) {
        fs.copyFileSync(s, d);
        try {
          const a = fs.statSync(s);
          fs.utimesSync(d, a.atime, a.mtime);
        } catch {
          /* best effort */
        }
        copied++;
      }
    }
  }
  if (mirror) {
    for (const ent of fs.readdirSync(dst, { withFileTypes: true })) {
      if (names.has(ent.name) || keep.includes(ent.name)) continue;
      fs.rmSync(path.join(dst, ent.name), { recursive: true, force: true });
      removed++;
    }
  }
  return { copied, removed };
}

function rmrf(p) {
  fs.rmSync(p, { recursive: true, force: true });
}

function portFree(port, host = '127.0.0.1') {
  return new Promise((resolve) => {
    const srv = net.createServer();
    srv.once('error', () => resolve(false));
    srv.once('listening', () => srv.close(() => resolve(true)));
    srv.listen(port, host);
  });
}
function freePort(host = '127.0.0.1') {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.once('error', reject);
    srv.listen(0, host, () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}
function canConnect(port, host = '127.0.0.1', timeoutMs = 800) {
  return new Promise((resolve) => {
    const s = net.connect({ port, host });
    const done = (v) => {
      s.destroy();
      resolve(v);
    };
    s.setTimeout(timeoutMs, () => done(false));
    s.once('connect', () => done(true));
    s.once('error', () => done(false));
  });
}
async function waitForPort(port, host, totalMs) {
  const end = Date.now() + totalMs;
  while (Date.now() < end) {
    if (await canConnect(port, host)) return true;
    await sleep(250);
  }
  return false;
}

function pidAlive(pid) {
  if (!pid) return false;
  try {
    process.kill(pid, 0);
    return true;
  } catch (e) {
    return e.code === 'EPERM';
  }
}

function fmtDuration(sec) {
  sec = Math.max(0, Math.round(sec));
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  return h ? `${h}h${String(m).padStart(2, '0')}m` : m ? `${m}m${String(s).padStart(2, '0')}s` : `${s}s`;
}

// Minimal "--flag value" / "--flag=value" / "--bool" / positional parser.
function parseArgs(argv, boolFlags = []) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const eq = a.indexOf('=');
      let key = eq > 0 ? a.slice(2, eq) : a.slice(2);
      key = key.replace(/-([a-z])/g, (m, ch) => ch.toUpperCase());
      if (eq > 0) out[key] = a.slice(eq + 1);
      else if (boolFlags.includes(key)) out[key] = true;
      else if (i + 1 < argv.length && !argv[i + 1].startsWith('--')) out[key] = argv[++i];
      else out[key] = true;
    } else out._.push(a);
  }
  return out;
}

function table(rows, headers) {
  const cols = headers.length;
  const widths = headers.map((h, i) => Math.max(String(h).length, ...rows.map((r) => String(r[i] ?? '').length)));
  const line = (r) => r.map((v, i) => String(v ?? '').padEnd(widths[i])).join('  ').trimEnd();
  return [c.bold(line(headers)), ...rows.map(line)].join('\n');
}

module.exports = {
  isWin, c, log, sleep, exists, isDir, isFile, mkdirp, readText, readJson, writeJson, readJsonl, expand, fwd,
  syncDir, rmrf, portFree, freePort, canConnect, waitForPort, pidAlive, fmtDuration, parseArgs, table, os, path, fs,
};
