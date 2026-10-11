// Local arena build of BalatroMultiplayerAPI-Server (GPL-3.0). See LICENSE-SERVER.md
import { createRequire as __cr } from "node:module"; const require = __cr(import.meta.url);

// src/main.ts
import { createServer } from "node:net";

// src/Client.ts
import { randomBytes } from "node:crypto";

// node_modules/uuid/dist/esm-node/rng.js
import crypto from "crypto";
var rnds8Pool = new Uint8Array(256);
var poolPtr = rnds8Pool.length;
function rng() {
  if (poolPtr > rnds8Pool.length - 16) {
    crypto.randomFillSync(rnds8Pool);
    poolPtr = 0;
  }
  return rnds8Pool.slice(poolPtr, poolPtr += 16);
}

// node_modules/uuid/dist/esm-node/stringify.js
var byteToHex = [];
for (let i = 0; i < 256; ++i) {
  byteToHex.push((i + 256).toString(16).slice(1));
}
function unsafeStringify(arr, offset = 0) {
  return byteToHex[arr[offset + 0]] + byteToHex[arr[offset + 1]] + byteToHex[arr[offset + 2]] + byteToHex[arr[offset + 3]] + "-" + byteToHex[arr[offset + 4]] + byteToHex[arr[offset + 5]] + "-" + byteToHex[arr[offset + 6]] + byteToHex[arr[offset + 7]] + "-" + byteToHex[arr[offset + 8]] + byteToHex[arr[offset + 9]] + "-" + byteToHex[arr[offset + 10]] + byteToHex[arr[offset + 11]] + byteToHex[arr[offset + 12]] + byteToHex[arr[offset + 13]] + byteToHex[arr[offset + 14]] + byteToHex[arr[offset + 15]];
}

// node_modules/uuid/dist/esm-node/native.js
import crypto2 from "crypto";
var native_default = {
  randomUUID: crypto2.randomUUID
};

// node_modules/uuid/dist/esm-node/v4.js
function v4(options, buf, offset) {
  if (native_default.randomUUID && !buf && !options) {
    return native_default.randomUUID();
  }
  options = options || {};
  const rnds = options.random || (options.rng || rng)();
  rnds[6] = rnds[6] & 15 | 64;
  rnds[8] = rnds[8] & 63 | 128;
  if (buf) {
    offset = offset || 0;
    for (let i = 0; i < 16; ++i) {
      buf[offset + i] = rnds[i];
    }
    return buf;
  }
  return unsafeStringify(rnds);
}
var v4_default = v4;

// src/InsaneInt.ts
var InsaneInt = class _InsaneInt {
  startingECount;
  coefficient;
  exponent;
  constructor(startingECount, coefficient, exponent) {
    this.startingECount = startingECount;
    this.coefficient = coefficient;
    this.exponent = exponent;
  }
  static fromString(val) {
    if (val instanceof _InsaneInt) {
      return new _InsaneInt(val.startingECount, val.coefficient, val.exponent);
    }
    let startingECount;
    let coefficient;
    let exponent;
    startingECount = 0;
    while (val.startsWith("e")) {
      startingECount += 1;
      val = val.slice(1);
    }
    if (val.includes("e")) {
      if (val.includes("#")) {
        startingECount += Number(val.split("#")[1]);
        val = val.split("#")[0];
      }
      [coefficient, exponent] = val.split("e").map(Number);
    } else {
      coefficient = Number(val);
      exponent = 0;
    }
    return new _InsaneInt(startingECount, coefficient, exponent);
  }
  toString() {
    let result = "";
    for (let i = 0; i < this.startingECount; i++) {
      result += "e";
    }
    result += this.coefficient;
    if (this.exponent != 0) {
      result += "e" + this.exponent;
    }
    return result;
  }
  greaterThan(other) {
    if (this.startingECount != other.startingECount) {
      return this.startingECount > other.startingECount;
    }
    if (this.exponent != other.exponent) {
      return this.exponent > other.exponent;
    }
    return this.coefficient > other.coefficient;
  }
  equalTo(other) {
    return this.startingECount == other.startingECount && this.exponent == other.exponent && this.coefficient == other.coefficient;
  }
  lessThan(other) {
    return !this.equalTo(other) && !this.greaterThan(other);
  }
  isBalanced() {
    if (this.coefficient == 0 && (this.exponent != 0 || this.startingECount != 0)) return false;
    if (this.exponent == 0 && this.startingECount != 0) return false;
    if (this.coefficient >= 10 && this.exponent > 0 || this.coefficient >= 1e7) return false;
    if (this.coefficient < 1 && this.exponent > 0) return false;
    if (this.exponent > 0 && this.exponent < 1e6 && this.startingECount > 1) return false;
    if (this.exponent >= 1e7) return false;
    if (this.exponent % 1 != 0 || this.startingECount % 1 != 0) return false;
    if (this.exponent > 0 && this.coefficient < 1) return false;
    return true;
  }
  balance() {
    while (!this.isBalanced()) {
      if (this.coefficient === 0) {
        this.exponent = 0;
        this.startingECount = 0;
        return;
      }
      if (this.startingECount > 0 && this.exponent % 1 != 0) {
        const prevECount = this.startingECount;
        this.startingECount = Math.max(this.startingECount - 1, 0);
        this.exponent *= Math.pow(10, prevECount - this.startingECount);
      }
      if (this.exponent % 1 != 0) {
        this.coefficient *= 1 / (this.exponent % 1);
        this.exponent = Math.floor(this.exponent);
      }
      if (this.coefficient >= 10 && this.exponent > 0 || this.coefficient >= 1e7) {
        const change = Math.floor(this.coefficient).toString().length - 1;
        this.coefficient /= Math.pow(10, change);
        this.exponent += change;
      }
      if (this.coefficient < 1 && this.exponent > 0) {
        let change = Math.ceil(Math.log10(1 / this.coefficient));
        if (change >= this.exponent) change = this.exponent - 1;
        this.coefficient *= Math.pow(10, change);
        this.exponent -= change / Math.pow(10, this.startingECount);
      }
      if (this.exponent >= 1e5 && this.startingECount > 0 || this.exponent >= 1e7) {
        const change = Math.floor(this.exponent).toString().length - 5;
        this.exponent /= Math.pow(10, change);
        this.startingECount += change;
      }
      if (this.exponent != 0 && this.exponent < 1e4 && this.startingECount != 0) {
        let change = 5 - Math.floor(this.exponent).toString().length;
        if (change >= this.startingECount) change = this.startingECount - 1;
        this.exponent *= Math.pow(10, change);
        this.startingECount -= change;
      }
    }
    ;
  }
  add(other) {
    this.balance();
    other.balance();
    let startingECount;
    let coefficient;
    let exponent;
    const myStartingECount = this.startingECount;
    let myCoefficient = this.coefficient;
    let myExponent = this.exponent;
    const otherStartingECount = other.startingECount;
    let otherCoefficient = other.coefficient;
    let otherExponent = other.exponent;
    if (myStartingECount > otherStartingECount) {
      otherExponent = otherExponent / Math.pow(10, myStartingECount - otherStartingECount);
      startingECount = myStartingECount;
    } else if (myStartingECount < otherStartingECount) {
      myExponent = myExponent / Math.pow(10, otherStartingECount - myStartingECount);
      startingECount = otherStartingECount;
    } else {
      startingECount = myStartingECount;
    }
    if (myExponent > otherExponent) {
      coefficient = otherCoefficient / Math.pow(10, myExponent - otherExponent) + myCoefficient;
      exponent = myExponent;
    } else if (myExponent < otherExponent) {
      coefficient = myCoefficient / Math.pow(10, otherExponent - myExponent) + otherCoefficient;
      exponent = otherExponent;
    } else {
      coefficient = myCoefficient + otherCoefficient;
      exponent = myExponent;
    }
    let result = new _InsaneInt(startingECount, coefficient, exponent);
    result.balance();
    return result;
  }
  div(other) {
    this.balance();
    other.balance();
    if (other.coefficient === 0) {
      console.error("InsaneInt: tried dividing by 0, returning 0");
      return new _InsaneInt(0, 0, 0);
    }
    ;
    let startingECount = this.startingECount;
    let coefficient = this.coefficient;
    let exponent = this.exponent;
    if (startingECount > other.startingECount) {
      exponent = exponent - other.exponent / Math.pow(10, startingECount - other.startingECount);
      startingECount = this.startingECount;
    } else if (startingECount < other.startingECount) {
      exponent = exponent / Math.pow(10, other.startingECount - startingECount) - other.exponent;
      startingECount = other.startingECount;
    } else {
      exponent -= other.exponent;
    }
    coefficient /= other.coefficient;
    let result = new _InsaneInt(this.startingECount, coefficient, exponent);
    result.balance();
    return result;
  }
};

// stubs/banStore.ts
var startBanAutoReload = (_intervalMs) => {
};
var isBanned = (_ip, _connId) => false;
var addBan = (_kind, _id, _ttlMs, reason) => {
  console.log(`[arena] ignoring ban request (${reason})`);
};

// src/abuse.ts
var num = (env, fallback) => {
  const raw = process.env[env];
  if (raw === void 0) return fallback;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : fallback;
};
var KB = 1024;
var ABUSE_CONFIG = {
  /** Largest single (newline-framed) message we will JSON.parse. The real worst
   *  case is submitLogHashes carrying a full carbon log (tens of KB). */
  MAX_MESSAGE_BYTES: num("ABUSE_MAX_MESSAGE_BYTES", 512 * KB),
  /** Largest the incomplete-message reassembly buffer may grow before we treat
   *  it as a no-newline flood and disconnect. */
  MAX_BUFFER_BYTES: num("ABUSE_MAX_BUFFER_BYTES", 1024 * KB),
  /** Sustained inbound byte budget and its burst allowance (token bucket). */
  BYTE_RATE_PER_SEC: num("ABUSE_BYTE_RATE_PER_SEC", 256 * KB),
  BYTE_BURST: num("ABUSE_BYTE_BURST", 2048 * KB),
  /** Sustained message budget and its burst allowance (token bucket). */
  MSG_RATE_PER_SEC: num("ABUSE_MSG_RATE_PER_SEC", 30),
  MSG_BURST: num("ABUSE_MSG_BURST", 100),
  /** Tier-1 strikes within STRIKE_WINDOW_MS before a Tier-2 disconnect. */
  STRIKE_LIMIT: num("ABUSE_STRIKE_LIMIT", 25),
  STRIKE_WINDOW_MS: num("ABUSE_STRIKE_WINDOW_MS", 1e4),
  /** Tier-2 disconnects (per IP/conn) within DISCONNECT_WINDOW_MS before a ban. */
  DISCONNECTS_BEFORE_BAN: num("ABUSE_DISCONNECTS_BEFORE_BAN", 3),
  DISCONNECT_WINDOW_MS: num("ABUSE_DISCONNECT_WINDOW_MS", 5 * 6e4),
  /** Base temp-ban length; each prior ban for the same id multiplies it. */
  BASE_BAN_MS: num("ABUSE_BASE_BAN_MS", 60 * 6e4),
  MAX_BAN_MS: num("ABUSE_MAX_BAN_MS", 24 * 60 * 6e4),
  /** Min gap between throttle notices sent back to one connection. */
  NOTICE_INTERVAL_MS: num("ABUSE_NOTICE_INTERVAL_MS", 5e3),
  /** When false, Tier-2 (rate) and Tier-3 (ban) are logged but not applied.
   *  Tier-1 message drops and buffer-overflow disconnects always apply. */
  ENFORCE: process.env.ABUSE_ENFORCE !== "false"
};
var TokenBucket = class {
  constructor(ratePerSec, capacity) {
    this.ratePerSec = ratePerSec;
    this.capacity = capacity;
    this.tokens = capacity;
    this.last = Date.now();
  }
  tokens;
  last;
  take(amount) {
    const now = Date.now();
    this.tokens = Math.min(
      this.capacity,
      this.tokens + (now - this.last) / 1e3 * this.ratePerSec
    );
    this.last = now;
    if (this.tokens >= amount) {
      this.tokens -= amount;
      return true;
    }
    this.tokens = 0;
    return false;
  }
};
var disconnectLog = /* @__PURE__ */ new Map();
var banCount = /* @__PURE__ */ new Map();
var noteDisconnectAndMaybeBan = (kind, id, reason) => {
  const key = `${kind}:${id}`;
  const now = Date.now();
  const within = (disconnectLog.get(key) ?? []).filter(
    (t) => now - t < ABUSE_CONFIG.DISCONNECT_WINDOW_MS
  );
  within.push(now);
  disconnectLog.set(key, within);
  if (within.length < ABUSE_CONFIG.DISCONNECTS_BEFORE_BAN) return;
  if (!ABUSE_CONFIG.ENFORCE) {
    console.warn(`[abuse:shadow] would ban ${key} (${reason})`);
    return;
  }
  const priorBans = banCount.get(key) ?? 0;
  const ttl = Math.min(
    ABUSE_CONFIG.BASE_BAN_MS * 2 ** priorBans,
    ABUSE_CONFIG.MAX_BAN_MS
  );
  banCount.set(key, priorBans + 1);
  disconnectLog.delete(key);
  addBan(kind, id, ttl, `auto: ${reason}`);
};
var ConnectionMeter = class {
  /** ip is for logging + ban keying; connId is filled in once the username
   *  action lands (it may be null before then). */
  constructor(ip, connId = null) {
    this.ip = ip;
    this.connId = connId;
  }
  byteBucket = new TokenBucket(
    ABUSE_CONFIG.BYTE_RATE_PER_SEC,
    ABUSE_CONFIG.BYTE_BURST
  );
  msgBucket = new TokenBucket(
    ABUSE_CONFIG.MSG_RATE_PER_SEC,
    ABUSE_CONFIG.MSG_BURST
  );
  strikes = [];
  lastNoticeAt = 0;
  /** Account raw bytes that just arrived on the socket (before reassembly). */
  noteBytes(n) {
    this.byteBucket.take(n);
  }
  /** The reassembly buffer can't be completed and has grown past the cap: a
   *  no-newline flood. Always a disconnect (this is the OOM guard). */
  bufferOverflow() {
    this.recordDisconnect("buffer-overflow flood");
    return { kind: "disconnect", reason: "message too large" };
  }
  /** Decide what to do with one complete, newline-framed message. */
  inspectMessage(byteLen) {
    if (byteLen > ABUSE_CONFIG.MAX_MESSAGE_BYTES) {
      return this.strike("oversized message");
    }
    const bytesOk = this.byteBucket.take(byteLen);
    const msgOk = this.msgBucket.take(1);
    if (!bytesOk || !msgOk) {
      return this.strike(bytesOk ? "message rate" : "byte rate");
    }
    return { kind: "ok" };
  }
  /** Register a Tier-1 strike and escalate to Tier-2 if too many land fast. */
  strike(reason) {
    const now = Date.now();
    this.strikes = this.strikes.filter(
      (t) => now - t < ABUSE_CONFIG.STRIKE_WINDOW_MS
    );
    this.strikes.push(now);
    if (this.strikes.length >= ABUSE_CONFIG.STRIKE_LIMIT) {
      if (ABUSE_CONFIG.ENFORCE) {
        this.recordDisconnect(`strike flood (${reason})`);
        return { kind: "disconnect", reason: "too many invalid messages" };
      }
      console.warn(
        `[abuse:shadow] would disconnect ${this.ip} (strike flood: ${reason})`
      );
    }
    const notify = now - this.lastNoticeAt > ABUSE_CONFIG.NOTICE_INTERVAL_MS;
    if (notify) this.lastNoticeAt = now;
    return { kind: "drop", reason, notify };
  }
  /** Record a Tier-2 disconnect against both identities and maybe ban. */
  recordDisconnect(reason) {
    console.warn(
      `[abuse] disconnecting ip=${this.ip} conn=${this.connId ?? "?"}: ${reason}`
    );
    noteDisconnectAndMaybeBan("ip", this.ip, reason);
    if (this.connId) noteDisconnectAndMaybeBan("conn", this.connId, reason);
  }
};
var parseConnectionId = (modHash) => {
  if (!modHash) return null;
  const match = modHash.match(/serversideConnectionID=([^;]+)/);
  return match ? match[1] : null;
};

// src/Client.ts
var Client = class {
  // Connection info
  id;
  // Could be useful later on to detect reconnects
  address;
  /** Remote peer IP (socket.remoteAddress). Used for abuse metering + bans —
   *  unlike `address`, which is the server's own bound address. */
  remoteAddress;
  /** Client hardware id (serversideConnectionID), parsed out of modHash once the
   *  username action arrives. Used as a second ban key to defeat IP rotation. */
  connectionId = null;
  sendAction;
  closeConnection;
  /** Token used to verify identity when reconnecting to a lobby */
  reconnectToken;
  // Game info
  username = "Guest";
  modHash = "NULL";
  lobby = null;
  isReadyLobby = false;
  /** Whether player is ready for next blind */
  isReady = false;
  firstReady = false;
  lives = 5;
  score = new InsaneInt(0, 0, 0);
  handsLeft = 4;
  /** Whether this player has played a hand in the current blind. Used to
   *  withhold the opponent's score until the player has committed a hand. */
  playedThisBlind = false;
  ante = 1;
  skips = 0;
  furthestBlind = 0;
  /** Guards against a duplicate life loss from the *same* cause firing twice
   *  (e.g. two failRound call sites for one blind failure). Kept separate per
   *  cause so a timer expiry and a blind/round loss can each cost a life even
   *  when they happen within the same round. */
  roundLivesBlocker = false;
  timerLivesBlocker = false;
  location = "loc_selecting";
  isCached = true;
  constructor(address, send, closeConnection, remoteAddress = "") {
    this.id = v4_default();
    this.address = address;
    this.remoteAddress = remoteAddress;
    this.sendAction = send;
    this.closeConnection = closeConnection;
    this.reconnectToken = randomBytes(16).toString("hex");
  }
  setLocation = (location) => {
    this.location = location;
    if (this.lobby) {
      if (this.lobby.host === this) {
        this.lobby.guest?.sendAction({ action: "enemyLocation", location: this.location });
      } else {
        this.lobby.host?.sendAction({ action: "enemyLocation", location: this.location });
      }
    }
  };
  setUsername = (username) => {
    this.username = username;
    this.lobby?.broadcastLobbyInfo();
  };
  setModHash = (modHash) => {
    this.modHash = modHash;
    this.connectionId = parseConnectionId(modHash);
    this.lobby?.broadcastLobbyInfo();
  };
  setLobby = (lobby) => {
    this.lobby = lobby;
  };
  resetBlocker = () => {
    this.roundLivesBlocker = false;
    this.timerLivesBlocker = false;
  };
  /**
   * @param cause 'round' for a blind/PvP-hand loss, 'timer' for an ante/PvP
   * timer expiry. Each cause has its own once-per-round guard, so a timer
   * expiry and a round loss can both cost a life in the same round.
   */
  loseLife = (cause = "round") => {
    const alreadyLost = cause === "timer" ? this.timerLivesBlocker : this.roundLivesBlocker;
    if (alreadyLost) return;
    this.lives -= 1;
    if (cause === "timer") {
      this.timerLivesBlocker = true;
    } else {
      this.roundLivesBlocker = true;
    }
    this.sendAction({ action: "playerInfo", lives: this.lives });
    if (this.lobby && this.lobby.host && this.lobby.guest) {
      const enemy = this.lobby.host === this ? this.lobby.guest : this.lobby.host;
      enemy.sendAction({
        action: "enemyInfo",
        handsLeft: this.handsLeft,
        score: this.score.toString(),
        skips: this.skips,
        lives: this.lives
      });
    }
  };
  setSkips = (skips) => {
    this.skips = skips;
  };
};
var Client_default = Client;

// src/GameMode.ts
var GameModes = {
  attrition: {
    startingLives: 4,
    getBlindFromAnte: (ante, options) => {
      return { boss: "bl_pvp" };
    }
  },
  showdown: {
    startingLives: 2,
    getBlindFromAnte: (ante, options) => {
      const starting_antes = options?.showdown_starting_antes ? parseInt(options.showdown_starting_antes) : 3;
      if (ante <= starting_antes) return {};
      else return { small: "bl_pvp", big: "bl_pvp", boss: "bl_pvp" };
    }
  },
  survival: {
    startingLives: 1,
    getBlindFromAnte: (ante, options) => {
      return {};
    }
  }
};
var GameMode_default = GameModes;

// src/Lobby.ts
var Lobbies = /* @__PURE__ */ new Map();
var generateUniqueLobbyCode = () => {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
  let result = "";
  for (let i = 0; i < 5; i++) {
    result += chars.charAt(Math.floor(Math.random() * chars.length));
  }
  return Lobbies.get(result) ? generateUniqueLobbyCode() : result;
};
var getEnemy = (client) => {
  const lobby = client.lobby;
  if (!lobby) return [null, null];
  if (lobby.host?.id === client.id) {
    return [lobby, lobby.guest];
  } else if (lobby.guest?.id === client.id) {
    return [lobby, lobby.host];
  }
  return [lobby, null];
};
var RECONNECT_GRACE_PERIOD = 6e4;
var Lobby = class {
  code;
  host;
  guest;
  gameMode;
  // biome-ignore lint/suspicious/noExplicitAny:
  options;
  tcgBets;
  handyAllowMPExtension;
  firstReadyAt;
  /** Tracks disconnected players awaiting reconnection */
  disconnectedSlot = null;
  /** Whether a game is currently in progress */
  isInGame = false;
  /** Authoritative seed generated for the current game (null until startGame,
   *  or for different-seeds games where each client uses its own). */
  seed = null;
  // Attrition is the default game mode
  constructor(host, gameMode = "attrition") {
    do {
      this.code = generateUniqueLobbyCode();
    } while (Lobbies.get(this.code));
    Lobbies.set(this.code, this);
    this.host = host;
    this.guest = null;
    this.gameMode = gameMode;
    this.options = {};
    this.tcgBets = /* @__PURE__ */ new Map();
    this.handyAllowMPExtension = /* @__PURE__ */ new Map();
    this.firstReadyAt = null;
    host.setLobby(this);
    host.isReadyLobby = false;
    host.sendAction({
      action: "joinedLobby",
      code: this.code,
      type: this.gameMode,
      reconnectToken: host.reconnectToken
    });
  }
  static get = (code) => {
    return Lobbies.get(code);
  };
  /** Voluntary leave — no grace period */
  leave = (client) => {
    if (this.disconnectedSlot) {
      clearTimeout(this.disconnectedSlot.timer);
      this.disconnectedSlot = null;
    }
    if (this.host?.id === client.id) {
      this.host = this.guest;
      this.guest = null;
    } else if (this.guest?.id === client.id) {
      this.guest = null;
    }
    client.setLobby(null);
    this.isInGame = false;
    const remaining = this.host ?? this.guest;
    if (!remaining) {
      Lobbies.delete(this.code);
    } else {
      if (!this.host && this.guest) {
        this.host = this.guest;
        this.guest = null;
      }
      this.handyAllowMPExtension.delete(client.id);
      this.broadcastAction({ action: "stopGame" });
      this.resetPlayers();
      this.broadcastLobbyInfo();
    }
  };
  /** Connection lost — use grace period if game is in progress */
  disconnect = (client) => {
    const isHost = this.host?.id === client.id;
    const isGuest = this.guest?.id === client.id;
    if (!isHost && !isGuest) return;
    if (!this.isInGame || isHost && !this.guest || isGuest && !this.host) {
      this.leave(client);
      return;
    }
    const role = isHost ? "host" : "guest";
    const enemy = isHost ? this.guest : this.host;
    console.log(`Player ${client.id} disconnected from lobby ${this.code}, reserving slot for ${RECONNECT_GRACE_PERIOD / 1e3}s (saving state: lives=${client.lives}, score=${client.score}, ante=${client.ante})`);
    this.disconnectedSlot = {
      reconnectToken: client.reconnectToken,
      role,
      savedState: {
        lives: client.lives,
        score: client.score,
        handsLeft: client.handsLeft,
        ante: client.ante,
        skips: client.skips,
        furthestBlind: client.furthestBlind,
        isReady: client.isReady,
        firstReady: client.firstReady,
        isReadyLobby: client.isReadyLobby,
        roundLivesBlocker: client.roundLivesBlocker,
        timerLivesBlocker: client.timerLivesBlocker,
        location: client.location,
        username: client.username,
        modHash: client.modHash
      },
      timer: setTimeout(() => {
        console.log(`Reconnect grace period expired for lobby ${this.code}`);
        this.disconnectedSlot = null;
        this.leave(client);
      }, RECONNECT_GRACE_PERIOD)
    };
    if (isHost) {
      this.host = null;
    } else {
      this.guest = null;
    }
    client.setLobby(null);
    enemy?.sendAction({ action: "enemyDisconnected", timeout: RECONNECT_GRACE_PERIOD / 1e3 });
  };
  /** Reconnecting client reclaims their slot */
  rejoin = (newClient, reconnectToken) => {
    if (!this.disconnectedSlot || this.disconnectedSlot.reconnectToken !== reconnectToken) {
      return false;
    }
    const { role, timer, savedState } = this.disconnectedSlot;
    clearTimeout(timer);
    this.disconnectedSlot = null;
    console.log(`Restoring state for ${role} in lobby ${this.code}: lives=${savedState.lives}, score=${savedState.score}, ante=${savedState.ante}, handsLeft=${savedState.handsLeft}, skips=${savedState.skips}, location=${savedState.location}`);
    newClient.lives = savedState.lives;
    newClient.score = savedState.score;
    newClient.handsLeft = savedState.handsLeft;
    newClient.ante = savedState.ante;
    newClient.skips = savedState.skips;
    newClient.furthestBlind = savedState.furthestBlind;
    newClient.isReady = savedState.isReady;
    newClient.firstReady = savedState.firstReady;
    newClient.isReadyLobby = savedState.isReadyLobby;
    newClient.roundLivesBlocker = savedState.roundLivesBlocker;
    newClient.timerLivesBlocker = savedState.timerLivesBlocker;
    newClient.location = savedState.location;
    newClient.username = savedState.username;
    newClient.modHash = savedState.modHash;
    if (role === "host") {
      this.host = newClient;
    } else {
      this.guest = newClient;
    }
    newClient.setLobby(this);
    this.handyAllowMPExtension.set(newClient.id, false);
    newClient.sendAction({
      action: "rejoinedLobby",
      code: this.code,
      type: this.gameMode,
      reconnectToken: newClient.reconnectToken
    });
    const enemy = role === "host" ? this.guest : this.host;
    enemy?.sendAction({ action: "enemyReconnected" });
    this.broadcastLobbyInfo();
    return true;
  };
  join = (client) => {
    if (this.guest) {
      client.sendAction({
        action: "error",
        message: "Lobby is full or does not exist."
      });
      return;
    }
    this.guest = client;
    client.setLobby(this);
    client.isReadyLobby = false;
    this.handyAllowMPExtension.set(client.id, false);
    client.sendAction({
      action: "joinedLobby",
      code: this.code,
      type: this.gameMode,
      reconnectToken: client.reconnectToken
    });
    client.sendAction({ action: "lobbyOptions", gamemode: this.gameMode, ...this.options });
    this.broadcastLobbyInfo();
  };
  broadcastAction = (action) => {
    this.host?.sendAction(action);
    this.guest?.sendAction(action);
  };
  broadcastLobbyInfo = () => {
    if (!this.host) {
      return;
    }
    const action = {
      action: "lobbyInfo",
      host: this.host.username,
      hostHash: this.host.modHash,
      isHost: false,
      hostCached: this.host.isCached
    };
    if (this.guest?.username) {
      action.guest = this.guest.username;
      action.guestHash = this.guest.modHash;
      action.guestCached = this.guest.isCached;
      action.guestReady = this.guest.isReadyLobby;
      this.guest.sendAction(action);
    }
    action.isHost = true;
    this.host.sendAction(action);
    this.broadcastAction({
      action: "handyMPExtensionLobbyEnabled",
      enabled: Array.from(this.handyAllowMPExtension.values()).every(Boolean)
    });
  };
  setPlayersLives = (lives) => {
    if (this.host) this.host.lives = lives;
    if (this.guest) this.guest.lives = lives;
    this.broadcastAction({ action: "playerInfo", lives });
  };
  // Deprecated
  sendGameInfo = (client) => {
    if (this.host !== client && this.guest !== client) {
      return client.sendAction({
        action: "error",
        message: "Client not in Lobby"
      });
    }
    client.sendAction({
      action: "gameInfo",
      ...GameMode_default[this.gameMode].getBlindFromAnte(client.ante, this.options)
    });
  };
  setOptions = (options) => {
    for (const key of Object.keys(options)) {
      if (options[key] === "true" || options[key] === "false") {
        this.options[key] = options[key] === "true";
      } else {
        this.options[key] = options[key];
      }
    }
    this.guest?.sendAction({ action: "lobbyOptions", gamemode: this.gameMode, ...options });
  };
  resetPlayers = () => {
    this.isInGame = false;
    if (this.host) {
      this.host.isReady = false;
      this.host.resetBlocker();
      this.host.setLocation("Blind Select");
      this.host.furthestBlind = 0;
      this.host.skips = 0;
      this.host.score = new InsaneInt(0, 0, 0);
    }
    if (this.guest) {
      this.guest.isReady = false;
      this.guest.resetBlocker();
      this.guest.setLocation("Blind Select");
      this.guest.furthestBlind = 0;
      this.guest.skips = 0;
      this.guest.score = new InsaneInt(0, 0, 0);
    }
    this.tcgBets.clear();
    this.firstReadyAt = null;
  };
};
var Lobby_default = Lobby;

// src/utils.ts
function generateSeed(length = 8) {
  let result = "";
  const characters = "ABCDEFGHIJKLMNPQRSTUVWXYZ123456789";
  const charactersLength = characters.length;
  let counter = 0;
  while (counter < length) {
    result += characters.charAt(Math.floor(Math.random() * charactersLength));
    counter += 1;
  }
  return result;
}

// stubs/logHashStore.ts
var recordLogHashes = (_record) => true;
var recordLiveLogLines = (_input) => {
};
var deleteLiveLog = (_gameId) => {
};

// src/actionHandlers.ts
var TCG_SERVER_VERSION = 1;
var usernameAction = ({ username, modHash }, client) => {
  client.setUsername(username);
  client.setModHash(modHash);
};
var createLobbyAction = ({ gameMode }, client) => {
  new Lobby_default(client, gameMode);
};
var joinLobbyAction = ({ code }, client) => {
  const newLobby = Lobby_default.get(code);
  if (!newLobby) {
    client.sendAction({
      action: "error",
      message: "Lobby does not exist."
    });
    return;
  }
  newLobby.join(client);
};
var leaveLobbyAction = (client) => {
  client.lobby?.leave(client);
};
var disconnectFromLobbyAction = (client) => {
  client.lobby?.disconnect(client);
};
var rejoinLobbyAction = ({ code, reconnectToken }, client) => {
  const lobby = Lobby_default.get(code);
  if (!lobby) {
    client.sendAction({
      action: "error",
      message: "Lobby no longer exists."
    });
    return;
  }
  if (!lobby.rejoin(client, reconnectToken)) {
    client.sendAction({
      action: "error",
      message: "Could not rejoin lobby. Token invalid or slot expired."
    });
  }
};
var lobbyInfoAction = (client) => {
  client.lobby?.broadcastLobbyInfo();
};
var readyLobbyAction = (client) => {
  client.isReadyLobby = true;
  client.lobby?.broadcastLobbyInfo();
};
var unreadyLobbyAction = (client) => {
  client.isReadyLobby = false;
  client.lobby?.broadcastLobbyInfo();
};
var keepAliveAction = (client) => {
  client.sendAction({ action: "keepAliveAck" });
};
var startGameAction = (client) => {
  const lobby = client.lobby;
  if (!lobby || lobby.host?.id !== client.id) {
    return;
  }
  const lives = lobby.options.starting_lives ? Number.parseInt(lobby.options.starting_lives) : GameMode_default[lobby.gameMode].startingLives;
  const seed = lobby.options.different_seeds ? void 0 : generateSeed();
  lobby.seed = seed ?? null;
  lobby.resetPlayers();
  lobby.isInGame = true;
  lobby.broadcastAction({
    action: "startGame",
    deck: "c_multiplayer_1",
    seed
  });
  lobby.setPlayersLives(lives);
  if (lobby.guest) {
    lobby.guest.isReadyLobby = false;
  }
};
var readyBlindAction = (client) => {
  client.isReady = true;
  const [lobby, enemy] = getEnemy(client);
  if (!client.firstReady && !enemy?.isReady && !enemy?.firstReady) {
    client.firstReady = true;
    if (lobby) lobby.firstReadyAt = Date.now();
    client.sendAction({ action: "speedrun" });
  }
  if (client.lobby?.host?.isReady && client.lobby.guest?.isReady) {
    if (lobby?.firstReadyAt && Date.now() - lobby.firstReadyAt <= 3e4) {
      client.sendAction({ action: "speedrun" });
    }
    lobby.firstReadyAt = null;
    client.lobby.host.isReady = false;
    client.lobby.guest.isReady = false;
    client.lobby.host.score = new InsaneInt(0, 0, 0);
    client.lobby.guest.score = new InsaneInt(0, 0, 0);
    client.lobby.host.handsLeft = 4;
    client.lobby.guest.handsLeft = 4;
    client.lobby.host.playedThisBlind = false;
    client.lobby.guest.playedThisBlind = false;
    let firstPlayer;
    if (client.lobby.host.firstReady) firstPlayer = "host";
    if (client.lobby.guest.firstReady) firstPlayer = "guest";
    client.lobby.broadcastAction({ action: "startBlind", firstPlayer });
  }
};
var unreadyBlindAction = (client) => {
  client.isReady = false;
};
var playHandAction = ({ handsLeft, score }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (lobby === null || enemy === null || lobby.host === null || lobby.guest === null) {
    stopGameAction(client);
    return;
  }
  client.score = InsaneInt.fromString(String(score));
  client.handsLeft = typeof handsLeft === "number" ? handsLeft : Number(handsLeft);
  client.handsLeft = Math.floor(client.handsLeft);
  const hideScore = Boolean(lobby.options.hide_score_until_played);
  const playedRealHand = client.score.greaterThan(new InsaneInt(0, 0, 0));
  if (playedRealHand) client.playedThisBlind = true;
  const isHostTurn = lobby.host.score.equalTo(lobby.guest.score) ? lobby.host.firstReady : lobby.host.score.greaterThan(lobby.guest.score);
  if (!hideScore || enemy.playedThisBlind) {
    enemy.sendAction({
      action: "enemyInfo",
      handsLeft,
      score: client.score.toString(),
      skips: client.skips,
      lives: client.lives,
      pvpTimerOrder: isHostTurn ? "host" : "guest"
    });
  } else {
    enemy.sendAction({
      action: "enemyInfo",
      handsLeft,
      score: null,
      skips: client.skips,
      lives: client.lives,
      noScore: true
    });
  }
  if (!hideScore || client.playedThisBlind) {
    client.sendAction({
      action: "enemyInfo",
      handsLeft: enemy.handsLeft,
      score: enemy.score.toString(),
      skips: enemy.skips,
      lives: enemy.lives,
      pvpTimerOrder: isHostTurn ? "host" : "guest"
    });
  } else {
    client.sendAction({
      action: "enemyInfo",
      handsLeft: enemy.handsLeft,
      score: null,
      skips: enemy.skips,
      lives: enemy.lives,
      noScore: true
    });
  }
  if (lobby.guest.handsLeft < 1 && lobby.guest.score.lessThan(lobby.host.score) || lobby.host.handsLeft < 1 && lobby.host.score.lessThan(lobby.guest.score) || lobby.host.handsLeft < 1 && lobby.guest.handsLeft < 1) {
    const roundWinner = lobby.guest.score.lessThan(lobby.host.score) ? lobby.host : lobby.guest;
    const roundLoser = roundWinner.id === lobby.host.id ? lobby.guest : lobby.host;
    if (!lobby.host.score.equalTo(lobby.guest.score)) {
      roundLoser.loseLife("round");
      if (lobby.host.lives <= 0 || lobby.guest.lives <= 0) {
        const gameWinner = lobby.host.lives > lobby.guest.lives ? lobby.host : lobby.guest;
        const gameLoser = gameWinner.id === lobby.host.id ? lobby.guest : lobby.host;
        gameWinner?.sendAction({ action: "winGame" });
        gameLoser?.sendAction({ action: "loseGame" });
        roundWinner.firstReady = false;
        roundLoser.firstReady = false;
        return;
      }
    }
    roundWinner.firstReady = false;
    roundLoser.firstReady = false;
    roundWinner.sendAction({ action: "endPvP", lost: false });
    roundLoser.sendAction({
      action: "endPvP",
      lost: !lobby.guest.score.equalTo(lobby.host.score)
    });
  }
};
var failPvPTimerAction = (client) => {
  const lobby = client.lobby;
  client.loseLife("timer");
  if (!lobby) return;
  if (client.lives === 0) {
    let gameLoser = null;
    let gameWinner = null;
    if (client.id === lobby.host?.id) {
      gameLoser = lobby.host;
      gameWinner = lobby.guest;
    } else {
      gameLoser = lobby.guest;
      gameWinner = lobby.host;
    }
    gameWinner?.sendAction({ action: "winGame" });
    gameLoser?.sendAction({ action: "loseGame" });
  } else {
    let roundWinner;
    let roundLoser;
    if (client.id === lobby.host?.id) {
      roundWinner = lobby.guest;
      roundLoser = lobby.host;
    } else {
      roundWinner = lobby.host;
      roundLoser = lobby.guest;
    }
    roundWinner.firstReady = false;
    roundLoser.firstReady = false;
    roundWinner.sendAction({
      action: "endPvP",
      lost: false,
      pvpTimerLost: true
    });
    roundLoser.sendAction({
      action: "endPvP",
      lost: true,
      pvpTimerLost: true
    });
  }
};
var stopGameAction = (client) => {
  if (!client.lobby) {
    return;
  }
  client.lobby.broadcastAction({ action: "stopGame" });
  client.lobby.resetPlayers();
};
var gameInfoAction = (client) => {
  client.lobby?.sendGameInfo(client);
};
var lobbyOptionsAction = (options, client) => {
  client.lobby?.setOptions(options);
};
var failRoundAction = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  if (lobby.options.death_on_round_loss) {
    client.loseLife("round");
  }
  if (client.lives === 0) {
    if (lobby.gameMode === "survival") {
      if (enemy.lives === 0) {
        if (client.furthestBlind === enemy.furthestBlind) {
          client.sendAction({ action: "winGame" });
          enemy.sendAction({ action: "winGame" });
        } else if (client.furthestBlind < enemy.furthestBlind) {
          client.sendAction({ action: "loseGame" });
          enemy.sendAction({ action: "winGame" });
        }
      } else {
        if (client.furthestBlind < enemy.furthestBlind) {
          client.sendAction({ action: "loseGame" });
          enemy.sendAction({ action: "winGame" });
        }
      }
    } else {
      let gameLoser = null;
      let gameWinner = null;
      if (client.id === lobby.host?.id) {
        gameLoser = lobby.host;
        gameWinner = lobby.guest;
      } else {
        gameLoser = lobby.guest;
        gameWinner = lobby.host;
      }
      gameWinner?.sendAction({ action: "winGame" });
      gameLoser?.sendAction({ action: "loseGame" });
    }
  }
};
var setAnteAction = ({ ante }, client) => {
  client.ante = ante;
};
var serverVersion = "0.3.2-MULTIPLAYER";
var versionAction = ({ version }, client) => {
  const versionMatch = version.match(/^(\d+\.\d+\.\d+)/);
  if (versionMatch) {
    const clientVersion = versionMatch[1];
    const serverVersionNumber = serverVersion.split("-")[0];
    const [clientMajor, clientMinor, clientPatch] = clientVersion.split(".").map(Number);
    const [serverMajor, serverMinor, serverPatch] = serverVersionNumber.split(".").map(Number);
    if (clientMajor < serverMajor || clientMajor === serverMajor && clientMinor < serverMinor || clientMajor === serverMajor && clientMinor === serverMinor && clientPatch < serverPatch) {
      client.sendAction({
        action: "error",
        message: `[WARN] Server expecting version ${serverVersion}`
      });
    }
  }
};
var setLocationAction = ({ location }, client) => {
  client.setLocation(location);
};
var newRoundAction = (client) => {
  client.resetBlocker();
};
var setFurthestBlindAction = ({ furthestBlind }, client) => {
  const [lobby, enemy] = getEnemy(client);
  client.furthestBlind = furthestBlind;
  if (!lobby || !enemy) return;
  if (lobby.gameMode === "survival" && enemy.lives === 0 && client.furthestBlind > enemy.furthestBlind) {
    client.sendAction({ action: "winGame" });
    enemy.sendAction({ action: "loseGame" });
  }
};
var skipAction = ({ skips }, client) => {
  const [lobby, enemy] = getEnemy(client);
  client.setSkips(skips);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "enemyInfo",
    handsLeft: client.handsLeft,
    score: client.score.toString(),
    skips: client.skips,
    lives: client.lives
  });
};
var sendPhantomAction = ({ key }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "sendPhantom",
    key
  });
};
var removePhantomAction = ({ key }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "removePhantom",
    key
  });
};
var asteroidAction = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "asteroid"
  });
};
var letsGoGamblingNemesisAction = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "letsGoGamblingNemesis"
  });
};
var eatPizzaAction = ({ whole }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "eatPizza",
    whole
  });
};
var soldJokerAction = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "soldJoker"
  });
};
var spentLastShopAction = ({ amount }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "spentLastShop",
    amount
  });
};
var magnetAction = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "magnet"
  });
};
var magnetResponseAction = ({ key }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "magnetResponse",
    key
  });
};
var getEndGameJokersAction = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "getEndGameJokers"
  });
};
var receiveEndGameJokersAction = ({ keys }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "receiveEndGameJokers",
    keys
  });
};
var getNemesisDeckAction = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "getNemesisDeck"
  });
};
var receiveNemesisDeckAction = ({ cards }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "receiveNemesisDeck",
    cards
  });
};
var requestNemesisStatsActionHandler = (client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "endGameStatsRequested"
  });
};
var receiveNemesisStatsActionHandler = (stats, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "nemesisEndGameStats",
    ...stats
  });
};
var startAnteTimerAction = ({ time, isPvP }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "startAnteTimer",
    time,
    ...isPvP ? { isPvP: true } : {}
  });
};
var pauseAnteTimerAction = ({ time }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "pauseAnteTimer",
    time
  });
};
var failTimerAction = (client) => {
  const lobby = client.lobby;
  client.loseLife("timer");
  if (!lobby) return;
  if (client.lives === 0) {
    let gameLoser = null;
    let gameWinner = null;
    if (client.id === lobby.host?.id) {
      gameLoser = lobby.host;
      gameWinner = lobby.guest;
    } else {
      gameLoser = lobby.guest;
      gameWinner = lobby.host;
    }
    gameWinner?.sendAction({ action: "winGame" });
    gameLoser?.sendAction({ action: "loseGame" });
  }
};
var syncClientAction = ({ isCached }, client) => {
  client.isCached = isCached;
};
var tcgServerVersionAction = ({ version }, client) => {
  if (version >= TCG_SERVER_VERSION) {
    client.sendAction({ action: "tcg_compatible" });
  }
};
var startTcgBettingAction = (client) => {
  const lobby = client.lobby;
  if (!lobby || lobby.host?.id !== client.id) {
    return;
  }
  lobby.tcgBets.clear();
  lobby.broadcastAction({
    action: "startGame",
    deck: "c_multiplayer_1",
    seed: generateSeed()
  });
};
var tcgBetAction = ({ bet }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  lobby.tcgBets.set(client.id, bet);
  if (!lobby.host || !lobby.guest) return;
  if (!lobby.tcgBets.has(lobby.host.id) || !lobby.tcgBets.has(lobby.guest.id)) {
    return;
  }
  const hostBet = lobby.tcgBets.get(lobby.host.id) ?? 0;
  const guestBet = lobby.tcgBets.get(lobby.guest.id) ?? 0;
  let winner;
  let loser;
  if (hostBet > guestBet) {
    winner = lobby.host;
    loser = lobby.guest;
  } else if (guestBet > hostBet) {
    winner = lobby.guest;
    loser = lobby.host;
  } else {
    if (Math.random() < 0.5) {
      winner = lobby.host;
      loser = lobby.guest;
    } else {
      winner = lobby.guest;
      loser = lobby.host;
    }
  }
  const winnerBet = lobby.tcgBets.get(winner.id) ?? 0;
  winner.sendAction({
    action: "tcgStartGame",
    damage: winnerBet,
    starting: true
  });
  loser.sendAction({
    action: "tcgStartGame",
    damage: 0,
    starting: false
  });
  lobby.tcgBets.clear();
};
var tcgPlayerStatusAction = (args, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "tcgPlayerStatus",
    ...args
  });
};
var tcgEndTurnAction = (args, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "tcgStartTurn",
    ...args
  });
};
var moddedAction = (args, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  const target = args.target;
  const { target: _, ...rest } = args;
  const from = lobby.host?.id === client.id ? "host" : "guest";
  const message = { action: "moddedAction", from, ...rest };
  const relayTarget = target ?? "nemesis";
  if (relayTarget === "all") {
    lobby.broadcastAction(message);
  } else {
    enemy.sendAction(message);
  }
};
var handyMPExtensionEnable = (args, client) => {
  if (!client.lobby) return;
  client.lobby.handyAllowMPExtension.set(client.id, true);
  client.lobby.broadcastLobbyInfo();
};
var handyMPExtensionDisable = (args, client) => {
  if (!client.lobby) return;
  client.lobby.handyAllowMPExtension.set(client.id, false);
  client.lobby.broadcastLobbyInfo();
};
var submitLogHashesAction = ({ carbon, human, seed, log, gameId }, client) => {
  const lobby = client.lobby;
  const complete = recordLogHashes({
    lobbyCode: lobby?.code ?? null,
    serverSeed: lobby?.seed ?? null,
    claimedSeed: seed ?? null,
    gameMode: lobby?.gameMode ?? null,
    username: client.username ?? null,
    modHash: client.modHash ?? null,
    isHost: lobby?.host?.id === client.id,
    carbonHash: carbon,
    humanHash: human,
    carbonLog: log ?? null
  });
  if (complete && gameId) deleteLiveLog(gameId);
};
var streamLogLinesAction = ({ gameId, lines }, client) => {
  recordLiveLogLines({
    clientId: client.id,
    gameId,
    lobbyCode: client.lobby?.code ?? null,
    username: client.username ?? null,
    lines
  });
};
var dataSyncAction = ({ timer }, client) => {
  const [lobby, enemy] = getEnemy(client);
  if (!lobby || !enemy) return;
  enemy.sendAction({
    action: "dataSync",
    timer: Number.isNaN(timer) ? void 0 : Number(timer)
  });
};
var actionHandlers = {
  username: usernameAction,
  createLobby: createLobbyAction,
  joinLobby: joinLobbyAction,
  rejoinLobby: rejoinLobbyAction,
  lobbyInfo: lobbyInfoAction,
  leaveLobby: leaveLobbyAction,
  readyLobby: readyLobbyAction,
  unreadyLobby: unreadyLobbyAction,
  keepAlive: keepAliveAction,
  startGame: startGameAction,
  readyBlind: readyBlindAction,
  unreadyBlind: unreadyBlindAction,
  playHand: playHandAction,
  stopGame: stopGameAction,
  gameInfo: gameInfoAction,
  lobbyOptions: lobbyOptionsAction,
  failRound: failRoundAction,
  setAnte: setAnteAction,
  version: versionAction,
  setLocation: setLocationAction,
  newRound: newRoundAction,
  setFurthestBlind: setFurthestBlindAction,
  skip: skipAction,
  sendPhantom: sendPhantomAction,
  removePhantom: removePhantomAction,
  asteroid: asteroidAction,
  letsGoGamblingNemesis: letsGoGamblingNemesisAction,
  eatPizza: eatPizzaAction,
  soldJoker: soldJokerAction,
  spentLastShop: spentLastShopAction,
  magnet: magnetAction,
  magnetResponse: magnetResponseAction,
  getEndGameJokers: getEndGameJokersAction,
  receiveEndGameJokers: receiveEndGameJokersAction,
  getNemesisDeck: getNemesisDeckAction,
  receiveNemesisDeck: receiveNemesisDeckAction,
  endGameStatsRequested: requestNemesisStatsActionHandler,
  nemesisEndGameStats: receiveNemesisStatsActionHandler,
  startAnteTimer: startAnteTimerAction,
  pauseAnteTimer: pauseAnteTimerAction,
  failTimer: failTimerAction,
  syncClient: syncClientAction,
  submitLogHashes: submitLogHashesAction,
  streamLogLines: streamLogLinesAction,
  tcgServerVersion: tcgServerVersionAction,
  startTcgBetting: startTcgBettingAction,
  tcgBet: tcgBetAction,
  tcgPlayerStatus: tcgPlayerStatusAction,
  tcgEndTurn: tcgEndTurnAction,
  moddedAction,
  handyMPExtensionEnable,
  handyMPExtensionDisable,
  failPvPTimer: failPvPTimerAction,
  dataSync: dataSyncAction
};

// src/main.ts
import { verify as cryptoVerify, createPublicKey } from "node:crypto";
import { readFileSync, existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
var PORT = Number(process.env.PORT) || 8788;
var MAX_MESSAGE_BUFFER_BYTES = Number(process.env.MAX_MESSAGE_BUFFER_BYTES) || 4 * 1024 * 1024;
var KEEP_ALIVE_INITIAL_TIMEOUT = 15e3;
var KEEP_ALIVE_RETRY_TIMEOUT = 5e3;
var KEEP_ALIVE_RETRY_COUNT = 4;
BigInt.prototype.toJSON = function() {
  return this.toString();
};
var serializeAction = (action) => {
  const entries = Object.entries(action);
  const parts = entries.filter(([_key, value]) => value !== void 0 && value !== null).map(([key, value]) => `${key}:${value}`);
  return parts.join(",");
};
var sendActionToSocket = (socket) => (action) => {
  if (!socket || socket.destroyed) {
    return;
  }
  const data = JSON.stringify(action);
  const { action: actionName, ...actionArgs } = action;
  if (actionName !== "keepAlive" && actionName !== "keepAliveAck") {
    console.log(
      `${(/* @__PURE__ */ new Date()).toISOString()}: Sent action ${actionName} to client: ${JSON.stringify(actionArgs)}`
    );
  }
  socket.write(`${data}
`);
};
var server = createServer((socket) => {
  socket.allowHalfOpen = false;
  socket.setNoDelay();
  socket.setKeepAlive(true, 1e4);
  const remoteAddress = socket.remoteAddress ?? "";
  if (isBanned(remoteAddress, null)) {
    sendActionToSocket(socket)({ action: "error", message: "Unknown Error." });
    socket.end();
    return;
  }
  const client = new Client_default(
    socket.address(),
    sendActionToSocket(socket),
    socket.end,
    remoteAddress
  );
  client.sendAction({ action: "connected" });
  client.sendAction({ action: "version" });
  const meter = new ConnectionMeter(remoteAddress);
  let dataBuffer = "";
  let isRetry = false;
  let retryCount = 0;
  const retryTimer = setTimeout(() => {
    if (!isRetry) {
      return;
    }
    client.sendAction({ action: "keepAlive" });
    retryCount++;
    if (retryCount >= KEEP_ALIVE_RETRY_COUNT) {
      socket.end();
    } else {
      retryTimer.refresh();
    }
  }, KEEP_ALIVE_RETRY_TIMEOUT);
  const keepAlive = setTimeout(() => {
    client.sendAction({ action: "keepAlive" });
    isRetry = true;
    retryTimer.refresh();
  }, KEEP_ALIVE_INITIAL_TIMEOUT);
  socket.on("data", (data) => {
    isRetry = false;
    retryCount = 0;
    keepAlive.refresh();
    meter.noteBytes(data.length);
    dataBuffer += data.toString();
    if (dataBuffer.length > MAX_MESSAGE_BUFFER_BYTES) {
      console.warn(
        `Message buffer exceeded ${MAX_MESSAGE_BUFFER_BYTES} bytes from ${client.id}; dropping connection`
      );
      dataBuffer = "";
      socket.end();
      return;
    }
    const messages = dataBuffer.split("\n");
    dataBuffer = messages.pop() ?? "";
    if (dataBuffer.length > ABUSE_CONFIG.MAX_BUFFER_BYTES) {
      const verdict = meter.bufferOverflow();
      client.sendAction({ action: "error", message: verdict.reason });
      dataBuffer = "";
      socket.end();
      return;
    }
    for (const msg of messages) {
      if (!msg) continue;
      const verdict = meter.inspectMessage(Buffer.byteLength(msg));
      if (verdict.kind === "disconnect") {
        client.sendAction({ action: "error", message: verdict.reason });
        socket.end();
        return;
      }
      if (verdict.kind === "drop") {
        if (verdict.notify) {
          client.sendAction({
            action: "error",
            message: "Rate limit exceeded; message dropped."
          });
        }
        continue;
      }
      try {
        const message = JSON.parse(msg);
        const { action, ...actionArgs } = message;
        if (action !== "keepAlive" && action !== "keepAliveAck") {
          const logged = action === "submitLogHashes" ? JSON.stringify({
            carbon: actionArgs.carbon,
            human: actionArgs.human,
            seed: actionArgs.seed,
            logBytes: actionArgs.log?.length ?? 0
          }) : action === "streamLogLines" ? JSON.stringify({
            gameId: actionArgs.gameId,
            lineCount: actionArgs.lines?.length ?? 0
          }) : JSON.stringify(actionArgs);
          console.log(
            `${(/* @__PURE__ */ new Date()).toISOString()}: Received action ${action} from ${client.id}: ${logged}`
          );
        }
        switch (action) {
          case "setLocation":
            actionHandlers.setLocation(
              actionArgs,
              client
            );
            break;
          case "version":
            actionHandlers.version(
              actionArgs,
              client
            );
            break;
          case "username":
            actionHandlers.username(
              actionArgs,
              client
            );
            break;
          case "createLobby":
            actionHandlers.createLobby(
              actionArgs,
              client
            );
            break;
          case "joinLobby":
            actionHandlers.joinLobby(
              actionArgs,
              client
            );
            break;
          case "rejoinLobby":
            actionHandlers.rejoinLobby(
              actionArgs,
              client
            );
            break;
          case "lobbyInfo":
            actionHandlers.lobbyInfo(client);
            break;
          case "leaveLobby":
            actionHandlers.leaveLobby(client);
            break;
          case "readyLobby":
            actionHandlers.readyLobby(client);
            break;
          case "unreadyLobby":
            actionHandlers.unreadyLobby(client);
            break;
          case "startGame":
            actionHandlers.startGame(client);
            break;
          case "readyBlind":
            actionHandlers.readyBlind(client);
            break;
          case "unreadyBlind":
            actionHandlers.unreadyBlind(client);
            break;
          case "keepAlive":
            actionHandlers.keepAlive(client);
            break;
          case "playHand":
            actionHandlers.playHand(
              actionArgs,
              client
            );
            break;
          case "stopGame":
            actionHandlers.stopGame(client);
            break;
          // Deprecated
          case "gameInfo":
            actionHandlers.gameInfo(client);
            break;
          case "lobbyOptions":
            actionHandlers.lobbyOptions(
              actionArgs,
              client
            );
            break;
          case "newRound":
            actionHandlers.newRound(client);
            break;
          case "failRound":
            actionHandlers.failRound(client);
            break;
          case "setAnte":
            actionHandlers.setAnte(
              actionArgs,
              client
            );
            break;
          case "setFurthestBlind":
            actionHandlers.setFurthestBlind(
              actionArgs,
              client
            );
            break;
          case "skip":
            actionHandlers.skip(
              actionArgs,
              client
            );
            break;
          case "sendPhantom":
            actionHandlers.sendPhantom(
              actionArgs,
              client
            );
            break;
          case "removePhantom":
            actionHandlers.removePhantom(
              actionArgs,
              client
            );
            break;
          case "asteroid":
            actionHandlers.asteroid(client);
            break;
          case "letsGoGamblingNemesis":
            actionHandlers.letsGoGamblingNemesis(client);
            break;
          case "eatPizza":
            actionHandlers.eatPizza(
              actionArgs,
              client
            );
            break;
          case "soldJoker":
            actionHandlers.soldJoker(client);
            break;
          case "spentLastShop":
            actionHandlers.spentLastShop(
              actionArgs,
              client
            );
            break;
          case "magnet":
            actionHandlers.magnet(client);
            break;
          case "magnetResponse":
            actionHandlers.magnetResponse(
              actionArgs,
              client
            );
            break;
          case "getEndGameJokers":
            actionHandlers.getEndGameJokers(client);
            break;
          case "receiveEndGameJokers":
            actionHandlers.receiveEndGameJokers(
              actionArgs,
              client
            );
            break;
          case "getNemesisDeck":
            actionHandlers.getNemesisDeck(client);
            break;
          case "receiveNemesisDeck":
            actionHandlers.receiveNemesisDeck(
              actionArgs,
              client
            );
            break;
          case "startAnteTimer":
            actionHandlers.startAnteTimer(
              actionArgs,
              client
            );
            break;
          case "pauseAnteTimer":
            actionHandlers.pauseAnteTimer(
              actionArgs,
              client
            );
            break;
          case "failTimer":
            actionHandlers.failTimer(client);
            break;
          case "failPvPTimer":
            actionHandlers.failPvPTimer(client);
            break;
          case "syncClient":
            actionHandlers.syncClient(
              actionArgs,
              client
            );
            break;
          case "submitLogHashes":
            actionHandlers.submitLogHashes(
              actionArgs,
              client
            );
            break;
          case "streamLogLines":
            actionHandlers.streamLogLines(
              actionArgs,
              client
            );
            break;
          case "endGameStatsRequested":
            actionHandlers.endGameStatsRequested(client);
            break;
          case "nemesisEndGameStats":
            actionHandlers.nemesisEndGameStats(
              actionArgs,
              client
            );
            break;
          case "tcgServerVersion":
            actionHandlers.tcgServerVersion(
              actionArgs,
              client
            );
            break;
          case "startTcgBetting":
            actionHandlers.startTcgBetting(client);
            break;
          case "tcgBet":
            actionHandlers.tcgBet(
              actionArgs,
              client
            );
            break;
          case "tcgPlayerStatus":
            actionHandlers.tcgPlayerStatus(
              actionArgs,
              client
            );
            break;
          case "tcgEndTurn":
            actionHandlers.tcgEndTurn(
              actionArgs,
              client
            );
            break;
          case "moddedAction":
            actionHandlers.moddedAction(
              actionArgs,
              client
            );
            break;
          case "dataSync":
            actionHandlers.dataSync(
              actionArgs,
              client
            );
            break;
          case "handyMPExtensionEnable":
            actionHandlers.handyMPExtensionEnable(
              actionArgs,
              client
            );
            break;
          case "handyMPExtensionDisable":
            actionHandlers.handyMPExtensionDisable(
              actionArgs,
              client
            );
            break;
        }
      } catch (error) {
        const failedToParseError = "Failed to parse message";
        console.error(failedToParseError, error);
        client.sendAction({
          action: "error",
          message: failedToParseError
        });
      }
      if (client.connectionId && meter.connId !== client.connectionId) {
        meter.connId = client.connectionId;
        if (isBanned(client.remoteAddress, client.connectionId)) {
          client.sendAction({ action: "error", message: "Unknown Error" });
          socket.end();
          return;
        }
      }
    }
  });
  socket.on("end", () => {
    console.log(`Client disconnected ${client.id}`);
    disconnectFromLobbyAction(client);
  });
  socket.on(
    "error",
    (err) => {
      if (err.code === "ECONNRESET") {
        console.warn("TCP connection reset by peer (client).");
      } else {
        console.error("An unexpected error occurred:", err);
      }
      disconnectFromLobbyAction(client);
    }
  );
});
server.listen(PORT, process.env.HOST || "127.0.0.1", () => {
  console.log(`Server listening on port ${PORT}`);
  startBanAutoReload();
});
var ADMIN_PORT = Number(process.env.ADMIN_PORT) || 8789;
var scriptDir = typeof __dirname !== "undefined" ? __dirname : dirname(fileURLToPath(import.meta.url));
var ADMIN_PUBLIC_KEY_PATH = resolve(scriptDir, "..", ".github", "admin_public.pem");
var adminPublicKey = existsSync(ADMIN_PUBLIC_KEY_PATH) ? createPublicKey(readFileSync(ADMIN_PUBLIC_KEY_PATH, "utf-8")) : null;
if (!adminPublicKey) {
  console.warn("WARNING: admin_public.pem not found, admin server will reject all requests");
}
var verifyAdminSignature = (payload, signature) => {
  if (!adminPublicKey) return false;
  try {
    return cryptoVerify(null, Buffer.from(payload), adminPublicKey, Buffer.from(signature, "base64"));
  } catch {
    return false;
  }
};
var sendToTargets = (lobby_code, is_host, action) => {
  let recipients = 0;
  if (lobby_code) {
    const lobby = Lobbies.get(lobby_code);
    if (!lobby) return { success: false, error: "Lobby not found" };
    if (is_host === true) {
      if (lobby.host) {
        lobby.host.sendAction(action);
        recipients++;
      }
    } else if (is_host === false) {
      if (lobby.guest) {
        lobby.guest.sendAction(action);
        recipients++;
      }
    } else {
      if (lobby.host) {
        lobby.host.sendAction(action);
        recipients++;
      }
      if (lobby.guest) {
        lobby.guest.sendAction(action);
        recipients++;
      }
    }
  } else {
    for (const lobby of Lobbies.values()) {
      if (lobby.host) {
        lobby.host.sendAction(action);
        recipients++;
      }
      if (lobby.guest) {
        lobby.guest.sendAction(action);
        recipients++;
      }
    }
  }
  return { success: true, recipients };
};
var adminHandlers = {
  message(parsed, socket) {
    const { message, lobby_code, is_host } = parsed;
    if (!message || typeof message !== "string") {
      socket.end(JSON.stringify({ success: false, error: "Missing message" }) + "\n");
      return;
    }
    const result = sendToTargets(lobby_code, is_host, { action: "error", message });
    socket.end(JSON.stringify(result) + "\n");
  },
  jimboAppear(parsed, socket) {
    const { pos, text, lobby_code, is_host } = parsed;
    if (typeof pos !== "number" || pos < 1 || pos > 4) {
      socket.end(JSON.stringify({ success: false, error: "pos must be a number 1-4" }) + "\n");
      return;
    }
    if (text !== void 0 && typeof text !== "string") {
      socket.end(JSON.stringify({ success: false, error: "text must be a string" }) + "\n");
      return;
    }
    const result = sendToTargets(lobby_code, is_host, { action: "jimboAppear", pos, text });
    socket.end(JSON.stringify(result) + "\n");
  },
  jimboTalk(parsed, socket) {
    const { text, lobby_code, is_host } = parsed;
    if (!text || typeof text !== "string") {
      socket.end(JSON.stringify({ success: false, error: "Missing text" }) + "\n");
      return;
    }
    const result = sendToTargets(lobby_code, is_host, { action: "jimboTalk", text });
    socket.end(JSON.stringify(result) + "\n");
  },
  jimboMove(parsed, socket) {
    const { pos, lobby_code, is_host } = parsed;
    if (typeof pos !== "number" || pos < 1 || pos > 4) {
      socket.end(JSON.stringify({ success: false, error: "pos must be a number 1-4" }) + "\n");
      return;
    }
    const result = sendToTargets(lobby_code, is_host, { action: "jimboMove", pos });
    socket.end(JSON.stringify(result) + "\n");
  },
  jimboRemove(parsed, socket) {
    const { lobby_code, is_host } = parsed;
    const result = sendToTargets(lobby_code, is_host, { action: "jimboRemove" });
    socket.end(JSON.stringify(result) + "\n");
  },
  listLobbies(_parsed, socket) {
    const lobbies = [];
    for (const [code, lobby] of Lobbies.entries()) {
      const host = lobby.host?.username ?? "???";
      const guest = lobby.guest?.username;
      lobbies.push(guest ? `${code} - ${host}, ${guest}` : `${code} - ${host}`);
    }
    socket.end(JSON.stringify({ success: true, count: lobbies.length, lobbies }) + "\n");
  }
};
var adminServer = createServer((socket) => {
  socket.on("data", (data) => {
    const messages = data.toString().split("\n");
    for (const msg of messages) {
      if (!msg) continue;
      try {
        const envelope = JSON.parse(msg);
        const { payload, signature } = envelope;
        if (!payload || !signature) {
          socket.end(JSON.stringify({ success: false, error: "Missing payload or signature" }) + "\n");
          return;
        }
        if (!verifyAdminSignature(payload, signature)) {
          socket.end(JSON.stringify({ success: false, error: "Invalid signature" }) + "\n");
          return;
        }
        const parsed = JSON.parse(payload);
        const command = parsed.command ?? "message";
        const handler = adminHandlers[command];
        if (!handler) {
          socket.end(JSON.stringify({ success: false, error: `Unknown command: ${command}` }) + "\n");
          return;
        }
        handler(parsed, socket);
      } catch (error) {
        socket.end(JSON.stringify({ success: false, error: "Invalid JSON" }) + "\n");
      }
    }
  });
});
adminServer.listen(ADMIN_PORT, "127.0.0.1", () => {
  console.log(`Admin server listening on 127.0.0.1:${ADMIN_PORT}`);
});
export {
  serializeAction
};
