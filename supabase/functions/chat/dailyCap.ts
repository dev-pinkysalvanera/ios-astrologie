/**
 * Global daily cap on Gemini calls, across all users.
 *
 * The rate limit is per user and the turn cap per session, and anonymous
 * sign-in makes both cheap to multiply: a script can mint users, each with a
 * fresh limit. This is the one count nobody can reset from the client.
 *
 * Production uses `createPostgresDailyCap`, backed by `chat_daily_usage` (see
 * `supabase/migrations/20261012000000_create_chat_daily_usage.sql`).
 * `createInMemoryDailyCap` is a test fake with the same semantics.
 *
 * Semantics (identical in both): every call increments today's count (UTC),
 * and the call is allowed while the new count is ≤ the cap. Calls past the cap
 * still count, which only matters for the record; the day's answer is already
 * "no".
 */

import { LimitStoreError, type RpcCaller } from "./limitStore.ts";

/** Default calls per UTC day. Override with the CHAT_DAILY_CAP function secret. */
export const DEFAULT_DAILY_CAP = 200;

/** Result of a daily-cap check. */
export type DailyCapResult =
  | { allowed: true; calls: number }
  | { allowed: false; calls: number };

/** Increments and checks today's count. Throws `LimitStoreError` if the store is down. */
export type DailyCap = () => Promise<DailyCapResult>;

/**
 * The cap to enforce: CHAT_DAILY_CAP when it's a positive whole number,
 * otherwise the default. Read per call so a changed secret applies without a
 * code change.
 */
export function dailyCapLimit(env: (key: string) => string | undefined): number {
  const raw = env("CHAT_DAILY_CAP");
  const parsed = raw === undefined ? Number.NaN : Number(raw);
  if (Number.isInteger(parsed) && parsed > 0) return parsed;
  if (raw !== undefined) {
    console.warn("[chat] ignoring invalid CHAT_DAILY_CAP:", raw);
  }
  return DEFAULT_DAILY_CAP;
}

function toResult(calls: number, cap: number): DailyCapResult {
  return calls > cap ? { allowed: false, calls } : { allowed: true, calls };
}

/** Store-backed cap. The increment is one atomic upsert in `chat_increment_daily_calls`. */
export function createPostgresDailyCap(
  rpc: RpcCaller,
  env: (key: string) => string | undefined,
): DailyCap {
  return async () => {
    const data = await rpc("chat_increment_daily_calls", {});
    // A scalar-returning function comes back from PostgREST as the bare value.
    const calls = typeof data === "number" ? data : Number.NaN;
    if (!Number.isInteger(calls) || calls < 1) {
      throw new LimitStoreError(
        `chat_increment_daily_calls returned an unexpected value: ${
          JSON.stringify(data)
        }`,
      );
    }
    return toResult(calls, dailyCapLimit(env));
  };
}

/** Per-instance cap for tests. Not for production: see the header. */
export function createInMemoryDailyCap(cap: number = DEFAULT_DAILY_CAP): DailyCap {
  let calls = 0;
  return () => {
    calls += 1;
    return Promise.resolve(toResult(calls, cap));
  };
}
