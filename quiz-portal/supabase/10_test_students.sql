-- =====================================================================
-- LEAD Quiz Portal — 10: sample test students (3 per round, 5-digit roll numbers)
--
-- Roll number = username. Run AFTER 09_rounds.sql.
-- Re-running RESETS them completely (attempts, violations, chats, bans cleared),
-- so you can rehearse a round as many times as you like.
--
-- DELETE THEM BEFORE THE REAL EXAM:
--   delete from quiz.students where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- =====================================================================

-- retire every earlier placeholder (they used non-numeric or 10-digit roll numbers)
delete from quiz.students where roll_no like 'TESTB%' or roll_no like 'TEST%' or roll_no = '1025030923';

insert into quiz.students (roll_no, password_hash, full_name, batch_id)
select v.roll, quiz.hash_password(v.pass), v.name, b.id
from (values
  ('41729', 'JAILEAD', 'Tester A - Round 1', 'Round 1'),
  ('60853', 'JAILEAD', 'Tester B - Round 1', 'Round 1'),
  ('27164', 'JAILEAD', 'Tester C - Round 1', 'Round 1'),

  ('39508', 'JAILEAD', 'Tester A - Round 2', 'Round 2'),
  ('72641', 'JAILEAD', 'Tester B - Round 2', 'Round 2'),
  ('18395', 'JAILEAD', 'Tester C - Round 2', 'Round 2'),

  ('84072', 'JAILEAD', 'Tester A - Round 3', 'Round 3'),
  ('53619', 'JAILEAD', 'Tester B - Round 3', 'Round 3'),
  ('26748', 'JAILEAD', 'Tester C - Round 3', 'Round 3'),

  ('91536', 'JAILEAD', 'Tester A - Backup', 'Round 4 (Backup)'),
  ('47280', 'JAILEAD', 'Tester B - Backup', 'Round 4 (Backup)'),
  ('65913', 'JAILEAD', 'Tester C - Backup', 'Round 4 (Backup)')
) as v(roll, pass, name, batch_name)
join quiz.batches b on b.name = v.batch_name
on conflict (roll_no) do update
  set password_hash = excluded.password_hash,
      full_name     = excluded.full_name,
      batch_id      = excluded.batch_id;

-- full reset so every rehearsal starts clean
update quiz.students set banned = false, banned_reason = null, banned_at = null
 where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.attempts   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');   -- cascades answers + violations
delete from quiz.detections where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.messages   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.threads    where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.sessions   where kind = 'student' and subject in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');

select s.roll_no as username, b.name as round, s.full_name
  from quiz.students s join quiz.batches b on b.id = s.batch_id
 where s.roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204')
 order by b.name, s.roll_no;
