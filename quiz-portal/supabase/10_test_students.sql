-- =====================================================================
-- LEAD Quiz Portal — 10: sample test students (3 per round, 5-digit roll numbers)
--
-- Roll number = username. Passwords are set by PASSWORDS.local.sql, never here.
-- Re-running does NOT reset them (see the commented block below).
--
-- DELETE THEM BEFORE THE REAL EXAM:
--   delete from quiz.students where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- =====================================================================

-- retire every earlier placeholder (they used non-numeric or 10-digit roll numbers)
delete from quiz.students where roll_no like 'TESTB%' or roll_no like 'TEST%' or roll_no = '1025030923';

insert into quiz.students (roll_no, password_hash, full_name, batch_id)
select v.roll, quiz.hash_password(gen_random_uuid()::text), v.name, b.id
from (values
  ('41729', 'Tester A - Round 1', 'Round 1'),
  ('60853', 'Tester B - Round 1', 'Round 1'),
  ('27164', 'Tester C - Round 1', 'Round 1'),

  ('39508', 'Tester A - Round 2', 'Round 2'),
  ('72641', 'Tester B - Round 2', 'Round 2'),
  ('18395', 'Tester C - Round 2', 'Round 2'),

  ('84072', 'Tester A - Round 3', 'Round 3'),
  ('53619', 'Tester B - Round 3', 'Round 3'),
  ('26748', 'Tester C - Round 3', 'Round 3'),

  ('91536', 'Tester A - Backup', 'Round 4 (Backup)'),
  ('47280', 'Tester B - Backup', 'Round 4 (Backup)'),
  ('65913', 'Tester C - Backup', 'Round 4 (Backup)')
) as v(roll, name, batch_name)
join quiz.batches b on b.name = v.batch_name
on conflict (roll_no) do update
  set full_name     = excluded.full_name,
      batch_id      = excluded.batch_id;

-- RESET IS OFF so re-running SETUP.sql during a live exam changes nothing.
-- Uncomment to wipe the demo accounts for a fresh rehearsal:
-- -- full reset so every rehearsal starts clean
-- update quiz.students set banned = false, banned_reason = null, banned_at = null
--  where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.attempts   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');   -- cascades answers + violations
-- delete from quiz.detections where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.messages   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.threads    where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.sessions   where kind = 'student' and subject in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');


select s.roll_no as username, b.name as round, s.full_name
  from quiz.students s join quiz.batches b on b.id = s.batch_id
 where s.roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204')
 order by b.name, s.roll_no;
