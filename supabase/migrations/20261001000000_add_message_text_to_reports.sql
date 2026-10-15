-- Week 9 Task 4: store the reported reply's text.
--
-- Replies aren't persisted anywhere and message ids are minted on the device, so
-- without the text a report row can't be traced back to what was flagged. The
-- text is the raw model output (`ChatMessage.text`), not the markdown-stripped
-- version the bubble displays.
ALTER TABLE public.reports ADD COLUMN IF NOT EXISTS message_text text;
