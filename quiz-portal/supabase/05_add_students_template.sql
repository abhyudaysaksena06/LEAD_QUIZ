-- =====================================================================
-- LEAD Quiz Portal — 05: add / update students (template)
-- Username = roll number. Re-running with the same roll number UPDATES the password.
-- Replace the rows below and run in the Supabase SQL Editor.
-- (Or use Admin portal → Students → "Bulk add".)
-- =====================================================================

insert into quiz.students (roll_no, password_hash, full_name)
select roll_no, quiz.hash_password(password), full_name
from (values
  -- ('roll_no',     'password', 'Full Name')
  ('ROLL_NO', 'CHOOSE_A_PASSWORD', 'Full Name')
  -- ,('ROLL_NO_2', 'CHOOSE_A_PASSWORD', 'Another Student')
) as t(roll_no, password, full_name)
on conflict (roll_no) do update
  set password_hash = excluded.password_hash,
      full_name     = coalesce(excluded.full_name, quiz.students.full_name);

-- Check:
-- select roll_no, full_name, created_at from quiz.students order by roll_no;

-- Change the admin password:
-- update quiz.admins set password_hash = quiz.hash_password('NEW-STRONG-PASSWORD') where username = 'admin';
