// Bundles the official Balatro Multiplayer relay (GPL-3.0) into a single dependency-free
// file for local use: SQLite stores are swapped for in-memory stubs and the listen address
// is restricted to loopback (override with HOST=0.0.0.0 if you really want LAN access).
import { build } from "esbuild";
import { readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const stubs = {
	"banStore.js": resolve(here, "stubs/banStore.ts"),
	"logHashStore.js": resolve(here, "stubs/logHashStore.ts"),
};

const plugin = {
	name: "arena-patches",
	setup(b) {
		b.onResolve({ filter: /^\.\/(banStore|logHashStore)\.js$/ }, (args) => {
			const key = args.path.slice(2);
			return { path: stubs[key] };
		});
		b.onLoad({ filter: /src[\\/]main\.ts$/ }, (args) => {
			let src = readFileSync(args.path, "utf8");
			const before = src;
			src = src.replace("server.listen(PORT, '0.0.0.0',", "server.listen(PORT, process.env.HOST || '127.0.0.1',");
			if (src === before) throw new Error("main.ts listen() patch did not apply - server source changed?");
			return { contents: src, loader: "ts" };
		});
	},
};

await build({
	entryPoints: [resolve(here, "src/main.ts")],
	bundle: true,
	platform: "node",
	target: "node18",
	format: "esm",
	outfile: resolve(here, "dist/arena-server.mjs"),
	plugins: [plugin],
	banner: { js: "// Local arena build of BalatroMultiplayerAPI-Server (GPL-3.0). See LICENSE-SERVER.md\nimport { createRequire as __cr } from \"node:module\"; const require = __cr(import.meta.url);" },
	logLevel: "info",
});
