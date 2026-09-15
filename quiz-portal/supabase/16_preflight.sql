-- =====================================================================
-- LEAD Quiz Portal — 16: pre-flight check
--   Changes nothing. Run it any time — especially on exam morning — and
--   read the STATUS column. Everything should say OK.
-- =====================================================================
with c as (select * from quiz.config where id = 1),
q as (
  select count(*) filter (where kind='mcq'    and active and section='A')    as a,
         count(*) filter (where kind='mcq'    and active and section='B')    as b,
         count(*) filter (where kind='mcq'    and active and section='C')    as c,
         count(*) filter (where kind='mcq'    and active and section='TECH') as t,
         count(*) filter (where kind='coding' and active)                    as x,
         count(*) filter (where active and ext_code is null)                 as placeholders,
         count(*) filter (where kind='mcq' and active and correct_index is null) as keyless,
         count(*) filter (where kind='coding' and active
                            and body not like '%any programming language%')  as nolang
    from quiz.questions
),
r as (
  select count(*) as total,
         count(*) filter (where b.name = 'Round 1') as r1,
         count(*) filter (where b.name = 'Round 2') as r2,
         count(*) filter (where b.name = 'Round 3') as r3,
         count(*) filter (where a.email !~ '^[^@]+@(thapar\.edu|gmail\.com)$') as bad_email
    from quiz.allowlist a left join quiz.batches b on b.id = a.batch_id
),
s as (
  select count(*) filter (where roll_no ~ '^\d{5}$')            as demo_students,
         count(*) filter (where roll_no !~ '^\d{5}$')           as real_students
    from quiz.students
),
t as (
  select count(*) filter (where status in ('in_progress','paused')) as live,
         count(*)                                                   as total
    from quiz.attempts
)
select * from (
  select 1 as ord, 'question bank — Section A' as check,
         case when q.a >= (select sec_a_count from c) then 'OK' else 'PROBLEM' end as status,
         q.a || ' questions, need ' || (select sec_a_count from c) as detail from q
  union all select 2, 'question bank — Section B',
         case when q.b >= (select sec_b_count from c) then 'OK' else 'PROBLEM' end,
         q.b || ' questions, need ' || (select sec_b_count from c) from q
  union all select 3, 'question bank — Section C',
         case when q.c >= (select sec_c_count from c) then 'OK' else 'PROBLEM' end,
         q.c || ' questions, need ' || (select sec_c_count from c) from q
  union all select 4, 'question bank — Technical',
         case when q.t >= (select tech_count from c) then 'OK' else 'PROBLEM' end,
         q.t || ' questions, need ' || (select tech_count from c) from q
  union all select 5, 'question bank — Coding',
         case when q.x >= (select coding_count from c) then 'OK' else 'PROBLEM' end,
         q.x || ' questions, need ' || (select coding_count from c) from q
  union all select 6, 'placeholder questions gone',
         case when q.placeholders = 0 then 'OK' else 'PROBLEM' end,
         q.placeholders || ' placeholders still active' from q
  union all select 7, 'every MCQ has an answer key',
         case when q.keyless = 0 then 'OK' else 'PROBLEM' end,
         q.keyless || ' without a key' from q
  union all select 8, 'coding says any language allowed',
         case when q.nolang = 0 then 'OK' else 'PROBLEM' end,
         q.nolang || ' missing the note' from q
  union all select 9, 'paper template',
         case when (select sec_a_count+sec_b_count+sec_c_count+tech_count from c) = 17
               and (select coding_count from c) = 3 then 'OK' else 'CHECK' end,
         (select sec_a_count||' A + '||sec_b_count||' B + '||sec_c_count||' C + '||
                 tech_count||' technical + '||coding_count||' coding' from c)
  union all select 10, 'students allowlisted',
         case when r.total >= 165 then 'OK' else 'CHECK' end,
         r.r1 || ' in Round 1, ' || r.r2 || ' in Round 2, ' || r.r3 || ' in Round 3, '
             || r.total || ' total' from r
  union all select 11, 'all addresses are thapar.edu or gmail.com',
         case when r.bad_email = 0 then 'OK' else 'PROBLEM' end,
         r.bad_email || ' look wrong' from r
  union all select 12, 'demo / test accounts kept',
         case when s.demo_students >= 12 then 'OK' else 'CHECK' end,
         s.demo_students || ' five-digit test students' from s
  union all select 13, 'admin + proctor logins',
         case when (select count(*) from quiz.admins) >= 6 then 'OK' else 'CHECK' end,
         (select count(*)::text from quiz.admins) || ' logins'
  union all select 14, 'rounds created',
         case when (select count(*) from quiz.batches) = 4 then 'OK' else 'PROBLEM' end,
         (select string_agg(name || case when is_open then ' (OPEN)' else '' end, ', ' order by name)
            from quiz.batches)
  union all select 15, 'exam is open for business',
         case when (select exam_open from c) then 'OK' else 'PROBLEM' end,
         'minutes per student: ' || (select duration_minutes::text from c) ||
         ', round window: ' || (select coalesce(max(window_minutes)::text,'—') from quiz.batches)
  union all select 16, 'camera monitoring',
         case when (select require_camera from c) then 'OK' else 'CHECK' end,
         'mic required: ' || (select require_mic::text from c)
  union all select 17, 'live attempts right now',
         case when t.live = 0 then 'OK' else 'CHECK' end,
         t.live || ' in progress, ' || t.total || ' attempts on record (reset these before the real run)'
         from t
  union all select 18, 'auto-submit timer (pg_cron)',
         case when to_regclass('cron.job') is null then 'PROBLEM' else 'OK' end,
         case when to_regclass('cron.job') is null
              then 'pg_cron not enabled — enable it in Database > Extensions, then re-run SETUP.sql'
              else 'scheduled' end
) x order by ord;
