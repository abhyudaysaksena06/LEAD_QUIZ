-- =====================================================================
-- LEAD Quiz Portal — 26: instructions before sign-in
--
-- The sign-in pages now show the exam instructions beside the sign-in box,
-- so the numbers in them (questions, minutes, violation limit, camera and
-- microphone) must be readable before anyone has signed in. This returns
-- only those display settings — nothing about questions, answers or people.
-- Safe to re-run.
-- =====================================================================

create or replace function public.exam_info()
returns json language sql stable security definer set search_path = quiz, public as $$
  select json_build_object(
    'exam_title',       c.exam_title,
    'mcq_count',        c.mcq_count,
    'coding_count',     c.coding_count,
    'duration_minutes', c.duration_minutes,
    'max_flags',        c.max_flags,
    'require_camera',   c.require_camera,
    'require_mic',      c.require_mic)
  from quiz.config c where c.id = 1;
$$;

grant execute on function public.exam_info() to anon, authenticated;
