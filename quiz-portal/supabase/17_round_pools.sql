-- =====================================================================
-- LEAD Quiz Portal — 17: round-specific pools, 20-minute papers,
--                        coding remarked instead of marked
--
-- 1. Every round gets its own exclusive slice of the bank. More than half
--    of each paper (10 of 17 MCQ, 2 of 3 coding) is drawn from questions
--    NO OTHER ROUND CAN SEE, so a Round 2 student briefed by a Round 1
--    friend still meets mostly fresh questions. The rest come from a
--    shared pool — those may repeat across rounds, but the paper order and
--    the option order are randomised per student, so they never arrive
--    arranged the same way.
-- 2. 20 minutes per student inside a 30-minute round window.
-- 3. Coding carries no marks. Proctors leave a written remark instead.
--
-- Safe to re-run. The pool split is deterministic — re-running does not
-- reshuffle which question belongs to which round.
-- =====================================================================

-- ---------------------------------------------------------------- 1. pools
alter table quiz.questions add column if not exists round_pool int;   -- null = shared
alter table quiz.batches   add column if not exists pool_no    int;   -- slice this round draws

do $$ begin
  alter table quiz.questions add constraint questions_round_pool_ck
    check (round_pool is null or round_pool between 1 and 4);
exception when duplicate_object then null; end $$;

update quiz.batches set pool_no = case name
         when 'Round 1' then 1 when 'Round 2' then 2
         when 'Round 3' then 3 when 'Round 4 (Backup)' then 4 end
 where name in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)');

-- Deterministic split, per section and for coding: the first ~30% by id stay
-- shared, the rest are dealt round-robin to rounds 1-4.
with ranked as (
  select id,
         row_number() over (partition by coalesce(section, 'CODING') order by id) as rn,
         ceil(count(*) over (partition by coalesce(section, 'CODING')) * 0.30)    as shared_n
    from quiz.questions
   where active and ext_code is not null and question_set = 'recruitment'
)
update quiz.questions q
   set round_pool = case when r.rn <= r.shared_n then null
                         else ((r.rn - r.shared_n - 1)::int % 4) + 1 end
  from ranked r
 where q.id = r.id;

-- how much of each paper must come from the round's own slice (the rest is shared)
alter table quiz.config add column if not exists sec_a_excl  int not null default 2;
alter table quiz.config add column if not exists sec_b_excl  int not null default 2;
alter table quiz.config add column if not exists sec_c_excl  int not null default 2;
alter table quiz.config add column if not exists tech_excl   int not null default 4;
alter table quiz.config add column if not exists coding_excl int not null default 2;

-- ------------------------------------------------- 2. 20 minutes in a 30 window
update quiz.config
   set duration_minutes = 20,
       sec_a_count = 4, sec_b_count = 3, sec_c_count = 3, tech_count = 7,
       coding_count = 3, mcq_count = 17,
       sec_a_excl = 2, sec_b_excl = 2, sec_c_excl = 2, tech_excl = 4, coding_excl = 2
 where id = 1;

-- null duration on the round = use the 20 minutes from config
update quiz.batches set window_minutes = 30, duration_minutes = null
 where name in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)');

-- ------------------------------------ 3. coding is not marked, only remarked
alter table quiz.answers add column if not exists remark text;

update quiz.questions set marks = 0 where kind = 'coding';

-- Total score is the MCQ score. Coding is read and commented on, never added up.
create or replace function quiz.recompute_scores(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
declare v_mcq numeric;
begin
  select coalesce(sum(q.marks), 0) into v_mcq
    from quiz.answers a join quiz.questions q on q.id = a.question_id
   where a.attempt_id = p_attempt and q.kind = 'mcq' and a.selected_index = q.correct_index;

  update quiz.attempts
     set mcq_score = v_mcq, coding_score = 0, total_score = v_mcq
   where id = p_attempt;
end $$;

-- Written remark on one coding answer. Replaces marking it out of 5.
create or replace function public.admin_remark_coding(p_token uuid, p_roll text,
                                                      p_question_id int, p_remark text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if not exists (select 1 from quiz.questions where id = p_question_id and kind = 'coding') then
    raise exception 'NOT_A_CODING_QUESTION';
  end if;

  insert into quiz.answers (attempt_id, question_id, remark, graded_by)
  values (v_att.id, p_question_id, nullif(btrim(p_remark), ''), v_admin)
  on conflict (attempt_id, question_id)
  do update set remark = nullif(btrim(excluded.remark), ''), graded_by = excluded.graded_by;

  perform quiz.audit(v_admin, 'REMARK_CODING', p_roll,
                     json_build_object('question_id', p_question_id)::jsonb);
  return json_build_object('ok', true);
end $$;

grant execute on function public.admin_remark_coding(uuid, text, int, text) to anon, authenticated;

-- ---------------------------------------------------- the draw itself
-- Picks p_excl questions from this round's own slice, then tops the paper up
-- to p_total from the shared pool. If a slice is short, the shortfall comes
-- from shared; if the whole section is short, from whatever is left. A paper
-- is never short and never contains the same question twice.
create or replace function quiz.pick_questions(p_kind text, p_section text, p_pool int,
                                               p_excl int, p_total int)
returns table (id int) language plpgsql security definer set search_path = quiz, public as $$
declare v_ids int[] := '{}';
begin
  if p_pool is not null and p_excl > 0 then
    select array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and (p_section is null or q.section = p_section)
                    and q.round_pool = p_pool
                  order by random() limit p_excl)
      into v_ids;
  end if;

  select v_ids || array(select q.id from quiz.questions q
                where q.kind = p_kind and q.active
                  and (p_section is null or q.section = p_section)
                  and q.round_pool is null
                  and not (q.id = any (v_ids))
                order by random()
                limit greatest(p_total - coalesce(array_length(v_ids, 1), 0), 0))
    into v_ids;

  if coalesce(array_length(v_ids, 1), 0) < p_total then
    select v_ids || array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and (p_section is null or q.section = p_section)
                    and not (q.id = any (v_ids))
                  order by random()
                  limit p_total - coalesce(array_length(v_ids, 1), 0))
      into v_ids;
  end if;

  return query select unnest(v_ids);
end $$;

create or replace function public.start_attempt(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_roll  text := quiz.student_from_token(p_token);
  v_cfg   quiz.config;
  v_batch quiz.batches;
  v_pool  int;
  v_ids   int[];
  v_minutes int;
begin
  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.exam_open then raise exception 'EXAM_CLOSED'; end if;

  select b.* into v_batch from quiz.batches b
    join quiz.students s on s.batch_id = b.id
   where s.roll_no = v_roll;
  if v_batch.id is null   then raise exception 'NO_BATCH'; end if;
  if not v_batch.is_open  then raise exception 'BATCH_CLOSED'; end if;
  if v_batch.closes_at is not null and now() > v_batch.closes_at then
    raise exception 'ROUND_ENDED';
  end if;

  if (select count(*) from quiz.attempts where status in ('in_progress', 'paused'))
       >= v_cfg.max_concurrent then
    raise exception 'CAPACITY_FULL';
  end if;

  v_minutes := coalesce(v_batch.duration_minutes, v_cfg.duration_minutes);
  v_pool    := v_batch.pool_no;        -- null on a round with no slice: shared only

  if not exists (select 1 from quiz.students
                  where roll_no = v_roll and consented_at is not null) then
    raise exception 'CONSENT_REQUIRED';
  end if;

  if not exists (select 1 from quiz.attempts where roll_no = v_roll) then
    with picked as (
               select * from quiz.pick_questions('mcq', 'A',    v_pool, v_cfg.sec_a_excl, v_cfg.sec_a_count)
      union all select * from quiz.pick_questions('mcq', 'B',    v_pool, v_cfg.sec_b_excl, v_cfg.sec_b_count)
      union all select * from quiz.pick_questions('mcq', 'C',    v_pool, v_cfg.sec_c_excl, v_cfg.sec_c_count)
      union all select * from quiz.pick_questions('mcq', 'TECH', v_pool, v_cfg.tech_excl,  v_cfg.tech_count)
    ),
    code as (select * from quiz.pick_questions('coding', null, v_pool,
                                               v_cfg.coding_excl, v_cfg.coding_count))
    select array(select id from picked order by random())    -- MCQ first, shuffled
        || array(select id from code  order by random())     -- coding always last
      into v_ids;

    if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'NO_QUESTIONS'; end if;

    insert into quiz.attempts (roll_no, question_ids, deadline_at)
    values (v_roll, v_ids,
            least(now() + make_interval(mins => v_minutes),
                  coalesce(v_batch.closes_at, now() + make_interval(mins => v_minutes))))
    on conflict (roll_no) do nothing;
  end if;

  update quiz.sessions set revoked = true
   where kind = 'student' and subject = v_roll and not revoked and token <> p_token;

  return public.get_exam_state(p_token);
end $$;

grant execute on function public.start_attempt(uuid) to anon, authenticated;

-- ---------------------------------------------------- report the split
do $$
declare r record;
begin
  for r in
    select coalesce(section, 'CODING') as sec,
           count(*) filter (where round_pool is null) as shared,
           count(*) filter (where round_pool = 1) as r1,
           count(*) filter (where round_pool = 2) as r2,
           count(*) filter (where round_pool = 3) as r3,
           count(*) filter (where round_pool = 4) as r4
      from quiz.questions where active and ext_code is not null
     group by 1 order by 1
  loop
    raise notice 'Pool split %: shared=% R1=% R2=% R3=% R4=%', r.sec, r.shared, r.r1, r.r2, r.r3, r.r4;
  end loop;
end $$;
