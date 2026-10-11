'use strict';
// `node arena.js selftest` - drives the bundled local relay server with two scripted TCP clients that speak
// the same newline-delimited JSON protocol as the Multiplayer mod. It checks the pieces the arena relies on:
// lobby create/join/ready, startGame, readyBlind/startBlind, playHand -> PvP resolution (lives, win/lose,
// ties), stopGame, leave/host promotion, and that bot-speed message bursts are not throttled.
const net = require('net');
const os = require('os');
const { path, fs, sleep, freePort, mkdirp, log, c } = require('./util');
const { LocalServer } = require('./server');

class Client {
  constructor(name, port) {
    this.name = name;
    this.port = port;
    this.msgs = [];
    this.buf = '';
    this.closed = false;
  }
  connect() {
    return new Promise((resolve, reject) => {
      this.sock = net.connect({ port: this.port, host: '127.0.0.1' }, resolve);
      this.sock.setNoDelay(true);
      this.sock.on('data', (d) => {
        this.buf += d.toString();
        const parts = this.buf.split('\n');
        this.buf = parts.pop();
        for (const p of parts) {
          if (!p) continue;
          try {
            this.msgs.push(JSON.parse(p));
          } catch {
            /* ignore */
          }
        }
      });
      this.sock.on('close', () => (this.closed = true));
      this.sock.on('error', (e) => {
        this.closed = true;
        reject(e);
      });
    });
  }
  send(obj) {
    this.sock.write(JSON.stringify(obj) + '\n');
  }
  // wait for (and consume) the first queued message matching `pred`
  async wait(pred, ms = 3000, label = '') {
    const end = Date.now() + ms;
    for (;;) {
      const i = this.msgs.findIndex(pred);
      if (i >= 0) return this.msgs.splice(i, 1)[0];
      if (Date.now() > end) throw new Error(`${this.name}: timed out waiting for ${label || 'message'}; queued: ${this.msgs.map((m) => m.action).join(',') || '(none)'}`);
      await sleep(10);
    }
  }
  act(name, ms, label) {
    return this.wait((m) => m.action === name, ms, label || name);
  }
  drain() {
    this.msgs.length = 0;
  }
  close() {
    try {
      this.sock.destroy();
    } catch {
      /* ignore */
    }
  }
}

async function run({ verbose = false } = {}) {
  const port = await freePort();
  const adminPort = await freePort();
  const logPath = path.join(os.tmpdir(), `arena-selftest-${process.pid}.log`);
  const server = new LocalServer({ host: '127.0.0.1', port, adminPort }, logPath);
  const results = [];
  const check = (ok, msg) => {
    results.push({ ok, msg });
    console.log(`  ${ok ? c.green('PASS') : c.red('FAIL')} ${msg}`);
  };
  const step = async (msg, fn) => {
    try {
      await fn();
      check(true, msg);
    } catch (e) {
      check(false, `${msg}: ${e.message}`);
    }
  };

  console.log(`Starting the bundled server on 127.0.0.1:${port} ...`);
  await server.start();
  const A = new Client('A', port);
  const B = new Client('B', port);
  let code = null;
  try {
    await A.connect();
    await B.connect();

    await step('both clients receive "connected" and a version request', async () => {
      for (const x of [A, B]) {
        await x.act('connected');
        await x.act('version');
      }
    });
    for (const [x, n] of [[A, 'BotA'], [B, 'BotB']]) {
      x.send({ action: 'version', version: '0.5.5' });
      x.send({ action: 'username', username: n, modHash: 'arena-selftest' });
    }

    await step('A creates a lobby and gets a 5-letter code', async () => {
      A.send({ action: 'createLobby', gameMode: 'attrition' });
      const m = await A.act('joinedLobby');
      code = m.code;
      if (!/^[A-Z]{5}$/.test(code || '')) throw new Error(`bad lobby code ${code}`);
    });

    await step('B joins with that code; both see lobbyInfo with each other', async () => {
      B.send({ action: 'joinLobby', code });
      await B.act('joinedLobby');
      const ia = await A.wait((m) => m.action === 'lobbyInfo' && m.guest);
      const ib = await B.wait((m) => m.action === 'lobbyInfo' && m.guest);
      if (!ia.isHost || ib.isHost) throw new Error('host/guest flags wrong');
    });

    await step('guest readyLobby is reflected to the host', async () => {
      A.drain();
      B.send({ action: 'readyLobby' });
      const m = await A.wait((x) => x.action === 'lobbyInfo' && x.guestReady === true);
      if (!m) throw new Error('no ready info');
    });

    await step('a non-host cannot start the game', async () => {
      A.drain();
      B.drain();
      B.send({ action: 'startGame' });
      await sleep(250);
      if (A.msgs.some((m) => m.action === 'startGame') || B.msgs.some((m) => m.action === 'startGame')) throw new Error('guest started the game');
    });

    let seed1 = null;
    await step('host startGame -> both receive startGame with the same seed', async () => {
      A.send({ action: 'startGame' });
      const a = await A.act('startGame');
      const b = await B.act('startGame');
      if (a.seed !== b.seed || !a.seed) throw new Error(`seeds differ/missing: ${a.seed} vs ${b.seed}`);
      seed1 = a.seed;
    });

    // --- A beats B four times (attrition starts at 4 lives) -------------------------------------------
    for (let round = 1; round <= 4; round++) {
      await step(`PvP round ${round}: both ready -> startBlind -> scores resolve (${round < 4 ? 'B loses a life' : 'B loses the game'})`, async () => {
        A.send({ action: 'readyBlind' });
        B.send({ action: 'readyBlind' });
        await A.act('startBlind');
        await B.act('startBlind');
        A.send({ action: 'playHand', score: '300', handsLeft: 0, hasSpeedrun: false });
        B.send({ action: 'playHand', score: '100', handsLeft: 0, hasSpeedrun: false });
        if (round < 4) {
          const ea = await A.act('endPvP');
          const eb = await B.act('endPvP');
          if (ea.lost !== false || eb.lost !== true) throw new Error(`lost flags wrong: A=${ea.lost} B=${eb.lost}`);
          A.send({ action: 'newRound' }); // the mod does this every round; it re-arms the server's one-life-per-round guard
          B.send({ action: 'newRound' });
          await sleep(50);
        } else {
          await A.act('winGame');
          await B.act('loseGame');
        }
      });
    }

    await step('host stopGame returns both players to the lobby', async () => {
      A.drain();
      B.drain();
      A.send({ action: 'stopGame' });
      await A.act('stopGame');
      await B.act('stopGame');
    });

    await step('second game: new seed, tie scores cost nobody a life', async () => {
      B.send({ action: 'readyLobby' });
      await sleep(100);
      A.drain();
      B.drain();
      A.send({ action: 'startGame' });
      const a = await A.act('startGame');
      await B.act('startGame');
      if (a.seed === seed1) throw new Error('seed was reused');
      A.send({ action: 'readyBlind' });
      B.send({ action: 'readyBlind' });
      await A.act('startBlind');
      await B.act('startBlind');
      A.send({ action: 'playHand', score: '500', handsLeft: 0, hasSpeedrun: false });
      B.send({ action: 'playHand', score: '500', handsLeft: 0, hasSpeedrun: false });
      const ea = await A.act('endPvP');
      const eb = await B.act('endPvP');
      if (ea.lost || eb.lost) throw new Error('a tie must not cost a life');
    });

    await step('bot-speed message burst (400 msgs in a blink) is not throttled or disconnected', async () => {
      B.drain();
      for (let i = 0; i < 400; i++) B.send({ action: 'keepAlive' });
      const end = Date.now() + 5000;
      let acks = 0;
      while (Date.now() < end && acks < 400) {
        acks += B.msgs.filter((m) => m.action === 'keepAliveAck').length;
        B.msgs = B.msgs.filter((m) => m.action !== 'keepAliveAck');
        await sleep(20);
      }
      if (B.closed) throw new Error('server disconnected the client');
      if (acks < 400) throw new Error(`only ${acks}/400 acks`);
    });

    await step('guest leaving stops the game and tells the host', async () => {
      A.drain();
      B.drain();
      B.send({ action: 'leaveLobby' });
      await A.act('stopGame');
      const li = await A.wait((m) => m.action === 'lobbyInfo');
      if (li.guest) throw new Error('host still sees a guest');
    });

    await step('guest can rejoin the same lobby afterwards', async () => {
      B.send({ action: 'joinLobby', code });
      await B.act('joinedLobby');
      await A.wait((m) => m.action === 'lobbyInfo' && m.guest);
    });

    await step('host leaving promotes the guest to host', async () => {
      A.drain();
      B.drain();
      A.send({ action: 'leaveLobby' });
      const li = await B.wait((m) => m.action === 'lobbyInfo' && m.isHost === true);
      if (li.guest) throw new Error('promoted host still sees a guest');
    });
  } catch (e) {
    check(false, `unexpected error: ${e.message}`);
  } finally {
    A.close();
    B.close();
    server.stop();
    await sleep(200);
    if (verbose) console.log(fs.readFileSync(logPath, 'utf8'));
  }
  const failed = results.filter((r) => !r.ok).length;
  console.log(failed ? c.red(`\n${failed} of ${results.length} checks failed (server log: ${logPath})`) : c.green(`\nAll ${results.length} protocol checks passed.`));
  return failed === 0;
}

module.exports = { run, Client };
