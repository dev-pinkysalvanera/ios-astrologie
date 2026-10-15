/**
 * Request handling for the `chat` function, kept separate from `index.ts` so
 * the logic can be exercised without the Supabase auth wrapper or a live
 * Gemini key. `index.ts` stays a thin entrypoint.
 *
 * Response contract:
 *   success  -> 200 text/event-stream  (SSE: data: <chunk>\n\n … data: [DONE]\n\n)
 *   (debug/internal detail is logged server-side only, never in the response body)
 *   failure  -> non-2xx { error: string }
 *
 * Status mapping:
 *   400 invalid input (bad JSON, wrong types, empty message)
 *   500 server misconfiguration (missing GEMINI_API_KEY) or unexpected fault
 *   401 missing/invalid Bearer token
 *   403 per-session turn cap reached (or disallowed Origin)
 *   429 per-session rate limit exceeded (with Retry-After)
 *   502 upstream Gemini failure (network fault, non-200, unusable body)
 *   503 shared limit store unreachable — fail closed, Gemini never called
 *       (also: the global daily cap on Gemini calls is reached)
 *   504 upstream Gemini timeout (our own AbortController fired)
 *
 * No path may return a bare runtime error: `handleChat` wraps the whole request
 * in a catch-all so even an unforeseen throw comes back as `{ error }`.
 */

import { SYSTEM_PROMPT } from "./systemPrompt.ts";
import {
  createPostgresRateLimiter,
  type RateLimiter,
  type RateLimitResult,
  REPORT_RATE_LIMIT_CONFIG,
} from "./rateLimiter.ts";
import { detectJailbreak, moderateOutput } from "./moderator.ts";
import {
  createPostgresTurnCounter,
  type TurnCounter,
  type TurnLimitResult,
} from "./turnCounter.ts";
import { createSupabaseRpc } from "./limitStore.ts";
import {
  createPostgresDailyCap,
  type DailyCap,
  type DailyCapResult,
} from "./dailyCap.ts";

// ---------------------------------------------------------------------------
// CORS configuration
// ---------------------------------------------------------------------------

/**
 * Maximum request body size in bytes (64 KB).
 *
 * Checked before the body is read or routed, so it has to fit the largest
 * legitimate request: a report carries a whole reply's text, and a long reading
 * runs past 10 KB (the old limit). A chat message is still held to
 * MAX_MESSAGE_LENGTH by validation.
 */
export const MAX_BODY_BYTES = 64 * 1024;

/** Maximum message field length in characters. */
export const MAX_MESSAGE_LENGTH = 2000;

/**
 * Parse the allowed origins from the ALLOWED_ORIGINS env var (comma-separated).
 * Falls back to a sensible development default.
 */
function getAllowedOrigins(env: (key: string) => string | undefined): string[] {
  const raw = env("ALLOWED_ORIGINS");
  if (raw) {
    return raw.split(",").map((o) => o.trim()).filter(Boolean);
  }
  return ["http://localhost:3000"];
}

/** Check if a request origin is in the allowed list. */
function isOriginAllowed(
  origin: string | null,
  allowedOrigins: string[],
): boolean {
  if (!origin) return false;
  return allowedOrigins.includes(origin);
}

/** Build CORS response headers for a valid origin. */
function corsHeaders(origin: string): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization, apikey",
    "Access-Control-Max-Age": "86400",
  };
}

/** Handle a CORS preflight (OPTIONS) request. */
function handlePreflight(origin: string): Response {
  return new Response(null, {
    status: 204,
    headers: corsHeaders(origin),
  });
}

/**
 * Gemini model + endpoint.
 *
 * Model history for this project:
 *  - `gemini-2.0-flash` is shut down and returns 404 NOT_FOUND.
 *  - `gemini-2.5-flash` still appears in ListModels but generateContent returns
 *    404 "no longer available to new users" for keys created after its cutoff.
 *  - `gemini-3.6-flash` answered free-tier requests with 503 "high demand" for
 *    over a day (2026-10-14/15), after Google moved it to "previous generation".
 *  - `gemini-3.8-flash` is the current free-tier Flash model and served the
 *    production check on 2026-10-15.
 *
 * Override with the GEMINI_MODEL secret to switch models without a code change.
 */
export const DEFAULT_GEMINI_MODEL = "gemini-3.8-flash";
export const GEMINI_API_BASE = "https://generativelanguage.googleapis.com/v1beta";
export const DEFAULT_GEMINI_ENDPOINT = ":streamGenerateContent";

/**
 * Asks Gemini for Server-Sent Events rather than its default framing.
 *
 * Not optional. Without `alt=sse`, `:streamGenerateContent` answers a
 * pretty-printed JSON *array*, whose lines are fragments (`[{`,
 * `  "candidates": [`) that never parse as standalone objects — so a
 * line-at-a-time reader drops every chunk and the reply looks empty. With it,
 * each line is `data: {…}`, one whole object per line.
 */
export const GEMINI_STREAM_QUERY = "alt=sse";

/**
 * Hard ceiling on the outbound Gemini call so a hang can never eat the worker
 * budget.
 *
 * Raised from 20s after production verification (Week 7) showed successful
 * replies taking ~15s and the same prompt, retried, timing out right at the old
 * ceiling — real latency variance, not a hang. 45s gives headroom without
 * holding a connection open indefinitely; revisit if streamed replies start
 * routinely running past it.
 */
export const GEMINI_TIMEOUT_MS = 45_000;

/**
 * Longest gap allowed between chunks once Gemini has started streaming.
 *
 * `GEMINI_TIMEOUT_MS` only covers the wait for the response headers: the timer
 * is cleared once `fetch` resolves, so it never cut a long reading short, but a
 * stream that stalled part way had no limit at all (Week 10 Task 11). Gemini
 * sends chunks well inside this gap; 20s without one means the stream is stuck.
 * The stream then ends without `[DONE]`, and the app shows its truncated-reply
 * error.
 */
export const GEMINI_STREAM_IDLE_TIMEOUT_MS = 20_000;

/**
 * Output-token ceiling sent as `generationConfig.maxOutputTokens`.
 *
 * Was the model's own limit (65,536), which let one request run up the most a
 * reply can cost. Lowered to 8,192 (open-source hardening, Task 4): a reading
 * is asked to stay under about 250 words (~350 tokens), an expanded one runs to
 * ~2,000, and thinking tokens count against the same ceiling, so this leaves
 * ~6,000 for thinking. A reply that still hits the ceiling ends with
 * `MAX_TOKENS` and goes out without `[DONE]`.
 */
export const GEMINI_MAX_OUTPUT_TOKENS = 8_192;

/**
 * Gemini's safety thresholds, set explicitly (Week 10 Task 10).
 *
 * Left unset, the API's defaults apply, and for current models those are lax
 * (`OFF` / `BLOCK_NONE` for most categories). Medium-and-above blocks the
 * clearly harmful while leaving ordinary readings alone. Nothing here may be
 * `BLOCK_NONE`; a test checks that.
 */
export const GEMINI_SAFETY_SETTINGS = [
  "HARM_CATEGORY_HARASSMENT",
  "HARM_CATEGORY_HATE_SPEECH",
  "HARM_CATEGORY_SEXUALLY_EXPLICIT",
  "HARM_CATEGORY_DANGEROUS_CONTENT",
].map((category) => ({ category, threshold: "BLOCK_MEDIUM_AND_ABOVE" }));

/**
 * `finishReason`s that mean Gemini refused or blocked the reply. Logged as
 * safety blocks, with the user and session, so a grinding client shows up in
 * the logs rather than only on the bill.
 */
const SAFETY_FINISH_REASONS = new Set([
  "SAFETY",
  "RECITATION",
  "BLOCKLIST",
  "PROHIBITED_CONTENT",
  "SPII",
]);

/** The only `finishReason` that means the model finished its reply. */
const COMPLETE_FINISH_REASON = "STOP";

/** HTTP statuses this function returns. One place, so the mapping stays honest. */
export const STATUS = {
  /** Missing or invalid Authorization Bearer token. */
  UNAUTHORIZED: 401,
  /** Caller sent something we cannot use. */
  BAD_REQUEST: 400,
  /** Per-session conversation turn limit exceeded. */
  THREAD_LIMIT: 403,
  /** Per-session rate limit exceeded. */
  RATE_LIMITED: 429,
  /** Our own deployment is missing a secret. Not the caller's fault. */
  MISCONFIGURED: 500,
  /** Gemini failed: network fault, non-200, or a body we cannot read. */
  UPSTREAM_FAILURE: 502,
  /**
   * The shared rate-limit / turn-count store could not be reached. Fail closed:
   * without the counters nothing caps Gemini spend, so Gemini is not called.
   */
  LIMITS_UNAVAILABLE: 503,
  /** Every user's calls today have used up the global daily cap. */
  DAILY_CAP: 503,
  /** Gemini did not answer inside GEMINI_TIMEOUT_MS. */
  UPSTREAM_TIMEOUT: 504,
  /** Something we did not anticipate threw. Also our fault, hence 500. */
  INTERNAL: 500,
} as const;

/** Client-facing failure messages. Deliberately vague about upstream internals. */
export const ERROR_MESSAGE = {
  UNAUTHORIZED: "Missing or invalid authorization token.",
  THREAD_LIMIT: "Conversation limit reached. Please start a new thread.",
  OFF_TOPIC: "I can only help with Vedic astrology questions.",
  RATE_LIMITED: "Rate limit exceeded. Try again later.",
  UPSTREAM_FAILURE: "Failed to get response from AI service.",
  UPSTREAM_TIMEOUT: "AI service timed out.",
  LIMITS_UNAVAILABLE: "Service temporarily unavailable. Please try again shortly.",
  DAILY_CAP:
    "The astrologer has answered all the questions it can for today. Please try again tomorrow.",
  MISSING_API_KEY: "Server misconfiguration: missing GEMINI_API_KEY.",
  INTERNAL: "Unexpected server error.",
} as const;

/** Result of authenticating a user token. */
export type AuthResult =
  | { ok: true; userId: string }
  | { ok: false; error: string };

/** Injection seam so tests can drive the upstream and the environment. */
export interface ChatDeps {
  fetch: typeof fetch;
  env: (key: string) => string | undefined;
  timeoutMs: number;
  /** Longest gap between stream chunks before the reply is abandoned. */
  streamIdleTimeoutMs: number;
  /** Validate a Bearer token and return the authenticated user's ID. */
  getUser: (token: string) => Promise<AuthResult>;
  /**
   * Check and record one chat request against the per-user rate limit.
   * Throws if the shared store is unreachable; the handler fails closed (503).
   */
  checkRateLimit: RateLimiter;
  /**
   * Check and record one report against the per-user report limit.
   * Throws if the shared store is unreachable; the handler fails closed (503).
   */
  checkReportRateLimit: RateLimiter;
  /**
   * Increment and check the per-session turn count.
   * Throws if the shared store is unreachable; the handler fails closed (503).
   */
  checkTurnLimit: TurnCounter;
  /**
   * Increment and check today's global count of Gemini calls.
   * Throws if the shared store is unreachable; the handler fails closed (503).
   */
  checkDailyCap: DailyCap;
}

export function defaultDeps(): ChatDeps {
  const env = (key: string) => Deno.env.get(key);
  // Both counters share one Postgres-backed store so every isolate sees the
  // same counts. See limitStore.ts for the fail-closed policy.
  const rpc = createSupabaseRpc({ fetch: (input, init) => fetch(input, init), env });
  return {
    fetch: (input, init) => fetch(input, init),
    env,
    timeoutMs: GEMINI_TIMEOUT_MS,
    streamIdleTimeoutMs: GEMINI_STREAM_IDLE_TIMEOUT_MS,
    getUser: defaultGetUser,
    checkRateLimit: createPostgresRateLimiter(rpc),
    checkReportRateLimit: createPostgresRateLimiter(rpc, REPORT_RATE_LIMIT_CONFIG),
    checkTurnLimit: createPostgresTurnCounter(rpc),
    checkDailyCap: createPostgresDailyCap(rpc, env),
  };
}

/**
 * Default auth implementation: calls Supabase Auth's getUser with the token.
 * Uses the SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY env vars available in
 * every edge function at runtime.
 */
async function defaultGetUser(token: string): Promise<AuthResult> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return { ok: false, error: "Auth service misconfigured." };
  }
  try {
    const res = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: {
        Authorization: `Bearer ${token}`,
        apikey: serviceRoleKey,
      },
    });
    if (!res.ok) {
      return { ok: false, error: "Invalid or expired token." };
    }
    const user = await res.json();
    if (!user?.id) {
      return { ok: false, error: "Invalid or expired token." };
    }
    return { ok: true, userId: user.id };
  } catch {
    return { ok: false, error: "Auth service unavailable." };
  }
}

/** Keep log/debug payloads small and predictable. */
export function truncate(text: string, max = 500): string {
  return text.length > max ? `${text.slice(0, max)}…[truncated]` : text;
}

/**
 * Every failure path goes through here, so the error shape can't drift.
 *
 * `debug` is logged, never returned: upstream status codes, model names, and
 * Gemini error bodies are internal diagnostics, and a client — including
 * anyone poking the endpoint with the publishable key, which ships inside the
 * app — has no business reading them off the wire.
 */
function errorResponse(
  status: number,
  message: string,
  debug?: Record<string, unknown>,
): Response {
  if (debug !== undefined) {
    console.error("[chat] error debug detail |", JSON.stringify(debug));
  }
  return Response.json({ error: message }, { status });
}

/**
 * An abort is our own timeout firing, not a network fault — those map to
 * different statuses. Deno surfaces it as `AbortError`; `TimeoutError` is the
 * newer spelling some runtimes use.
 */
function isTimeout(name: string): boolean {
  return name === "AbortError" || name === "TimeoutError";
}

/** Normalize a thrown value into a loggable name/message pair. */
function describeError(err: unknown): { name: string; message: string } {
  return err instanceof Error
    ? { name: err.name, message: err.message }
    : { name: "UnknownError", message: String(err) };
}

/** Map any thrown upstream error to its status + error shape. */
function upstreamErrorResponse(
  stage: string,
  err: unknown,
): Response {
  const { name, message } = describeError(err);
  if (isTimeout(name)) {
    return errorResponse(
      STATUS.UPSTREAM_TIMEOUT,
      ERROR_MESSAGE.UPSTREAM_TIMEOUT,
      { stage, name },
    );
  }
  return errorResponse(
    STATUS.UPSTREAM_FAILURE,
    ERROR_MESSAGE.UPSTREAM_FAILURE,
    { stage, name, message: truncate(message) },
  );
}

/** The fail-closed answer when the shared limit store can't be used. */
function limitsUnavailable(stage: string, err: unknown): Response {
  const { name, message } = describeError(err);
  return errorResponse(
    STATUS.LIMITS_UNAVAILABLE,
    ERROR_MESSAGE.LIMITS_UNAVAILABLE,
    { stage, name, message: truncate(message) },
  );
}

export interface ValidatedChatRequest {
  sessionId: string;
  message: string;
}

export type ValidationResult =
  | { ok: true; value: ValidatedChatRequest }
  | { ok: false; error: string };

/**
 * Week 1 input validation, unchanged in behavior — every rejection here is a
 * 400. Pulled out of the request path so it can be tested directly.
 */
export function validateChatBody(body: unknown): ValidationResult {
  // Body must be a JSON object.
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "Request body must be a JSON object." };
  }

  const { sessionId, message } = body as Record<string, unknown>;

  // sessionId: required, must be a string.
  if (sessionId === undefined || sessionId === null) {
    return { ok: false, error: "Missing required field: sessionId." };
  }
  if (typeof sessionId !== "string") {
    return { ok: false, error: "Field sessionId must be a string." };
  }

  // message: required, must be a string, non-empty once trimmed.
  if (message === undefined || message === null) {
    return { ok: false, error: "Missing required field: message." };
  }
  if (typeof message !== "string") {
    return { ok: false, error: "Field message must be a string." };
  }
  if (message.trim().length === 0) {
    return { ok: false, error: "Field message must not be empty." };
  }
  if (message.length > MAX_MESSAGE_LENGTH) {
    return {
      ok: false,
      error: `Field message must not exceed ${MAX_MESSAGE_LENGTH} characters.`,
    };
  }

  return { ok: true, value: { sessionId, message } };
}

/** The 413 for a body over MAX_BODY_BYTES, whichever check caught it. */
function payloadTooLarge(): Response {
  return Response.json({ error: "Payload too large." }, { status: 413 });
}

/**
 * The request body as text, or `null` once it passes `maxBytes`.
 *
 * `req.json()` buffers the whole body, so a chunked request (no
 * Content-Length) or one whose header undercounts could send any amount. This
 * stops reading at the limit instead.
 */
async function readBodyCapped(req: Request, maxBytes: number): Promise<string | null> {
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      reader.cancel().catch(() => {});
      return null;
    }
    chunks.push(value);
  }
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return new TextDecoder().decode(bytes);
}

/** fetch() with an AbortController timeout. The timer is always cleared. */
async function fetchWithTimeout(
  deps: ChatDeps,
  url: string,
  init: RequestInit = {},
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), deps.timeoutMs);
  try {
    return await deps.fetch(url, { ...init, signal: controller.signal });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Public entrypoint. The catch-all is the last line of defense on the response
 * contract: if anything below throws unexpectedly, the caller still gets
 * `{ error }` with a 500 rather than an opaque runtime failure from the
 * surrounding auth wrapper.
 *
 * CORS and body-size enforcement happen here, before routing.
 */
export async function handleChat(
  req: Request,
  deps: ChatDeps = defaultDeps(),
): Promise<Response> {
  try {
    // --- CORS: validate Origin and handle preflight ---
    const origin = req.headers.get("origin");
    const allowedOrigins = getAllowedOrigins(deps.env);

    // If there's an Origin header, it must be in the allow-list.
    if (origin) {
      if (!isOriginAllowed(origin, allowedOrigins)) {
        return errorResponse(403, "Origin not allowed.");
      }
    }

    // Handle OPTIONS preflight.
    if (req.method === "OPTIONS") {
      if (origin) {
        return handlePreflight(origin);
      }
      // No origin on OPTIONS → reject.
      return errorResponse(403, "Origin not allowed.");
    }

    // --- Body size enforcement ---
    //
    // Fast path only: a chunked request has no Content-Length, so routeChat
    // also reads the body through `readBodyCapped`.
    const contentLength = req.headers.get("content-length");
    if (contentLength && parseInt(contentLength, 10) > MAX_BODY_BYTES) {
      return payloadTooLarge();
    }

    // Route the actual request.
    const res = await routeChat(req, deps);

    // Attach CORS headers to the response if an allowed origin was present.
    if (origin && isOriginAllowed(origin, allowedOrigins)) {
      const headers = corsHeaders(origin);
      for (const [key, value] of Object.entries(headers)) {
        res.headers.set(key, value);
      }
    }

    return res;
  } catch (err) {
    const { name, message } = describeError(err);
    console.error("[chat] unhandled error | name:", name, "| message:", message);
    return errorResponse(STATUS.INTERNAL, ERROR_MESSAGE.INTERNAL, {
      stage: "unhandled",
      name,
      message: truncate(message),
    });
  }
}

/**
 * Handle a report action — stores a flagged-message report in the reports table.
 */
async function handleReport(
  body: Record<string, unknown>,
  reporterUserId: string,
  deps: ChatDeps,
): Promise<Response> {
  const { sessionId, messageId, messageText, reason } = body;

  // Validate required fields.
  if (typeof sessionId !== "string" || !sessionId) {
    return errorResponse(STATUS.BAD_REQUEST, "Missing required field: sessionId.");
  }
  if (typeof messageId !== "string" || !messageId) {
    return errorResponse(STATUS.BAD_REQUEST, "Missing required field: messageId.");
  }
  // Required: replies aren't stored anywhere, so the text is the only record of
  // what was reported.
  if (typeof messageText !== "string" || !messageText) {
    return errorResponse(STATUS.BAD_REQUEST, "Missing required field: messageText.");
  }

  const supabaseUrl = deps.env("SUPABASE_URL");
  const serviceRoleKey = deps.env("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    console.error("[chat] report: missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
    return errorResponse(502, "Failed to store report.");
  }

  try {
    const res = await deps.fetch(`${supabaseUrl}/rest/v1/reports`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        Prefer: "return=minimal",
      },
      body: JSON.stringify({
        session_id: sessionId,
        message_id: messageId,
        message_text: messageText,
        reason: typeof reason === "string" ? reason : null,
        reporter_user_id: reporterUserId,
      }),
    });

    if (!res.ok) {
      const errText = await res.text().catch(() => "");
      console.error(
        "[chat] report insert failed | status:",
        res.status,
        "| body:",
        errText,
      );
      return errorResponse(502, "Failed to store report.");
    }

    return Response.json({ success: true }, { status: 201 });
  } catch (err) {
    const { name, message } = describeError(err);
    console.error("[chat] report fetch threw | name:", name, "| message:", message);
    return errorResponse(502, "Failed to store report.");
  }
}

/**
 * The rate limiter's key for a user.
 *
 * Prefixed so a user id can never collide with a session id: both share
 * `chat_rate_limits` (the key column is still named `session_id`), and old rows
 * there are keyed by bare session ids.
 */
export function rateLimitKey(userId: string): string {
  return `user:${userId}`;
}

/** The report limiter's key for a user. Kept apart from the chat key. */
export function reportRateLimitKey(userId: string): string {
  return `report:user:${userId}`;
}

/** A 429 with `Retry-After` in whole seconds, rounded up. */
function rateLimitedResponse(retryAfterMs: number): Response {
  return new Response(
    JSON.stringify({ error: ERROR_MESSAGE.RATE_LIMITED }),
    {
      status: STATUS.RATE_LIMITED,
      headers: {
        "Content-Type": "application/json",
        "Retry-After": String(Math.ceil(retryAfterMs / 1000)),
      },
    },
  );
}

async function routeChat(
  req: Request,
  deps: ChatDeps,
): Promise<Response> {
  console.log("[chat] request received", req.method);

  // --- Auth: validate the Bearer token ---
  const authHeader = req.headers.get("authorization");
  const token = authHeader?.startsWith("Bearer ")
    ? authHeader.slice("Bearer ".length).trim()
    : null;

  if (!token) {
    console.error("[chat] missing or malformed Authorization header");
    return errorResponse(STATUS.UNAUTHORIZED, ERROR_MESSAGE.UNAUTHORIZED);
  }

  const authResult = await deps.getUser(token);
  if (!authResult.ok) {
    console.error("[chat] auth failed:", authResult.error);
    return errorResponse(STATUS.UNAUTHORIZED, ERROR_MESSAGE.UNAUTHORIZED);
  }

  console.log("[chat] authenticated user:", authResult.userId);

  const rawBody = await readBodyCapped(req, MAX_BODY_BYTES);
  if (rawBody === null) {
    console.error("[chat] body over MAX_BODY_BYTES without a usable Content-Length");
    return payloadTooLarge();
  }

  // Parse the request body. Malformed / unparseable JSON is a bad request.
  let body: unknown;
  try {
    body = JSON.parse(rawBody);
  } catch (err) {
    const { name, message } = describeError(err);
    console.error("[chat] request body JSON parse failed:", `${name}: ${message}`);
    return errorResponse(STATUS.BAD_REQUEST, "Request body must be valid JSON.");
  }

  // --- Action routing: check for "report" before chat body validation ---
  const bodyObj = (typeof body === "object" && body !== null && !Array.isArray(body))
    ? body as Record<string, unknown>
    : null;
  if (bodyObj?.action === "report") {
    // Limited before anything is stored: reports used to skip every limit, so
    // one token could insert unlimited rows (Week 10 Task 8). Fails closed like
    // the chat limits.
    let reportLimit: RateLimitResult;
    try {
      reportLimit = await deps.checkReportRateLimit(
        reportRateLimitKey(authResult.userId),
      );
    } catch (err) {
      return limitsUnavailable("report-rate-limit", err);
    }
    if (!reportLimit.allowed) {
      console.error(
        "[chat] report rate limited | userId:",
        authResult.userId,
        "| retryAfterMs:",
        reportLimit.retryAfterMs,
      );
      return rateLimitedResponse(reportLimit.retryAfterMs);
    }
    return await handleReport(bodyObj, authResult.userId, deps);
  }

  const validation = validateChatBody(body);
  if (!validation.ok) {
    console.error("[chat] invalid input:", validation.error);
    return errorResponse(STATUS.BAD_REQUEST, validation.error);
  }
  const { message } = validation.value;
  const { sessionId } = validation.value;

  // --- Rate limit (per user) + turn cap (per session), both in the shared store ---
  //
  // Fail closed: if either counter can't be read, answer 503 and never reach
  // Gemini. These are the only caps on Gemini spend, so "store is down" must
  // not quietly mean "no limits" (see limitStore.ts).
  //
  // The rate limit is keyed on the user from the verified token, not on the
  // client-chosen `sessionId`: a client that sent a new session id with every
  // request used to get past it (Week 10 Task 7).
  let rateResult: RateLimitResult;
  try {
    rateResult = await deps.checkRateLimit(rateLimitKey(authResult.userId));
  } catch (err) {
    return limitsUnavailable("rate-limit", err);
  }
  if (!rateResult.allowed) {
    console.error(
      "[chat] rate limited | userId:",
      authResult.userId,
      "| sessionId:",
      sessionId,
      "| retryAfterMs:",
      rateResult.retryAfterMs,
    );
    return rateLimitedResponse(rateResult.retryAfterMs);
  }

  // --- Jailbreak denylist ---
  //
  // After the rate limit, so repeated attempts still count against it; before
  // the turn cap, so a refused message doesn't use up a turn. Gemini is never
  // called for a match.
  const jailbreak = detectJailbreak(message);
  if (jailbreak) {
    console.warn(
      "[chat] refused: jailbreak framing | pattern:",
      jailbreak,
      "| userId:",
      authResult.userId,
      "| sessionId:",
      sessionId,
    );
    return errorResponse(STATUS.BAD_REQUEST, ERROR_MESSAGE.OFF_TOPIC);
  }

  // --- Turn limit: per-session conversation cap ---
  //
  // Stays per session on purpose: it caps one conversation, and "Start new
  // conversation" in the app works by sending a new session id.
  let turnResult: TurnLimitResult;
  try {
    turnResult = await deps.checkTurnLimit(sessionId);
  } catch (err) {
    return limitsUnavailable("turn-limit", err);
  }
  if (!turnResult.allowed) {
    console.error(
      "[chat] turn limit reached | sessionId:",
      sessionId,
      "| turn:",
      turnResult.turnNumber,
    );
    return errorResponse(
      STATUS.THREAD_LIMIT,
      ERROR_MESSAGE.THREAD_LIMIT,
      { maxTurns: 20, currentTurn: turnResult.turnNumber },
    );
  }

  // --- Daily cap: every user's Gemini calls today ---
  //
  // Last of the limits, so only a request that would really reach Gemini counts
  // against it. Fails closed like the others.
  let dailyResult: DailyCapResult;
  try {
    dailyResult = await deps.checkDailyCap();
  } catch (err) {
    return limitsUnavailable("daily-cap", err);
  }
  if (!dailyResult.allowed) {
    console.error(
      "[chat] daily cap reached | calls:",
      dailyResult.calls,
      "| userId:",
      authResult.userId,
    );
    return errorResponse(STATUS.DAILY_CAP, ERROR_MESSAGE.DAILY_CAP);
  }

  // Read the Gemini API key from function secrets.
  const GEMINI_API_KEY = deps.env("GEMINI_API_KEY");
  if (!GEMINI_API_KEY) {
    console.error("[chat] GEMINI_API_KEY missing from function secrets");
    return errorResponse(STATUS.MISCONFIGURED, ERROR_MESSAGE.MISSING_API_KEY);
  }

  const model = deps.env("GEMINI_MODEL") ?? DEFAULT_GEMINI_MODEL;
  const endpoint = `${GEMINI_API_BASE}/models/${model}${DEFAULT_GEMINI_ENDPOINT}`;

  // Call the Gemini generateContent endpoint.
  console.log(
    "[chat] starting Gemini request | model:",
    model,
    "| endpoint:",
    endpoint,
    "| timeout_ms:",
    deps.timeoutMs,
  );

  const startedAt = Date.now();
  let geminiRes: Response;
  try {
    geminiRes = await fetchWithTimeout(
      deps,
      `${endpoint}?${GEMINI_STREAM_QUERY}`,
      {
        method: "POST",
        // In a header rather than `?key=`, so no URL that ends up in a log
        // carries it.
        headers: { "Content-Type": "application/json", "x-goog-api-key": GEMINI_API_KEY },
        body: JSON.stringify({
          // `systemInstruction` is a Content object on the v1beta
          // generateContent request — it carries the astrology persona and
          // scope. Prompt-level only; it is not a hard guardrail.
          systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
          contents: [{ role: "user", parts: [{ text: message }] }],
          generationConfig: { maxOutputTokens: GEMINI_MAX_OUTPUT_TOKENS },
          safetySettings: GEMINI_SAFETY_SETTINGS,
        }),
      },
    );
  } catch (err) {
    const { name, message: msg } = describeError(err);
    console.error(
      "[chat] Gemini fetch threw | name:",
      name,
      "| message:",
      msg,
      "| elapsed_ms:",
      Date.now() - startedAt,
    );
    return upstreamErrorResponse("fetch", err);
  }

  console.log(
    "[chat] Gemini responded | status:",
    geminiRes.status,
    "| statusText:",
    geminiRes.statusText,
    "| elapsed_ms:",
    Date.now() - startedAt,
  );

  if (!geminiRes.ok) {
    // Read the error body as text so non-JSON error bodies stay visible.
    let errBody = "";
    try {
      errBody = await geminiRes.text();
    } catch {
      // best-effort; log what we have
    }
    console.error(
      "[chat] Gemini returned non-OK | status:",
      geminiRes.status,
      geminiRes.statusText,
      "| model:",
      model,
      "| body:",
      truncate(errBody),
    );
    return errorResponse(
      STATUS.UPSTREAM_FAILURE,
      ERROR_MESSAGE.UPSTREAM_FAILURE,
      { stage: "status", status: geminiRes.status, model, body: truncate(errBody) },
    );
  }

  // Translate Gemini's SSE body into this function's own SSE contract:
  // one event per chunk (one `data: ` line per line of text, see `sseEvent`),
  // closing with `data: [DONE]\n\n`.
  //
  // Failures split on one question — has the status been sent yet? Before the
  // first chunk they are still reportable as JSON with a real status code.
  // After it, the only honest signal left is ending the stream without
  // `[DONE]`, which the client already reads as a truncated reply.
  //
  // The same signal covers a reply Gemini itself cut short. Its stream ends
  // normally either way, so only the last `finishReason` tells a finished reply
  // (`STOP`) from one stopped by `MAX_TOKENS`, `SAFETY` or `RECITATION`. A
  // stream that ends with no reason at all is treated as cut short too: a
  // partial reply shown as finished is the failure this guards against.
  const encoder = new TextEncoder();

  const finish: FinishState = { reason: null };
  const parts = geminiTextParts(geminiRes.body!, finish, deps.streamIdleTimeoutMs);

  // Awaiting the first chunk *before* building the Response is the fix for the
  // empty-200: the status stays open until there is real text to justify it.
  //
  // What stood here raced a `setTimeout(…, 0)` against the network. On any real
  // connection nothing had arrived inside one tick, so it committed 200, then
  // found no text and had no status left to say so — the client got
  // `200 text/event-stream` and zero bytes. Only the synchronous mock streams
  // in the tests ever won that race, which is why the suite stayed green.
  let firstText: string;
  try {
    const first = await parts.next();
    if (first.done) {
      logIfSafetyBlock(finish, authResult.userId, sessionId);
      console.error(
        "[chat] Gemini stream carried no text part | model:",
        model,
        "| finish_reason:",
        finish.reason,
        "| block_reason:",
        finish.blockReason,
        "| elapsed_ms:",
        Date.now() - startedAt,
      );
      return errorResponse(
        STATUS.UPSTREAM_FAILURE,
        ERROR_MESSAGE.UPSTREAM_FAILURE,
        { stage: "parse", status: geminiRes.status, model },
      );
    }
    firstText = first.value;
  } catch (err) {
    const { name, message: msg } = describeError(err);
    console.error("[chat] stream read failed | name:", name, "| message:", msg);
    return upstreamErrorResponse("stream-read", err);
  }

  const { readable, writable } = new TransformStream<Uint8Array, Uint8Array>();
  const writer = writable.getWriter();

  // Not awaited: the Response has to go back so the body can stream while this
  // keeps filling it.
  (async () => {
    try {
      await writer.write(encoder.encode(frameFor(firstText)));
      for await (const text of parts) {
        await writer.write(encoder.encode(frameFor(text)));
      }
      console.log("[chat] Gemini finished | finish_reason:", finish.reason);
      logIfSafetyBlock(finish, authResult.userId, sessionId);
      if (finish.reason === COMPLETE_FINISH_REASON) {
        await writer.write(encoder.encode(`data: ${DONE_SENTINEL}\n\n`));
      } else {
        // No `[DONE]`, for the reason above: the client keeps the partial
        // reply and shows its truncated-reply error.
        console.warn(
          "[chat] reply cut short, ending without [DONE] | finish_reason:",
          finish.reason,
          "| model:",
          model,
        );
      }
    } catch (err) {
      // Deliberately no `[DONE]`: a stream that stops short is exactly how a
      // post-commit failure reads on the wire, and the client keeps whatever
      // arrived and surfaces an error. Inventing an error frame here would
      // append it to the reply as ordinary text.
      const { name, message: msg } = describeError(err);
      console.error(
        "[chat] stream aborted after commit | name:",
        name,
        "| message:",
        msg,
      );
    } finally {
      await writer.close().catch(() => {});
    }
  })();

  console.log(
    "[chat] streaming SSE response started | elapsed_ms:",
    Date.now() - startedAt,
  );
  return new Response(readable, {
    status: 200,
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
}

/** The only parts of a Gemini stream chunk this function reads. */
interface GeminiChunk {
  candidates?: Array<{
    content?: { parts?: Array<{ text?: string }> };
    finishReason?: string;
  }>;
  /** Set when Gemini refuses the prompt itself; no candidates come back then. */
  promptFeedback?: { blockReason?: string };
}

/**
 * The last `finishReason` seen on the stream, filled in by `geminiTextParts`.
 *
 * Gemini sends it on the final chunk, often alongside that chunk's text, so it
 * can't be a separate yielded value without splitting that chunk in two.
 */
interface FinishState {
  reason: string | null;
  /** `promptFeedback.blockReason`, when the prompt itself was blocked. */
  blockReason?: string | null;
}

/** Logs a safety refusal with who asked, if `finish` records one. */
function logIfSafetyBlock(finish: FinishState, userId: string, sessionId: string): void {
  const blocked = finish.blockReason ??
    (finish.reason && SAFETY_FINISH_REASONS.has(finish.reason) ? finish.reason : null);
  if (!blocked) return;
  console.warn(
    "[chat] refused: safety block | reason:",
    blocked,
    "| userId:",
    userId,
    "| sessionId:",
    sessionId,
  );
}

/**
 * Yields each text part from Gemini's SSE body, in arrival order.
 *
 * Buffers across reads. One `read()` can end mid-line, so a line is only
 * emitted once its newline has arrived — splitting each read on its own (what
 * this used to do) corrupts any object that straddles a read boundary, and on a
 * real connection they routinely do.
 */
async function* geminiTextParts(
  body: ReadableStream<Uint8Array>,
  finish: FinishState,
  idleTimeoutMs: number,
): AsyncGenerator<string> {
  const reader = body.pipeThrough(new TextDecoderStream()).getReader();
  let buffered = "";

  while (true) {
    let read: ReadableStreamReadResult<string>;
    try {
      read = await readWithin(reader, idleTimeoutMs);
    } catch (err) {
      // Let go of the upstream connection rather than leave it open behind us.
      reader.cancel().catch(() => {});
      throw err;
    }
    const { done, value } = read;
    if (done) break;
    if (!value) continue;

    buffered += value;

    // Everything before the last newline is complete; the remainder waits for
    // the read that finishes it.
    const lines = buffered.split("\n");
    buffered = lines.pop() ?? "";

    for (const line of lines) {
      const text = textPart(line, finish);
      if (text !== null) yield text;
    }
  }

  // A trailing line with no newline after it is still a line.
  const tail = textPart(buffered, finish);
  if (tail !== null) yield tail;
}

/**
 * Pulls the text out of one SSE line, or `null` when it carries none — a blank
 * separator, a comment, Gemini's own `[DONE]`, or a chunk that is only usage
 * metadata. Records any `finishReason` on the line in `finish`.
 *
 * A line that looks like data and will not parse gets logged rather than
 * dropped. The silent `catch {}` that used to sit here is what let a
 * wrong-wire-format bug read as an empty reply for weeks.
 */
function textPart(line: string, finish: FinishState): string | null {
  const trimmed = line.trim();
  // `:` opens an SSE comment, which some proxies send as a keep-alive.
  if (!trimmed || trimmed.startsWith(":")) return null;

  if (!trimmed.startsWith("data:")) {
    console.warn("[chat] non-data SSE line | line:", truncate(trimmed, 120));
    return null;
  }

  const payload = trimmed.slice("data:".length).trim();
  if (!payload || payload === "[DONE]") return null;

  let parsed: unknown;
  try {
    parsed = JSON.parse(payload);
  } catch {
    console.error(
      "[chat] unparseable data line | payload:",
      truncate(payload, 200),
    );
    return null;
  }

  const blockReason = (parsed as GeminiChunk)?.promptFeedback?.blockReason;
  if (typeof blockReason === "string") {
    finish.blockReason = blockReason;
  }

  const candidate = (parsed as GeminiChunk)?.candidates?.[0];
  if (typeof candidate?.finishReason === "string") {
    finish.reason = candidate.finishReason;
  }

  const text = candidate?.content?.parts?.[0]?.text;
  return typeof text === "string" && text.length > 0 ? text : null;
}

/**
 * One `read()`, or a `TimeoutError` if nothing arrives within `ms`.
 *
 * Named `TimeoutError` so `isTimeout` maps it to a 504 when it happens before
 * the first chunk; after that it ends the stream without `[DONE]`.
 */
async function readWithin<T>(
  reader: ReadableStreamDefaultReader<T>,
  ms: number,
): Promise<ReadableStreamReadResult<T>> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const idle = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new DOMException(`No stream data for ${ms}ms`, "TimeoutError")),
      ms,
    );
  });
  try {
    return await Promise.race([reader.read(), idle]);
  } finally {
    clearTimeout(timer);
  }
}

/** The payload of the stream's closing event. */
export const DONE_SENTINEL = "[DONE]";

/**
 * Moderates one chunk and returns the SSE frame(s) to send for it.
 *
 * Exported for tests: the multi-line framing is easiest to pin down here.
 */
export function frameFor(text: string): string {
  const moderated = moderateOutput(text);
  if (moderated.passed) return sseEvent(text);
  console.warn("[chat] chunk filtered | reason:", moderated.reason);
  return sseEvent("[Content filtered]");
}

/**
 * Encodes `text` as one SSE event, per the spec's multi-line data rule: every
 * line of the text gets its own `data: ` field, and a spec-compliant reader
 * joins them back with `\n`.
 *
 * Interpolating the text into a single `data: ${text}\n\n` (what stood here
 * before) broke on any line break: a `\n\n` in the model's text closed the event
 * early and everything after it went out with no `data:` prefix, which the
 * client rightly drops — the reply lost every paragraph after the first.
 *
 * `\r\n` and lone `\r` are both SSE line terminators, so they are folded to
 * `\n` first; left alone, a lone `\r` would split a field in the reader.
 *
 * A chunk that is literally `[DONE]` would read as the terminator, so it is
 * sent as two events (`[` then `DONE]`). The client concatenates chunks, so the
 * reply text is unchanged and only the real terminator is ever exactly
 * `[DONE]`.
 */
function sseEvent(text: string): string {
  const normalized = text.replace(/\r\n?/g, "\n");
  if (normalized === DONE_SENTINEL) {
    return sseEvent("[") + sseEvent("DONE]");
  }
  return normalized.split("\n").map((line) => `data: ${line}`).join("\n") +
    "\n\n";
}
