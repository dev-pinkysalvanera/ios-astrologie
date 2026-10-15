// Follow this setup guide to integrate the Deno language server with your editor:
// https://deno.land/manual/getting_started/setup_your_environment
// This enables autocomplete, go to definition, etc.

// Setup type definitions for built-in Supabase Runtime APIs
import "@supabase/functions-js/edge-runtime.d.ts";
import { withSupabase } from "@supabase/server";
import { handleChat } from "./handler.ts";

console.log("[chat] module loaded");

// This endpoint uses 'publishable' | 'secret' access, apiKey is required.
// Use publishable for Client-facing, key-validated endpoints
// Use secret for Server-to-server, internal calls
export default {
  fetch: withSupabase(
    { auth: ["publishable", "secret"] },
    // Request handling lives in handler.ts so it stays testable outside the
    // auth wrapper. See that file for the status-code mapping.
    (req, _ctx) => handleChat(req),
  ),
};

/* To invoke against the hosted project:

  1. Ensure GEMINI_API_KEY is set in your function secrets.
  2. Make an HTTP request:

  curl -i --location --request POST \
    'https://<project-ref>.supabase.co/functions/v1/chat' \
    --header 'apikey: <your sb_publishable_... key>' \
    --header 'Content-Type: application/json' \
    --data '{"sessionId":"abc","message":"What does Mercury retrograde mean?"}'

  Expected: 200 {"reply":"<Gemini-generated answer>"}
  Bad input: 400 {"error":"Field message must not be empty."}
  Timeout:   504 {"error":"AI service timed out."}
  Upstream:  502 {"error":"Failed to get response from AI service.", ...}
  No key:    500 {"error":"Server misconfiguration: missing GEMINI_API_KEY."}
  Unhandled: 500 {"error":"Unexpected server error.", ...}

*/
