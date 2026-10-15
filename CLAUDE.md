# Astrologie — instructions for Claude Code

A Vedic-astrology chat app: a SwiftUI iOS client (`Astrologie/`) and a Supabase
Edge Function that proxies Gemini (`supabase/functions/chat/`). Planning docs live
in `portfolio-weekly-executables/` (`overview.md`, `week-NN.md`, `tech-debts.md`,
`architecture.md`).

## How we work: spec-driven, one task at a time

- The source of truth is `.kiro/specs/astrology-chat/tasks.md`. It was written
  with Kiro up to Week 9 Task 3 and keeps Kiro's format. Status lives in its
  checkboxes (`[ ]` todo, `[-]` in progress, `[x]` done) and its Notes section.
- Pinky names a task by number. Do only that task. Don't start the next one, and
  don't fix unrelated things you notice. Report them instead.
- Build what the task's bullets say. If a bullet is ambiguous, contradicts the
  code, or looks wrong, stop and ask before writing code. Don't widen or narrow
  the scope on your own. If the spec needs to change, propose the exact edit to
  `tasks.md` and wait for a yes.
- Before starting: read the task, the Notes section, the dependency graph, and
  the code the task touches. Run `git status` to see work in progress.
- Mark the task `[-]` when you start.
- Subagents are fine for the task's work. Give them the task text word for word.

## Verifying before a task is done

- Check the task's _Done when_ line yourself. Never trust an existing checkbox.
  Past weeks ticked boxes before their done-conditions were met.
- Run the relevant tests and read the results. Don't report "should pass".
- Tick `[x]` only when every part of the done-condition has been verified. If
  part of it needs a person (physical device, VoiceOver, haptics, a server-side
  check in production), leave `[-]` and list exactly what Pinky has to do.
- Finish with a report: files changed, test results with counts, what's
  verified, what's left for Pinky, and a suggested commit message.

## Git: Pinky's gate

- Never stage, commit or push. Never run a command that discards or rewrites
  working-tree changes (`reset`, `restore`, `checkout`, `switch`, `clean`,
  `stash`, `rebase`, `merge`). `.claude/settings.json` blocks these.
- Leave every change uncommitted. Pinky reviews and commits each task.
- Read-only git (`status`, `diff`, `log`, `show`) is fine.

## Commands

iOS unit tests, from `Astrologie/`:

```
xcodebuild test -project Astrologie.xcodeproj -scheme Astrologie \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:AstrologieTests 2>&1 | tail -n 80
```

- The scheme is autocreated by Xcode (no shared scheme in the repo). If
  `xcodebuild` can't find it, run `xcodebuild -list` and ask.
- Unit tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- UI tests: `-only-testing:AstrologieUITests`. Slower; run them when a task
  touches UI flows.
- `LiveStreamingUITests` calls production and spends Gemini quota. It skips
  unless `TEST_RUNNER_ASTRO_LIVE=1` is set. Never set that without asking.

Edge function, from `supabase/functions/chat/`:

- `deno task test`: unit tests.
- `deno task verify`: type check, lint, format check and tests. Run it before
  reporting any server change as done.

Production: `supabase functions deploy` and `supabase db push` change the live
app. Ask first, every time.

## Conventions

- `systemPrompt.ts` is product content. Don't reword it. Add only what a task
  specifies.
- `ChatMessage.text` stays exactly what the model produced. Display changes
  happen in views.
- Comments explain why, not what. Match the tone and style of nearby code.
- No physical device is available for testing. Flag device-only checks such as
  haptics as open; never mark them verified.
- `.kiro/specs/astrology-chat/tasks.meta.json` is Kiro's execution history.
  Leave it alone.
