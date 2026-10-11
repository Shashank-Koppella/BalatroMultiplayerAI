#!/usr/bin/env node
'use strict';
// Stand-in for Balatro.exe used by tests/launcher_test.js. It reads the same environment the real
// instances get, behaves like the BotArena mod from the launcher's point of view (heartbeat status file,
// command file, exit codes) and connects to the relay server using the Multiplayer copy's .env.
const fs = require('fs');
const path = require('path');
const net = require('net');
const E = process.env;
const id = E.BOTARENA_ID;
const run = E.BOTARENA_SHARED;
const mode = (E.FAKE_MODE || 'normal').split(',');
const has = (m) => mode.includes(m);
const statusPath = `${run}/status/inst${id}.json`;
const cmdPath = `${run}/commands/inst${id}.json`;
fs.mkdirSync(`${run}/envdump`, { recursive: true });
fs.mkdirSync(`${run}/status`, { recursive: true });

const runsFile = `${run}/envdump/runs_${id}`;
let runs = 1;
try { runs = Number(fs.readFileSync(runsFile, 'utf8')) + 1; } catch {}
fs.writeFileSync(runsFile, String(runs));

const mpDir = fs.readdirSync(E.LOVELY_MOD_DIR).find((d) => /^multiplayer/i.test(d));
const mpEnv = {};
for (const line of fs.readFileSync(path.join(E.LOVELY_MOD_DIR, mpDir, '.env'), 'utf8').split(/\r?\n/)) {
  const m = line.match(/^([\w]+)\s*=\s*(.+)$/);
  if (m) mpEnv[m[1]] = m[2];
}
const keys = Object.keys(E).filter((k) => k.startsWith('BOTARENA_') || k === 'LOVELY_MOD_DIR');
fs.writeFileSync(`${run}/envdump/inst${id}.json`, JSON.stringify({ env: Object.fromEntries(keys.map((k) => [k, E[k]])), argv: process.argv.slice(2), cwd: process.cwd(), runs, mpEnv, mods: fs.readdirSync(E.LOVELY_MOD_DIR) }));

let sock = null;
if (!has('noserver')) {
  sock = net.connect({ host: mpEnv.server_url, port: Number(mpEnv.server_port) }, () => {
    sock.write(JSON.stringify({ action: 'username', username: E.BOTARENA_NAME, modHash: 'fake' }) + '\n');
  });
  sock.on('error', () => {});
}

let finished = false;
const started = Date.now();
let frozen = false;
function writeStatus(extra = {}) {
  if (frozen) return;
  let more = {};
  try { more = JSON.parse(E.FAKE_STATUS || '{}'); } catch {} // lets a test put e.g. reward/waiting fields on the status board
  fs.writeFileSync(statusPath, JSON.stringify({ inst: Number(id), name: E.BOTARENA_NAME, phase: 'lobby', t: Math.floor(Date.now() / 1000), matches: 0, wins: 0, losses: 0, fps: 60, ...more, ...extra }));
}
writeStatus();
const iv = setInterval(() => {
  const age = Date.now() - started;
  if (has('fatal')) { writeStatus({ fatal: 'fake fatal' }); process.exit(2); }
  if (has('crash_once') && runs === 1 && age > 1500) process.exit(1);
  if (has('hang_once') && runs === 1 && age > 1500) { frozen = true; return; }
  if (has('close') && age > 1500) process.exit(0);
  if (has('stall_quit') && runs === 1 && age > 1500) { writeStatus({ quit_reason: 'stalled' }); process.exit(0); }
  if (has('finish') && age > 2000) { writeStatus({ finished: true, phase: 'finished', matches: 3, wins: 2, losses: 1 }); process.exit(0); }
  writeStatus();
  try {
    const cmd = JSON.parse(fs.readFileSync(cmdPath, 'utf8'));
    fs.rmSync(cmdPath, { force: true });
    if (cmd.cmd === 'quit') { writeStatus({ finished: true, phase: 'finished' }); process.exit(0); }
  } catch {}
}, 300);
process.on('SIGTERM', () => process.exit(0));
