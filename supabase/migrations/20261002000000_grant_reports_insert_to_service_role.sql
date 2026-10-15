-- Week 9 Task 4: let the chat function store reports.
--
-- `handleReport` inserts through PostgREST as service_role, but the reports
-- migration never granted it INSERT (this project's default privileges don't),
-- so every report failed with "Failed to store report." and the table stayed
-- empty. Same explicit-grant approach as 20260929000000_create_chat_limits.sql.
-- INSERT only: the function sends `Prefer: return=minimal` and never reads back.
GRANT INSERT ON TABLE public.reports TO service_role;
