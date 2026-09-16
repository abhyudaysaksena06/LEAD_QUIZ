-- =====================================================================
-- LEAD Quiz Portal — PASSWORDS TEMPLATE
--
-- Copy to PASSWORDS.local.sql (gitignored), fill in real passwords, run it.
-- Run it in the Supabase SQL Editor AFTER SETUP.sql and 11_test_access.sql.
-- Re-running it is safe. To change a password, edit it here and run again.
-- =====================================================================

-- ---------- staff logins ----------
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'admin';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'proctor1';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'proctor2';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'proctor3';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'proctor4';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'proctor5';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'ADMIN1';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'ADMIN2';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'ADMIN3';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'ADMIN4';
update quiz.admins set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where username = 'ADMIN5';

-- ---------- demo / test student logins ----------
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '58204';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '41729';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '60853';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '27164';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '39508';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '72641';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '18395';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '84072';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '53619';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '26748';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '91536';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '47280';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '65913';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '30217';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '68459';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '15743';
update quiz.students set password_hash = quiz.hash_password('CHOOSE_A_PASSWORD') where roll_no = '82096';

-- sign everyone out, so any session opened with an old password ends
update quiz.sessions set revoked = true where not revoked;
delete from quiz.login_failures;

select 'passwords set' as step, count(*) as staff_logins from quiz.admins;
