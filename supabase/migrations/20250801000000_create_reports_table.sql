CREATE TABLE IF NOT EXISTS public.reports (
  id uuid DEFAULT gen_random_uuid() PRIMARY KEY,
  session_id text NOT NULL,
  message_id text NOT NULL,
  reason text,
  reporter_user_id uuid,
  created_at timestamptz DEFAULT now() NOT NULL
);

-- RLS: only service-role can insert/read
ALTER TABLE public.reports ENABLE ROW LEVEL SECURITY;
