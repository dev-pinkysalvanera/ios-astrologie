# Astrology Chat — Project Overview

A Vedic-astrology AI chat iOS app. Gemini powers the responses through a Supabase
Edge Function proxy (the API key never ships in the app). Built as a portfolio
piece targeting senior iOS roles, and intended for App Store submission.

## Working cadence
- Monday–Friday, ~30 minutes per session.
- One weekly file per week (`week-01.md`, `week-02.md`, ...), each with daily
  checkbox tasks.
- Tick a box when the session's task is done. Each task is scoped to fit in 30
  minutes with a clear "done" signal.

## Tooling
- **Spec:** `.kiro/specs/astrology-chat/tasks.md` holds the current week's
  implementation plan, one task per item, each with a "done when". It's the
  source of truth for what gets built.
- **Executor:** up to Week 9 Task 3, tasks were run with AWS Kiro. From Week 9
  Task 7 (2026-10-01), Claude Code runs them. Its rules and the build and test
  commands are in `CLAUDE.md` at the repo root. See `week-09.md` for why the
  switch happened mid-week.
- **Gate:** the agent never commits. Each task's changes stay uncommitted until
  Pinky reviews them and commits, one commit per task. `.claude/settings.json`
  enforces this.

## Tech decisions (locked)
- **Backend:** Supabase Edge Functions (Deno/TypeScript) as a proxy to Gemini.
- **Streaming:** Server-Sent Events (SSE) from the function to the app.
- **System prompt & guardrails:** live server-side, not in the app.
- **iOS minimum target:** iOS 18 (one back from current; enables `@Observable`,
  SwiftData, `.sensoryFeedback`, modern streaming APIs).
- **iOS architecture:** MVVM, protocol-based service layer, `@Observable`
  ViewModel on `@MainActor`, SwiftData for message persistence _(framework
  chosen; model and wiring deferred to post-MVP — see `beyond-mvp.md` §5)_,
  Keychain for the session identifier.

## Project details
- Supabase project: **Astrologie** — region Oceania (Sydney)
- Project ref: `dpmzorjfuzfpxthyqiyg`

## Roadmap (week by week)
- **Week 1** — Supabase CLI setup, init, link, deployable function skeleton, API contract.
- **Week 2** — Gemini integration (non-streaming), astrology system prompt, error handling, streaming (SSE).
- **Week 3** — Anonymous auth/session, rate limiting, moderation + reporting, production deploy. Backend done.
- **Week 4** — iOS: strip template, set iOS 18 target, network DTOs, `ChatMessage` UI model, Keychain session manager.
- **Week 5** — iOS: service layer (protocol, error enum, non-streaming impl), `@Observable` ViewModel with optimistic updates, explicit view-state modeling.
- **Week 6** — iOS: streaming in service + ViewModel, chat UI (bubbles, list, auto-scroll), expanding input bar.
- **Week 7** — iOS: sign-in (SDK, provider, access token), bearer header on `chat`, first live reply, turn-limit escape hatch, token refresh verification.
- **Week 8** — Closing the gaps found verifying Week 7 live: SSE wire-format/streaming-commit bug in `chat`, Gemini timeout tuning, stripping internal `debug` detail from error responses, and the still-open rate-limit/turn-counter durability gap.
- **Week 9** — iOS: typing indicator, haptics + material polish, moderation/report UI, accessibility (Dynamic Type, VoiceOver).
- **Week 10** — Unit tests (mock service, ViewModel streaming/errors/429), privacy manifest, App Store prep and submission.

See `tech-debts.md` for debt deferred out of the weeks above. It is a gate on
Week 10, not a week of sessions. See `architecture.md` for the locked iOS
architecture decision and its trade-offs, and `beyond-mvp.md` for senior-signal
client enhancements that are not scheduled in any week.

## Progress dashboard

Tracked by session (each day = one 30-minute session). Update the counts here
and the header in each weekly file as sessions are completed.

**Overall: 37 / 46 sessions complete (80%)**

```
[███████████████████████████·······] 80%
```

| Week | Focus | Sessions | Done | % |
|------|-------|----------|------|---|
| 1 | Supabase setup & skeleton | 3 | 3 | 100% |
| 2 | Gemini, prompt, streaming | 5 | 5 | 100% |
| 3 | Backend auth, limits, moderation, deploy | 5 | 5 | 100% |
| 4 | iOS models & project setup | 5 | 5 | 100% |
| 5 | iOS service layer & ViewModel | 5 | 5 | 100% |
| 6 | Streaming & core chat UI | 5 | 5 | 100% |
| 7 | Sign-in & first live reply | 9 | 9 | 100% |
| 8 | Closing the gaps found in Week 7 | 5 | 0 | 0% |
| 9 | Polish, moderation UI, a11y | 5 | 0 | 0% |
| 10 | Tests, privacy, submission | 5 | 0 | 0% |
| **Total** | | **46** | **37** | **80%** |

Milestones:
- Backend complete: end of Week 3 (13 sessions, ~28%).
- First live reply in the app: Week 7/8 — the first real production 200 with
  streamed content came out of the Week 8 SSE-format fix, not Week 7 itself; see
  `tech-debts.md`.
- iOS feature-complete: end of Week 9 (41 sessions, ~89%).
- Tech debts cleared: before Week 10 submission (see `tech-debts.md`).
- Submitted to App Store: end of Week 10 (46 sessions, 100%).

## Debt policy
Debt found mid-week goes to `tech-debts.md` rather than being fixed on the spot,
so the MVP flow is not derailed. Before adding an item, check the coverage table
at the bottom of that file — most hardening is already scheduled in Week 3.

`tech-debts.md` is a **gate on submission**: nothing in it ships to the App Store
unfixed. Anything unsafe to defer stays in its original week — backend auth and
rate limiting are the current examples and remain in Week 3.

One caveat learned the hard way in Week 6: "unsafe to defer" has to cover the
*client* half of a backend feature too. Week 3's auth was ticked complete while
the app still had no way to obtain a token, and nothing caught it for four weeks
because every test drove a stub. Hence Week 7.

## Status
- Week 1: complete ✅ (3/3)
- Week 2: complete ✅ (5/5)
- Week 3: complete ✅ (5/5) — Backend done 🎉
- Week 4: complete ✅ (5/5) — iOS foundation done 🎉
- Week 5: complete ✅ (5/5) — Service layer & ViewModel
- Week 6: complete ✅ (5/5) — Streaming & core chat UI, visible failures
- Week 7: complete ✅ (9/9) — Sign-in & first live reply
- Week 8: up next ⏳ (0/5) — Closing the gaps found in Week 7
- Week 9: not started (0/5) — Polish, moderation UI, a11y
- Week 10: not started (0/5) — Tests, privacy, submission
