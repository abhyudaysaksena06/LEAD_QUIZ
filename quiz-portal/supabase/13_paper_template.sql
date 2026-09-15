-- =====================================================================
-- LEAD Quiz Portal — 13: paper template
--   Every student gets a freshly randomised paper drawn to a fixed quota:
--     Section A  (logical reasoning)      4
--     Section B  (design)                 3
--     Section C  (marketing & events)     3
--     Technical MCQ                       7
--     Coding (optional, saved as text)    3
--   = 17 MCQ + 3 coding, same shape for everyone, different questions each.
-- Safe to re-run.
-- =====================================================================

alter table quiz.config add column if not exists sec_a_count int not null default 4;
alter table quiz.config add column if not exists sec_b_count int not null default 3;
alter table quiz.config add column if not exists sec_c_count int not null default 3;
alter table quiz.config add column if not exists tech_count  int not null default 7;

update quiz.config
   set sec_a_count = 4, sec_b_count = 3, sec_c_count = 3, tech_count = 7,
       coding_count = 3,
       mcq_count = 17            -- kept in sync; the draw below uses the quotas
 where id = 1;

-- ---------- start_attempt: sectioned, per-student random draw ----------
create or replace function public.start_attempt(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_roll  text := quiz.student_from_token(p_token);
  v_cfg   quiz.config;
  v_batch quiz.batches;
  v_ids   int[];
  v_minutes int;
begin
  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.exam_open then raise exception 'EXAM_CLOSED'; end if;

  -- a student may only start once THEIR batch has been opened
  select b.* into v_batch from quiz.batches b
    join quiz.students s on s.batch_id = b.id
   where s.roll_no = v_roll;
  if v_batch.id is null   then raise exception 'NO_BATCH'; end if;
  if not v_batch.is_open  then raise exception 'BATCH_CLOSED'; end if;
  if v_batch.closes_at is not null and now() > v_batch.closes_at then
    raise exception 'ROUND_ENDED';
  end if;

  -- capacity: never let more than max_concurrent students sit the test at once
  if (select count(*) from quiz.attempts where status in ('in_progress', 'paused'))
       >= v_cfg.max_concurrent then
    raise exception 'CAPACITY_FULL';
  end if;

  v_minutes := coalesce(v_batch.duration_minutes, v_cfg.duration_minutes);

  -- checked last, so a student whose round is closed gets that message instead
  if not exists (select 1 from quiz.students
                  where roll_no = v_roll and consented_at is not null) then
    raise exception 'CONSENT_REQUIRED';
  end if;

  if not exists (select 1 from quiz.attempts where roll_no = v_roll) then
    -- one random draw per section, then the MCQ block itself is shuffled so the
    -- sections are interleaved and two students never see the same order
    with picked as (
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='A'
                       order by random() limit v_cfg.sec_a_count) a
      union all
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='B'
                       order by random() limit v_cfg.sec_b_count) b
      union all
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='C'
                       order by random() limit v_cfg.sec_c_count) c
      union all
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='TECH'
                       order by random() limit v_cfg.tech_count) t
    ),
    code as (select id from quiz.questions
              where kind='coding' and active order by random() limit v_cfg.coding_count)
    select array(select id from picked order by random())   -- MCQ first, shuffled
         || array(select id from code order by random())    -- coding always last
      into v_ids;

    if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'NO_QUESTIONS'; end if;

    -- their own clock, but never past the moment the round window shuts
    insert into quiz.attempts (roll_no, question_ids, deadline_at)
    values (v_roll, v_ids,
            least(now() + make_interval(mins => v_minutes),
                  coalesce(v_batch.closes_at, now() + make_interval(mins => v_minutes))))
    on conflict (roll_no) do nothing;   -- double-click safe
  end if;

  -- The test is now live: close every other device this student left signed in.
  -- From here until they finish, this token is the only one that works.
  update quiz.sessions set revoked = true
   where kind = 'student' and subject = v_roll and not revoked and token <> p_token;

  return public.get_exam_state(p_token);
end $$;

grant execute on function public.start_attempt(uuid) to anon, authenticated;

-- ---------- warn loudly if the bank cannot fill the template ----------
do $$
declare c record;
begin
  select (select count(*) from quiz.questions where kind='mcq' and active and section='A')    as a,
         (select count(*) from quiz.questions where kind='mcq' and active and section='B')    as b,
         (select count(*) from quiz.questions where kind='mcq' and active and section='C')    as c,
         (select count(*) from quiz.questions where kind='mcq' and active and section='TECH') as t,
         (select count(*) from quiz.questions where kind='coding' and active)                 as x
    into c;
  if c.a < 4 or c.b < 3 or c.c < 3 or c.t < 7 or c.x < 3 then
    raise warning 'Question bank too small for the template: A=% B=% C=% TECH=% coding=% (need 4/3/3/7/3). Run 12_question_bank.sql.',
      c.a, c.b, c.c, c.t, c.x;
  else
    raise notice 'Paper template OK — drawing 4/3/3/7 MCQ + 3 coding from A=% B=% C=% TECH=% coding=%.',
      c.a, c.b, c.c, c.t, c.x;
  end if;
end $$;
