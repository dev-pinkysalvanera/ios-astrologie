-- Open-source hardening, Task 5: a global daily cap on Gemini calls.
--
-- The per-user rate limit and per-session turn cap don't bound total spend:
-- anonymous sign-in lets a script mint users, and each new user starts with a
-- fresh rate limit. This counts every call that is about to reach Gemini, across
-- all users, per UTC day. The limit itself lives in the edge function
-- (dailyCap.ts), which decides the 503.
--
-- Access: same as 20260929000000_create_chat_limits.sql. RLS on, no policies,
-- and privileges revoked from anon/authenticated. Only the service role (used
-- by the edge function) can touch it.

CREATE TABLE IF NOT EXISTS public.chat_daily_usage (
  day date PRIMARY KEY,
  calls integer NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.chat_daily_usage ENABLE ROW LEVEL SECURITY;

-- ---------------------------------------------------------------------------
-- chat_increment_daily_calls
--
-- Atomically bumps today's count (UTC) and returns the new value. One upsert,
-- so concurrent isolates can't both read the same count.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_increment_daily_calls()
RETURNS integer
LANGUAGE sql
SECURITY INVOKER
SET search_path = ''
AS $$
  INSERT INTO public.chat_daily_usage AS d (day, calls)
  VALUES ((now() AT TIME ZONE 'utc')::date, 1)
  ON CONFLICT (day)
  DO UPDATE SET calls = d.calls + 1, updated_at = now()
  RETURNING d.calls;
$$;

REVOKE ALL ON TABLE public.chat_daily_usage FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.chat_daily_usage TO service_role;

REVOKE ALL ON FUNCTION public.chat_increment_daily_calls()
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.chat_increment_daily_calls() TO service_role;

-- ---------------------------------------------------------------------------
-- Expiry: the daily cron job from 20261004010000 now also drops usage rows
-- older than 30 days. Only today's row affects a decision; a month of history
-- is kept so spend can be checked against the Gemini bill.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.chat_expire_limit_rows()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  DELETE FROM public.chat_rate_limits WHERE updated_at < now() - interval '1 day';
  DELETE FROM public.chat_turn_counts WHERE updated_at < now() - interval '7 days';
  DELETE FROM public.chat_daily_usage
    WHERE day < (now() AT TIME ZONE 'utc')::date - 30;
$$;

REVOKE ALL ON FUNCTION public.chat_expire_limit_rows() FROM PUBLIC, anon, authenticated;
