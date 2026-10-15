# Architecture Decision — iOS Client

**Status:** Accepted. **Recorded:** Aug 7, 2026 (end of Week 3, before Week 4 iOS work begins).

## Why this is being written now

The choice itself is not new. The iOS architecture was decided at project start
(~3 weeks ago) and has lived in `overview.md` under "Tech decisions (locked)"
since then. The decision stands unchanged.

What is new is writing it down as a record *before the first line of iOS code*.
The backend is done; the iOS phase starts Monday (Week 4). This is the right
seam to capture the reasoning: late enough that the backend contract is fixed
and real, early enough that nothing has been built to retro-justify.

That ordering matters. An architecture note written before implementation is a
**decision record** — it can be checked against, and the code can be held to it.
One written after the fact is a justification, and justifications bend to fit
whatever was already built. This file exists to keep the iOS work honest, the
same way `tech-debts.md` keeps deferred work honest.

## Decision

Build the iOS client as **MVVM** with:

- A **protocol-based service layer** (`ChatServiceProtocol`) — the ViewModel
  depends on the protocol, never on `URLSession` directly.
- A single **`@Observable` `ChatViewModel` on `@MainActor`** owning view state.
- **SwiftData** for message persistence _(framework chosen; the actual model and
  wiring are deferred to post-MVP — see `beyond-mvp.md` §5)_.
- **Keychain** for the session identifier.
- **Server-side system prompt and guardrails** (already true — the client holds
  no secrets and no prompt logic).

## Trade-offs — what was rejected and why

### TCA (The Composable Architecture)
Rejected. TCA earns its ceremony when you have complex shared state, deep
navigation, and many features that must compose and be tested as reducers. This
app is a **single conversation stream** with no cross-feature shared state. TCA
here would add a dependency, a learning tax for any reviewer, and reducer/effect
boilerplate out of proportion to the problem. The one thing people usually reach
for TCA to get — testability — we already get from the protocol service seam.

### VIPER / Clean Architecture (multi-layer)
Rejected. Presenters, interactors, entities, and routers are built for large
teams partitioning ownership across many screens. At one screen and ~30-minute
sessions, the indirection would cost more than it returns and would read as
over-engineering in a portfolio review.

### Plain "MV" (SwiftUI views + `@Observable` models, no ViewModel)
Considered, rejected. Viable for small apps, but it tends to pull networking and
state transitions into the view. The explicit ViewModel is what makes the async
send/stream flow **unit-testable without a network** (see Week 9). That
testability is the single highest senior-signal in this project, so it wins.

## The cost we are accepting

MVVM is not free: the ViewModel can become a dumping ground ("massive
ViewModel") if service calls, state modeling, and formatting all pile in. The
mitigation is the protocol seam (I/O stays in the service) and explicit state
modeling (see `beyond-mvp.md`). If a second screen or a topic selector lands
later (see `tech-debts.md`), revisit whether shared state has grown enough to
justify more structure — but not before.

## What would change this decision

- Multiple screens sharing mutable state → reconsider a coordinator or a
  lightweight store.
- Multi-turn threading + topic selection (currently in `tech-debts.md`) growing
  into real cross-screen state → revisit then, with evidence, not preemptively.

Until one of those is true, MVVM is the proportionate choice. Choosing the
smallest structure that keeps the code testable is itself the senior move.
