# Week 8 — Closing the Gaps Found Verifying Week 7 Live

Progress: 1/5 sessions (20%)

Backend-heavy. Week 7's Wed task was ticked with its own done-condition unmet —
"replies stream on device" never actually happened, and `tech-debts.md` said so.
Chasing that down live (not in this file yet) surfaced a real bug in `chat`'s
streaming path, plus a security leak and a durability gap that were already
sitting in `tech-debts.md` unaddressed. This week clears all of it.

## The gap this week closes

`handler.ts`'s streaming path had three compounding bugs, found by reproducing a
production failure with curl rather than trusting the green test suite:

- **Wrong wire format.** `:streamGenerateContent` was called without `alt=sse`,
  so Gemini returned a pretty-printed JSON array whose lines never parse as
  standalone objects. Every chunk was silently dropped.
- **No buffering across reads.** Lines were parsed per-read rather than
  per-complete-line, so a JSON object straddling a read boundary broke into two
  unparseable halves — a real-network failure mode a synchronous mock stream
  can't reproduce.
- **A commit race.** The 200 status was sent after a bare `setTimeout(…, 0)`,
  a delay long enough for the tests' synchronous mocks but never long enough for
  a real network response. The client ended up with `200 text/event-stream` and
  zero bytes — indistinguishable from a client bug, which is what made this look
  like an iOS problem for two rounds of investigation.

All three passed 135 green tests, because the mock Gemini responses encoded the
same wrong format the parser expected. Fixed and reproduced live in the same
session: first production 200 with real streamed content this project has had.

Two more items came out of the same investigation, already logged in
`tech-debts.md` but not yet fixed:

- **Error responses leak internals.** The `debug` field on error bodies returned
  upstream status codes, model names, and Gemini error text to any caller —
  including a caller with nothing but the publishable key, which ships inside
  the app.
- **Rate limit and turn limit don't work in production.** Both counters live in
  per-isolate memory. Supabase spreads requests across isolates that each start
  empty, so 70 requests in 73 seconds never tripped the 429, and the 403 turn cap
  has never fired outside a test. Week 7's client-side reset button for the 403
  (Fri, Task 8) has no way to be exercised live until this is fixed.

## Mon, Sep 28 — Fix the SSE streaming bug in `chat`
_Closes: the empty-200 regression found verifying Week 7 Wed_

- [ ] Add `alt=sse` to the `streamGenerateContent` request so Gemini returns
      actual SSE framing (`data: {...}\n\n` per line) instead of a JSON array.
- [ ] Rewrite the chunk reader to buffer across reads and only parse complete
      lines, so an object split across two reads doesn't break.
- [ ] Hold the 200 response open until the first real text chunk has arrived
      instead of racing a `setTimeout(0)` against the network. A stream that
      fails before any text arrives should still be a reportable error status,
      not a committed 200 with an empty body.
- [ ] Log parse failures instead of swallowing them in a bare `catch {}` — that
      silence is what hid this for two weeks.
- **Done when:** a real production request returns `200 text/event-stream` with
  actual chunked text and a clean `data: [DONE]\n\n` close, confirmed via curl
  against the deployed function, not just a passing test.

## Tue, Sep 29 — Rewrite the test mocks to match Gemini's real format
_Closes: the test-suite blind spot that let Monday's bug ship_

- [ ] Replace the bare newline-delimited-JSON mock with one that emits real
      `alt=sse` framing across genuinely separate reads (not one synchronous
      burst), so the suite can catch a read-boundary split.
- [ ] Add a regression test for the empty-200 case specifically: a 200 stream
      that never yields a text part must answer 502, never a bodyless 200.
- [ ] Add a test asserting the request actually carries `alt=sse`, so losing it
      again fails loudly instead of silently.
- **Done when:** the suite would have caught Monday's bug before it shipped —
  verify by reverting Monday's fix locally and confirming the new tests fail.

## Wed, Sep 30 — Stop leaking internals in error responses
_Closes: the `debug` field tech-debt item_

Done ahead of schedule, during the same session that found the SSE bug above —
the leak was sitting right next to it in the same file, so it got fixed and
deployed before this week's plan existed. Logged here anyway so the week's scope
stays accurate.

- [x] Strip `debug` from every client-facing error response. Log the same detail
      server-side (`console.error`) instead.
- [x] Update `errorResponse` so `debug` can never reach `Response.json` again —
      make the leak structurally impossible, not just absent today.
- [x] Confirm the 429 response's `Retry-After` header (already client-useful)
      is untouched — only the redundant `debug.retryAfterMs` body field goes.
- **Done when:** every error path returns `{ error: string }` and nothing else,
  confirmed with a test that fails if any response body contains a `debug` key.
  ✅ Verified live against production: a 400 now returns
  `{"error":"Missing required field: message."}` with no `debug` key.

## Thu, Oct 1 — Rate limit and turn limit need a shared store
_Closes: the tech-debt item on in-memory counters, and unblocks Week 7 Fri's
turn-limit escape hatch, which currently has no 403 to respond to in production_

- [ ] Pick a shared store for both counters — Postgres table or a KV store,
      whichever fits the existing Supabase setup with the least new
      infrastructure.
- [ ] Move `rateLimiter.ts` and `turnCounter.ts` off per-isolate memory onto it.
- [ ] Re-run the rate-limit and turn-limit curl tests parked in `tech-debts.md`
      against production and confirm they actually trip this time.
- **Done when:** rapid-fire requests trigger a real 429 in production, and the
  20-turn cap fires a real 403 that Week 7's reset button can be exercised
  against.
- **This is the one with real cost exposure.** Until this lands, nothing caps
  Gemini spend per user or per session in production.

## Fri, Oct 2 — Verify on device, close the loop, buffer
_Closes: Week 7 Wed's original, still-unmet done-condition_

- [ ] Run the app on a real device or simulator and confirm a reply streams into
      the transcript with no error — the thing Week 7 Wed claimed and didn't
      deliver.
- [ ] Re-run all four Week 7 Wed cases now that streaming actually works: second
      message, after relaunch, fresh install.
- [ ] Update `tech-debts.md`: check off the happy-path SSE test and correct any
      note that still describes this as blocked on Gemini quota — it wasn't.
- [ ] Buffer day for whichever of Mon–Thu overran. The shared-store migration
      (Thu) is the most likely candidate.
- **Done when:** a person can type a question on device and watch a real answer
  stream back, with no caveats left in `tech-debts.md` about this path.

## Notes / blockers

Mon → Wed is a fix-then-prove-it-can't-regress order, deliberately: shipping the
fix before the test that would have caught it means the next similar bug ships
the same way. Don't skip Tuesday even though Monday alone makes the app work.

Thursday is the biggest unknown of the week — picking and wiring a shared store
is a real design decision, not a config change, and may not fit in one session.
If it overruns, that's what Friday's buffer is for; don't compress it.

This week exists because a "done" checkbox (Week 7 Wed) didn't match its own
stated done-condition, and nothing caught that for a full review cycle. Worth
carrying forward: re-verify a done-condition independently before trusting the
checkbox, especially for anything marked done under time pressure.

_(jot anything that tripped you up so we pick it up next session)_
