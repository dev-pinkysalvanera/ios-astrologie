# Beyond MVP — Senior-Signal Enhancements

Not required to ship. These are the iOS-client refinements that separate "the
feature works" from "the engineer reasoned about failure, change, and stress."
They came out of an audit of Weeks 4–8: each item below is **not currently
scheduled** in any weekly file.

This is a **companion to `tech-debts.md`, not a duplicate of it.** Tech-debts is
a gate on submission (nothing there ships unfixed) and is mostly backend. This
file is client-side polish that is safe to defer past launch — but each item is
a concrete, defensible talking point for a senior review.

Each entry notes whether it is better **folded into an existing week** (cheap,
do it inline) or a **true post-MVP stretch** (defer unless there's time).

---

## 1. Explicit view-state modeling — ✅ SHIPPED in Week 5 (Fri, Aug 21)

No longer beyond-MVP. Promoted to a first-class Week 5 task and now delivered:
the loose flags (`isWaitingForResponse`, `lastError`) are gone, replaced by a
single `ChatState` enum (`idle`, `sending`, `streaming`, `failed(ChatError)`) that
the ViewModel exposes as one `private(set) var state`, so illegal states are
unrepresentable — you can't be `streaming` and `failed` at once. Kept here for
traceability. It filled the Week 5 slot freed when the Keychain session manager
moved up to Week 4.

The `streaming` case is unreachable so far: the service returns a complete reply,
so the flow is `sending → idle`. Week 6 wires it up.

## 2. Stream cancellation & lifecycle
**Partly fold into Week 6; some is stretch. Moderate effort, high signal.**

- [ ] Cancel an in-flight stream when the user sends a new message (supersede).
- [ ] Cancel / tear down the stream cleanly when the app backgrounds.
- [ ] Use structured concurrency: hold the streaming `Task`, honor
      `Task.isCancelled`, and ensure `state` returns to `.idle` on cancel rather
      than parking in `.failed` (cancellation is not a failure to show).

_Why it matters:_ streaming without cancellation leaks tasks and produces
"ghost" replies writing into a stale message. Correct cancellation is a real
concurrency-competence signal and is arguably a correctness issue, not just
polish — the backgrounding case especially.

## 3. Token-update coalescing (backpressure)
**True post-MVP stretch. Do only if streaming visibly janks.**

- [ ] Batch incoming SSE tokens (e.g. coalesce on a short interval or by
      buffer size) instead of mutating `@Observable` state on every token.
- [ ] Measure first — only optimize if the token rate thrashes SwiftUI diffing.

_Why it matters:_ Gemini can emit tokens faster than 60fps; naive per-token
state writes cause layout thrash on long replies. Coalescing is a senior-level
performance detail — but premature if the profiler doesn't show a problem, so
this stays deferred until there's evidence.

## 4. Typed-error UX (the delta beyond the enum)
**Partly fold into Week 6/7; some is stretch.**

Already scheduled: the `ChatError` enum (Week 5) and 429 friendly messaging
tests (Week 9). The gap is the **user-facing recovery** around those errors:

- [ ] Honor `Retry-After` on 429 — disable send with a visible cooldown rather
      than a generic error toast.
- [ ] Map each error case to a distinct recoverable affordance (retry button for
      network/5xx, cooldown for 429, non-retryable message for 4xx input).
- [ ] Handle a mid-stream drop — partial reply already on screen, connection
      lost — with a retry that doesn't duplicate the partial text.

_Why it matters:_ the backend already returns distinct 401/429/502 semantics
(see `PRODUCTION_ENDPOINT.md`). Handling them precisely on the client closes the
loop end-to-end and shows you designed the two halves to fit.

---

## 5. Message persistence (SwiftData) — DECIDED: post-MVP

**Decision (Aug 7):** deferred to post-MVP. The MVP keeps messages in an
in-memory array; conversations do not survive relaunch. The SwiftData `@Model`
is **not** built in Week 4 — the framework choice stands (see `architecture.md`)
but the model and wiring wait until this feature is scheduled.

- [ ] Add the `ChatMessage` SwiftData `@Model` (with session grouping) and
      register a `ModelContainer` at app launch.
- [ ] Persist each message on send; load history on launch via `@Query`.
- [ ] Decide retention (all history vs capped) and whether to expose a "clear
      conversation" action.

_Why post-MVP:_ persistence is a self-contained feature that adds real surface
(migration, retention policy, load-on-launch) without being needed to
demonstrate the core streaming chat. Building the model in Week 4 with nothing
reading it would have been dead code. When scheduled, it's a clean, demoable
win: "your conversation is still here when you reopen the app."

---

## 6. Periodic context reset instead of a topical gate — IDEA (Oct 4)

**Idea:** instead of a topical gate (a second Gemini call per message checking
the question is about Vedic astrology), reset the conversation context every
few turns — say every 5.

- [ ] Decide the reset interval and what carries over (nothing, or a short
      server-side summary).
- [ ] Decide whether the person sees the reset (a divider, a note) or it's
      invisible.

_Why instead of a gate:_ long-thread jailbreaks need turns to build up; a
regular reset denies them that without doubling Gemini calls, and the free tier
allows about 20 a day. The gate was deferred in Week 10 Task 10 for that cost.

_Why later:_ the backend is single-turn today. Gemini only ever sees the
current message, so there's no context to reset yet. This becomes worth doing
the moment follow-ups (conversation history) are added. See "Context integrity"
in `tech-debts.md`.
