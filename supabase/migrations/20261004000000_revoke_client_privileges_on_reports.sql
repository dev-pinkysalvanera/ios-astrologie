-- Week 10 Task 9: only the chat function may touch reports.
--
-- reports was created with RLS on but no explicit grants, so anon and
-- authenticated kept TRIGGER, REFERENCES and TRUNCATE. RLS doesn't stop
-- TRUNCATE. Same approach as 20260929000000_create_chat_limits.sql.
-- service_role keeps the INSERT granted in 20261002000000.
REVOKE ALL ON TABLE public.reports FROM PUBLIC, anon, authenticated;
