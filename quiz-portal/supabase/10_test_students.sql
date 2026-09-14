-- =====================================================================
-- LEAD Quiz Portal — 10: sample test students (3 per round)
--
-- Roll number = username. Run AFTER 09_rounds.sql.
-- Re-running RESETS them completely (attempts, violations, chats, bans cleared),
-- so you can rehearse a round as many times as you like.
--
-- DELETE THEM BEFORE THE REAL EXAM:
--   delete from quiz.students where roll_no like 'TEST%';
-- =====================================================================

-- clear out the older test accounts from 06 (superseded by this file)
delete from quiz.students where roll_no like 'TESTB%';

insert into quiz.students (roll_no, password_hash, full_name, batch_id)
select v.roll, quiz.hash_password(v.pass), v.name, b.id
from (values
  ('TEST101', 'LEAD@101', 'Tester A - Round 1', 'Round 1'),
  ('TEST102', 'LEAD@102', 'Tester B - Round 1', 'Round 1'),
  ('TEST103', 'LEAD@103', 'Tester C - Round 1', 'Round 1'),

  ('TEST201', 'LEAD@201', 'Tester A - Round 2', 'Round 2'),
  ('TEST202', 'LEAD@202', 'Tester B - Round 2', 'Round 2'),
  ('TEST203', 'LEAD@203', 'Tester C - Round 2', 'Round 2'),

  ('TEST301', 'LEAD@301', 'Tester A - Round 3', 'Round 3'),
  ('TEST302', 'LEAD@302', 'Tester B - Round 3', 'Round 3'),
  ('TEST303', 'LEAD@303', 'Tester C - Round 3', 'Round 3'),

  ('TEST401', 'LEAD@401', 'Tester A - Backup', 'Round 4 (Backup)'),
  ('TEST402', 'LEAD@402', 'Tester B - Backup', 'Round 4 (Backup)'),
  ('TEST403', 'LEAD@403', 'Tester C - Backup', 'Round 4 (Backup)')
) as v(roll, pass, name, batch_name)
join quiz.batches b on b.name = v.batch_name
on conflict (roll_no) do update
  set password_hash = excluded.password_hash,
      full_name     = excluded.full_name,
      batch_id      = excluded.batch_id;

-- full reset so every rehearsal starts clean
update quiz.students set banned = false, banned_reason = null, banned_at = null
 where roll_no like 'TEST%';
delete from quiz.attempts   where roll_no like 'TEST%';   -- cascades answers + violations
delete from quiz.detections where roll_no like 'TEST%';
delete from quiz.messages   where roll_no like 'TEST%';
delete from quiz.threads    where roll_no like 'TEST%';
delete from quiz.sessions   where kind = 'student' and subject like 'TEST%';

select s.roll_no as username, b.name as round, s.full_name
  from quiz.students s join quiz.batches b on b.id = s.batch_id
 where s.roll_no like 'TEST%'
 order by s.roll_no;
