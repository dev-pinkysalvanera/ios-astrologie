# Astrologie — Decisions and Why

Every decision behind Astrologie: what was chosen, why, what was turned down,
what it costs, and how it's likely to come up in an iOS interview.

How to read it:

- Each decision has the same parts. **Decision**, **Why**, **Rejected** (when
  there was a real alternative), **Cost**, and **In an interview**: the
  question you're likely to get and the shape of a good answer.
- Facts were checked against the code on 2026-10-11. File names are given so
  you can open the code before an interview and talk from it.
- Part 0 is your own story, reworded. Part 12 lists what changed from your
  original notes and why.
- The "In an interview" parts are prep for you. Decide whether they go public
  (see the portfolio spec, Task 5).

---

## Part 0 — Why Astrologie exists

### The story, in your words, tightened

At my day job I've worked through several architecture migrations in one
production app: UIKit with VIPER, then MVVM split into modules so new screens
could use SwiftUI, then cross-platform code embedded in different ways, first
React Native modules, then Compose Multiplatform, first as source files and
later as a Swift package.

Each migration solved a real problem, and each one taught me that architecture
is a bet on what the app will need. Astrologie is my chance to make that bet
on purpose for a small greenfield app: pick the smallest structure that keeps
the code testable, write down why, and write down what would make me change it.

> **Public vs private.** Keep the day-job version general in public ("I've
> worked through five architecture migrations in one production app").
> Specifics such as which embedded module caused scroll problems are your
> employer's internal history. Fine to talk about in an interview, but don't
> put them in writing.

### What's true about this app

- One screen: a chat with a Vedic-astrology assistant.
- More could come later, such as a birth-chart generator or other astrology
  traditions (BaZi, Western). So the code should be able to grow routing
  without a rewrite, but shouldn't build routing before there's a second
  screen.

### The 30-second pitch

> Astrologie is an iOS chat app where you ask a Vedic-astrology question and
> the answer streams in as it's generated. The app is SwiftUI with MVVM and a
> protocol-based service layer. The AI sits behind a Supabase Edge Function, so
> the Gemini key and the system prompt never ship in the app. Most of the work
> is in what happens around the happy path: parsing a streamed reply, typed
> errors, rate and turn limits backed by Postgres, guardrails, accessibility,
> and 250 unit tests that run without a network.

---

## Part 1 — Product scope

### D1. One screen, single-turn chat

**Decision.** One chat screen. Each message is answered on its own: the backend
sends Gemini only the current message, not the conversation so far.

**Why.** It's the smallest version that shows the hard parts (streaming,
errors, limits, guardrails). Follow-up context brings its own security
problems (see D17), which are better solved once than half-solved early.

**Cost.** A follow-up like "what about my career?" doesn't know what came
before. The UI is honest about this: "Start new conversation" clears the
transcript, because keeping old messages on screen suggested a continuity that
wasn't there (Week 10 Task 4).

**In an interview.** *"Why no conversation history?"* Because history is a
security decision before it's a feature: who stores it, how long it gets, and
whether the client can forge it. I scoped the MVP to single-turn and
documented what history would need (`tech-debts.md`, "Context integrity").

### D2. No App Store release; TestFlight optional

**Decision.** No App Store submission. A TestFlight build is optional.

**Why.** A portfolio app doesn't justify the business requirements of a public
release (for example support and running costs). It's still built
to App Store standards: privacy manifest, a way to report a reply,
accessibility.

**In an interview.** *"Is it on the App Store?"* No, on purpose, and here's
what I'd need before shipping it: the device checks, a paid model tier, and
the open items in the tech-debt log.

---

## Part 2 — Architecture

### D3. MVVM

**Decision.** MVVM: SwiftUI views, one `@Observable` `ChatViewModel`, and a
protocol-based service layer underneath. Recorded in `architecture.md` before
the first line of iOS code.

**Why.**

- **It fits the app's shape.** One screen, one stream of messages, no state
  shared between features.
- **SwiftUI first.** For a greenfield app, SwiftUI is the better default, and
  `@Observable` makes MVVM lightweight.
- **Testability.** The ViewModel holds the send/stream flow, so it can be
  tested with a stub service and no network. This is the main reason for MVVM
  over plain MV.
- **Room to grow.** Feature folders (`Models/`, `Services/`, `ViewModels/`,
  `Views/`) can become Swift packages later, and a coordinator can be added
  when there's a second screen.
- **Easy to onboard onto.** A junior developer can read it on day one. Your
  own first codebase was UIKit with VIPER, and you know how steep that was.

**Rejected.**

- **TCA.** Worth its overhead with complex shared state, deep navigation and
  many features composed together. Here it would add a dependency and
  boilerplate, and the testability it's usually chosen for already comes from
  the protocol seams.
- **VIPER or layered Clean Architecture.** Built for large teams splitting
  ownership across many screens. At one screen, the indirection costs more
  than it returns.
- **Plain MV** (views plus `@Observable` models, no ViewModel). Viable for
  small apps, but networking and state transitions tend to drift into the
  view, which makes the async flow hard to test.

**Cost.** A ViewModel can turn into a dumping ground. Mitigations: I/O stays
in the service, and state is one enum (D5).

**What would change it.** Several screens sharing mutable state, which would
call for a coordinator or a lightweight store. Revisit with evidence, not
ahead of time.

**In an interview.** This is the most likely question you'll get. Answer in
three parts: (1) what the app needs, (2) why MVVM fits that, (3) what you
rejected and when you'd revisit. Bring in the day-job history as evidence
that you've seen what an architecture costs to change. If asked about
navigation: "I designed for a coordinator but didn't build one. With one
screen it would be dead code."

### D4. Protocol seams for everything that does I/O

**Decision.** The ViewModel depends on `ChatServiceProtocol`, never on
`URLSession`. Below that, narrower seams: `ChatTransport` (bytes in, bytes
out), `AuthSessionProvider` (the two things auth needs from Supabase) and
`MessageReporting`. The ViewModel has no default service. The caller decides
whether it gets the real client or a stub.

**Why.** Each seam is as small as the code that uses it, so a test stub is a
few lines. `AuthSessionProvider` uses the app's own `AuthSession` type rather
than the SDK's, so tests don't need Supabase or the Keychain.

**In an interview.** *"How do you test networking code?"* Two layers. The
service is tested against a stub transport that replays canned bytes,
including bytes split across packet boundaries. The ViewModel is tested
against a stub service. Neither layer touches the network.

### D5. One state enum instead of flags

**Decision.** `ChatState` has four cases: `idle`, `sending`, `streaming`,
`failed(ChatError)`. It replaced an `isWaitingForResponse` / `lastError` pair
(`ViewModels/ChatState.swift`).

**Why.** Two booleans allow four combinations, and "waiting *and* failed" was
one of them. An enum makes that impossible. Everything else is derived from
the state rather than stored: `isBusy`, `showsTypingIndicator`, the haptic for
a transition (`ChatHaptic.forTransition(from:to:)`), the VoiceOver
announcement. Derived values can't drift out of step with it.

**In an interview.** *"Making impossible states impossible"* is a known idea;
you have a concrete before and after. Also a good answer to *"How do you
avoid a massive ViewModel?"*

### D6. `@MainActor` ViewModel, `nonisolated` service

**Decision.** The ViewModel is `@Observable @MainActor`. The service is
`Sendable` with a `nonisolated` stream method, so network work runs off the
main actor and every state change happens on it. The project builds with the
Swift 6.2 toolchain in the Swift 5 language mode, with approachable
concurrency and main-actor default isolation turned on, so types that must run
off the main actor are marked `nonisolated` explicitly.

**Why.** View state belongs on the main actor. Default isolation means
forgetting an annotation leaves code on the main actor (safe but maybe slow)
rather than off it (fast but racy).

> **Be precise if asked.** It's not in the Swift 6 language mode yet, so the
> compiler doesn't enforce full data-race safety. Moving to Swift 6 mode is a
> reasonable next step, and since the code is already annotated for it, it
> should be a short list of fixes rather than a rewrite. Don't claim it's done.

**In an interview.** Expect Swift Concurrency questions: actor isolation,
`Sendable`, what `nonisolated` means, how `AsyncThrowingStream` bridges
callbacks. Open `ChatService.swift` and walk the stream from bytes to
ViewModel.

### D7. No modules yet

**Decision.** One app target, organised by folder. No Swift packages.

**Why.** With one feature, a module boundary would be ceremony. The folders
match the layers, and the protocol seams are where module boundaries would go.

**In an interview.** *"How would this scale to ten features?"* Split by
feature into Swift packages, each with its own views, ViewModel and service
protocol, plus a shared core package for networking and auth, and a
coordinator owning navigation between them. This is where the day-job
experience with modularising for SwiftUI is directly relevant.

---

## Part 3 — Platform

### D8. iOS 18 minimum

**Decision.** Minimum target iOS 18, one version back from current.

**Why.** It's a support policy, not an API requirement: one version behind
current covers most active devices and keeps the number of OS versions to
test small. The APIs the app relies on (`@Observable`, `.sensoryFeedback`,
SwiftData, `URLSession` async byte streams) all arrived by iOS 17.

**Rejected.** iOS 26 only: it would cut out devices for nothing the app
needs. iOS 17: the code would likely run there, but it's another OS to test
for little gain on a portfolio app.

> **Be precise if asked.** Don't say iOS 18 was *needed* for `@Observable`;
> that's iOS 17. Say iOS 18 was the policy, and lowering it to 17 would be a
> settings change plus a test pass.

**In an interview.** *"How do you choose a minimum iOS version?"* Look at
adoption numbers, list the APIs you need, and weigh testing cost. At work
that's a product and analytics call; here it was mine.

### D9. Liquid Glass: system default, no custom glass

**Decision.** The app doesn't use the iOS 26 glass APIs (such as
`.glassEffect`). Custom surfaces like the input bar use `.ultraThinMaterial`,
which works on iOS 18. The app is built with the iOS 26 SDK and doesn't opt
out (`UIDesignRequiresCompatibility` isn't set), so on iOS 26 the system
navigation bar and toolbars get Liquid Glass automatically.

**Why.** One code path on both OS versions, no `if #available` branches in
views, and the app still looks native on iOS 26.

> **Correction from your notes.** "No Liquid Glass, so it supports older
> models" isn't quite accurate. The app *does* show Liquid Glass on iOS 26,
> through system components. What it avoids is the glass *APIs*, which need
> iOS 26.

**In an interview.** *"Have you adopted Liquid Glass?"* Yes, through system
components. I avoided the custom glass APIs to keep one code path back to
iOS 18. If I raised the minimum to 26, I'd adopt them for the input bar.

### D10. Swift Testing

**Decision.** Unit tests use Swift Testing (`@Test`, `#expect`), not XCTest.
UI tests use XCTest, which is still required for UI automation.

**Why.** Parameterized tests, clearer failure output, `async` support by
default, and it's where Apple is heading.

**Numbers.** 250 iOS unit test cases and 104 Deno tests, all passing (run on
2026-10-11).

### D11. Messages in memory only; SwiftData deferred

**Decision.** The transcript is an in-memory array. SwiftData was chosen as the
framework for persistence, but the model and wiring are deferred until after
the MVP (`beyond-mvp.md` §5).

**Why.** Persistence is a feature of its own: retention policy, migrations,
loading on launch. Building the model with nothing reading it would have been
dead code.

**In an interview.** *"Why not Core Data?"* SwiftData fits a new SwiftUI app
with a simple model on iOS 17+. I'd reach for Core Data for complex
migrations or heavy background processing.

---

## Part 4 — Streaming

### D12. Server-Sent Events, parsed by hand

**Decision.** The Edge Function streams the reply as SSE: `data: <line>` per
line of text, a blank line between events, and `data: [DONE]` at the end. The
app reads it with `URLSession.bytes(for:)` and parses events as bytes arrive
(`Services/ChatService.swift`). The parsed text comes out as an
`AsyncThrowingStream<String, Error>`.

**Why.**

- SSE is plain HTTP, one direction, and enough for a reply arriving in pieces.
  WebSockets would add a persistent two-way connection the app doesn't need.
- No SSE library: the format is small, and a hand-written parser can be tested
  byte by byte (including an event split across two network packets).
- **`[DONE]` is the only proof a reply is complete.** A stream that ends
  without it (server stall, model hitting its token limit, dropped
  connection) shows a "reply was cut off" error, and the partial text stays
  on screen.

**War story.** The first live reply came back empty. Gemini's streaming
endpoint returns a pretty-printed JSON array by default, not SSE, and a
line-by-line reader dropped every piece. The fix was one query parameter
(`alt=sse`), found in Week 8 by verifying against production rather than
trusting the tests, which all used stubs.

**In an interview.** *"How would you stream an LLM response on iOS?"* Walk
through it: bytes, events, an async stream, the ViewModel appending to one
message. Then the edge cases: packet boundaries, the completion marker,
non-2xx responses whose error body arrives as a stream, cancellation.

### D13. One reply row, created on the first chunk

**Decision.** The assistant's message is created when the first chunk arrives,
not when the request starts, and later chunks are appended to it. Its `id`
never changes. The ViewModel tracks it by id, not array index.

**Why.** Until the first chunk arrives, the typing indicator shows and there's
no empty bubble. A stable id means SwiftUI updates the same row instead of
replacing it. Using an id rather than an index across `await` points avoids
writing into the wrong message if the array changed in the meantime.

### D14. Cancellation

**Decision.** Cancelling the task that reads the stream cancels the network
request (`onTermination` cancels the inner task). A cancelled send ends as
`.failed(.network(.cancelled))` but doesn't buzz or announce, because a
cancellation isn't an error the person needs to hear about.

**Still open** (`beyond-mvp.md` §2): no Stop button, no cancel when the app
goes to the background, and a cancelled send still leaves `.failed` rather
than returning to `.idle`. Be upfront about this if asked.

### D15. No batching of updates yet

**Decision.** Each streamed piece updates `@Observable` state directly. Batching
pieces (for example per frame) is listed in `beyond-mvp.md` §3 but not built.

**Why.** Measure first. Gemini sends pieces of text, not single tokens, and
there's no visible jank. Optimising without a profiler trace would be
guesswork.

**In an interview.** *"What if tokens arrive faster than 60 fps?"* Batch them
on a short interval or by buffer size, then profile with Instruments
(SwiftUI and Time Profiler) before and after. Saying you deliberately didn't
do it yet, and why, is the strong answer.

---

## Part 5 — AI and backend

### D16. The AI sits behind a server

**Decision.** The app calls a Supabase Edge Function (Deno, TypeScript), which
calls Gemini. The Gemini key, the system prompt and every guardrail live on
the server. The app holds only the Supabase publishable key, which is meant
to be public.

**Why.**

- An API key shipped in an app can be extracted. A proxy keeps it secret.
- The prompt and guardrails can change without an App Store release.
- **The model can be swapped without an app release:** the `GEMINI_MODEL`
  secret overrides the default. This already mattered: `gemini-2.0-flash` was
  shut down and `gemini-2.5-flash` stopped accepting new keys during the
  project.

**In an interview.** *"How do you keep API keys out of a mobile app?"* You
can't hide them in the binary; anything shipped can be pulled out. Put a
server in between, authenticate the user to that server, and enforce limits
there. Then connect it to GlobeOne: same idea as server-configured campaigns,
changing behaviour without a release.

### D17. A hosted model, prompted; no RAG or fine-tuning

**Decision.** A general hosted model (Gemini Flash) with a system prompt. No
retrieval (RAG), no fine-tuning, no web search.

**Why.** The content isn't private or company-specific. Vedic astrology is
widely published and the model already knows it. What the app needs is to
shape the answers (persona, scope, length, tone), and a system prompt does
that.

**When the answer changes.**

- **Private or changing knowledge** (a company's documents, current prices):
  add RAG so answers come from your sources and can cite them.
- **Personal data** (and birth date, time and place count; `tech-debts.md`
  already flags them): call Gemini through **Vertex AI**, Google Cloud's
  platform, for enterprise data terms (prompts not used for training) and a
  choice of region.
- **Fresh facts from the web:** turn on Google Search grounding. It isn't on
  today.

> **Corrections from your notes.**
> - "Foundational models" → **foundation models**.
> - The app doesn't search the internet. `handler.ts` sends no search tool.
>   It's the system prompt plus what the model already knows.
> - Vertex AI isn't a model. It's the platform you'd call Gemini through when
>   data terms matter.

**Rejected: Apple's Foundation Models framework** (on-device). You'll likely
be asked about it in an iOS interview. It needs iOS 26 and an Apple
Intelligence device, which conflicts with the iOS 18 target. The on-device
model is small and is better at summarising and pulling data out of text
than at detailed domain knowledge. It would be a good fit for a privacy-first
feature on new devices, not for this one.

**In an interview.** *"Why not RAG?"* Because there's nothing private to
retrieve; RAG solves a problem this app doesn't have. Then name when it would.
Choosing the simpler tool and knowing when it stops being enough is the
point.

### D18. Gemini as the provider

**Decision.** Gemini Flash (`gemini-3.6-flash` today, set by `GEMINI_MODEL`).

**Why.** Cost. It has a free tier (about 20 requests a day on this project)
and low per-token pricing for a fast model, which suits a portfolio app with
no revenue. Because of the proxy (D16), switching providers is a server
change.

**When the answer changes.** Different priorities pick differently: answer
quality, latency, context length, data terms, or tools the provider offers.
Re-evaluate per use case.

> **Correction from your notes.** "The cheapest of the three" needs a model
> tier and a date, since prices change often. Safer: "Gemini Flash had a free
> tier and the lowest price for the speed I needed when I started, and the
> proxy means I'm not locked in."

**In an interview.** Lead with the trade-off, not the brand: "I chose on cost
because a portfolio app has no revenue, and I designed so that choice is
cheap to undo."

### D19. Reply length

**Decision.** Length is guided in the system prompt: keep a reading under about
250 words unless the person asks for more (Week 10 Task 11).
`maxOutputTokens` stays at the model's limit (65,536) as a safety net, not as
a length policy.

**Why.** Readings were running 2,600–5,000 characters. Output tokens are what
you pay for, long replies keep the connection open longer, and 5,000
characters is a lot to scroll on a phone. A low token cap would cut replies
mid-sentence, and on this model thinking tokens count against it too, so a
cap could be used up before the model writes anything. The prompt shapes
length; the cap only catches runaways.

### D20. Two timeouts

**Decision.** 45 s to wait for Gemini to start responding
(`GEMINI_TIMEOUT_MS`), and 20 s maximum between chunks once it has started
(`GEMINI_STREAM_IDLE_TIMEOUT_MS`).

**Why.** One overall timeout either cuts off long but healthy replies or
lets a stuck stream hang. Production replies were taking about 15 s, and
the old 20 s limit tripped on normal variation, so it went to 45 s. A stream
that stops part way is caught by the gap timer: it ends without `[DONE]`,
and the app shows its cut-off error.

**In an interview.** Good example of measuring before tuning: the number came
from production timings, not a guess.

---

## Part 6 — Safety, abuse and cost

The theme: **the system prompt asks; code enforces.**

### D21. Guardrails in layers

**Decision.** Several cheap layers, none trusted alone:

1. **System prompt**: scope, persona and format (`systemPrompt.ts`, treated as
   product content).
2. **Gemini safety settings**, set explicitly to `BLOCK_MEDIUM_AND_ABOVE` for
   harassment, hate, sexual and dangerous content. Left unset, current models
   default to lax thresholds. A test fails if any category is `BLOCK_NONE`.
3. **Input denylist** for known jailbreak wording ("ignore previous
   instructions", "you are now", "write a story where"). A match returns 400,
   never reaches Gemini, and doesn't use a turn. A speed bump, not a wall.
4. **Output check** on every streamed chunk before it reaches the app
   (`moderator.ts`).
5. **Logging** of refusals and safety blocks with user and session ids, so
   abuse shows up in logs before it shows up on a bill.

**Rejected for now: a topic gate.** A second, fresh-context Gemini call per
message asking "is this a Vedic astrology question?" It's the strongest
defence against prompt injection, but it doubles calls on a free tier of
about 20 a day. Deferred, with a cheaper idea logged for when history
arrives: reset the context every few turns (`beyond-mvp.md` §6).

**In an interview.** *"How do you stop prompt injection?"* You can't fully;
you layer defences and cap the damage. Name the layers and explain why the
denylist is the weakest. Then the cost trade-off on the gate. Also: never
accept conversation history from the client, or an attacker can forge a
"prior agreement" (D1).

### D22. Rate, turn and report limits, stored in Postgres

**Decision.**

- **Rate limit:** 20 requests per minute **per user**. Returns 429 with
  `Retry-After`.
- **Turn limit:** 20 turns **per conversation** (session id). Returns 403, and
  the app offers "Start new conversation".
- **Report limit:** 10 reports per hour per user.
- All stored in Postgres and checked through database functions. If the
  database can't be reached, the function **fails closed** (503) and never
  calls Gemini.
- A daily `pg_cron` job deletes old rows.

**Why each one.**

- **Postgres, not memory.** The first version counted in memory. Supabase
  spreads requests across instances that each start empty, so 70 requests in
  73 seconds never triggered a 429. Found only by testing against production
  (Week 8).
- **Per user, not per session.** The session id is chosen by the client, so a
  new id per request skipped both limits. The rate limit moved to the
  authenticated user id (Week 10 Task 7). The turn limit stayed per session
  so "Start new conversation" still works.
- **Fail closed.** If the limits can't be checked, the safe default is to
  refuse, not to spend quota.

**In an interview.** Strong story about the gap between "tests pass" and
"works in production": unit tests used an in-memory store, so they passed,
and production didn't behave the same. Also a good "how would you design rate
limiting?" answer: key, window, storage, failure mode, client experience.

### D23. Nothing internal in error responses

**Decision.** Error responses are `{ "error": "<plain message>" }` only.
Upstream status, model names and Gemini error text go to server logs, never
to the client.

**Why.** The publishable key ships in the app, so anyone can call the
function. Error details are free reconnaissance. A debug branch that returned
the model list was removed for the same reason.

---

## Part 7 — Identity

### D24. Anonymous sign-in

**Decision.** One anonymous Supabase user per install, signed in at launch.
The SDK keeps that session (a JWT) in the Keychain, so a relaunch reuses the
same user. The token is fetched fresh for each request, so the SDK handles
refresh.

**Why.** The backend needs to know a caller is *a* user so it can rate-limit
them. It doesn't need to know *who*. A sign-up screen would add friction and
personal data for no benefit.

**Cost.** Deleting and reinstalling the app creates a new user, which resets
the per-user limit. Acceptable for a portfolio app. Sign in with Apple would
close that gap if it shipped.

### D25. Two kinds of "session", kept separate

**Decision.** The **auth session** (JWT in the `Authorization` header, kept
in the Keychain, survives relaunch) is separate from the **conversation
session id** (a UUID in the request body, made fresh every launch, used only
to count turns). See the header comment in `Services/SessionManager.swift`.

**Why.** The session id proves nothing; anyone can send any value, so it must
never be used for identity. It used to live in the Keychain and survive
relaunches, but the messages didn't, so a chat that looked new could hit the
turn limit early (Week 10 Task 4). One launch, one conversation keeps the two
in step.

**In an interview.** *"Authentication vs identification"* in one example.

---

## Part 8 — UI and accessibility

### D26. Errors people can act on

**Decision.** `ChatError` is an enum with plain value payloads (so it's
`Equatable` and tests can compare exact errors). Each case maps to a short,
friendly message. On failure:

- the person's message stays in the transcript (sending is optimistic and
  nothing is rolled back),
- the compose field gets their text back so they don't retype it,
- any partial reply stays visible under the error,
- the turn-limit 403 gets its own action, "Start new conversation".

**Still open** (`beyond-mvp.md` §4): a visible cooldown from `Retry-After` on
429, and different recovery actions per error type.

### D27. Markdown removed, not rendered

**Decision.** The prompt asks for plain prose. When the model uses Markdown
anyway, the view removes the markers before display (`Views/MarkdownStripper.swift`).
`ChatMessage.text` keeps exactly what the model produced, so a report sends
the original.

**Why not render it.**

- Half-open markers flicker while a reply streams in (`**bold` before its
  closing `**` arrives).
- `AttributedString(markdown:)` doesn't handle headings.
- VoiceOver reads leftover symbols aloud.

The stripper runs on the whole accumulated text on every render, not per
chunk, because a `**` split across two chunks only forms a pair once they're
joined.

**In an interview.** Good example of "model output isn't UI". Keep the source
untouched, transform at display time, and think about streaming and
accessibility before choosing a renderer.

### D28. Accessibility built in

**Decision.**

- **VoiceOver:** the screen announces when a reply is on its way (the
  typing indicator is only an animation otherwise) and when a send fails.
  It doesn't re-read the growing reply on every chunk; the finished bubble is
  there to read. Announcements are derived from state transitions, like
  haptics, and a cancelled send is silent. "Report Message" is in the Actions
  rotor.
- **Dynamic Type:** layouts checked at the largest sizes, including the
  report menu preview.
- Markdown symbols removed so they aren't read aloud (D27).

**Status.** Built and unit-tested. The checks on a real device (VoiceOver
and haptics) are still open (Week 10 Task 13), because no physical device
is available for testing. **Don't claim they're
device-verified until they are.**

**In an interview.** *"How do you make streaming text accessible?"* Don't let
VoiceOver re-read every chunk. Announce that a reply is coming, announce
failures, and let the person read the finished reply at their own pace.

### D29. Haptics derived from state

**Decision.** Distinct haptics for send, reply finished and failure, chosen by
a pure function of the old and new state (`ViewModels/ChatHaptic.swift`) and
played with `.sensoryFeedback`.

**Why.** The simulator can't play haptics, so the only testable thing is that
the right one is *requested*. A pure function makes that a unit test.

### D30. Reporting a reply

**Decision.** Any finished assistant reply can be reported from a long-press
menu. The original text goes to a `reports` table that only the server can
write to; app clients have no access to the table at all.

**Why.** App Review expects apps with user-generated content to offer a way
to report objectionable content, and AI chat apps tend to be held to the same
standard. Reporting a reply that's
still streaming isn't offered: it would record text the person never saw in
full.

### D31. Privacy manifest

**Decision.** `PrivacyInfo.xcprivacy` declares what the app collects (a user
ID, message content, and one "other data" entry), all for app functionality
and none used for tracking.

---

## Part 9 — Process

### D32. Planned as a spec, in 30-minute sessions

**Decision.** Ten weeks of weekday sessions, about 30 minutes each. Each week
has a task list in `.kiro/specs/astrology-chat/tasks.md` where every task has
a "Done when" condition. Debt found mid-week goes to `tech-debts.md` instead
of derailing the plan, and that file is a gate: nothing in it ships unfixed.
`architecture.md` was written before the iOS work started, as a record to
hold the code to, not a justification after the fact.

**In an interview.** *"How do you manage scope?"* Show the debt log: each
item explains why it's deferred and what would bring it back.

### D33. AI coding agents, with a human gate

**Decision.** Tasks were carried out by AI coding agents, AWS Kiro up to Week
9 and Claude Code after, but the agent never commits. Every task's changes
stay uncommitted until you've reviewed them, one commit per task. This is
enforced by tool settings (`.claude/settings.json` blocks staging, committing,
pushing and commands that discard work), not just by instruction. Production
deploys need your approval every time.

**Why the switch.** The Kiro subscription ended. Claude in the Cowork desktop
app was tried first, but its shell couldn't run `xcodebuild`, so it couldn't
verify iOS work on its own. Claude Code in the terminal could.

**Lesson learned: verify, don't trust the checkbox.** In Week 3, backend auth
was ticked done while the app still had no way to get a token. Every test used
a stub, so nothing caught it for four weeks. Since then, each "Done when" is
re-checked independently before the box is ticked.

**In an interview.** Expect *"How do you use AI tools?"* Your answer: they
write code against a spec, I review every change, and the guardrails are in
config, not trust. Give the specific failures you've caught: work ticked done
before it was, and the tests-versus-production gaps in D12 and D22.

---

## Part 10 — What's next

In priority order, each already written up:

1. Device checks for VoiceOver and haptics (Week 10 Task 13).
2. Better error recovery: a 429 cooldown and retry for a dropped stream
   (`beyond-mvp.md` §4).
3. Stream lifecycle: a Stop button and cancel on background
   (`beyond-mvp.md` §2).
4. Message persistence with SwiftData (`beyond-mvp.md` §5).
5. Follow-up questions, with history stored on the server and bounded, plus a
   periodic context reset (`tech-debts.md` "Context integrity",
   `beyond-mvp.md` §6).
6. A second feature (birth chart, another tradition), which is when a
   coordinator and feature modules earn their place (D3, D7).

**In an interview.** *"What would you do differently?"* Two honest ones:
verify against production earlier (the empty streaming reply and the limits
that never fired were both found late), and build the client half of a
backend feature in the same week as the server half.

---

## Part 11 — Interview cheat sheet

| They ask | Lead with | Decision |
|---|---|---|
| Why MVVM? | Fits one screen, testable without a network, easy to onboard onto; TCA and VIPER rejected with reasons | D3 |
| How do you test async code? | Protocol seams, stub transport replaying bytes, 250 unit tests | D4, D10 |
| How does streaming work? | SSE, `URLSession.bytes`, async stream, `[DONE]` means complete | D12, D13 |
| Swift Concurrency? | `@MainActor` ViewModel, `nonisolated` service, cancellation propagates | D6, D14 |
| Why Gemini? | Cost, with a proxy so it's easy to switch | D16, D18 |
| RAG? Fine-tuning? Apple Foundation Models? | No private data to retrieve; when each would apply | D17 |
| Prompt injection? | Layers, the denylist is weakest, gate deferred for cost | D21 |
| Rate limiting? | Per user in Postgres, fails closed, found by testing in production | D22 |
| API keys in apps? | Can't hide them; server in between | D16 |
| Accessibility? | Announce "reply coming" and failures; no re-reading while streaming | D28 |
| Liquid Glass? | System components get it; custom glass APIs avoided for iOS 18 | D9 |
| How do you use AI tools? | Spec, human review of every change, guardrails in config | D33 |
| What would you change? | Verify in production earlier | Part 10 |

---

## Part 12 — What changed from your original notes

| Original | Changed to | Why |
|---|---|---|
| "Support up to iOS __" | Minimum iOS 18 | From the project settings; "up to" would mean a maximum |
| "No liquid glass yet, so the app may support older models" | No custom glass APIs; system bars get Liquid Glass on iOS 26 | The app does show Liquid Glass on iOS 26 |
| "Foundational models" | Foundation models | Standard term |
| "…plus it searching through the internet" | Removed; search grounding listed as an option | The backend doesn't use search |
| "Development models like Vertex AI" | Gemini through Vertex AI, Google Cloud's platform | Vertex AI is a platform, and the reason is data terms |
| "Cheapest amongst the 3" | Free tier and low price for the speed needed, at the time, with no lock-in | Prices change; the proxy is the stronger point |
| "If I onboard a junior developer, he won't be shocked" | "A junior developer can read it on day one" | Gender-neutral |
| "Ready for a scenario where routing will be added" | Designed for a coordinator, not built until there's a second screen | Accurate, and the restraint is the point |
| "Easy when I have to modularize" | Folders match layers; seams are where module boundaries would go | Says why it's easy |
| Day-job specifics (RN scroll issues) | General in public: "five architecture migrations" | Employer's internal history |
