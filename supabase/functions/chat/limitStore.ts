/**
 * Shared-store plumbing for the rate limiter and turn counter.
 *
 * Both counters live in Postgres (see
 * `supabase/migrations/20260929000000_create_chat_limits.sql`) and are reached
 * through PostgREST RPC with the service-role key — the same no-SDK pattern
 * `handleReport` uses for the reports table.
 *
 * Failure policy: **fail closed.** Any problem reaching or reading the store
 * throws `LimitStoreError`, and the handler answers 503 without calling Gemini.
 * The alternative — fail open — would mean a store outage silently removes the
 * only per-session cap on Gemini spend, which is exactly the state production
 * was in before this existed. The cost of failing closed is that a database
 * outage also takes chat down; given chat needs the same project to
 * authenticate the caller anyway, that is not a new dependency.
 */

/** Anything that went wrong talking to the limit store. Mapped to 503. */
export class LimitStoreError extends Error {
  override name = "LimitStoreError";
}

/** Calls a Postgres function by name and returns its parsed JSON result. */
export type RpcCaller = (fn: string, args: Record<string, unknown>) => Promise<unknown>;

/** How long a single limit-store call may take before it counts as down. */
export const LIMIT_STORE_TIMEOUT_MS = 5_000;

export interface SupabaseRpcOptions {
  fetch: typeof fetch;
  env: (key: string) => string | undefined;
  timeoutMs?: number;
}

/**
 * Build an `RpcCaller` against `${SUPABASE_URL}/rest/v1/rpc/<fn>`.
 *
 * Env is read per call rather than captured, so a missing secret surfaces as a
 * `LimitStoreError` on the request that needs it instead of a crash at boot.
 */
export function createSupabaseRpc(opts: SupabaseRpcOptions): RpcCaller {
  const timeoutMs = opts.timeoutMs ?? LIMIT_STORE_TIMEOUT_MS;

  return async (fn, args) => {
    const url = opts.env("SUPABASE_URL");
    const key = opts.env("SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !key) {
      throw new LimitStoreError("missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    let res: Response;
    try {
      res = await opts.fetch(`${url}/rest/v1/rpc/${fn}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: key,
          Authorization: `Bearer ${key}`,
        },
        body: JSON.stringify(args),
        signal: controller.signal,
      });
    } catch (err) {
      const detail = err instanceof Error ? `${err.name}: ${err.message}` : String(err);
      throw new LimitStoreError(`rpc ${fn} fetch failed: ${detail}`);
    } finally {
      clearTimeout(timer);
    }

    if (!res.ok) {
      const body = await res.text().catch(() => "");
      throw new LimitStoreError(
        `rpc ${fn} returned ${res.status}: ${body.slice(0, 300)}`,
      );
    }

    try {
      return await res.json();
    } catch {
      throw new LimitStoreError(`rpc ${fn} returned a non-JSON body`);
    }
  };
}
