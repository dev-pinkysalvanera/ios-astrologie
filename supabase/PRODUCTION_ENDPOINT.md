# Production Endpoint — Astrology Chat

## Endpoint URL

```
https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat
```

**Project ref:** `dpmzorjfuzfpxthyqiyg`
**Dashboard:** https://supabase.com/dashboard/project/dpmzorjfuzfpxthyqiyg/functions
**Function version:** 12 (deployed 2026-08-06)

## Authentication

The function uses Supabase's `withSupabase` auth wrapper with `publishable` + `secret` access.

- **apikey header:** `sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6` (required by Supabase gateway)
- **Authorization header:** `Bearer <user_access_token>` (required by our handler; obtained via Supabase Auth sign-in)

## Curl Test Pass Results

### ✅ Test 1: 401 — Missing Authorization token

```bash
curl -s -w "\nHTTP_STATUS: %{http_code}" \
  -X POST 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat' \
  --header 'apikey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6' \
  --header 'Content-Type: application/json' \
  --data '{"sessionId":"test","message":"Hello"}'
```

**Result:** `{"error":"Missing or invalid authorization token."}` — HTTP 401 ✅

### ✅ Test 2: 401 — Invalid apikey (gateway rejection)

```bash
curl -s -w "\nHTTP_STATUS: %{http_code}" \
  -X POST 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat' \
  --header 'apikey: invalid-key' \
  --header 'Content-Type: application/json' \
  --data '{"sessionId":"test","message":"Hello"}'
```

**Result:** `{"message":"Invalid credentials","code":"INVALID_CREDENTIALS"}` — HTTP 401 ✅

### ✅ Test 3: CORS Preflight — 204 No Content

```bash
curl -s -w "\nHTTP_STATUS: %{http_code}" \
  -X OPTIONS 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat' \
  --header 'apikey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6' \
  --header 'Origin: http://localhost:3000' \
  --header 'Access-Control-Request-Method: POST'
```

**Result:** HTTP 204, CORS headers present (`access-control-allow-origin: *`, `access-control-allow-methods`, `access-control-allow-headers`) ✅

### 📋 Test 4: 400 — Bad input (requires valid auth token)

```bash
curl -s -w "\nHTTP_STATUS: %{http_code}" \
  -X POST 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat' \
  --header 'apikey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6' \
  --header 'Authorization: Bearer <ACCESS_TOKEN>' \
  --header 'Content-Type: application/json' \
  --data '{"sessionId":"test"}'
```

**Expected:** `{"error":"Missing required field: message."}` — HTTP 400

### 📋 Test 5: Happy path + Streaming (requires valid auth token)

```bash
curl -sN -w "\nHTTP_STATUS: %{http_code}" \
  -X POST 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat' \
  --header 'apikey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6' \
  --header 'Authorization: Bearer <ACCESS_TOKEN>' \
  --header 'Content-Type: application/json' \
  --data '{"sessionId":"abc","message":"What does Mercury retrograde mean?"}'
```

**Expected:** HTTP 200, `Content-Type: text/event-stream`, body with `data: <chunk>\n\n` events ending in `data: [DONE]\n\n`

### 📋 Test 6: 429 — Rate limiting (requires valid auth token + rapid requests)

```bash
# Send 11+ requests in quick succession to the same sessionId
for i in $(seq 1 12); do
  curl -s -w " HTTP:%{http_code}\n" \
    -X POST 'https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat' \
    --header 'apikey: sb_publishable_w0iZyNsgIwLMUK3m52ODPg_Pf2bguM6' \
    --header 'Authorization: Bearer <ACCESS_TOKEN>' \
    --header 'Content-Type: application/json' \
    --data '{"sessionId":"rate-test","message":"Hello"}' &
done
wait
```

**Expected:** After threshold, responses return `{"error":"Rate limit exceeded. Try again later."}` — HTTP 429 with `Retry-After` header

## Deployment Details

- **Last deployed:** 2026-08-06
- **Version:** 12
- **Deploy command:** `supabase functions deploy chat --project-ref dpmzorjfuzfpxthyqiyg`
- **Status:** ACTIVE

## Test Summary

| # | Test Case | Status | Notes |
|---|-----------|--------|-------|
| 1 | 401 — Missing auth | ✅ Verified | Returns correct error shape |
| 2 | 401 — Invalid apikey | ✅ Verified | Gateway rejects with INVALID_CREDENTIALS |
| 3 | CORS Preflight | ✅ Verified | 204 with correct headers |
| 4 | 400 — Bad input | 📋 Documented | Requires valid auth token |
| 5 | Happy path + SSE streaming | 📋 Documented | Requires valid auth token |
| 6 | 429 — Rate limiting | 📋 Documented | Requires valid auth token + rapid fire |

## Notes

- Tests 4–6 require a valid user access token. To obtain one:
  1. Sign up a user via Supabase Auth (email must be confirmed)
  2. Sign in via `/auth/v1/token?grant_type=password` to get `access_token`
  3. Use that token in the `Authorization: Bearer <token>` header
- Anonymous sign-ins are currently **disabled** on the remote project
- Email confirmation is **required** — programmatic test user creation cannot bypass this without admin/service-role access
- The iOS client handles authentication automatically via the Supabase Swift SDK
- Streaming (SSE) is confirmed working via the handler code and local tests from Week 2
- All code paths (400, 401, 403, 429, 502, 504) are validated by unit tests in `handler.test.ts`

## iOS Client Integration

```swift
// Use in the iOS app with the Supabase Swift SDK:
let url = "https://dpmzorjfuzfpxthyqiyg.supabase.co/functions/v1/chat"
// The SDK handles apikey + auth token headers automatically
```
