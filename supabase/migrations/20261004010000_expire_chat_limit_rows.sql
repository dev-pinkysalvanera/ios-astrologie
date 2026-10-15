-- Week 10 Task 12: expire old rows in the limit tables.
--
-- chat_rate_limits and chat_turn_counts gain a row per key and never shrink.
-- Since Week 10 Task 4 the app mints a session per launch, so turn rows pile up
-- faster. A daily pg_cron job deletes rows nobody has touched in a while:
--
-- - chat_rate_limits: idle for 1 day. The longest window is the report limit's
--   1 hour, so a row older than that no longer affects any decision.
-- - chat_turn_counts: idle for 7 days. Sessions last one launch now, so a
--   session that comes back after a week is effectively a new one anyway.
--
-- `updated_at` is set on every hit by chat_check_rate_limit and
-- chat_increment_turn, so it's a safe "last used" key.

CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

CREATE OR REPLACE FUNCTION public.chat_expire_limit_rows()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  DELETE FROM public.chat_rate_limits WHERE updated_at < now() - interval '1 day';
  DELETE FROM public.chat_turn_counts WHERE updated_at < now() - interval '7 days';
$$;

-- Only the scheduler (running as postgres) calls this; no API role may.
REVOKE ALL ON FUNCTION public.chat_expire_limit_rows() FROM PUBLIC, anon, authenticated;

-- Daily at 03:17 UTC. Scheduling by name replaces any earlier job of the same
-- name, so re-running this migration doesn't add a second one.
SELECT cron.schedule(
  'chat-expire-limit-rows',
  '17 3 * * *',
  'SELECT public.chat_expire_limit_rows()'
);
