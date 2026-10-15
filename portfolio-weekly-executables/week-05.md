# Week 5 — iOS Service Layer & ViewModel

Progress: 5/5 sessions (100%) ✅

iOS focus. Goal by Friday: a protocol-based service that talks to the backend
(non-streaming), an `@Observable` ViewModel doing optimistic sends, and explicit
view-state modeling.

_Note: the Keychain session manager moved to Week 4 (Fri). The remaining days
shifted up, and the freed Friday now holds the view-state enum pulled in from
`beyond-mvp.md`._

## Mon, Aug 17 — Service protocol + error type
- [x] Define `ChatServiceProtocol` (send a message, return a reply).
- [x] Define a custom `ChatError` enum (bad URL, decoding, HTTP status, network).
- **Done when:** protocol + error type compile.

## Tue, Aug 18 — Service implementation (non-streaming)
- [x] Implement the protocol with `URLSession` + `async/await`.
- [x] Encode the request DTO, decode the response DTO, map failures to `ChatError`.
- [x] Attach the Keychain session id (from Week 4) to every request.
- **Done when:** a manual call from a test/preview returns a real backend reply.

## Wed, Aug 19 — ViewModel skeleton _(moved up from Thu)_
- [x] Create an `@Observable`, `@MainActor` `ChatViewModel`.
- [x] Publish state: `messages`, `inputText`, `isWaitingForResponse`.
- **Done when:** ViewModel compiles and injects the service via the protocol.

## Thu, Aug 20 — Optimistic send flow _(moved up from Fri)_
- [x] Append the user's message immediately, then call the service.
- [x] Append the assistant reply on success; surface errors to state.
- **Done when:** driving the ViewModel from a test/preview shows the full round trip.

## Fri, Aug 21 — Explicit view-state modeling _(pulled from beyond-mvp)_
- [x] Replace the loose flags with a single state enum, e.g.
      `enum ChatState { case idle, sending, streaming, failed(ChatError) }`.
- [x] Drive the ViewModel from that enum so illegal states are unrepresentable
      (can't be `streaming` and `failed` at once).
- [x] Pin the enum directly with `ChatStateTests`: the derived flags (`isBusy`,
      `error`) and case equality.
- **Done when:** the ViewModel exposes one `state` value and the send/reply flow
      transitions through it cleanly.

## Notes / blockers
_(jot anything that tripped you up so we pick it up next session)_
