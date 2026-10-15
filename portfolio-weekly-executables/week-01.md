# Week 1 — Supabase Setup & Function Skeleton

Progress: 3/3 sessions (100%) ✅

Short week: starts Wednesday July 22. Backend focus. Goal by Friday: a deployed
`chat` Edge Function that accepts a request and returns a well-defined JSON shape
(no Gemini yet).

## Wed, Jul 22 — Tooling
- [x] Install Homebrew.
- [x] Install the Supabase CLI (`brew install supabase/tap/supabase`).
- [x] `supabase login` and confirm the CLI can see the Astrologie project.

## Thu, Jul 23 — Init, link, deploy a skeleton
- [x] `supabase init` to create the `supabase/` folder in this repo.
- [x] `supabase link --project-ref dpmzorjfuzfpxthyqiyg`.
- [x] `supabase functions new chat` to scaffold the function.
- [x] `supabase functions deploy chat` and hit it with `curl` — confirm a 2xx response.
- **Done when:** curl returns a response from the deployed function.

## Fri, Jul 24 — API contract
- [x] Decide the request shape (e.g. `{ sessionId: string, message: string }`).
- [x] Decide the response shape (e.g. `{ reply: string }`) and error shape (`{ error: string }`).
- [x] Implement request parsing + validation in the function; return the response
      shape with a hardcoded/echoed reply (still no Gemini).
- [x] Redeploy and `curl` with a JSON body to verify parsing works.
- **Done when:** curl with a valid JSON body returns the response shape; a bad body returns the error shape.

## API contract — request shape (decided Fri, Jul 24)
The `chat` function accepts a **POST** request with a JSON body:

```json
{ "sessionId": "string", "message": "string" }
```

| Field       | Type   | Required | Notes                                                        |
| ----------- | ------ | -------- | ------------------------------------------------------------ |
| `sessionId` | string | yes      | Identifies the conversation/thread; groups messages together. |
| `message`   | string | yes      | The user's chat message text. Must be non-empty once validated. |

Decisions:
- Both fields are required; a body missing either (or with wrong types) is a bad
  request and will return the error shape (see next task).
- `Content-Type: application/json` is expected.
- This replaces the scaffold's `{ name }` echo body.
- Response shape and validation are handled in the subsequent tasks, not here.

## API contract — response & error shape (decided Fri, Jul 24)
On success, the `chat` function returns **HTTP 200** with a JSON body:

```json
{ "reply": "string" }
```

On a bad request, it returns a **4xx** status with a JSON error body:

```json
{ "error": "string" }
```

| Field   | Type   | Response        | Status | Notes                                                        |
| ------- | ------ | --------------- | ------ | ------------------------------------------------------------ |
| `reply` | string | success         | 200    | The assistant's reply text. Hardcoded/echoed for now (see below). |
| `error` | string | error           | 4xx    | Human-readable description of what was wrong with the request. |

Conditions that return the error shape (`400 Bad Request`):
- Body is not valid JSON (malformed / unparseable).
- Missing `sessionId` or `message`.
- `sessionId` or `message` is the wrong type (not a string).
- `message` is empty once validated.

Decisions:
- Success is always `200` with `{ "reply": "string" }` and `Content-Type: application/json`.
- Validation failures use `400` with `{ "error": "string" }`; the `error` string
  states which field/condition failed so the client can surface it.
- Only the two keys are returned per shape — no extra metadata for now.
- `reply` is **hardcoded/echoed** until Gemini is integrated in a later week; the
  shape stays the same so wiring Gemini later won't change the contract.
- Parsing/validation and the actual response body are implemented in the
  subsequent tasks, not here — this task only records the decision.

## Notes / blockers
_(jot anything that tripped you up so we pick it up next session)_
- Deploy worked with Docker not running (CLI just warns and uploads assets).
- The `apiKey` in the scaffolded `index.ts` comment is a placeholder and returns
  401 "Invalid API key". The function uses `withSupabase({ auth: ["publishable", "secret"] })`,
  so it needs the **new-style** key, not the legacy JWT `anon` key (that gives 401
  "Invalid credentials").
- Working curl uses the project's real publishable key from
  `supabase projects api-keys` (name `default`, `sb_publishable_...`):
  ```
  curl -i -X POST 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat' \
    -H 'apiKey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6' \
    -H 'Content-Type: application/json' \
    --data '{"sessionId":"abc","message":"hello"}'
  ```
  → `200 {"reply":"You said: hello"}`
  A bad body (e.g. `--data '{"sessionId":"abc"}'`) → `400 {"error":"Missing required field: message."}`
