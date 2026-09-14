-- =====================================================================
-- LEAD Quiz Portal — 07: UPGRADE for Submissions + coding auto-grading
--
-- Run this if you have ALREADY run ALL_IN_ONE.sql with batches.
-- (Re-running ALL_IN_ONE.sql achieves exactly the same thing — this is
--  just the smaller delta.) Safe to re-run. Your data is preserved.
-- =====================================================================

-- 1. coding test cases (hidden expected output never reaches a student)
create table if not exists quiz.question_tests (
  id              serial primary key,
  question_id     int not null references quiz.questions (id) on delete cascade,
  ord             int not null default 1,
  stdin           text not null default '',
  expected_output text not null,
  is_sample       boolean not null default false,
  points          numeric not null default 1
);
create index if not exists question_tests_q_idx on quiz.question_tests (question_id, ord);
alter table quiz.question_tests enable row level security;

-- 2. grading columns on stored answers
alter table quiz.answers add column if not exists auto_passed int;
alter table quiz.answers add column if not exists auto_total  int;
alter table quiz.answers add column if not exists auto_report jsonb;
alter table quiz.answers add column if not exists graded_by   text;

-- 3. student API — coding questions now carry their SAMPLE tests
create or replace function public.get_exam_state(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_roll text := quiz.student_from_token(p_token);
  v_cfg  quiz.config;
  v_att  quiz.attempts;
  v_student quiz.students;
  v_batch quiz.batches;
  v_questions json := '[]'::json;
  v_answers   json := '{}'::json;
begin
  select * into v_cfg from quiz.config where id = 1;
  select * into v_student from quiz.students where roll_no = v_roll;
  select b.* into v_batch from quiz.batches b where b.id = v_student.batch_id;
  select * into v_att from quiz.attempts where roll_no = v_roll;

  if v_att.id is not null then
    perform quiz.expire_if_needed(v_att.id);
    select * into v_att from quiz.attempts where id = v_att.id;
  end if;

  if v_att.id is not null and v_att.status = 'in_progress' then
    -- questions in this student's order; options shuffled per student; NO correct_index
    select coalesce(json_agg(json_build_object(
             'id', q.id, 'kind', q.kind, 'title', q.title, 'body', q.body, 'marks', q.marks,
             'starter_code', q.starter_code, 'language', q.language,
             -- SAMPLE tests only. Hidden tests' expected output must never reach a student.
             'tests', case when q.kind = 'coding' then (
                 select coalesce(json_agg(json_build_object(
                          'ord', t.ord, 'stdin', t.stdin, 'expected_output', t.expected_output)
                        order by t.ord), '[]'::json)
                   from quiz.question_tests t where t.question_id = q.id and t.is_sample
               ) end,
             'options', case when q.kind = 'mcq' then (
                 select json_agg(json_build_object('i', (o.ord - 1)::int, 't', o.val)
                                 order by md5(v_att.id::text || q.id::text || o.ord::text))
                   from jsonb_array_elements_text(q.options) with ordinality as o(val, ord)
               ) end
           ) order by u.pos), '[]'::json)
      into v_questions
      from unnest(v_att.question_ids) with ordinality as u(qid, pos)
      join quiz.questions q on q.id = u.qid;

    select coalesce(json_object_agg(a.question_id, json_build_object(
             'selected_index', a.selected_index, 'code', a.code,
             'language', a.language, 'revision', a.revision)), '{}'::json)
      into v_answers
      from quiz.answers a where a.attempt_id = v_att.id;
  end if;

  return json_build_object(
    'server_now', now(),
    'config', json_build_object(
       'exam_title', v_cfg.exam_title, 'duration_minutes', v_cfg.duration_minutes,
       'mcq_count', v_cfg.mcq_count, 'coding_count', v_cfg.coding_count,
       'max_flags', v_cfg.max_flags, 'exam_open', v_cfg.exam_open),
    'student', json_build_object('roll_no', v_student.roll_no, 'full_name', v_student.full_name),
    'batch', case when v_batch.id is null then null else json_build_object(
       'id', v_batch.id, 'name', v_batch.name, 'is_open', v_batch.is_open,
       'duration_minutes', coalesce(v_batch.duration_minutes, v_cfg.duration_minutes)) end,
    'can_start', (v_cfg.exam_open and coalesce(v_batch.is_open, false)),
    'attempt', case when v_att.id is null then null else json_build_object(
       'id', v_att.id, 'status', v_att.status, 'started_at', v_att.started_at,
       'deadline_at', v_att.deadline_at, 'submitted_at', v_att.submitted_at,
       'submit_reason', v_att.submit_reason, 'flag_count', v_att.flag_count) end,
    'questions', v_questions,
    'answers', v_answers
  );
end $$;

-- 4. admin API
create or replace function public.admin_student_detail(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts; v_student quiz.students;
begin
  select * into v_student from quiz.students where roll_no = p_roll;
  if v_student.roll_no is null then raise exception 'NO_SUCH_STUDENT'; end if;
  select * into v_att from quiz.attempts where roll_no = p_roll;

  return json_build_object(
    'student', json_build_object('roll_no', v_student.roll_no, 'full_name', v_student.full_name),
    'attempt', row_to_json(v_att),
    'questions', coalesce((
      select json_agg(json_build_object(
        'id', q.id, 'kind', q.kind, 'title', q.title, 'body', q.body, 'marks', q.marks,
        'options', q.options, 'correct_index', q.correct_index,
        'selected_index', a.selected_index, 'code', a.code, 'language', a.language,
        'coding_marks', a.coding_marks, 'updated_at', a.updated_at,
        'auto_passed', a.auto_passed, 'auto_total', a.auto_total, 'auto_report', a.auto_report,
        'graded_by', a.graded_by,
        -- admins get ALL tests (including hidden) so grading can re-run the code
        'tests', case when q.kind = 'coding' then (
            select coalesce(json_agg(json_build_object('id', t.id, 'ord', t.ord, 'stdin', t.stdin,
                     'expected_output', t.expected_output, 'is_sample', t.is_sample, 'points', t.points)
                   order by t.ord), '[]'::json)
              from quiz.question_tests t where t.question_id = q.id) end) order by u.pos)
      from unnest(v_att.question_ids) with ordinality as u(qid, pos)
      join quiz.questions q on q.id = u.qid
      left join quiz.answers a on a.attempt_id = v_att.id and a.question_id = q.id), '[]'::json),
    'flags', coalesce((
      select json_agg(json_build_object('kind', kind, 'detail', detail, 'counted', counted,
                                        'created_at', created_at) order by created_at)
      from quiz.flags where attempt_id = v_att.id), '[]'::json)
  );
end $$;

create or replace function public.admin_save_auto_grade(p_token uuid, p_roll text, p_question_id int,
                                                        p_passed_ids int[], p_report jsonb)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin text := quiz.admin_from_token(p_token);
  v_att quiz.attempts; v_max numeric; v_total numeric; v_got numeric; v_marks numeric; v_n int;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  select marks into v_max from quiz.questions where id = p_question_id and kind = 'coding';
  if v_max is null then raise exception 'NOT_A_CODING_QUESTION'; end if;

  select coalesce(sum(points), 0), count(*) into v_total, v_n
    from quiz.question_tests where question_id = p_question_id;
  select coalesce(sum(points), 0) into v_got
    from quiz.question_tests where question_id = p_question_id and id = any (coalesce(p_passed_ids, '{}'));

  v_marks := case when v_total > 0 then round(v_max * v_got / v_total, 2) else 0 end;

  insert into quiz.answers (attempt_id, question_id, coding_marks, auto_passed, auto_total, auto_report, graded_by)
  values (v_att.id, p_question_id, v_marks, coalesce(array_length(p_passed_ids, 1), 0), v_n, p_report, v_admin)
  on conflict (attempt_id, question_id) do update
    set coding_marks = excluded.coding_marks, auto_passed = excluded.auto_passed,
        auto_total = excluded.auto_total, auto_report = excluded.auto_report,
        graded_by = excluded.graded_by;

  perform quiz.recompute_scores(v_att.id);
  return json_build_object('ok', true, 'marks', v_marks,
                           'passed', coalesce(array_length(p_passed_ids, 1), 0), 'total', v_n);
end $$;

create or replace function public.admin_pending_coding(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
      'roll_no', at.roll_no, 'question_id', q.id, 'title', q.title, 'marks', q.marks,
      'language', a.language, 'code', a.code,
      'tests', (select coalesce(json_agg(json_build_object('id', t.id, 'stdin', t.stdin,
                        'expected_output', t.expected_output) order by t.ord), '[]'::json)
                  from quiz.question_tests t where t.question_id = q.id))
      order by at.roll_no, q.id)
    from quiz.attempts at
    join quiz.answers a on a.attempt_id = at.id
    join quiz.questions q on q.id = a.question_id and q.kind = 'coding'
   where at.status in ('submitted', 'blocked')
     and length(coalesce(a.code, '')) > 0
     and a.graded_by is null
     and exists (select 1 from quiz.question_tests t where t.question_id = q.id)
  ), '[]'::json);
end $$;

create or replace function public.admin_export_answers(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  perform quiz.audit(v_admin, 'EXPORT_ANSWERS', null);
  return coalesce((
    select json_agg(json_build_object(
      'roll_no', s.roll_no, 'full_name', s.full_name,
      'batch', (select b.name from quiz.batches b where b.id = s.batch_id),
      'status', at.status, 'submitted_at', at.submitted_at,
      'question_id', q.id, 'kind', q.kind, 'title', q.title, 'marks', q.marks,
      'chosen', case when q.kind = 'mcq' then q.options ->> a.selected_index end,
      'correct', case when q.kind = 'mcq' then q.options ->> q.correct_index end,
      'is_correct', case when q.kind = 'mcq' then (a.selected_index = q.correct_index) end,
      'code', a.code, 'language', a.language,
      'tests_passed', a.auto_passed, 'tests_total', a.auto_total,
      'awarded', case when q.kind = 'mcq' then (case when a.selected_index = q.correct_index then q.marks else 0 end)
                      else a.coding_marks end,
      'graded_by', a.graded_by)
      order by s.roll_no, q.id)
    from quiz.students s
    join quiz.attempts at on at.roll_no = s.roll_no
    join quiz.answers a on a.attempt_id = at.id
    join quiz.questions q on q.id = a.question_id
  ), '[]'::json);
end $$;

drop function if exists public.admin_update_config(uuid, boolean, int, text);
create or replace function public.admin_update_config(p_token uuid, p_exam_open boolean,
                                                      p_duration_minutes int, p_exam_title text,
                                                      p_mcq_count int default null,
                                                      p_coding_count int default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  update quiz.config set
    exam_open        = coalesce(p_exam_open, exam_open),
    duration_minutes = coalesce(p_duration_minutes, duration_minutes),
    exam_title       = coalesce(nullif(trim(p_exam_title), ''), exam_title),
    mcq_count        = coalesce(p_mcq_count, mcq_count),
    coding_count     = greatest(coalesce(p_coding_count, coding_count), 0)  -- 0 = MCQ-only exam
  where id = 1;
  perform quiz.audit(v_admin, 'UPDATE_CONFIG', null, json_build_object(
    'exam_open', p_exam_open, 'duration_minutes', p_duration_minutes)::jsonb);
  return (select row_to_json(c) from quiz.config c where id = 1);
end $$;

-- 5. let the browser call the new functions
do $$
declare f text;
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    for f in
      select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in
         ('admin_save_auto_grade','admin_pending_coding','admin_export_answers','admin_update_config')
    loop
      execute format('grant execute on function %s to anon, authenticated', f);
    end loop;
  end if;
end $$;

-- 6. sample/hidden tests for the placeholder coding questions ("print sum 1..N")
insert into quiz.question_tests (question_id, ord, stdin, expected_output, is_sample, points)
select q.id, v.ord, v.stdin, v.expected, v.sample, 1
  from quiz.questions q
 cross join (values (1, '5', '15', true), (2, '10', '55', false), (3, '1', '1', false)) as v(ord, stdin, expected, sample)
 where q.kind = 'coding'
   and not exists (select 1 from quiz.question_tests t where t.question_id = q.id);

select 'upgrade complete' as status,
       (select count(*) from quiz.question_tests) as test_cases;
