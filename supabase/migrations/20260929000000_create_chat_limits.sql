-- Shared store for the `chat` function's per-session rate limit and turn cap.
--
-- Both counters used to live in each edge-function isolate's memory, and
-- Supabase spreads requests across isolates that each start empty, so neither
-- limit was enforced in production (70 requests in 73s never tripped a 429).
-- Postgres is already here, so it is the store with the least new
-- infrastructure.
--
-- Every mutation goes through a function that does its read-modify-write in
-- one statement or under a row lock, so concurrent isolates cannot race each
-- other past a limit.
--
-- Access: RLS on, no policies, and table/function privileges revoked from
-- anon/authenticated. Only the service role (used by the edge function) can
-- touch any of it. The publishable key that ships in the app cannot read,
-- reset, or inflate anyone's counters.

-- ---------------------------------------------------------------------------
-- Rate limit: sliding window of request timestamps per session
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.chat_rate_limits (
  session_id text PRIMARY KEY,
  -- Timestamps of accepted requests still inside the window, oldest first.
  hits timestamptz[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.chat_rate_limits ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- Turn cap: total messages per session
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS public.chat_turn_counts (
  session_id text PRIMARY KEY,
  turns integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.chat_turn_counts ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- chat_check_rate_limit
--
-- Same semantics as the old in-memory limiter: prune timestamps outside the
-- window; if the session is at the max, reject with the time until the oldest
-- one ages out; otherwise record this request and allow it. Rejected requests
-- are not recorded.
--
-- Uses the database clock, not the caller's, so isolates with skewed clocks
-- all measure against one timeline.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_check_rate_limit(
  p_session_id text,
  p_max_requests integer,
  p_window_ms integer
)
RETURNS TABLE (allowed boolean, retry_after_ms integer)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = ''
AS $$
DECLARE
  v_now timestamptz := clock_timestamp();
  v_window interval := make_interval(secs => p_window_ms / 1000.0);
  v_hits timestamptz[];
BEGIN
  -- Make sure a row exists, then lock it. Concurrent calls for the same
  -- session queue on the lock, so the count they see is always current.
  INSERT INTO public.chat_rate_limits (session_id)
  VALUES (p_session_id)
  ON CONFLICT (session_id) DO NOTHING;

  SELECT r.hits INTO v_hits
  FROM public.chat_rate_limits r
  WHERE r.session_id = p_session_id
  FOR UPDATE;

  v_hits := ARRAY(
    SELECT h FROM unnest(v_hits) AS h
    WHERE h > v_now - v_window
    ORDER BY h
  );

  IF cardinality(v_hits) >= p_max_requests THEN
    UPDATE public.chat_rate_limits
    SET hits = v_hits, updated_at = v_now
    WHERE session_id = p_session_id;

    RETURN QUERY SELECT
      false,
      greatest(
        1,
        ceil(extract(epoch FROM (v_hits[1] + v_window - v_now)) * 1000)::integer
      );
    RETURN;
  END IF;

  UPDATE public.chat_rate_limits
  SET hits = array_append(v_hits, v_now), updated_at = v_now
  WHERE session_id = p_session_id;

  RETURN QUERY SELECT true, 0;
END;
$$;

-- ---------------------------------------------------------------------------
-- chat_increment_turn
--
-- Atomically bumps the session's turn count and returns the new value. The
-- limit comparison stays in the edge function (turnCounter.ts), which is what
-- decides the 403.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_increment_turn(p_session_id text)
RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  INSERT INTO public.chat_turn_counts AS t (session_id, turns)
  VALUES (p_session_id, 1)
  ON CONFLICT (session_id)
  DO UPDATE SET turns = t.turns + 1, updated_at = now()
  RETURNING t.turns;
$$;

-- ---------------------------------------------------------------------------
-- Privileges: service role only
-- ---------------------------------------------------------------------------

REVOKE ALL ON TABLE public.chat_rate_limits FROM PUBLIC, anon, authenticated;
REVOKE ALL ON TABLE public.chat_turn_counts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.chat_rate_limits TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.chat_turn_counts TO service_role;

-- Functions are executable by PUBLIC by default; Supabase also grants anon and
-- authenticated on new public functions. Take all of that back.
REVOKE ALL ON FUNCTION public.chat_check_rate_limit(text, integer, integer)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.chat_increment_turn(text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chat_check_rate_limit(text, integer, integer)
  TO service_role;
GRANT EXECUTE ON FUNCTION public.chat_increment_turn(text) TO service_role;
