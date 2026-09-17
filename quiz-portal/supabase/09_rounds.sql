-- =====================================================================
-- LEAD Quiz Portal — 09: the four rounds
--
--   Round 1, Round 2, Round 3   — ~60 students each
--   Round 4 (Backup)            — spare slot for anyone who missed their round,
--                                 had a technical problem, or needs a re-sit
--
-- All four start CLOSED with a 30-minute window; each student gets their own
-- 15 minutes inside it. You open one at a time from Admin -> Rounds.
--
-- Leaves EXACTLY these four batches. Anyone sitting in an old batch is moved to
-- Round 4 first, so nobody is stranded. Safe to re-run.
-- =====================================================================

-- 1. the four rounds
insert into quiz.batches (name, is_open, window_minutes) values
  ('Round 1',          false, 30),
  ('Round 2',          false, 30),
  ('Round 3',          false, 30),
  ('Round 4 (Backup)', false, 30)
on conflict (name) do nothing;

update quiz.batches set window_minutes = 30
 where name in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)');

-- 2. move anyone left in an older batch into the backup round
update quiz.students s
   set batch_id = (select id from quiz.batches where name = 'Round 4 (Backup)')
 where s.batch_id is not null
   and s.batch_id not in (select id from quiz.batches
                           where name in ('Round 1','Round 2','Round 3','Round 4 (Backup)','Public Quiz'));

update quiz.allowlist a
   set batch_id = (select id from quiz.batches where name = 'Round 4 (Backup)')
 where a.batch_id is not null
   and a.batch_id not in (select id from quiz.batches
                           where name in ('Round 1','Round 2','Round 3','Round 4 (Backup)','Public Quiz'));

-- 3. remove every other batch (now guaranteed empty)
delete from quiz.batches
 where name not in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)', 'Public Quiz');

-- 4. confirm: this must show exactly four rows
select b.name, b.is_open, b.window_minutes,
       (select count(*) from quiz.allowlist a where a.batch_id = b.id) as emails_authorised,
       (select count(*) from quiz.students  s where s.batch_id = b.id) as registered
  from quiz.batches b
 order by b.name;
