# Week 10 — Tests, Privacy & TestFlight

Progress: 0/5 sessions (0%)

Goal by Friday: the ViewModel is unit-tested and the privacy manifest is in
place. No App Store submission: a portfolio doesn't justify the business
requirements. A TestFlight build is optional.

## Mon, Oct 12 — Shared mock service
- [ ] Audit the existing test doubles and ViewModel tests.
- [ ] Build one mock conforming to `ChatServiceProtocol` that simulates
      success, errors, 429, and streamed tokens. Replace the per-file stubs
      where it fits.
- **Done when:** the mock can drive the ViewModel without the network.

## Tue, Oct 13 — ViewModel test gaps
- [ ] Fill only what the audit found missing. Expected: 429 handling and
      friendly messaging. Optimistic append, streaming accumulation, error
      surfacing and state cleanup are already covered.
- **Done when:** the gaps are tested and the target is green.

## Wed, Oct 14 — Bug fixes from Week 9
See `tech-debts.md`.
- [ ] Auto-scroll: the transcript doesn't follow a new reply or the typing
      indicator.
- [ ] Session lifecycle: mint a new session id on each launch, so the turn
      count starts fresh with the empty transcript. `SessionManager.sessionID`
      stops reading the Keychain id back (rate-limit scoping moves with it).
- [ ] "Start new conversation" clears the transcript as well as minting a new
      id. Update `ChatViewModel.startNewConversation()` and its tests.
- **Done when:** a new reply scrolls into view on the simulator, and a
  relaunch and the reset button both start at turn 1 with an empty transcript,
  confirmed against `chat_turn_counts`.

## Thu, Oct 15 — Privacy manifest
- [ ] Add `PrivacyInfo.xcprivacy` with accurate data-use declarations.
- **Done when:** the manifest is included.

## Fri, Oct 16 — TestFlight (optional)
- [ ] Archive and validate the build.
- [ ] Upload to TestFlight for internal testing.
- **Done when:** the build installs from TestFlight. Skip this session if
  there's no TestFlight release.

## Notes / blockers
_(jot anything that tripped you up so we pick it up next session)_

Mon–Tue are compressed from the original three test sessions: Weeks 5 and 6
already landed stub services and ViewModel tests covering optimistic append,
streaming accumulation, error surfacing and state cleanup (`ChatViewModelTests`,
`ChatViewModelStreamingTests`, `ChatViewErrorTests`). 429 handling and a single
shared mock look like the genuine gaps.
