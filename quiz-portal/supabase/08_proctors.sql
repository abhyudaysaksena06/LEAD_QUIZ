-- =====================================================================
-- LEAD Quiz Portal — 08: five proctor logins
--
-- Creates one login per proctor station. Student chat queries are shared
-- automatically between whichever of these are signed in and active.
--
-- CHANGE THESE PASSWORDS before exam day. Safe to re-run (it resets them).
-- =====================================================================

insert into quiz.admins (username, password_hash, display_name) values
  ('proctor1', quiz.hash_password('LEAD-P1-2026'), 'Proctor 1'),
  ('proctor2', quiz.hash_password('LEAD-P2-2026'), 'Proctor 2'),
  ('proctor3', quiz.hash_password('LEAD-P3-2026'), 'Proctor 3'),
  ('proctor4', quiz.hash_password('LEAD-P4-2026'), 'Proctor 4'),
  ('proctor5', quiz.hash_password('LEAD-P5-2026'), 'Proctor 5')
on conflict (username) do update
  set password_hash = excluded.password_hash,
      display_name  = excluded.display_name;

-- change one password later:
-- update quiz.admins set password_hash = quiz.hash_password('NEW-PASSWORD') where username = 'proctor3';

-- add a sixth station:
-- insert into quiz.admins (username, password_hash, display_name)
-- values ('proctor6', quiz.hash_password('...'), 'Proctor 6');

select username, display_name, last_seen_at from quiz.admins order by username;
