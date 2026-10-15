# Website copy — Astrologie section

Replaces the "TODO (T14)" placeholder under **Projects → Personal project** on
pinkysalvanera.com. Same shape as the GlobeOne block: a label, a title, a
one-paragraph intro, then four highlight cards (title plus one or two
sentences). Every claim here is backed by `decisions.md`; the decision number
is in brackets after each card for your reference, not for the site.

---

## Label

PERSONAL PROJECT

## Title

Astrologie ↗ (link to the GitHub repo)

## Intro

An iOS chat app for Vedic astrology, with its code on GitHub. Ask a question,
and the reading streams in as it's written. Built in SwiftUI with MVVM, backed by a Supabase
Edge Function that keeps the AI key and prompt off the device. I planned it
week by week with written specs and built it with AI coding agents, reviewing
every change before it went in.

## Highlight cards

**Streaming AI Replies**
Replies appear as they're generated, parsed from a live event stream with
Swift Concurrency. Cut-off replies are detected and shown, not mistaken for
finished ones. [D12, D13]

**Secure AI Backend**
The AI key, system prompt and guardrails live on a server, not in the app.
The model can be changed without an app release. [D16, D21]

**Usage and Cost Controls**
Per-user rate limits and per-conversation turn limits, enforced on the server
in Postgres. If the limits can't be checked, the request is refused. [D22]

**Testable Architecture**
MVVM with protocol seams around every network call. 250 unit tests run
without touching the network. [D3, D4, D10]

## Media

Screen recording: clip W1 from `screen-recordings.md` (the hero clip).

## Links line

GitHub ↗ · Read the decisions behind it ↗ (link to `decisions.md` or the README
"Key decisions" section, depending on what you choose in the portfolio spec's
Task 5)

## Skills chips

Like the GlobeOne block:

Swift · SwiftUI · async/await · MVVM · Swift Testing · Supabase · TypeScript ·
Gemini API

---

## Alternatives

**Shorter intro**, if the card layout feels crowded:

> An iOS chat app for Vedic astrology, with replies streamed live
> from an AI model behind a secure Supabase backend.

**Swap-in cards**, if you'd rather lead with something else:

**Accessible by Default**
VoiceOver announcements that don't re-read a reply as it streams, Dynamic Type
support, and haptics tied to the state of the conversation. [D28, D29]

**Guardrails in Code**
Safety settings, a jailbreak filter and output checks on the server, because
a prompt alone can be talked around. [D21]

**AI-Assisted, Human-Reviewed**
Built from written specs by AI coding agents, with every change reviewed
before it's committed and the rules enforced by tool settings. [D32, D33]

---

## Notes for you

- **Not "open source".** The repo is public so the code can be read, but it has
  no licence on purpose (decided 2026-10-15), so the copy says "code on GitHub".
- **Don't add "VoiceOver-tested on device"** until Week 10 Task 13 is done.
  "Accessible by Default" as written is accurate today.
- **"250"** comes from a run on 2026-10-11 (250 passing). If you'd rather not
  update the number as tests are added, "250+" ages better.
