-- =====================================================================
-- LEAD Quiz Portal — 18: extending time actually works
--
-- The trap this fixes: a proctor gives a student who dropped offline 10
-- extra minutes, but the ROUND WINDOW closes first and sweep_expired()
-- force-submits them anyway with reason ROUND_ENDED. The extension looked
-- like it worked and silently did nothing. That is far more likely now
-- that students sit the test from their own homes and connections.
--
-- admin_extend_time now pushes the round's closing time out far enough to
-- cover the extension, and reports what it did. This does NOT give anyone
-- else extra time: every student still has their own deadline_at, and the
-- window is only the backstop that catches stragglers.
-- Safe to re-run.
-- =====================================================================

create or replace function public.admin_extend_time(p_token uuid, p_roll text, p_minutes int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin    text := quiz.admin_from_token(p_token);
  v_deadline timestamptz;
  v_batch    quiz.batches;
  v_pushed   boolean := false;
begin
  update quiz.attempts set deadline_at = greatest(deadline_at, now()) + make_interval(mins => p_minutes)
   where roll_no = p_roll and status = 'in_progress'
  returning deadline_at into v_deadline;
  if not found then raise exception 'NOT_IN_PROGRESS'; end if;

  select b.* into v_batch from quiz.batches b
    join quiz.students s on s.batch_id = b.id
   where s.roll_no = p_roll;

  -- keep the round open long enough for the extension to be usable
  if v_batch.id is not null and v_batch.closes_at is not null
     and v_batch.closes_at < v_deadline then
    update quiz.batches set closes_at = v_deadline + interval '1 minute'
     where id = v_batch.id;
    v_pushed := true;
  end if;

  perform quiz.audit(v_admin, 'EXTEND_TIME', p_roll,
                     json_build_object('minutes', p_minutes,
                                       'round_window_pushed', v_pushed)::jsonb);
  return json_build_object('ok', true, 'deadline_at', v_deadline,
                           'round_window_pushed', v_pushed,
                           'round_closes_at', case when v_pushed then v_deadline + interval '1 minute'
                                                   else v_batch.closes_at end);
end $$;

grant execute on function public.admin_extend_time(uuid, text, int) to anon, authenticated;
