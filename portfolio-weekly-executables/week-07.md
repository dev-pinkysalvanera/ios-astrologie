# Week 7 — Closing the Gaps: Sign-in and the First Live Call

Progress: 0/5 sessions (0%)

iOS + Supabase config. Five full sessions, no buffer. The bar is behavioural
rather than structural: **a person types a question and a reply streams back on a
real device.** Today that cannot happen — every live send answers 401.

This is the first week that exists to close earlier weeks' gaps rather than add a
feature. Every item below traces back to something left unfinished, and the day
headings say which.

## The gap this week closes

Week 3 Monday was titled "Anonymous session/auth" and was ticked off, but it was
a backend week. The server half landed: `routeChat` in `handler.ts` rejects a
missing or invalid Bearer token with 401 before it even parses the body. The
client half was never scheduled in any week, so the app has never sent that token.

Three findings behind that:

- `ChatService.makeRequest(for:)` sets `Content-Type`, `Accept`, and `apikey`.
  There is no `Authorization` header. The function answers 401, which surfaces as
  `ChatError.httpStatus(code: 401, message:)`.
- The Supabase Swift SDK is **not a dependency** of the Xcode project. No package
  reference exists, so there is no code path that could obtain a token.
- `tech-debts.md` defers three production curl tests on the grounds that the iOS
  client "bypasses this via the Supabase Swift SDK's normal auth flow." That flow
  does not exist. The debt is blocked on work that was never scheduled.

Three more found while planning, which is why Thu and Fri are now sessions:

- **A 401 and a failed sign-in would read the same.** Anything thrown on the way
  to a token folds through `ChatError(from:)` into `.network(.unknown)`, which the
  banner renders as "No connection." Wrong, and wrong in the direction that wastes
  a debugging session.
- **The app dead-ends at message 21.** `turnCounter.ts` allows
  `DEFAULT_MAX_TURNS = 20` per `sessionId` with no sliding window and no expiry,
  while `SessionManager` persists one id in the Keychain forever with no reset. The
  403 says "start a new thread" and the app has no way to start one.
- **`send()` still eats the question on failure.** Week 6's error fix was scoped to
  visibility only, so after a failure the text sits in the transcript while the
  compose field is empty.

Already proven and not in scope: the function is deployed and ACTIVE (version 12),
the gateway accepts the publishable key in `apikey`, and CORS is a non-issue
because `URLSession` sends no `Origin` header and the handler only enforces the
allow-list when one is present.

Two things easily confused, and they must stay separate:

| | What it is | Where it lives |
|---|---|---|
| `sessionId` | Client-generated UUID scoping the backend's rate-limit and turn counters. Sent in the **request body**. | `SessionManager`, Keychain. Built Week 4, working. |
| Access token | Supabase-issued JWT proving the caller is an authenticated user. Belongs in the **`Authorization` header**. | Does not exist yet. This week. |

Both are called "session" in different docs. They are unrelated, and merging
them would be a security mistake — a client-generated UUID authenticates nothing.

## Mon, Sep 21 — Sign-in: provider, SDK, access token
_Closes: Week 3 Mon (client half)_

The densest session of the week, and the one everything else waits on.

- [ ] Enable anonymous sign-ins in the Supabase dashboard (Auth → Providers).
      Currently **disabled**, with email confirmation required — this is remote
      project configuration, not code, and nothing in the repo can change it.
- [ ] Add `supabase-community/supabase-swift` as a Swift Package dependency.
      Pin an exact version rather than a range.
- [ ] Add an auth service behind a protocol (the same seam style as
      `ChatServiceProtocol`) that signs in anonymously on first launch and exposes
      the current access token.
- [ ] Persist across launches so a relaunch reuses the same anonymous user rather
      than minting a new one each time. A new user every launch would silently
      reset the backend's per-user state.
- [ ] Leave `SessionManager` alone, but document the distinction in it — a future
      reader should not have to work out which "session" is which.
- **Done when:** the app obtains a non-nil access token, and a second launch
  returns the same user id.
- **Decision to confirm first:** anonymous sign-in, not email. It keeps the
  no-signup flow the app already assumes and matches Week 3's server-side choice.
  Email/password would mean building sign-up UI, confirmation handling, and a
  password reset path — a feature, not a gap fix.
- **Order matters:** the dashboard change before the SDK install, not after. With
  the provider off, an installed SDK can't sign anyone in, so the install would
  look done while proving nothing.

## Tue, Sep 22 — Attach the token, and make the first send wait for it
_Closes: Week 3 Mon (the header itself)_

- [ ] Thread the token into `ChatService` through its initializer as an **async**
      closure (`@Sendable () async throws -> String`), mirroring the existing
      `sessionID` closure, and `await` it inside `makeRequest(for:)`.
- [ ] Set `Authorization: Bearer <access token>` in `makeRequest(for:)`.
- [ ] Update the launch wiring: start sign-in at launch and build the service
      against the auth service, instead of the parameterless `ChatService()` that
      `ContentView` constructs today.
- [ ] Keep `publishableKey` in the `apikey` header. New-format keys
      (`sb_publishable_…`) are **not** JWTs and must never be sent as a bearer
      token — that mistake already cost a debugging session in Week 1.
- [ ] Tests through the existing `ChatTransport` stub seam asserting the header is
      present and correctly formed, on both `sendMessage(_:)` and
      `streamMessage(_:)` — plus one where the token closure resolves slowly and
      the request still carries it.
- **Done when:** unit tests prove the header is on both requests, including when a
  send starts before sign-in has finished. Still no live call — that is Wednesday.
- **The trap, spelled out:** a token captured as a `String` at construction is the
  obvious shape and the wrong one. `ContentView` builds its service synchronously
  in a `@State` initializer, so a captured token is whatever existed before
  sign-in resolved — nothing — and the first send of a cold launch 401s while every
  stub test stays green, because a stub's token is always ready.

## Wed, Sep 23 — First live verification, and clear the blocked debt
_Closes: three curl tests parked in `tech-debts.md`_

- [ ] Run the app against production and send a real question. Watch tokens stream
      into the transcript. This is the **first end-to-end verification in the
      project** — every green test so far has run against a stub.
- [ ] Then three more passes, because one successful send doesn't cover the week's
      bar: a **second** message in the same session, a send after **relaunching**,
      and a send from a **fresh install** (no Keychain id, no stored auth session).
- [ ] With a token now obtainable, clear the three curl tests parked in
      `tech-debts.md`: 400 on bad input, happy path + SSE framing, and 429 under
      rapid fire.
- [ ] Update `tech-debts.md`: check those off and correct the blocked-reason note,
      which currently rests on an SDK flow that did not exist.
- **Done when:** replies stream into the app on device across all four cases, and
  the three curl tests are ticked.
- **Verify on an iOS device or simulator, not on Mac.** `SUPPORTED_PLATFORMS`
  includes `macosx` and `ENABLE_APP_SANDBOX = YES`, while `Astrologie.entitlements`
  is an empty dict that the project doesn't reference at all. A sandboxed Mac build
  without `com.apple.security.network.client` fails every request as a plain
  network error — which would look exactly like a bug in Monday and Tuesday's work.

## Thu, Sep 24 — Failures that read correctly and don't cost you the question
_Closes: Week 6's error banner, which was scoped to visibility only_

Deliberately after Wednesday: the live session is what shows which failures
actually turn up, so the copy gets written against real ones.

- [ ] Map a sign-in failure deliberately instead of letting it fold into
      `.network(.unknown)` — a new `ChatError` case or an explicit mapping. "No
      connection" for a broken session points the next debugging session the wrong
      way.
- [ ] Give a 401 *after* sign-in its own copy. Post-Tuesday it means a broken
      session, not a bad question, so the banner's generic passthrough of the
      backend message is no longer right for that status.
- [ ] Restore `inputText` when a send fails. `send()` clears the field
      optimistically, so today a failed question has to be retyped from the
      transcript.
- [ ] Tests pinning each: offline, failed sign-in, and 401 read differently; a
      failed send leaves the field populated.
- **Done when:** the three failures are distinguishable in the UI and a failed
  send costs nothing but a tap.

## Fri, Sep 25 — Keep working past the first few minutes
_Closes: the 20-turn dead end, and verifies token expiry_

Both items are the same question asked twice: does the app still work an hour in,
and twenty messages in?

- [ ] Add a session reset to `SessionManager` (mint and persist a new UUID) and
      offer it from the banner when a 403 arrives. The transcript is in-memory
      only, so nothing else has to change.
- [ ] Confirm token refresh behaviour. Supabase access tokens expire (~1 hour) and
      the SDK refreshes them automatically, so expect verification rather than
      construction: confirm a send after expiry succeeds instead of assuming it.
- [ ] If the SDK does *not* cover refresh, build a refresh-and-retry-once path on
      401. That is real work and takes the rest of the session — the reset above
      goes first for that reason.
- **Done when:** hitting the turn limit offers a way forward instead of a dead
  end, and a send after token expiry still gets a reply.
- **Not the same as the tech-debt item** on replacing the in-memory turn counter.
  That's a durability fix on the server; this is the client having somewhere to go
  when the limit is hit. The rate limit needs nothing — 20 requests per 60s
  sliding window heals on its own.

## Notes / blockers

Monday's dashboard change is the hard dependency for the whole week. It cannot be
done from the codebase, and if anonymous sign-ins stay disabled, nothing after it
can be verified.

Mon → Wed is a strictly linear spine, which is unusual here and worth saying out
loud: each session is the precondition for the next, so there's no parallel track
to fall back on if one stalls. If Monday overruns, push Thursday's work rather
than compressing Tuesday — an `Authorization` header that is only eyeballed is how
this gap got here in the first place.

The 401 is legible rather than silent as of Week 6 — the error banner reads
`ChatError.errorDescription`. Useful while working through this week: a failure
mid-change will say what it was instead of looking like the app ignoring the send.

The SDK stores its auth session in the Keychain by default, so Monday's
persistence check carries the same code-signing caveat that made
`SessionManagerTests` inject an in-memory store. If persistence misbehaves in a
test bundle, suspect that before the sign-in call.

No client guard on message length: `handler.ts` caps `message` at 2,000 characters
and answers 400, and the app sends whatever is typed. Acceptable, and not
scheduled anywhere — noted so it isn't mistaken for a regression from this week.

**Don't confuse the two "sessions".** `SessionManager`'s Keychain UUID is a
rate-limit scope in the request body. It is not authentication and cannot become
authentication. See the table above.

_(jot anything that tripped you up so we pick it up next session)_
