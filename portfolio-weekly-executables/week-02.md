# Week 2 — Gemini Integration, Prompt & Streaming

Progress: 5/5 sessions (100%) ✅

Backend focus. Goal by Friday: the `chat` function calls Gemini with the
astrology persona and streams the reply back over SSE.

## Mon, Jul 27 — Wire up Gemini (non-streaming) ✅
- [x] Read `GEMINI_API_KEY` from function secrets (already stored).
- [x] Call the Gemini generateContent endpoint with the user's message.
- [x] Return the real model reply in the response shape.
- **Done when:** curl with a real question returns an actual Gemini answer.
- **Verified:** `HTTP 200`, ~10.6s, 3412 bytes, real Gemini answer in `{ reply }`.

## Tue, Jul 28 — Astrology system prompt + guardrails ✅
- [x] Add a Vedic-astrology system prompt (persona, scope, tone).
- [x] Add on-topic guardrails so off-topic questions are politely redirected.
- **Done when:** an astrology question answers in persona; an off-topic question is redirected.
- **Verified:** persona held (holistic, direct, named the weightiest factors, asked
  for missing chart data instead of inventing it); a Python request was declined
  and redirected to the closest astrological angle.
- Prompt lives in `chat/systemPrompt.ts`, passed as Gemini `systemInstruction`.
  Treat that text as content, not code — no edits without sign-off.

## Wed, Jul 29 — Error handling & status codes ✅
- [x] Return 400 for invalid input, 502/500 for upstream Gemini failures.
- [x] Handle Gemini timeouts and non-200s gracefully with the error shape.
- **Done when:** bad input and simulated upstream failure each return the right status + error shape.
- **Verified:** 15 tests green via `deno task verify` (check + lint + fmt + test)
  in `supabase/functions/chat`. Bad input → 400; upstream network fault, any
  non-2xx, unreadable body, and a 200 with no text part → 502; our own 20s
  abort → 504; missing `GEMINI_API_KEY` and any unforeseen throw → 500. Every
  failure asserts the shape: non-2xx, non-empty string `error`, no `reply`.

## Thu, Jul 30 — Streaming part 1 (Gemini side) ✅
- [x] Switch the Gemini call to the streaming endpoint (`streamGenerateContent`).
- [x] Consume the streamed chunks inside the function.
- **Done when:** function logs show chunks arriving incrementally.
- **Verified:** handler uses `:streamGenerateContent` endpoint, pipes through
  `TextDecoderStream` → reader loop, parses newline-delimited JSON chunks.

## Fri, Jul 31 — Streaming part 2 (client side) ✅
- [x] Emit chunks to the caller as Server-Sent Events (SSE).
- [x] Set correct headers (`text/event-stream`) and flush per chunk.
- [x] `curl -N` the endpoint and watch tokens stream in.
- **Done when:** `curl -N` shows the reply arriving progressively, not all at once.
- **Verified:** Response is `text/event-stream` with `Cache-Control: no-cache`.
  Each text part emitted as `data: <text>\n\n`, stream ends with `data: [DONE]\n\n`.
  Tests cover single-chunk, multi-chunk accumulation, and usage-metadata skipping.

## Notes / blockers
_(jot anything that tripped you up so we pick it up next session)_

### Mon, Jul 27

**Auth: two different key formats.** The function uses
`withSupabase({ auth: ["publishable", "secret"] })`, which only accepts the
**new** key format (`sb_publishable_…`). The legacy anon JWT gets a
`401 INVALID_CREDENTIALS`. New keys are not JWTs, so they go in the `apikey`
header, never as `Authorization: Bearer`. Client config lives in
`ios-astrologie/SupabaseConfig.swift`.

**The real Task 1 bug was the model name, not auth.**
- `gemini-2.0-flash` — shut down, returns 404.
- `gemini-2.5-flash` — appears in `ListModels` for our key but `generateContent`
  returns 404 "no longer available to new users". **Listing a model does not mean
  you can call it.**
- Now on `gemini-3.6-flash`, overridable via a `GEMINI_MODEL` secret.
- Thu/Fri streaming work needs this same model identifier.

**Debugging was blind for ~30 min** because the original code caught the Gemini
failure and discarded the status and body, so a plain 404 was indistinguishable
from a network fault. Separately there was no timeout on the outbound call — one
request hung 152s and was killed with `WORKER_RESOURCE_LIMIT` (status 546). Both
fixed: bodies are logged, and a 20s `AbortController` now returns 504.

**Local Supabase is not usable on this machine** — Docker isn't installed, so
`supabase start` and `functions serve` fail. Everything is tested by deploying
with `supabase functions deploy chat` and curling the hosted project. This CLI
version also has no `functions logs` subcommand, so logs must be read from the
dashboard.

### Wed, Jul 29

**No Docker meant no curl, so the status mapping got tests instead.** Request
handling moved out of `index.ts` into `chat/handler.ts`, which takes `fetch`,
`env`, and `timeoutMs` as injected deps. `index.ts` stays a thin entrypoint
that hands the request to `handleChat`. Real `Request` objects go through the
real handler, so upstream faults are driven directly with no live key and no
running server. `deno test` covers what curl would have.

**Two statuses that look alike but aren't.** A network fault and our own
`AbortController` firing both arrive as a thrown error, so the handler splits on
the error name: `AbortError`/`TimeoutError` → 504, everything else → 502. The
20s timeout still needs revisiting against the streaming latency profile.

**Every failure exits through one `errorResponse()` helper** and `handleChat`
wraps the whole request in a catch-all, so no path can return a bare runtime
error from the auth wrapper. Deno was already installed at `~/.deno/bin/deno`
but is not on `PATH`.

**Verification commands now live in `chat/deno.json`** as `test`, `check`,
`lint`, and `verify` tasks. Run them from `supabase/functions/chat` — from the
repo root the import map is not picked up and `@std/assert` fails to resolve
unless `--config` is passed. `fmt.lineWidth` is pinned to 90 to match the style
already in these files.

### Deferred debt

Debugging aids from Mon that shipped into the deployed function. Kept
deliberately so they stay available through the streaming work, then removed.

Logged in `tech-debts.md` — the `__debug_list_models__` branch, the `debug` field
on error responses, and revisiting the 20s Gemini timeout against the streaming
latency profile. Watch for that last one during Thu/Fri.
