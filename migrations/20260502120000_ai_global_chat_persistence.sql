-- Persistent multi-conversation history for the Global AI Chat panel.
-- Adds three tables (sessions, messages, attachments), a touch-up trigger to keep
-- the session's last_message_at fresh, and a private storage bucket for uploaded files.

CREATE TABLE IF NOT EXISTS public.ai_chat_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  branch_id uuid,
  title text NOT NULL DEFAULT 'New chat',
  is_archived boolean NOT NULL DEFAULT false,
  last_message_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_sessions_user_recent
  ON public.ai_chat_sessions(created_by, is_archived, last_message_at DESC NULLS LAST);

CREATE TABLE IF NOT EXISTS public.ai_chat_messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES public.ai_chat_sessions(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('user', 'assistant', 'system')),
  content text NOT NULL DEFAULT '',
  provider text,
  model text,
  status text NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'aborted', 'failed')),
  error_message text,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_messages_session
  ON public.ai_chat_messages(session_id, created_at);

CREATE TABLE IF NOT EXISTS public.ai_chat_attachments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id uuid REFERENCES public.ai_chat_messages(id) ON DELETE CASCADE,
  session_id uuid REFERENCES public.ai_chat_sessions(id) ON DELETE CASCADE,
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  file_name text NOT NULL,
  mime_type text NOT NULL,
  byte_size integer NOT NULL,
  storage_path text NOT NULL,
  kind text NOT NULL CHECK (kind IN ('text', 'pdf', 'docx', 'image', 'other')),
  parsed_text text,
  parse_status text NOT NULL DEFAULT 'pending' CHECK (parse_status IN ('pending', 'done', 'failed', 'skipped')),
  parse_error text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_ai_chat_attachments_message
  ON public.ai_chat_attachments(message_id);

CREATE INDEX IF NOT EXISTS idx_ai_chat_attachments_owner_unlinked
  ON public.ai_chat_attachments(created_by, created_at)
  WHERE message_id IS NULL;

CREATE OR REPLACE FUNCTION public.touch_ai_chat_session_on_message()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE public.ai_chat_sessions
  SET
    last_message_at = NEW.created_at,
    updated_at = now()
  WHERE id = NEW.session_id;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_ai_chat_messages_touch_session ON public.ai_chat_messages;
CREATE TRIGGER trg_ai_chat_messages_touch_session
AFTER INSERT ON public.ai_chat_messages
FOR EACH ROW
EXECUTE FUNCTION public.touch_ai_chat_session_on_message();

INSERT INTO storage.buckets (id, name, public)
VALUES ('ai-chat-attachments', 'ai-chat-attachments', false)
ON CONFLICT (id) DO NOTHING;

GRANT ALL ON TABLE public.ai_chat_sessions TO service_role;
GRANT ALL ON TABLE public.ai_chat_messages TO service_role;
GRANT ALL ON TABLE public.ai_chat_attachments TO service_role;
