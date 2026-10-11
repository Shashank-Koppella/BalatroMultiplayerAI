# Local arena server – source

`arena-server.mjs` is a bundle of the official Balatro Multiplayer relay server
(https://github.com/Balatro-Multiplayer/balatromultiplayerapi-server, commit d664c29, GPL-3.0, see LICENSE-SERVER.md)
with two modifications, both visible in `source/`:

* `source/stubs/banStore.ts` and `source/stubs/logHashStore.ts` replace the SQLite-backed stores with in-memory no-ops
  (no native modules needed, nothing is persisted).
* `source/build.mjs` rewrites the listen address from `0.0.0.0` to `process.env.HOST || '127.0.0.1'`, so the server
  is only reachable from this PC unless you set `server.host` yourself.

Everything else in `source/src/` is unmodified upstream code. To rebuild:

    cd source && npm install && node build.mjs     # writes dist/arena-server.mjs

(`arena.js` sets the anti-abuse limits it needs through environment variables, see `lib/server.js`.)
