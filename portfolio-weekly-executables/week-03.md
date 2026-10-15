# Week 3 — Auth, Rate Limiting, Moderation & Deploy (Backend done)

Progress: 5/5 sessions (100%) ✅

Backend focus. Goal by Friday: a hardened, production-deployed `chat` function
with session auth, rate limiting, and a moderation/reporting path.

## Mon, Aug 3 — Anonymous session/auth
- [x] Enable Supabase anonymous auth (or decide on a signed session-token scheme).
- [x] Require and validate a session identifier on each request.
- [x] Reject requests with a missing/invalid session (401).
- **Done when:** a request without a valid session is rejected; a valid one passes.

## Tue, Aug 4 — Rate limiting
- [x] Add per-session rate limiting (e.g. counts in a Postgres table or KV).
- [x] Return 429 with the error shape when the limit is exceeded.
- **Done when:** rapid repeated curls start returning 429 after the threshold.

## Wed, Aug 5 — Moderation & reporting
- [x] Add server-side output filtering for disallowed content.
- [x] Add a `report` action/endpoint so the app can flag a response.
- [x] Persist reports (table) for later review.
- **Done when:** a report request stores a row; filtered content is blocked.

## Thu, Aug 6 — Hardening
- [x] Lock down CORS to expected origins.
- [x] Enforce input size limits and reject oversized payloads.
- [x] Review secrets handling and remove any debug logging of sensitive data.
- **Done when:** oversized/invalid-origin requests are rejected cleanly.

## Fri, Aug 7 — Production deploy + test pass
- [x] Deploy the final function.
- [x] Run a curl test pass: happy path, bad input, 401, 429, streaming.
- [x] Note the production endpoint URL for the iOS client.
- **Done when:** all curl cases behave; backend is feature-complete.

## Notes / blockers
_(jot anything that tripped you up so we pick it up next session)_
