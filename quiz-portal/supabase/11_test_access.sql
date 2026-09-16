-- =====================================================================
-- LEAD Quiz Portal — 11: your test access
--
--   Google sign-in : abhyuday.saksena06@gmail.com  -> Round 1
--                    mr.developer4u@gmail.com      -> Round 3
--   Password logins: 30217 -> Round 1, 68459 -> Round 2,
--                    15743 -> Round 3, 82096 -> Round 4 (Backup)
--                    (5-digit so they can never clash with a real roll number)
--   Admin logins   : ADMIN1 … ADMIN5
--   Passwords are NOT set here. Run PASSWORDS.local.sql afterwards.
--
-- Run AFTER SETUP.sql. Safe to re-run (it resets the USER* accounts).
-- =====================================================================

-- 1. the two Gmail addresses allowed to use Google sign-in
insert into quiz.allowlist (email, batch_id, full_name)
values
  ('abhyuday.saksena06@gmail.com', (select id from quiz.batches where name = 'Round 1'), 'Abhyuday Saksena'),
  ('mr.developer4u@gmail.com',     (select id from quiz.batches where name = 'Round 3'), 'Developer Test')
on conflict (email) do update
  set batch_id  = excluded.batch_id,
      full_name = coalesce(excluded.full_name, quiz.allowlist.full_name);

-- 2. four roll-number + password logins
insert into quiz.students (roll_no, password_hash, full_name, batch_id)
select v.roll, quiz.hash_password(gen_random_uuid()::text), v.name, b.id
from (values
  ('30217', 'My Test User - Round 1', 'Round 1'),
  ('68459', 'My Test User - Round 2', 'Round 2'),
  ('15743', 'My Test User - Round 3', 'Round 3'),
  ('82096', 'My Test User - Backup',  'Round 4 (Backup)')
) as v(roll, name, batch_name)
join quiz.batches b on b.name = v.batch_name
on conflict (roll_no) do update
  set full_name     = excluded.full_name,
      batch_id      = excluded.batch_id;

-- clean slate for those four every time this runs
update quiz.students set banned = false, banned_reason = null, banned_at = null
 where roll_no in ('30217','68459','15743','82096');
delete from quiz.attempts   where roll_no in ('30217','68459','15743','82096');
delete from quiz.detections where roll_no in ('30217','68459','15743','82096');
delete from quiz.messages   where roll_no in ('30217','68459','15743','82096');
delete from quiz.threads    where roll_no in ('30217','68459','15743','82096');
delete from quiz.sessions   where kind = 'student' and subject in ('30217','68459','15743','82096');

-- 2b. free the two Gmail addresses so you can redo the Google registration
--     (removes their registration, ID photo and attempt - test accounts only)
delete from quiz.students
 where email in ('abhyuday.saksena06@gmail.com', 'mr.developer4u@gmail.com');

-- 3. five admin logins
insert into quiz.admins (username, password_hash, display_name)
values
  ('ADMIN1', quiz.hash_password(gen_random_uuid()::text), 'Admin 1'),
  ('ADMIN2', quiz.hash_password(gen_random_uuid()::text), 'Admin 2'),
  ('ADMIN3', quiz.hash_password(gen_random_uuid()::text), 'Admin 3'),
  ('ADMIN4', quiz.hash_password(gen_random_uuid()::text), 'Admin 4'),
  ('ADMIN5', quiz.hash_password(gen_random_uuid()::text), 'Admin 5')
on conflict (username) do update
  set display_name  = excluded.display_name;

-- clear any lockout from earlier failed attempts
delete from quiz.login_failures;

-- =====================================================================
-- To test Google REGISTRATION a second time with the same address, wipe the
-- registration first (this frees the email and deletes their ID photo):
--
--   delete from quiz.students
--    where email in ('abhyuday.saksena06@gmail.com', 'mr.developer4u@gmail.com');
-- =====================================================================

select 'GOOGLE  ' || a.email as login, b.name as round,
       case when a.claimed_by is null then 'not registered yet' else 'registered as ' || a.claimed_by end as status
  from quiz.allowlist a join quiz.batches b on b.id = a.batch_id
union all
select 'STUDENT ' || s.roll_no || '', b.name, coalesce(s.full_name, '')
  from quiz.students s join quiz.batches b on b.id = s.batch_id where s.roll_no in ('30217','68459','15743','82096')
union all
select 'ADMIN   ' || username || '', '-', coalesce(display_name, '')
  from quiz.admins where username like 'ADMIN%'
order by 1;
