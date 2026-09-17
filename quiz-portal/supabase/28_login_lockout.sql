-- =====================================================================
-- LEAD Quiz Portal — 28: sign-in lockouts can't be used against real users
--
-- Before: 8 wrong passwords for a username locked that username for 10
-- minutes, whoever typed them. Anyone who knew "ADMIN1" could keep the real
-- ADMIN1 out of the portal for the whole exam with a small script.
--
-- Now failures are counted per username AND per network address, so a
-- stranger only locks themselves out. A separate cap of 60 failures per admin
-- username (from all addresses together) still bounds a distributed attack.
--
-- Stuck anyway? Run:  delete from quiz.login_failures;
-- Safe to re-run. No data changes.
-- =====================================================================

-- The caller's address as seen by Supabase's API gateway (null when unknown,
-- in which case behaviour is exactly as before).
create or replace function quiz.client_ip()
returns text language plpgsql stable security definer set search_path = quiz, public as $$
declare h jsonb; ip text;
begin
  begin
    h := nullif(current_setting('request.headers', true), '')::jsonb;
  exception when others then h := null;
  end;
  if h is null then return null; end if;
  ip := coalesce(h ->> 'cf-connecting-ip',
                 trim(split_part(h ->> 'x-forwarded-for', ',', 1)),
                 h ->> 'x-real-ip');
  return nullif(left(trim(coalesce(ip, '')), 64), '');
end $$;

create or replace function public.admin_login(p_username text, p_password text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare a quiz.admins; v_token uuid;
        v_key text := 'admin:' || trim(p_username) || '@' || coalesce(quiz.client_ip(), '?');
begin
  -- returns instead of raising, so the recorded failure survives (see student_login)
  -- 8 wrong guesses per username FROM ONE PLACE, and 60 per username from
  -- everywhere, in 10 minutes. A stranger guessing can no longer lock the real
  -- admin out, and a spread-out attack is still capped.
  if (select count(*) from quiz.login_failures
       where subject = v_key and failed_at > now() - interval '10 minutes') >= 8
     or (select count(*) from quiz.login_failures
          where subject like 'admin:' || trim(p_username) || '@%'
            and failed_at > now() - interval '10 minutes') >= 60 then
    return json_build_object('ok', false, 'code', 'TOO_MANY_ATTEMPTS');
  end if;

  select * into a from quiz.admins where username = trim(p_username);
  if a.username is null or not quiz.check_password(p_password, a.password_hash) then
    insert into quiz.login_failures (subject) values (v_key);
    return json_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;
  delete from quiz.login_failures where subject = v_key;
  insert into quiz.sessions (kind, subject, expires_at)
  values ('admin', a.username, now() + interval '12 hours') returning token into v_token;
  perform quiz.audit(a.username, 'ADMIN_LOGIN', null);
  return json_build_object('ok', true, 'token', v_token, 'username', a.username,
                           'display_name', a.display_name);
end $$;

create or replace function public.student_login(p_roll text, p_password text,
                                                p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare s quiz.students; v_token uuid;
        v_key text := 'student:' || trim(p_roll) || '@' || coalesce(quiz.client_ip(), '?');
begin
  -- NOTE: these paths RETURN a failure instead of raising. A raise would roll back the
  -- failure we just recorded, which would silently disable the throttle.
  if (select count(*) from quiz.login_failures
       where subject = v_key
         and failed_at > now() - interval '10 minutes') >= 8 then
    return json_build_object('ok', false, 'code', 'TOO_MANY_ATTEMPTS');
  end if;

  select * into s from quiz.students where roll_no = trim(p_roll);
  if s.roll_no is null or not quiz.check_password(p_password, s.password_hash) then
    insert into quiz.login_failures (subject) values (v_key);
    return json_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;
  if s.banned then return json_build_object('ok', false, 'code', 'BANNED'); end if;
  delete from quiz.login_failures where subject = v_key;

  -- Before the test starts they may sign in and out as often as they like, on as many
  -- devices as they like. Once their attempt is live it is one device only, so a new
  -- login signs the other one out.
  if exists (select 1 from quiz.attempts
              where roll_no = s.roll_no and status in ('in_progress', 'paused')) then
    update quiz.sessions set revoked = true
     where kind = 'student' and subject = s.roll_no and not revoked;
  end if;

  -- 12h: students sign in hours before the test, so the session must outlive the wait
  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', s.roll_no, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('ok', true, 'token', v_token, 'roll_no', s.roll_no,
                           'full_name', s.full_name);
end $$;

grant execute on function public.admin_login(text, text) to anon, authenticated;
