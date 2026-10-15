# Week 9 — Polish, Moderation UI & Accessibility

Progress: 0/5 sessions (0%)

iOS focus. Goal by Friday: the app feels tactile and native, users can report a
response, and the UI is accessible.

## Mon, Oct 5 — Typing indicator
- [ ] Animated typing indicator shown while `state` is `.sending`, the gap
      before the first chunk. It hides on `.streaming`, where the growing
      bubble takes over, and on error or cancel.
- **Done when:** the indicator appears before the first token and disappears
      when it arrives.

## Tue, Oct 6 — Haptics
- [ ] Add `.sensoryFeedback` on message send and on reply completion.
- **Done when:** sending and receiving produce distinct haptics on device.

## Wed, Oct 7 — Material polish
- [ ] Apply `.ultraThinMaterial` to the input bar / nav for the glass look.
- [ ] Tidy spacing, colors, and empty state.
- [ ] Stop markdown markers (`##`, `**`) showing up in replies. Add a
      plain-prose formatting rule to `SYSTEM_PROMPT`, plus a display-side
      strip in the app as a backstop. Keep `message.text` raw.
- **Done when:** the screen looks intentional, not default, and a long reading
  shows no `#` or `**`.

## Thu, Oct 8 — Report a response
- [ ] Add a report action on assistant messages (context menu or swipe).
- [ ] Wire it to the backend report endpoint from Week 3.
- **Done when:** reporting a message hits the backend and confirms to the user.

## Fri, Oct 9 — Accessibility
- [ ] Support Dynamic Type; verify layout at large sizes.
- [ ] Add VoiceOver labels for bubbles, input, and controls. Confirm VoiceOver
      doesn't read out stray `#` or `*` in replies.
- **Done when:** VoiceOver reads the conversation sensibly and text scales.

## Notes / blockers
_(jot anything that tripped you up so we pick it up next session)_

Thursday's report endpoint likely needs the same user access token the `chat`
function wants — that landed in Week 7.

Friday inherits some work already done: `ChatBubble`, the compose bar and the
error line all carry VoiceOver labels and scale with Dynamic Type, but none of it
has been verified with VoiceOver actually running or at the largest type sizes.
That verification is the real task.

Wednesday's markdown item was added on 2026-09-30, after a manual simulator
test. A long reading came back full of raw `##` and `**`. `ChatBubble` renders
`Text(message.text)`, and SwiftUI doesn't parse markdown from a `String`
variable. The system prompt says nothing about formatting either. We chose plain
text over rendering markdown because half-open markers flicker while a reply
streams, `AttributedString(markdown:)` doesn't handle headings, and VoiceOver
reads stray symbols aloud. Whether readings need real structure is deferred.
Full detail is in `.kiro/specs/astrology-chat/tasks.md`, Task 7.

**2026-10-01: tooling change mid-week, Kiro to Claude Code.** The Kiro
subscription ended after Task 3 (the material polish commit). From Task 7 on,
tasks are run with Claude Code in the terminal. The spec didn't move:
`.kiro/specs/astrology-chat/tasks.md` is still the source of truth and keeps
Kiro's format, so task IDs and checkboxes carry over unchanged. The rules are the
same as before: one task at a time, named by number; each done-condition checked
independently before its box is ticked; Pinky reviews and commits every task.

Two files came with the handover. `CLAUDE.md` holds the workflow rules and the
build and test commands, and loads at the start of every session.
`.claude/settings.json` blocks `git add`, `commit`, `push` and the commands that
discard uncommitted work, and asks before a production deploy. Claude in the
Cowork desktop app was tried first, but it can't run `xcodebuild`: its shell is a
Linux sandbox, and macOS limits it to plain clicks in Xcode. It couldn't verify
iOS work on its own, so it wasn't a fit.

State at the switch: Task 7 was in progress and uncommitted. The system-prompt
rule, `MarkdownStripper` and its tests, and `ChatBubble.displayText` exist, but
the stripper covers only the first scope (`#`, `**`, `__`). The widened scope
(bullet markers and single `*` / `_` emphasis) still has to be built and tested.
