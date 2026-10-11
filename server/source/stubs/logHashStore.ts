// Arena stub: the official relay stores replay-log hashes in SQLite. Not needed locally.
export interface LogHashRecord { [k: string]: unknown }
export interface LiveLogInput { [k: string]: unknown }
export const recordLogHashes = (_record: LogHashRecord): boolean => true;
export const recordLiveLogLines = (_input: LiveLogInput): void => {};
export const deleteLiveLog = (_gameId: string | null | undefined): void => {};
