/**
 * Tests for the shared limit store: the PostgREST RPC caller, the
 * Postgres-backed limiter/counter adapters, and the in-memory fakes.
 *
 * The SQL itself (`20260929000000_create_chat_limits.sql`) can't run here —
 * no Docker, no local Postgres — so these pin down the wire contract with the
 * RPC functions, and the live curl pass against production verifies the SQL.
 *
 * Run from this directory:  deno task test
 */

import { assert, assertEquals, assertRejects } from "@std/assert";
import { createSupabaseRpc, LimitStoreError, type RpcCaller } from "./limitStore.ts";
import {
  createInMemoryRateLimiter,
  createPostgresRateLimiter,
  DEFAULT_RATE_LIMIT_CONFIG,
} from "./rateLimiter.ts";
import {
  createInMemoryTurnCounter,
  createPostgresTurnCounter,
  DEFAULT_MAX_TURNS,
} from "./turnCounter.ts";
import {
  createInMemoryDailyCap,
  createPostgresDailyCap,
  dailyCapLimit,
  DEFAULT_DAILY_CAP,
} from "./dailyCap.ts";

const ENV: Record<string, string> = {
  SUPABASE_URL: "https://proj.supabase.co",
  SUPABASE_SERVICE_ROLE_KEY: "service-role-test-key",
};
const env = (k: string) => ENV[k];

/** Records the one request it receives and answers with `response`. */
function recordingFetch(response: () => Response | Promise<Response>) {
  const calls: Array<{ url: string; init: RequestInit }> = [];
  const fetchFn: typeof fetch = (input, init) => {
    calls.push({ url: String(input), init: init ?? {} });
    return Promise.resolve(response());
  };
  return { fetchFn, calls };
}

/** An RpcCaller that returns a fixed value and records what it was asked. */
function fixedRpc(value: unknown) {
  const calls: Array<{ fn: string; args: Record<string, unknown> }> = [];
  const rpc: RpcCaller = (fn, args) => {
    calls.push({ fn, args });
    return Promise.resolve(value);
  };
  return { rpc, calls };
}

// ---------------------------------------------------------------------------
// createSupabaseRpc
// ---------------------------------------------------------------------------

Deno.test("rpc POSTs to /rest/v1/rpc/<fn> with the service-role key", async () => {
  const { fetchFn, calls } = recordingFetch(() => Response.json(7));
  const rpc = createSupabaseRpc({ fetch: fetchFn, env });

  const result = await rpc("chat_increment_turn", { p_session_id: "s1" });

  assertEquals(result, 7);
  assertEquals(calls.length, 1);
  assertEquals(calls[0].url, "https://proj.supabase.co/rest/v1/rpc/chat_increment_turn");
  assertEquals(calls[0].init.method, "POST");
  const headers = calls[0].init.headers as Record<string, string>;
  assertEquals(headers.apikey, ENV.SUPABASE_SERVICE_ROLE_KEY);
  assertEquals(headers.Authorization, `Bearer ${ENV.SUPABASE_SERVICE_ROLE_KEY}`);
  assertEquals(JSON.parse(String(calls[0].init.body)), { p_session_id: "s1" });
});

Deno.test("rpc throws LimitStoreError when env is missing", async () => {
  const { fetchFn, calls } = recordingFetch(() => Response.json(1));
  const rpc = createSupabaseRpc({ fetch: fetchFn, env: () => undefined });
  await assertRejects(() => rpc("f", {}), LimitStoreError);
  assertEquals(calls.length, 0);
});

Deno.test("rpc throws LimitStoreError on a non-2xx answer", async () => {
  const { fetchFn } = recordingFetch(() =>
    Response.json({ message: "permission denied" }, { status: 401 })
  );
  const rpc = createSupabaseRpc({ fetch: fetchFn, env });
  await assertRejects(() => rpc("f", {}), LimitStoreError, "401");
});

Deno.test("rpc throws LimitStoreError when fetch rejects", async () => {
  const rpc = createSupabaseRpc({
    fetch: () => Promise.reject(new TypeError("dns error")),
    env,
  });
  await assertRejects(() => rpc("f", {}), LimitStoreError, "dns error");
});

Deno.test("rpc throws LimitStoreError on timeout", async () => {
  const hanging: typeof fetch = (_input, init) =>
    new Promise((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () =>
        reject(new DOMException("aborted", "AbortError")));
    });
  const rpc = createSupabaseRpc({ fetch: hanging, env, timeoutMs: 10 });
  await assertRejects(() => rpc("f", {}), LimitStoreError, "AbortError");
});

// ---------------------------------------------------------------------------
// createPostgresRateLimiter
// ---------------------------------------------------------------------------

Deno.test("postgres rate limiter sends session and config, maps allowed", async () => {
  const { rpc, calls } = fixedRpc([{ allowed: true, retry_after_ms: 0 }]);
  const result = await createPostgresRateLimiter(rpc)("s1");
  assertEquals(result, { allowed: true });
  assertEquals(calls, [{
    fn: "chat_check_rate_limit",
    args: {
      p_session_id: "s1",
      p_max_requests: DEFAULT_RATE_LIMIT_CONFIG.maxRequests,
      p_window_ms: DEFAULT_RATE_LIMIT_CONFIG.windowMs,
    },
  }]);
});

Deno.test("postgres rate limiter maps a rejection with retry-after", async () => {
  const { rpc } = fixedRpc([{ allowed: false, retry_after_ms: 41_500 }]);
  assertEquals(await createPostgresRateLimiter(rpc)("s1"), {
    allowed: false,
    retryAfterMs: 41_500,
  });
});

Deno.test("postgres rate limiter throws on an unexpected shape", async () => {
  for (const bad of [[], null, [{}], [{ allowed: "yes" }], "nope"]) {
    const { rpc } = fixedRpc(bad);
    await assertRejects(() => createPostgresRateLimiter(rpc)("s1"), LimitStoreError);
  }
});

// ---------------------------------------------------------------------------
// createPostgresTurnCounter
// ---------------------------------------------------------------------------

Deno.test("postgres turn counter allows through the cap and rejects past it", async () => {
  const at = async (n: number) => await createPostgresTurnCounter(fixedRpc(n).rpc)("s1");
  assertEquals(await at(1), { allowed: true, turnNumber: 1 });
  assertEquals(await at(DEFAULT_MAX_TURNS), {
    allowed: true,
    turnNumber: DEFAULT_MAX_TURNS,
  });
  assertEquals(await at(DEFAULT_MAX_TURNS + 1), {
    allowed: false,
    turnNumber: DEFAULT_MAX_TURNS + 1,
  });
});

Deno.test("postgres turn counter calls chat_increment_turn with the session", async () => {
  const { rpc, calls } = fixedRpc(1);
  await createPostgresTurnCounter(rpc)("abc");
  assertEquals(calls, [{ fn: "chat_increment_turn", args: { p_session_id: "abc" } }]);
});

Deno.test("postgres turn counter throws on an unexpected value", async () => {
  for (const bad of [null, "3", 0, 1.5, [3], { turns: 3 }]) {
    const { rpc } = fixedRpc(bad);
    await assertRejects(() => createPostgresTurnCounter(rpc)("s1"), LimitStoreError);
  }
});

// ---------------------------------------------------------------------------
// createPostgresDailyCap
// ---------------------------------------------------------------------------

Deno.test("postgres daily cap allows through the cap and rejects past it", async () => {
  const at = async (n: number) =>
    await createPostgresDailyCap(fixedRpc(n).rpc, () => undefined)();
  assertEquals(await at(1), { allowed: true, calls: 1 });
  assertEquals(await at(DEFAULT_DAILY_CAP), { allowed: true, calls: DEFAULT_DAILY_CAP });
  assertEquals(await at(DEFAULT_DAILY_CAP + 1), {
    allowed: false,
    calls: DEFAULT_DAILY_CAP + 1,
  });
});

Deno.test("postgres daily cap calls chat_increment_daily_calls with no args", async () => {
  const { rpc, calls } = fixedRpc(1);
  await createPostgresDailyCap(rpc, () => undefined)();
  assertEquals(calls, [{ fn: "chat_increment_daily_calls", args: {} }]);
});

Deno.test("postgres daily cap uses CHAT_DAILY_CAP when set", async () => {
  const capEnv = (k: string) => (k === "CHAT_DAILY_CAP" ? "5" : undefined);
  assertEquals(await createPostgresDailyCap(fixedRpc(5).rpc, capEnv)(), {
    allowed: true,
    calls: 5,
  });
  assertEquals(await createPostgresDailyCap(fixedRpc(6).rpc, capEnv)(), {
    allowed: false,
    calls: 6,
  });
});

Deno.test("postgres daily cap throws on an unexpected value", async () => {
  for (const bad of [null, "3", 0, 1.5, [3], { calls: 3 }]) {
    const { rpc } = fixedRpc(bad);
    await assertRejects(
      () => createPostgresDailyCap(rpc, () => undefined)(),
      LimitStoreError,
    );
  }
});

Deno.test("dailyCapLimit falls back to the default for a missing or bad secret", () => {
  assertEquals(dailyCapLimit(() => undefined), DEFAULT_DAILY_CAP);
  assertEquals(DEFAULT_DAILY_CAP, 200);
  for (const bad of ["", "abc", "0", "-5", "2.5"]) {
    assertEquals(
      dailyCapLimit(() => bad),
      DEFAULT_DAILY_CAP,
      `for ${JSON.stringify(bad)}`,
    );
  }
  assertEquals(dailyCapLimit(() => "50"), 50);
});

Deno.test("in-memory daily cap: allowed through the cap, refused after", async () => {
  const cap = createInMemoryDailyCap(2);
  assertEquals(await cap(), { allowed: true, calls: 1 });
  assertEquals(await cap(), { allowed: true, calls: 2 });
  assertEquals(await cap(), { allowed: false, calls: 3 });
});

// ---------------------------------------------------------------------------
// In-memory fakes (same semantics as the SQL)
// ---------------------------------------------------------------------------

Deno.test("in-memory rate limiter: max per window, then retry-after, then frees up", async () => {
  let t = 1_000_000;
  const limit = createInMemoryRateLimiter({ maxRequests: 3, windowMs: 1000 }, () => t);

  for (let i = 0; i < 3; i++) {
    assertEquals(await limit("s"), { allowed: true });
    t += 100;
  }
  // t is 300ms past the first hit, so it frees up in 700ms.
  assertEquals(await limit("s"), { allowed: false, retryAfterMs: 700 });
  // Other sessions are unaffected.
  assertEquals(await limit("other"), { allowed: true });

  t += 701;
  assertEquals(await limit("s"), { allowed: true });
});

Deno.test("in-memory rate limiter never admits more than max in any window", async () => {
  // Randomised arrival gaps; the invariant must hold for every sliding window.
  const config = { maxRequests: 5, windowMs: 1000 };
  for (let run = 0; run < 50; run++) {
    let t = 0;
    const limit = createInMemoryRateLimiter(config, () => t);
    const admitted: number[] = [];
    for (let i = 0; i < 60; i++) {
      t += Math.floor(Math.random() * 300);
      if ((await limit("s")).allowed) admitted.push(t);
    }
    for (let i = 0; i < admitted.length; i++) {
      const inWindow = admitted.filter((a) =>
        a >= admitted[i] && a < admitted[i] + config.windowMs
      );
      assert(inWindow.length <= config.maxRequests, `run ${run}: ${admitted}`);
    }
  }
});

Deno.test("in-memory turn counter: independent instances share nothing", async () => {
  const a = createInMemoryTurnCounter(2);
  const b = createInMemoryTurnCounter(2);
  assertEquals((await a("s")).allowed, true);
  assertEquals((await a("s")).allowed, true);
  assertEquals(await a("s"), { allowed: false, turnNumber: 3 });
  assertEquals(await b("s"), { allowed: true, turnNumber: 1 });
});
