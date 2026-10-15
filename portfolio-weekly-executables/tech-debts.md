# Tech Debts

**Must be cleared before a TestFlight release, if there is one. No App Store submission is planned.**

Debt lands here when fixing it mid-week would derail the MVP flow. Only items
**not already scheduled** in a weekly file belong here.

Not a week of sessions. It's a gate.

---

## Debug surfaces left in the function

- [x] **Delete the `__debug_list_models__` branch** in `chat/index.ts`. Sending
      that exact string as `message` returns the Gemini model list. Needs nothing
      but the publishable key, which ships inside the app.
      _Already gone: removed in `d7ab861` (2026-08-02). Confirmed absent from
      `index.ts` and `handler.ts` on 2026-10-03._
- [x] **Strip the `debug` field from error responses.** Returns upstream status,
      model name, and a truncated Gemini error body to the client.
      _Distinct from Week 3 Thu, which removes debug **logging**, not response
      payloads._
      _Done in Week 8 (Task 3). Re-observed on **Week 8 Fri (2026-09-29)**: the
      production 502 body was exactly `{"error":"Failed to get response from AI
      service."}`, while the upstream detail showed up only in the function
      logs._

## Guardrails that need enforcement, not instruction

- [x] **Configure Gemini `safetySettings` explicitly.** _Done in Week 10 Task 10:
      `BLOCK_MEDIUM_AND_ABOVE` for harassment, hate speech, sexually explicit
      and dangerous content (`GEMINI_SAFETY_SETTINGS`), with a test that none is
      `BLOCK_NONE`._ Not set at all today, so
      API defaults apply. Make it a deliberate choice in code and confirm no
      category is `BLOCK_NONE`.
- [ ] **Add the topical gate call.** _Deferred in Week 10 Task 10: it doubles
      Gemini calls on a free tier of about 20 a day. A periodic context reset
      is the preferred alternative once follow-ups exist (`beyond-mvp.md` §6)._ A separate Gemini call with a **fresh context**
      containing only the current message, answering yes/no to "is this a Vedic
      astrology question." Reject before the reading model is invoked.
      _Prompt-level scope is bypassable via long threads and fictional framing.
      A fresh context has no thread to accumulate into._
      _Costs a second round-trip per message; interacts with streaming._
- [x] **Reject known jailbreak framing** _Done in Week 10 Task 10:
      `detectJailbreak` in `moderator.ts`. A match gets a 400 ("I can only help
      with Vedic astrology questions."), never reaches Gemini, and doesn't use a
      turn._ — roleplay, "write a story where",
      "ignore previous instructions", "you are now".
      _Speed bump, not the wall. Denylists get bypassed by rephrasing; the gate
      call is the wall._

## Context integrity

- [ ] **Never accept conversation history from the client.** If the app can send a
      transcript, an attacker can forge one containing any "prior agreement".
      History lives server-side or not at all.
      _Not live yet — the backend is single-turn. Activates the moment follow-ups
      are added._
- [ ] **Bound the server-side context.** If follow-ups are supported, keep a capped
      summary rather than a raw transcript. Long-thread jailbreaks need room to
      accumulate; bounded context denies it.
- [ ] **RLS on birth-data and chart tables.** Birth date, exact time, and place is
      sensitive personal data, and charts derive from it.
      _Conditional: only live once those tables exist._

## Reply length & cost

- [x] **Decide the reply length policy.** _Decided in Week 10 Task 11: length
      guidance in `systemPrompt.ts` ("Keep a reading under about 250 words unless
      the person asks for more detail."), signed off by the product owner.
      `maxOutputTokens` stays at the model limit as a safety net._ Readings currently run 2,600–5,000
      characters. Nothing in weeks 1–9 caps or shapes output length. Options, not
      mutually exclusive:
      - `maxOutputTokens` in `generationConfig` — a hard server-side ceiling.
      - Length guidance in `systemPrompt.ts` — softer, keeps readings coherent
        rather than truncated mid-sentence.
      - Client-side collapse / "read more" in the chat UI.
      _Three reasons this is debt and not just polish: output tokens are the
      billed side of Gemini, so unbounded replies are unbounded cost; long
      replies hold a streamed connection open longer, which pushes against the
      timeout item below; and 5,000 characters is a lot of scroll on a phone._
      _If throttling is needed, note it stacks with Week 3 Tue rate limiting —
      that caps requests per session, this caps size per request. Different
      levers, both may be wanted._

## Observability

- [x] **Log refusals and safety blocks** with the session identifier, so a grinding
      client shows up in logs rather than on a Gemini bill.
      _Done in Week 10 Task 10: `[chat] refused: …` warnings for denylist
      matches, safety `finishReason`s and blocked prompts, each with the user and
      session id._
- [x] **Revisit the Gemini timeout** against the streaming latency profile.
      _Revisited in Week 10 Task 11. `GEMINI_TIMEOUT_MS` (45s) only covers the
      wait for response headers, so it never cut a long reading; but a stream
      that stalled part way had no limit. Added `GEMINI_STREAM_IDLE_TIMEOUT_MS`
      (20s between chunks): a stall ends the stream without `[DONE]`, or answers
      504 if nothing had arrived yet._ A
      streamed call holds the connection far longer than a blocking one, so the
      current ceiling may trip 504s mid-stream.
      _Streaming landed in Week 2. Revisit during Week 3 deploy (Fri test pass)._
      _It was 20s when this was written. `GEMINI_TIMEOUT_MS` is now 45s (raised
      in `f39c4f2`, the empty-200 fix). Week 9 Task 8 also added
      `maxOutputTokens: 65536`, so a long reading has more room to hit it._




## Conversation Threading & Topic Selection
- ~~Replace in-memory turn counter with persistent per-thread tracking (Postgres/KV)~~
  Done in **Week 8 Thu (Task 4)**. Both the turn counter and the rate limiter
  now live in Postgres. Deployed as function v16 and verified live on
  2026-09-29: the 429 and the 403 both tripped at request 21. See
  "Week 8 Thu — shared store for the counters" below.
- Add iOS topic/framework selector buttons (BaZi, Vedic, Western, etc.) that start scoped threads
- Send conversation history to Gemini for multi-turn context (enables better readings but requires turn limit as safety valve against context-drift attacks)
- Consider per-topic system prompts to keep the model on-rail


## Week 7 Wed — live end-to-end verification closed with gaps

Task 5 is ticked without clearing its headline criterion. What that pass did and
did not establish, so the gaps stay visible.

**Proven on device** — three passes on an iPhone 17 iOS Simulator: a second send
in the same session, a send after app relaunch, and a send from a fresh install
(erased device, no Keychain id, no stored auth session). All three signed in
anonymously, sent a valid `Authorization: Bearer <JWT>` with the publishable key
in `apikey`, cleared the 401 gate and body validation, and failed inside the
Gemini call with a 502. So **Task 4's token wiring is verified end-to-end on
device**, and the full iOS suite is green — 135 tests, 26 suites, 0 failures.

**Not proven** — no request ever returned HTTP 200, so no tokens ever streamed
into the transcript and there is no true end-to-end confirmation. The app path is
proven up to the Gemini call and no further.

_**Correction (Week 8 Fri).** This note used to say the blocker was the Gemini
free-tier allowance "and nothing else", and that nothing in this repo was at
fault. That was wrong. The quota 429s were real, but the function also had three
streaming bugs that would have stopped a 200 even with quota to spare: it called
`:streamGenerateContent` without `alt=sse`, it parsed per read instead of per
complete line, and it committed the 200 after a `setTimeout(0)` race, so the
client got `200 text/event-stream` with zero bytes. All three were fixed in
Week 8 Mon (Task 1) and regression-tested in Task 2. See "Week 8 Fri —
on-device verification attempt" at the end._

- [x] **Observe a streamed reply on device.** _Observed on the simulator in
      Week 9 Task 6 (2026-10-03), which the spec now allows: a long reading grew
      on screen. Auto-scroll didn't follow it (see "Week 9 — auto-scroll
      doesn't follow a reply")._ Re-run the device passes once a
      request can come back 200. _Still not observed as of **Week 8 Fri
      (2026-09-29)**. The streaming bugs are fixed and deployed. The attempt
      that day failed only because Gemini returned upstream `503 UNAVAILABLE`.
      Details in "Week 8 Fri — on-device verification attempt"._
- [x] **Verify the 20-turn 403 cap.** Verified against production on
      **Week 8 Thu (2026-09-29)**, function v16, Postgres-backed store — see
      "Week 8 Thu — live verification results" below. The 21st request on one
      session got HTTP 403 and a fresh `sessionId` went straight through.
      _The reset button was later run against the real 403 in Week 9 Task 6.
      See "Week 7's reset button" below._

## Authenticated curl tests not yet verified in production

- [x] **Test 400 — bad input (missing `message` field).** Verified against
      production on **Week 7 Wed**: with a valid anonymous access token and a body
      of `{"sessionId":"…"}`, the function answers HTTP 400
      `{"error":"Missing required field: message."}`. The same request with no
      `Authorization` header answers HTTP 401
      `{"error":"Missing or invalid authorization token."}`, which is the auth
      gate running ahead of body validation, exactly as `routeChat` orders it.
- [x] **Test happy path + SSE streaming.** Send a real astrology question with a
      valid token and confirm HTTP 200, `Content-Type: text/event-stream`, chunked
      `data:` events ending in `data: [DONE]\n\n`. Confirmed locally in Week 2 but
      still not curl-verified against production.
      _**Verified against production on 2026-09-30, function v16.**
      Fresh anonymous token (`POST /auth/v1/signup`, HTTP 200,
      `is_anonymous: true`), fresh `sessionId`, one `curl --http1.1 -N -i`
      probe with "In one sentence, what does Mercury retrograde mean?". Got
      `HTTP/1.1 200 OK`, `Content-Type: text/event-stream`, 4 text `data:`
      chunks and then `data: [DONE]`, in 7.8s total. Request
      `01a0f16a-eaf9-7728-bb3e-1b1bc70ca087`, execution `9dce09dc…`. The
      function logs show `Gemini responded | status: 200` after 4346 ms for
      `gemini-3.6-flash`. The 503/429 notes below are kept for history._
      _**Correction (Week 8 Fri).** The Week 7 notes below treat Gemini quota as
      the only thing between this test and a 200. It wasn't. Even with Gemini
      answering 200, the deployed function would have sent an empty 200 because
      of the three streaming bugs fixed in Week 8 Mon (Task 1): no `alt=sse`, no
      line buffering across reads, and the `setTimeout(0)` commit race. The
      Week 7 notes are kept for history. The quota and 503 observations in them
      are accurate. The conclusion that nothing in the repo was at fault is not._
      _**Re-attempted Week 8 Fri (2026-09-29) and still not verified.** Function
      v16 with the Task 1 fix. Four curl attempts and two
      app sends from the simulator all got HTTP 502 `{"error":"Failed to get
      response from AI service."}`. For each one, the function logs show Gemini
      answering `503 UNAVAILABLE` ("This model is currently experiencing high
      demand") for `gemini-3.6-flash`, in 1.7–10.8s. The fixed request does carry
      `?alt=sse` (`handler.ts`, `GEMINI_STREAM_QUERY`). No 200 was observed, so
      this stays unchecked._
      _No longer blocked on auth — the token is obtainable and the request now
      gets past the 401 and past body validation, all the way to the Gemini call.
      It is blocked on Gemini. Two failure modes seen on **Week 7 Wed**: first
      HTTP 504 `{"error":"AI service timed out.","debug":{"stage":"fetch","name":"AbortError"}}`
      at ~21s, the 20s `GEMINI_TIMEOUT_MS` (45s since `f39c4f2`) firing on a call that never answered;
      then, for the rest of the session, HTTP 502 with
      `debug.status: 429` and a Gemini body of `RESOURCE_EXHAUSTED` —
      `Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests`.
      Related: the Gemini-timeout item under **Observability**._
      _**Re-attempted Week 7 Wed (second pass) and still not verified.** Three
      things were established, none of which produced a 200:_
      _1. **`gemini-3.6-flash` is a valid model id.** Worth stating because a bad
      id was the competing hypothesis. Gemini's own 429 body names it with a
      per-model allowance — `limit: 20, model: gemini-3.6-flash` — and an unknown
      model answers `404 NOT_FOUND`, not a per-model quota error. The quota
      attribution above stands; this is not a model-name problem._
      _2. **The quota is scoped per model**, which means switching `GEMINI_MODEL`
      is a third way out alongside waiting for a reset and leaving the free tier._
      _3. **The retry hint does not behave like a per-minute window.** First probe
      said `Please retry in 41.87852323s`, then 75s of idle, then the next probe
      said `Please retry in 50.644565568s` — it moved further out, not closer.
      Whether this is a per-day bucket with a misleading hint is unresolved,
      because `debug.body` is truncated at 500 chars (`truncate`, `handler.ts`) and
      cuts off before the `QuotaFailure` details that carry the `quotaId`. If this
      is retried, raise that cap first or read the body Gemini-side._
      _Also confirmed the `__debug_list_models__` branch is **already gone** from
      deployed version 12 — sending that string goes through to Gemini as an
      ordinary prompt. The debt item for it under **Debug surfaces** is about the
      source tree, not production behaviour._
      _**Re-attempted Week 7 Wed (third pass, 2026-09-22) — still not verified.**
      Deliberately capped at two calls to the function, to stop this test burning
      the allowance it is waiting on. A fresh anonymous token first
      (`POST /auth/v1/signup`, HTTP 200, `is_anonymous: true`), then one short
      question with a throwaway `sessionId`, then one retry of it. Both answered
      HTTP 502 at the gateway, and both cleared the auth gate and body validation —
      the failure is still entirely inside the Gemini call._
      _The first of the two is a **new** failure mode: `debug.status: 503`,
      `UNAVAILABLE`, "This model is currently experiencing high demand", returned
      in 6.1s. That is not a quota refusal, so at that moment the request was
      being accepted and served — the blocker was capacity, not the free tier._
      _The second, 20s later, was back to `debug.status: 429` /
      `RESOURCE_EXHAUSTED`, `limit: 20, model: gemini-3.6-flash`, "Please retry in
      25.599617113s", in 1.8s. So the quota ceiling is still the standing
      blocker; the 503 was a transient window on top of it. Note the difference in
      latency: a quota refusal comes back in under 2s, an overload took 6s, and a
      hung call takes the full timeout (20s then, 45s now) — useful for telling the three apart
      without reading the body._
      _Still unresolved, and unchanged by this pass: whether the bucket is
      per-minute or per-day. The retry hints remain inconsistent with a 60s window
      and `debug.body` is still truncated at 500 chars before the `QuotaFailure`
      details. Raise that cap before the next attempt._
      _No production configuration was changed. Getting this to 200 is a decision
      about the Gemini plan — wait out the bucket, switch `GEMINI_MODEL` to one with
      its own allowance, or leave the free tier — not more test attempts. No device
      pass was run this round either: it would have reproduced the same backend
      failure at much higher cost._
- [x] **Test 429 — rate limiting under load.** _Verified against production on
      **Week 8 Thu (2026-09-29)** once the limiter moved to Postgres: requests
      1–20 on one session passed the limiter, 21 and 22 answered HTTP 429 with
      `Retry-After: 56`. See "Week 8 Thu — live verification results" below.
      The Week 7 notes that follow are kept for history._
      Rapid-fire 12+ requests on the same
      session and confirm the threshold triggers `{"error":"Rate limit exceeded. Try again later."}`
      with HTTP 429 and a `Retry-After` header.
      _Attempted against production on **Week 7 Wed** and it did not trigger: 25
      concurrent requests, then 29 sequential, then 70 sequential in 73s, all on a
      single `sessionId`, and not one came back 429 — nor 403 from the 20-turn cap,
      which shares the same shape of state. The window is 20 per 60s, so 70
      requests in 73s should have tripped it several times over. The counters live
      in each isolate's memory (`rateLimiter.ts`, `turnCounter.ts`), and requests
      to a low-traffic function get spread across isolates that each start empty,
      so neither limit is actually enforced in production today. **This is an
      enforcement gap, not just an untested one** — see "Replace in-memory turn
      counter with persistent per-thread tracking" under **Conversation Threading
      & Topic Selection**; the rate limiter needs the same shared store. Retest
      once it has one._

_**Correction (Week 7 Wed).** The blocked-reason note that stood here said there
was "no way to programmatically obtain an access token without admin/service-role
intervention", and a Week 6 correction on top of it said the client had no auth
flow at all. Both are now out of date. Anonymous sign-ins are enabled on the
remote project (Week 7 Mon), so a token is obtainable two ways: the iOS client
signs in anonymously through `supabase-swift` and sends the resulting JWT as
`Authorization: Bearer <access token>`, with the publishable key staying in the
`apikey` header where it belongs; and for curl, `POST /auth/v1/signup` with the
publishable key and an empty JSON body returns an `is_anonymous` user's
`access_token` in one round trip. Nothing here is blocked on auth any more._

_Where that leaves the three (updated Week 8 Fri): the 400 test is done, and the
429 test is done (Week 8 Thu, Postgres-backed limiter). The happy path is still
open. Its code bugs are fixed (Week 8 Mon). What's left is Gemini actually
answering 200. On 2026-09-29 it was answering `503 UNAVAILABLE` for
`gemini-3.6-flash`. Getting past that is a model or plan decision (retry later,
set `GEMINI_MODEL`, or leave the free tier), not a code fix._

### Gemini model configuration — where it lives, and what is actually set

Recorded here because a future reader will go looking for a `GEMINI_MODEL` secret
and not find one.

- The model is read at `handler.ts` as `deps.env("GEMINI_MODEL") ?? DEFAULT_GEMINI_MODEL`,
  with `DEFAULT_GEMINI_MODEL = "gemini-3.6-flash"` in the same file. The endpoint is
  `${GEMINI_API_BASE}/models/${model}:streamGenerateContent` against `v1beta`.
- **`GEMINI_MODEL` is not set on the remote project.** `supabase secrets list`
  returns only `GEMINI_API_KEY` and the `SUPABASE_*` set, so production is running
  the code default. Changing the model today means either setting the secret or
  editing `handler.ts` and redeploying.
- Switching the model was **approved but not carried out** in Week 7 Wed. Choosing a
  target needs `ListModels` to see which ids exist and support `generateContent`,
  and that needs the `GEMINI_API_KEY` value — which the CLI will not reveal, it
  returns digests only. Guessing ids without that list risks trading a quota 502 for
  a 404 one. Unblocking this needs the key from whoever holds it; nothing in the
  repo has it.

## Week 8 Thu — shared store for the counters

**Deployed and verified live on 2026-09-29.** Migrations `20250801000000` and
`20260929000000` are applied and function v16 is deployed. Both limits tripped
in production as designed. See "Week 8 Thu — live verification results" at the
end.

What changed:

- **Store: Postgres**, via migration `20260929000000_create_chat_limits.sql`.
  Already in the project, no new service or secret. Two tables
  (`chat_rate_limits`, `chat_turn_counts`) and two functions
  (`chat_check_rate_limit`, `chat_increment_turn`). The edge function calls them
  over PostgREST RPC with the service-role key, the same way `handleReport`
  writes `reports`.
- **Atomic.** The turn increment is one `INSERT … ON CONFLICT DO UPDATE …
  RETURNING`. The sliding window is pruned, counted, and appended under a
  `SELECT … FOR UPDATE` row lock, so concurrent isolates queue up instead of
  both slipping under the limit. The window uses the database clock, not each
  isolate's own.
- **Locked down.** RLS is on with no policies, and table and function privileges
  are revoked from `PUBLIC`, `anon`, and `authenticated`. Only `service_role`
  can read or call anything, so the publishable key can't read, reset, or
  inflate anyone's counters.
- **Fails closed.** If the store is unreachable, times out (5s), or returns a
  bad shape, the function answers **503** `{"error":"Service temporarily
  unavailable. Please try again shortly."}` and doesn't call Gemini. These are
  the only per-session caps on Gemini spend, so a store outage shouldn't turn
  them off. The tradeoff is that a DB outage takes chat down too. Chat already
  depends on the same project for auth, so that isn't a new dependency.
- The per-isolate `Map`s are gone from the production path. They're kept as
  `createInMemoryRateLimiter` / `createInMemoryTurnCounter`, test fakes that
  behave the same way. Deno suite: 71 passed (was 53).

Still open after this lands:

- [x] **Keyed by client-supplied `sessionId`, not by user.** _Fixed in Week 10
      Task 7 (function v19): the rate limit is keyed on `user:<userId>`. The turn
      cap stays per session on purpose._ A client that picks
      a new `sessionId` for every request gets past both caps. The Week 7 reset
      button relies on exactly that to reset the turn cap. Real spend protection
      needs a per-`userId` ceiling on top, and anonymous sign-in is itself
      limited to 30 per hour per IP (`auth.rate_limit.anonymous_users`).
      _Since Week 10 Task 4 the app itself mints a new `sessionId` on every
      launch, so a relaunch also resets both caps._
- [x] **No row expiry.** Both tables gain one row per session and never shrink.
      _Fixed in Week 10 Task 12 (`20261004010000`): a daily pg_cron job
      (`chat-expire-limit-rows`, 03:17 UTC) deletes rate-limit rows idle for 1
      day and turn rows idle for 7. A manual run on 2026-10-04 took rate-limit
      rows from 18 to 4._
      _Grows faster since Week 10 Task 4: one session per launch now._
      Add a periodic `DELETE … WHERE updated_at < now() - interval '…'`
      (pg_cron), or accept the growth until volume makes it matter.
- [ ] **Two extra round trips per message** (rate check, then turn increment).
      Small next to Gemini latency, but they could become one RPC if it matters.
- [x] **The SQL hasn't run anywhere yet.** It has now. The live pass on
      2026-09-29 ran both plpgsql functions in production: 42 requests across 2
      sessions, with no store 503 at any point. There's still no local Postgres
      test of the SQL itself.

Steps to finish Task 4. Steps 1–5 were run on 2026-09-29, except the
on-device reset in step 5:

1. `supabase db push` (from the repo root, project linked). Applies the migration.
2. `supabase functions deploy chat`.
3. Get an anonymous token: `POST /auth/v1/signup` with the publishable key and
   `{}`.
4. **429:** send 21+ requests on one fresh `sessionId` within 60s. Expect HTTP
   429 with a `Retry-After` header once 20 are accepted. Watch the cost: the
   first 20 each reach Gemini. `supabase/rate_test*.py` already does this.
5. **403:** send 21 requests on one fresh `sessionId`, spaced to stay under
   20/min. Expect HTTP 403 `Conversation limit reached…` on the 21st. That also
   means 20 Gemini calls, and each one counts toward the turn cap even if
   Gemini fails. Then run Week 7's reset button against it on device.
6. **Fail-closed spot check (optional):** the function's logs should show no
   `[chat] error debug detail | {"stage":"rate-limit"…` or `"turn-limit"` lines
   during the passes above.

### Week 8 Thu — live verification results (2026-09-29)

Ran against production, function v16. Each test got its own fresh anonymous
token from `POST /auth/v1/signup`. Gemini (`gemini-3.6-flash`) was returning
upstream 503 "high demand" the whole time, so every request that got past the
limits came back **502** `Failed to get response from AI service.` That doesn't
affect the result, because both limit checks run before the Gemini call. It
does mean **no 200 was observed**.

**Test A (rate limit)**, session `limit-A-eaacc34f-33f9-4d4f-8eba-6e8d4d2dfd95`.
22 requests sent 0.25s apart, all within about 5.3s.

- Requests 1–20: `502` ×20. No 429, 403 or 503.
- Requests 21–22: `429` `{"error":"Rate limit exceeded. Try again later."}`,
  both with `Retry-After: 56`.
- **Tripped exactly at 21.** `Retry-After: 56` fits a 60s window that opened
  at request 1, about 5s earlier.

**Test B (turn cap)**, session `limit-B-3d5894af-ff2e-4898-b0fc-fb284b722a09`.
21 requests sent 3.2s apart, over about 65s. That
spacing keeps any 60s window under 20 requests, so the rate limit could not
fire.

- Requests 1–20: `502` ×20. No 429, 403 or 503.
- Request 21: `403` `{"error":"Conversation limit reached. Please start a new thread."}`.
- **Tripped exactly at 21.**
- Reset path: one request on a brand-new session
  `limit-B-reset-e968c120-a90a-49d8-a9c5-c92174fc13ca` right after
  returned `502`, not 403. Changing the `sessionId` clears the cap, as intended.

**Fail-closed:** our function never answered 503 (`Service temporarily
unavailable…`), so the store stayed reachable throughout. Function logs were
not read during this pass.

**Cost:** 41 requests reached Gemini (20 in Test A, 20 in Test B, plus the
reset request). All were refused upstream.

Still to re-check once Gemini recovers:

- [x] **Happy path.** A request under both limits should return 200 with a
      streamed reply. Every allowed request in this run was a 502 upstream.
      _Verified **Week 9 Task 6 (2026-10-03)**: `LiveStreamingUITests` passed
      against production (function v18) on fresh install, second send and send
      after relaunch, with a reply and no error banner each time._
- [x] **Week 7's reset button on device.** Drive a session to the real 403 on
      device, tap reset, and confirm the next send goes through with a reply.
      The server side of the reset is proven above. The on-device flow and the
      reply rendering aren't.
      _Verified **Week 9 Task 6 (2026-10-03)** on the simulator, which is
      enough here since the 403 comes from production either way. Session
      `3C21F24D…` was set to 20 turns in `chat_turn_counts`. The next send
      took it to 21 and got the real 403. After tapping "Start new
      conversation", session `05DE18FF…` sent turn 1 and got a
      reply._

## Week 8 Fri — on-device verification attempt (2026-09-29)

**Result: not verified.** No reply streamed, on device or over curl. Every failure
came from Gemini, not from this repo. Week 7 Wed's done-condition is still
unmet.

What was run:

- **Curl, production, function v16.** Each run used a fresh anonymous token
  from `POST /auth/v1/signup`. 4 requests, all
  `502 {"error":"Failed to get response from AI service."}`,
  `Content-Type: application/json`, in 3.6–12.8s.
- **Simulator, iPhone 17, fresh install** (app uninstalled first).
  `AstrologieUITests/LiveStreamingUITests` is a new opt-in XCUITest. It types a
  question, sends it, and asserts that an "Astrologer said:" bubble shows up
  and grows over more than one poll, with no error banner. It failed on the
  first send with the banner `Error: Failed to get response from AI service.`
  The function logs show that send passed auth and reached Gemini, so
  fresh-install sign-in worked. The second-send and relaunch steps never ran
  because the test stops at the first failure.
- **Function logs** (Management API `analytics/endpoints/logs`). Every attempt
  logged `Gemini returned non-OK | status: 503 Service Unavailable | model:
  gemini-3.6-flash`, with the body "This model is currently experiencing high
  demand".
- **Unit suite** (`AstrologieTests`) passed on the same simulator.

Re-run once Gemini answers 200:

```sh
xcrun simctl uninstall booted com.pinkysalvanera.Astrologie
TEST_RUNNER_ASTRO_LIVE=1 xcodebuild test -project Astrologie/Astrologie.xcodeproj \
  -scheme Astrologie -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:AstrologieUITests/LiveStreamingUITests
```

That covers fresh install, a second send, and a send after relaunch. Before
checking off "Observe a streamed reply on device", a person should still watch
at least one reply stream in, on a physical device if one is available.

**Retry (2026-09-29): still not verified.** Two curl probes to
function v16. Each used a fresh anonymous token (`POST /auth/v1/signup`, HTTP
200, `is_anonymous: true`) and a fresh `sessionId`:

- First probe: `502 {"error":"Failed to get response from AI service."}`,
  `Content-Type: application/json`, 7.4s, 0 `data:` lines.
- Second probe: the same 502 body and content type, 7.1s, 0 `data:` lines.

Both got past auth and body validation. That 502 body only comes from the
Gemini-call branch (`UPSTREAM_FAILURE`). The ~7s latency matches the earlier
503-overload pattern and not a quota refusal (<2s). **The upstream cause was
not confirmed.** The function logs couldn't be read this time. Supabase removed
`analytics/endpoints/logs.all` on 2026-09-23 (it now answers 410). Its
replacement, `analytics/endpoints/logs`, answered `Backend error! Retry your
query.` to every `logs`/`source_name` query tried. Read the logs from the
dashboard Logs Explorer instead, or retry the new endpoint later. The UI test
was not run, and no checkboxes were changed.

_**Confirmed later (next log pass).** Both probes were Gemini `503
UNAVAILABLE`. Request `01a0ee37-9b61-7085-b841-b8b5f8ca7529` (execution
`20406738…`) logged `Gemini responded | status: 503` after 4471 ms. Request
`01a0ee3b-4e3b-79de-a8a5-1bf721baec30` (execution `fafd896c…`) logged the same
after 4921 ms. Both carried the body "This model is currently experiencing high
demand". The earlier inference was right. The log endpoint wasn't broken. The
query was wrong: the column is `source`, not `source_name`._

### Week 8 Fri — logs readable, cause confirmed (2026-09-29)

**Result: still not verified. The cause is Gemini, confirmed from the function
logs.** Every 502 today is (a), Gemini returning a non-200. None is (b), a
Gemini 200 whose stream ended before a text chunk. Across 2026-09-29 up to
this pass (function v16), the function logged 54 `[chat] Gemini
responded` lines: **32 × 429, 22 × 503, 0 × 200**. No stream ever reached
the parser, so the "hold the 200 until first text" path in `handler.ts` never
ran in production. There is no code-side stream problem to point to.

Reading the logs:

- Endpoint: `GET /v1/projects/{ref}/analytics/endpoints/logs?sql=…&iso_timestamp_start=…&iso_timestamp_end=…`
  (range ≤ 24h), with the CLI's access token as a Bearer token. The SQL is
  ClickHouse. There is one `logs` table, filtered with **`source =
  'function_logs'`** (console lines) or **`source = 'function_edge_logs'`**
  (one row per invocation, with `log_attributes['request_id']`,
  `['execution_id']`, `['response.status_code']`, `['execution_time_ms']`,
  `['version']`). Join the two on `log_attributes['execution_id']`.
- `where source_name = 'function_logs'` returns **HTTP 200** with the body
  `{"error":"Backend error! Retry your query. …"}`. That's what "Backend error"
  meant in the earlier retry: a bad column, not permissions and not the time range. The
  Supabase changelog for the migration says `source_name`, but the API
  reference and the query guide say `source`, and only `source` works.
- The Supabase CLI (2.109.1) has no logs command. The docs say the CLI doesn't
  query these logs.

Probes this pass (fresh anonymous token and fresh `sessionId` each time,
`curl --http1.1 -N -i --max-time 90`):

- Request `01a0eeb5-b292-7214-abc7-deb56a318e8c`: `502
  {"error":"Failed to get response from AI service."}`, `Content-Type:
  application/json`, 11.5s, 0 `data:` lines, no `[DONE]`. Log: Gemini `503
  UNAVAILABLE` "high demand" after 9367 ms.
- Request `01a0eeb7-6c71-7fa0-9c83-212ec2958187`: the same 502 body
  and content type, 2.2s, 0 `data:` lines. Log: Gemini `429
  RESOURCE_EXHAUSTED`, `generate_content_free_tier_requests, limit: 20, model:
  gemini-3.6-flash`, "Please retry in 4.7s", after 299 ms.

So `gemini-3.6-flash` is now both overloaded **and** over its free-tier
request quota. Two 429s earlier that day came from requests outside these
passes.

_**Correction to "Week 8 Thu — live verification results".** That section
says Gemini "was returning upstream 503 'high demand' the whole time". The logs
for that run show **29 × 429 and 12 × 503**, so most of those 41 upstream
refusals were free-tier quota, not overload. The 429/403 limit results
themselves stand, because both checks run before the Gemini call._

Tooling note: the local `/usr/bin/curl` (8.7.1, SecureTransport) failed with
`curl: (43) A libcurl function was given a bad argument` (HTTP 000, ~0.07s) on
requests to `dpmzorjfuzfpxthyqiyg.supabase.co` over HTTP/2, including
`/auth/v1/signup`. `--http1.1` fixes it. `api.supabase.com` was not affected.

The UI test was not run, because no request returned 200. No checkboxes were
changed.

_**Update 2026-09-30:** Gemini answered 200 twice this morning. See "Week 8
Fri — retry, first 200s" below. Left unchecked because the device test didn't
pass._

- [x] **Gemini `503 UNAVAILABLE` on `gemini-3.6-flash`.** _Cleared: 200s
      since 2026-09-30, and the Week 9 Task 6 live run (2026-10-03) got three.
      The free-tier 429 (`limit: 20`) can still bite on a heavy test day._
      This is the only blocker
      left on this path. _As of 2026-09-29, the model also answers
      `429 RESOURCE_EXHAUSTED` (free tier, `limit: 20`), confirmed in the
      function logs. Waiting out the overload alone won't be enough._ Options: retry later, set a `GEMINI_MODEL` secret to
      a model with capacity (that needs `ListModels`, and so the API key; see
      "Gemini model configuration" above), or move off the free tier.

### Week 8 Fri — retry, first 200s (2026-09-30)

**Result: production streams a 200, confirmed over curl. The device test failed
on its own streaming assertion, not on the app.** `chat` is still ACTIVE at
v16.

**Curl probe (1 Gemini call).** Fresh anonymous token and fresh `sessionId`,
request `01a0f16a-eaf9-7728-bb3e-1b1bc70ca087`: `200`,
`text/event-stream`, 4 text `data:` chunks and then `data: [DONE]`, in 7.8s.
Log: `Gemini responded | status: 200` after 4346 ms. "Test happy path + SSE
streaming" is checked off above.

**Live UI test (1 run, 1 Gemini call).** iPhone 17 simulator (iOS 26.5), app
uninstalled first, result bundle `/tmp/astro_live.xcresult` (deleted afterwards).

- First send, fresh install: sign-in worked. The request
  (`01a0f16e-21df-7844-a8f2-055f7b009d64`) got a 200, and Gemini answered 200
  after 5880 ms. A 273-character "Astrologer said:" bubble rendered with no
  error banner (screenshot checked).
- The test then failed: `reply appeared in one piece; streaming not observed.
  observed reply lengths: [273]`. The second send and the relaunch step never
  ran.
- **Why: the test can't observe streaming on a short reply.** Gemini's
  "responded" log line (headers) and the end of the invocation were 34 ms
  apart, so the whole stream arrived within about 34 ms. The curl probe
  shows the same gap (33 ms). The test polls every 0.5s, and its first sight of
  the bubble came about 0.4s after the stream had already ended. This is the
  test's design (one-sentence prompts, coarse polling), not an app bug and not a
  selector problem, so the test was left unchanged. Options: use prompts that
  produce long replies (costs more tokens), or drop the "more than one length"
  assertion and prove incremental rendering in unit tests instead.

Not verified: incremental rendering in the app, second send, send after
relaunch. No checkboxes were changed besides the happy-path curl item.

Side note: the function logs `timeout_ms: 45000` for the Gemini call. The
earlier notes that said 20s were annotated with the current 45s in Week 9 Task 6.

## Week 9 — haptics not verified on device

Task 2 (haptics for send and reply completion) is implemented and unit-tested,
but it hasn't been felt on a physical device. **Access to a real device is
blocked right now**, and the simulator can't play haptics. So Task 2's
done-condition is unmet, and it stays in progress rather than completed.

**Proven:** `ChatHapticTests` (9 tests) passed on the iPhone 17 simulator along
with the rest of `AstrologieTests`. They confirm the right haptic is
*requested* for each `ChatState` transition: send → `.impact(weight: .light)`,
`.streaming` → `.idle` → `.success`, failure → `.error`, cancel → none. They
also confirm the success haptic is never requested on a failure.

**Not proven:** that the three haptics actually play, and that they feel
different from each other.

- [ ] **Feel the haptics on a physical device.** Once a device is available:
      1. Send a message and check you feel a light tap.
      2. When the reply finishes, check the success pattern feels different
         from the send tap.
      3. Force a failure (airplane mode, or the turn-limit 403) and check you
         get the error pattern, never the success one.
      Then mark Task 2 completed in `.kiro/specs/astrology-chat/tasks.md`.
      _Can be done in the same device session as Task 6's checks and the
      "Observe a streamed reply on device" item above._

## Week 9 — `reports` table privileges

Found during Task 4 (2026-10-02). `reports` was created in
`20250801000000_create_reports_table.sql` with RLS on but no explicit grants.
In production, `anon` and `authenticated` hold `TRIGGER, REFERENCES, TRUNCATE`
on it. RLS doesn't stop `TRUNCATE`, so only the API not exposing it stands
between a client role and an emptied table. Low risk, but it's the opposite of
what `chat_rate_limits` and `chat_turn_counts` do.

(Task 4 also found `service_role` had no `INSERT`, so no report had ever been
stored. That one was fixed in Task 4 by
`20261002000000_grant_reports_insert_to_service_role.sql`.)

- [x] **Revoke client-role privileges on `reports`.** _Done in Week 10 Task 9
      (`20261004000000`). Only `postgres` and `service_role` remain, and a report
      from the simulator still stored on 2026-10-03._ Add a migration with
      `REVOKE ALL ON TABLE public.reports FROM PUBLIC, anon, authenticated;`,
      matching `20260929000000_create_chat_limits.sql`. Then confirm with
      `information_schema.role_table_grants` that only `postgres` and
      `service_role` have privileges, and that a report still stores.

## Week 9 — VoiceOver not verified on device

Task 5 (VoiceOver and Dynamic Type) is marked done, but its VoiceOver half was
checked only in code and unit tests. The simulator can't run VoiceOver, and the
physical device can't pair with Xcode right now.

**Proven:** at the largest accessibility text size on the iPhone 17 simulator,
bubbles, the "Report Message" menu item, the wrapped compose placeholder and the
scaled send button all fit with no clipping or overlap.
`ChatViewAnnouncementTests` (11 tests) confirm VoiceOver is *asked* to announce
the typing indicator and the error banner, and nothing else.

**Not proven:** what VoiceOver actually says, and the report menu's new
fixed-size preview. Relaunching cleared the conversation, and Gemini was out of
quota for a new reply.

- [ ] **Run VoiceOver on a physical device.** Check that:
      1. Sending announces "Astrologer is typing" once.
      2. A streaming reply isn't re-read on every chunk.
      3. Bubbles read "Astrologer said: …" with no stray `#` or `*`.
      4. "Report Message" is in the Actions rotor on finished replies, and not
         on your own messages or on a reply that's still streaming.
      5. A failure (airplane mode) announces "Error: …".
      _Can be done in the same device session as the haptics check above._
- [x] **Check the report menu preview at the largest text size.** _Checked on the
      simulator in Week 10 Task 13 (2026-10-04): a few lines at a fixed width,
      clear of the menu._ Long-press a
      long reply. The preview should show a few lines at a fixed width, not a
      thin column behind the menu.

## Week 9 — a "new" chat after relaunch isn't a new session

Found during Task 6 (2026-10-03). After a relaunch the transcript is empty, since
messages live in memory only (`beyond-mvp.md` §5). But `SessionManager` reuses
the Keychain session id forever (the Week 4 done-condition), so the backend's
turn counter carries on from the previous launch. A chat that looks brand new can
hit "Conversation limit reached" early. Seen on the simulator: "I'm Nene" after a
relaunch landed as turn 4 of the live test's session.

Related: "Start new conversation" mints a new id but keeps the old messages on
screen (a deliberate Week 7 choice, `ChatViewModel.startNewConversation()`). The
label promises a new conversation, and Gemini never sees prior messages anyway,
so the kept transcript is display-only.

_Decided 2026-10-03: a new session id on each launch, and "Start new
conversation" clears the transcript. Scheduled in `week-10.md` (Wed, bug fixes
from Week 9), so it's tracked there, not here._

## Week 9 — auto-scroll doesn't follow a reply

Found during Task 6 (2026-10-03) on the simulator. While a long reading
streamed in, the transcript stayed where it was, and the new reply had to be
scrolled to by hand. The typing indicator wasn't seen either, possibly for the
same reason. `ChatViewScrollTests` only test the `ScrollAnchor` rule, not the
real scroll.

- [x] **Fix auto-scroll for a new reply and the typing indicator.** _Fixed in
      Week 10 Task 3: scrolls are deferred until the new row is laid out._ Start with
      `ChatView.scroll(to:from:using:)` and the `onChange(of: ScrollAnchor…)`
      wiring. _Scheduled in `week-10.md` (Wed)._

## Open-source hardening — minting anonymous users

Decided 2026-10-14 (open-source hardening, Task 7). Anonymous sign-in needs only
the publishable key, so a script can mint users, each with a fresh per-user rate
limit. The anonymous sign-in limit is now 5 an hour per IP (was 30), and the
global daily cap (Task 5) bounds total calls. On the free tier, Google's ~20
calls a day is the real ceiling, so abuse can use up the day's quota early but
can't cost money.

- [ ] **Add CAPTCHA on anonymous sign-in, or App Attest.** _Deferred: both need
      app and server changes, and on the free tier nothing can be billed._
      Revisit before turning on billing for the Gemini key.
