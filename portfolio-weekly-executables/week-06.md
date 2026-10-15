# Week 6 — Streaming & Core Chat UI

Progress: 5/5 sessions (100%) ✅

iOS focus. Goal by Friday: replies stream token-by-token into a working chat
screen with auto-scroll and an expanding input bar.

## Mon, Aug 24 — Streaming in the service
- [x] Add a streaming method returning `AsyncThrowingStream<String, Error>`.
- [x] Consume `URLSession.bytes` and parse the SSE chunks from the backend.
- **Done when:** a test/preview prints tokens as they arrive.

## Tue, Aug 25 — ViewModel consumes the stream
- [x] Append an empty assistant message, then append tokens as they stream in.
- [x] Drive `state` across the stream lifecycle: `.sending` → `.streaming` →
      `.idle` (the `.streaming` case landed unused in Week 5; this is where it
      starts being reached).
- **Done when:** ViewModel state updates incrementally during a stream.

## Wed, Aug 26 — Chat bubbles + message list
- [x] Build a `ChatBubble` view (user vs assistant styling).
- [x] Render `messages` in a scrolling list via `ForEach`.
- **Done when:** the screen shows a real conversation.

## Thu, Aug 27 — Auto-scroll
- [x] Wrap the list in `ScrollViewReader`.
- [x] Scroll to the newest message when `messages` changes.
- **Done when:** new/streaming messages keep the latest in view.

## Fri, Aug 28 — Input bar
- [x] Vertically expanding multiline `TextField`.
- [x] Send button wired to the ViewModel; disable while waiting.
- **Done when:** you can type and send from the UI end to end.

## Added mid-week — failures are visible

Not in the original plan. `ChatViewModel` had always parked failures in
`ChatState.failed`, but no view read them, so a failed send looked like the app
shrugging: the person's message appeared, the send button came back to life, and
no reply ever arrived.

- [x] Error banner in `ChatView` between the transcript and the compose bar,
      reading `ChatState.error` and `ChatError.errorDescription`, with a VoiceOver
      label that says the word "Error" (the tint and glyph carry that visually and
      neither is spoken).

Scoped to visibility only. No retry button, and no change to `ChatViewModel`,
`ChatError`, or `ChatService`. Styling and a real VoiceOver pass are Week 9.

## Notes / blockers

**Calendar slipped.** Planned for Aug 24–28, actually finished Sat Sep 19. The
weeks after this one were rescheduled forward rather than left in the past.

**The live app does not work yet, and the tests could not have told us.** Every
test in the target drives a stub — `EchoChatService`, `GatedChatService`, a stub
`ChatTransport` replaying canned bytes. A green suite proves the wiring is right
and says nothing about whether a real request gets a reply. It does not.

Root cause: `ChatService.makeRequest(for:)` sends no `Authorization` header, so
the `chat` function answers 401. The client half of authentication was never
scheduled — Week 3's "Anonymous session/auth" was backend-only. **Week 7 was
inserted to close it**, and the gap-fix items found while verifying it landed
in a new Week 8, pushing polish to Week 9 and submission to Week 10.

Two failure modes compounded, worth remembering: the request was rejected, *and*
the rejection was invisible. The second is what made it read as silence. The
error banner above fixes the second; Week 7 fixes the first.

**Don't confuse the two "sessions".** `SessionManager`'s Keychain UUID is a
rate-limit scope in the request body. It is not authentication and cannot become
authentication. See the table in `week-07.md`.
