// Arena stub: the official relay persists bans in SQLite (better-sqlite3, a native
// module). The local arena never bans anyone, so this is an in-memory no-op version
// with the same exports. Replaces src/banStore.ts at bundle time.
export type BanKind = "ip" | "conn";
export const startBanAutoReload = (_intervalMs?: number): void => {};
export const isBanned = (_ip: string | undefined, _connId: string | null): boolean => false;
export const addBan = (_kind: BanKind, _id: string, _ttlMs: number, reason: string): void => {
	console.log(`[arena] ignoring ban request (${reason})`);
};
