-- =====================================================================
-- LEAD Quiz Portal — 20: each round gets a scheduled date and time
--   Round 1   16 September 2026, 6:00 PM IST
--   Round 2   16 September 2026, 6:30 PM IST
--   Round 3   16 September 2026, 7:00 PM IST
--   Round 4 (Backup) — no fixed time; opened only if it is needed.
--
-- This is what the student sees on the waiting screen, next to their round.
-- It does NOT start the round: a proctor still opens each one by hand, and
-- the 30-minute window starts from the moment they do.
-- Safe to re-run.
-- =====================================================================

alter table quiz.batches add column if not exists starts_at timestamptz;

update quiz.batches set starts_at = timestamptz '2026-09-16 18:00:00+05:30' where name = 'Round 1';
update quiz.batches set starts_at = timestamptz '2026-09-16 18:30:00+05:30' where name = 'Round 2';
update quiz.batches set starts_at = timestamptz '2026-09-16 19:00:00+05:30' where name = 'Round 3';
update quiz.batches set starts_at = null                                    where name = 'Round 4 (Backup)';

-- get_exam_state hands starts_at to the student; that edit lives in
-- 02_student_api.sql, next to the rest of the batch payload.

-- Let an admin set or clear a round's scheduled time.
create or replace function public.admin_set_batch_schedule(p_token uuid, p_batch_id int,
                                                           p_starts_at timestamptz)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_b quiz.batches;
begin
  update quiz.batches set starts_at = p_starts_at where id = p_batch_id returning * into v_b;
  if v_b.id is null then raise exception 'NO_SUCH_BATCH'; end if;
  perform quiz.audit(v_admin, 'SET_BATCH_SCHEDULE', v_b.name,
                     json_build_object('starts_at', p_starts_at)::jsonb);
  return row_to_json(v_b);
end $$;

grant execute on function public.admin_set_batch_schedule(uuid, int, timestamptz) to anon, authenticated;

select 'round schedule' as step, name,
       to_char(starts_at at time zone interval '+05:30', 'DD-MM-YYYY HH12:MI AM') as starts_at_ist,
       window_minutes
  from quiz.batches order by name;
