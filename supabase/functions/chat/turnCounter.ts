/**
 * Per-session conversation turn cap.
 *
 * Production uses `createPostgresTurnCounter`, backed by a shared Postgres
 * table so the count survives isolate hops and restarts. The old per-isolate
 * `Map` meant the 20-turn 403 never fired in production; it survives only as
 * `createInMemoryTurnCounter`, a test fake with the same semantics.
 *
 * Semantics (identical in both): every call increments the session's count,
 * and the call is allowed while the new count is ≤ `maxTurns`. There is no
 * expiry — a capped session stays capped, and the client starts a new
 * `sessionId` to continue (Week 7's reset button).
 */

import { LimitStoreError, type RpcCaller } from "./limitStore.ts";

/** Default maximum turns allowed per session. */
export const DEFAULT_MAX_TURNS = 20;

/** Result of a turn-limit check. */
export type TurnLimitResult =
  | { allowed: true; turnNumber: number }
  | { allowed: false; turnNumber: number };

/** Increments and checks a session's turn count. Throws `LimitStoreError` if the store is down. */
export type TurnCounter = (sessionId: string) => Promise<TurnLimitResult>;

function toResult(turnNumber: number, maxTurns: number): TurnLimitResult {
  return turnNumber > maxTurns
    ? { allowed: false, turnNumber }
    : { allowed: true, turnNumber };
}

/** Store-backed counter. The increment is one atomic upsert in `chat_increment_turn`. */
export function createPostgresTurnCounter(
  rpc: RpcCaller,
  maxTurns: number = DEFAULT_MAX_TURNS,
): TurnCounter {
  return async (sessionId) => {
    const data = await rpc("chat_increment_turn", { p_session_id: sessionId });
    // A scalar-returning function comes back from PostgREST as the bare value.
    const turnNumber = typeof data === "number" ? data : Number.NaN;
    if (!Number.isInteger(turnNumber) || turnNumber < 1) {
      throw new LimitStoreError(
        `chat_increment_turn returned an unexpected value: ${JSON.stringify(data)}`,
      );
    }
    return toResult(turnNumber, maxTurns);
  };
}

/** Per-instance counter for tests. Not for production: see the header. */
export function createInMemoryTurnCounter(
  maxTurns: number = DEFAULT_MAX_TURNS,
): TurnCounter {
  const store = new Map<string, number>();
  return (sessionId) => {
    const current = (store.get(sessionId) ?? 0) + 1;
    store.set(sessionId, current);
    return Promise.resolve(toResult(current, maxTurns));
  };
}
