-- =====================================================================
-- LEAD Quiz Portal — 08: five proctor logins
--   proctor1..proctor5. No password is set here: run PASSWORDS.local.sql.
--
-- Creates one login per proctor station. Student chat queries are shared
-- automatically between whichever of these are signed in and active.
--
-- Safe to re-run: existing passwords are never overwritten.
-- =====================================================================

insert into quiz.admins (username, password_hash, display_name) values
  ('proctor1', quiz.hash_password(gen_random_uuid()::text), 'Proctor 1'),
  ('proctor2', quiz.hash_password(gen_random_uuid()::text), 'Proctor 2'),
  ('proctor3', quiz.hash_password(gen_random_uuid()::text), 'Proctor 3'),
  ('proctor4', quiz.hash_password(gen_random_uuid()::text), 'Proctor 4'),
  ('proctor5', quiz.hash_password(gen_random_uuid()::text), 'Proctor 5')
on conflict (username) do update
  set display_name = excluded.display_name;

-- change one password later:
-- update quiz.admins set password_hash = quiz.hash_password('NEW-PASSWORD') where username = 'proctor3';

-- add a sixth station:
-- insert into quiz.admins (username, password_hash, display_name)
-- values ('proctor6', quiz.hash_password('<choose one>'), 'Proctor 6');

select username, display_name, last_seen_at from quiz.admins order by username;
