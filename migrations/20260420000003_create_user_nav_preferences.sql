-- Per-user favorite pages and recent navigation history.
-- One row per user; favorites and recent_pages are kept as JSONB arrays so
-- toggling a favorite or logging a page visit is a single upsert.

CREATE TABLE IF NOT EXISTS public.user_nav_preferences (
  user_id      UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  favorites    JSONB NOT NULL DEFAULT '[]'::jsonb,
  recent_pages JSONB NOT NULL DEFAULT '[]'::jsonb,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

ALTER TABLE public.user_nav_preferences ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user reads own nav prefs" ON public.user_nav_preferences;
CREATE POLICY "user reads own nav prefs" ON public.user_nav_preferences
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "user inserts own nav prefs" ON public.user_nav_preferences;
CREATE POLICY "user inserts own nav prefs" ON public.user_nav_preferences
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "user updates own nav prefs" ON public.user_nav_preferences;
CREATE POLICY "user updates own nav prefs" ON public.user_nav_preferences
  FOR UPDATE USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);
