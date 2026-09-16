-- =====================================================================
-- LEAD Quiz Portal — 19: the clock only runs while the student is there
--
-- Before: the deadline was a fixed wall-clock time set when they pressed
-- Start. A student whose laptop died lost that time for good.
--
-- Now: the attempt accumulates elapsed_seconds, and that only advances
-- when the student's browser actually calls in. The browser heartbeats
-- every 10 seconds, so a gap of up to 25 seconds is counted as normal
-- working time (network jitter); anything beyond that is recorded as
-- offline_seconds and costs the student nothing.
--
-- deadline_at is kept up to date as "when they would finish if they stay
-- online from here", so the countdown in the student's browser and every
-- existing screen keep working unchanged.
--
-- The ROUND WINDOW is still a hard wall: when it shuts, everyone still
-- open is submitted (ROUND_ENDED), online or not. That is the backstop
-- that stops a disconnected student sitting in limbo forever.
--
-- TRADE-OFF, stated plainly: a student can now stop their own clock by
-- pulling their network cable. offline_seconds is recorded per attempt so
-- a proctor can see exactly who did that and for how long, and the round
-- window caps the total damage.
-- Safe to re-run.
-- =====================================================================

alter table quiz.attempts add column if not exists elapsed_seconds numeric not null default 0;
alter table quiz.attempts add column if not exists offline_seconds numeric not null default 0;
alter table quiz.attempts add column if not exists last_tick_at    timestamptz;
alter table quiz.attempts add column if not exists duration_seconds int;

-- how long a silence still counts as working time (heartbeat is every 10s)
create or replace function quiz.tick_grace() returns int language sql immutable as $$ select 25 $$;

-- Every new attempt gets its own budget, taken from the round (or config).
create or replace function quiz.attempt_defaults()
returns trigger language plpgsql security definer set search_path = quiz, public as $$
begin
  if new.duration_seconds is null then
    select coalesce(b.duration_minutes, c.duration_minutes) * 60
      into new.duration_seconds
      from quiz.config c
      left join quiz.students s on s.roll_no = new.roll_no
      left join quiz.batches  b on b.id = s.batch_id
     where c.id = 1;
    new.duration_seconds := coalesce(new.duration_seconds, 20 * 60);
  end if;
  new.last_tick_at := coalesce(new.last_tick_at, now());
  return new;
end $$;

drop trigger if exists attempts_defaults on quiz.attempts;
create trigger attempts_defaults before insert on quiz.attempts
  for each row execute function quiz.attempt_defaults();

-- existing attempts keep their budget
update quiz.attempts a
   set duration_seconds = coalesce(a.duration_seconds,
         (select coalesce(b.duration_minutes, c.duration_minutes) * 60
            from quiz.config c
            left join quiz.students s on s.roll_no = a.roll_no
            left join quiz.batches  b on b.id = s.batch_id
           where c.id = 1), 1200)
 where a.duration_seconds is null;

-- Attempts that were ALREADY RUNNING before this timer existed (last_tick_at is
-- null): bill them for the time they have genuinely used, so nobody writing
-- right now gets a fresh 20 minutes. Runs once per attempt; re-running is a no-op.
update quiz.attempts a
   set elapsed_seconds = least(greatest(extract(epoch from
                           (coalesce(a.paused_at, a.submitted_at, now()) - a.started_at)), 0),
                           a.duration_seconds),
       last_tick_at    = now()
 where a.last_tick_at is null;

-- ---------------------------------------------------------------------
-- The tick. Called only from things the STUDENT does, never from the cron
-- sweep — that is what makes an offline student's clock stand still.
-- ---------------------------------------------------------------------
create or replace function quiz.tick(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
declare v quiz.attempts; v_gap numeric; v_counted numeric;
begin
  select * into v from quiz.attempts where id = p_attempt;
  if v.id is null or v.status <> 'in_progress' then return; end if;

  v_gap := greatest(extract(epoch from (now() - coalesce(v.last_tick_at, v.started_at))), 0);
  v_counted := least(v_gap, quiz.tick_grace());

  update quiz.attempts
     set elapsed_seconds = elapsed_seconds + v_counted,
         offline_seconds = offline_seconds + (v_gap - v_counted),
         last_tick_at    = now(),
         deadline_at     = now() + make_interval(secs =>
                             greatest(coalesce(duration_seconds, 1200)
                                      - (elapsed_seconds + v_counted), 0))
   where id = p_attempt;
end $$;

-- Time is up when they have USED their budget, not when a wall clock passes.
create or replace function quiz.expire_if_needed(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  perform quiz.tick(p_attempt);
  if exists (select 1 from quiz.attempts
              where id = p_attempt and status = 'in_progress'
                and elapsed_seconds >= coalesce(duration_seconds, 1200)) then
    perform quiz.finalize_attempt(p_attempt, 'submitted', 'TIME_UP');
  end if;
end $$;

-- The sweep deliberately does NOT tick. It only ends people who have
-- genuinely used their time, plus everyone caught by the round window.
create or replace function quiz.sweep_expired()
returns int language plpgsql security definer set search_path = quiz, public as $$
declare r record; n int := 0;
begin
  -- 1. students who have used their whole budget
  for r in select id from quiz.attempts
            where status = 'in_progress'
              and elapsed_seconds >= coalesce(duration_seconds, 1200)
  loop
    perform quiz.finalize_attempt(r.id, 'submitted', 'TIME_UP');
    n := n + 1;
  end loop;

  -- 2. the round window closing ends EVERYTHING still open, paused and
  --    disconnected attempts included. This is the hard wall.
  for r in
    select a.id from quiz.attempts a
      join quiz.students s on s.roll_no = a.roll_no
      join quiz.batches  b on b.id = s.batch_id
     where a.status in ('in_progress', 'paused')
       and b.closes_at is not null and now() > b.closes_at
  loop
    update quiz.attempts set status = 'in_progress', paused_at = null where id = r.id;
    perform quiz.finalize_attempt(r.id, 'submitted', 'ROUND_ENDED');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Resuming after a pause must not bill the student for the pause.
create or replace function public.admin_resume_attempt(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts; v_left numeric;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if v_att.status <> 'paused' then raise exception 'NOT_PAUSED'; end if;

  v_left := greatest(coalesce(v_att.duration_seconds, 1200) - v_att.elapsed_seconds, 0);
  update quiz.attempts
     set status = 'in_progress', paused_at = null,
         last_tick_at = now(),                       -- the pause costs nothing
         deadline_at  = now() + make_interval(secs => v_left)
   where id = v_att.id;

  insert into quiz.messages (roll_no, sender, sender_name, body, read_by_admin)
  values (p_roll, 'admin', v_admin, 'Your test has been resumed. Return to fullscreen to continue.', true);
  perform quiz.audit(v_admin, 'RESUME_ATTEMPT', p_roll,
                     json_build_object('restored_seconds', v_left::int)::jsonb);
  return json_build_object('ok', true, 'restored_seconds', v_left::int);
end $$;

-- Extending now adds to the student's BUDGET, not to a wall-clock time.
create or replace function public.admin_extend_time(p_token uuid, p_roll text, p_minutes int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin    text := quiz.admin_from_token(p_token);
  v_att      quiz.attempts;
  v_deadline timestamptz;
  v_batch    quiz.batches;
  v_pushed   boolean := false;
begin
  update quiz.attempts
     set duration_seconds = coalesce(duration_seconds, 1200) + p_minutes * 60,
         deadline_at = now() + make_interval(secs =>
                         greatest(coalesce(duration_seconds, 1200) + p_minutes * 60
                                  - elapsed_seconds, 0))
   where roll_no = p_roll and status = 'in_progress'
  returning * into v_att;
  if not found then raise exception 'NOT_IN_PROGRESS'; end if;
  v_deadline := v_att.deadline_at;

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
                           'round_window_pushed', v_pushed);
end $$;

grant execute on function public.admin_resume_attempt(uuid, text) to anon, authenticated;
grant execute on function public.admin_extend_time(uuid, text, int) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Show proctors who has been disconnected, and for how long.
-- ---------------------------------------------------------------------
create or replace function public.admin_offline_report(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
      'roll_no', a.roll_no, 'full_name', s.full_name, 'status', a.status,
      'minutes_used',    round(a.elapsed_seconds / 60.0, 1),
      'minutes_offline', round(a.offline_seconds / 60.0, 1),
      'minutes_allowed', round(coalesce(a.duration_seconds, 1200) / 60.0, 1),
      'last_seen_at', a.last_tick_at)
      order by a.offline_seconds desc)
    from quiz.attempts a
    join quiz.students s on s.roll_no = a.roll_no
   where a.offline_seconds > 30), '[]'::json);
end $$;

grant execute on function public.admin_offline_report(uuid) to anon, authenticated;
-- NOTE: Student Live already shows who is silent right now (the green/grey dot
-- is driven by last_seen_at). admin_offline_report above is the place to see
-- accumulated lost time, so admin_live is deliberately left untouched.
