/**
 * Sliding-window rate limiter, keyed by any string.
 *
 * The handler keys it per user (`rateLimitKey` in handler.ts). It used to be
 * keyed per session, which a client could reset by picking a new session id.
 *
 * Production uses `createPostgresRateLimiter`, which keeps the window in a
 * shared Postgres table so every edge-function isolate sees the same count.
 * The old per-isolate `Map` never enforced anything in production — requests
 * spread across isolates that each started empty — so it survives only as
 * `createInMemoryRateLimiter`, a test fake with the same semantics.
 *
 * Semantics (identical in both): requests inside the window are counted; once
 * the max is hit, further requests are rejected — and not recorded — until the
 * oldest one ages out of the window.
 */

import { LimitStoreError, type RpcCaller } from "./limitStore.ts";

/** Configuration for the rate limiter. */
export interface RateLimitConfig {
  /** Maximum requests allowed within the window. */
  maxRequests: number;
  /** Window size in milliseconds. */
  windowMs: number;
}

/** Result of a rate-limit check. */
export type RateLimitResult =
  | { allowed: true }
  | { allowed: false; retryAfterMs: number };

/** Checks and records one request for `key`. Throws `LimitStoreError` if the store is down. */
export type RateLimiter = (key: string) => Promise<RateLimitResult>;

/** Default configuration: 20 requests per 60-second window. */
export const DEFAULT_RATE_LIMIT_CONFIG: RateLimitConfig = {
  maxRequests: 20,
  windowMs: 60_000,
};

/**
 * Reports: 10 per hour per user (Week 10 Task 8).
 *
 * Much tighter than chat. A person reports the odd reply, not dozens, and each
 * report can store up to 64 KB of text, so the chat limit would still let one
 * token fill the table quickly.
 */
export const REPORT_RATE_LIMIT_CONFIG: RateLimitConfig = {
  maxRequests: 10,
  windowMs: 60 * 60_000,
};

/**
 * Store-backed limiter. The prune/count/record step runs inside
 * `chat_check_rate_limit` under a row lock, so concurrent isolates can't both
 * slip in under the limit.
 */
export function createPostgresRateLimiter(
  rpc: RpcCaller,
  config: RateLimitConfig = DEFAULT_RATE_LIMIT_CONFIG,
): RateLimiter {
  return async (key) => {
    const data = await rpc("chat_check_rate_limit", {
      // The SQL parameter predates per-user keys; it takes any string.
      p_session_id: key,
      p_max_requests: config.maxRequests,
      p_window_ms: config.windowMs,
    });

    // A RETURNS TABLE function comes back from PostgREST as a one-row array.
    const row = Array.isArray(data) ? data[0] : data;
    if (typeof row !== "object" || row === null || typeof row.allowed !== "boolean") {
      throw new LimitStoreError(
        `chat_check_rate_limit returned an unexpected shape: ${JSON.stringify(data)}`,
      );
    }
    if (row.allowed) return { allowed: true };

    const retry = Number(row.retry_after_ms);
    return {
      allowed: false,
      retryAfterMs: Number.isFinite(retry) && retry > 0 ? retry : 1,
    };
  };
}

/**
 * Per-instance limiter for tests. Each call creates an independent store, so
 * tests can't leak state into each other. Not for production: see the header.
 */
export function createInMemoryRateLimiter(
  config: RateLimitConfig = DEFAULT_RATE_LIMIT_CONFIG,
  now: () => number = Date.now,
): RateLimiter {
  const store = new Map<string, number[]>();

  return (key) => {
    const t = now();
    const windowStart = t - config.windowMs;
    const timestamps = (store.get(key) ?? []).filter((ts) => ts > windowStart);

    if (timestamps.length >= config.maxRequests) {
      store.set(key, timestamps);
      const retryAfterMs = timestamps[0] + config.windowMs - t;
      return Promise.resolve({ allowed: false, retryAfterMs: Math.max(retryAfterMs, 1) });
    }

    timestamps.push(t);
    store.set(key, timestamps);
    return Promise.resolve({ allowed: true });
  };
}
