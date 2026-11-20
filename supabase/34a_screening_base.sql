-- =====================================================================
-- PRIMUS 2026 screening round — STANDALONE INSTALL (base)
--
-- For a database that does NOT have the LEAD quiz (e.g. the PRIMUS event
-- project). Creates only what the screening round needs: the private quiz
-- schema, admin logins + sessions, sign-in throttling and the audit log.
-- Run this, then 34_screening_round.sql (SCREENING_STANDALONE.sql = both).
--
-- Every definition here is identical to the full quiz setup (01, 03, 28),
-- so running it on the full quiz database changes nothing. Safe to re-run.
-- Admin accounts are created by you afterwards — see the end of this file.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
create schema if not exists quiz;

create table if not exists quiz.admins (
  username      text primary key,
  password_hash text not null,
  display_name  text,
  created_at    timestamptz not null default now()
);
alter table quiz.admins add column if not exists last_seen_at timestamptz;

create table if not exists quiz.sessions (
  token      uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('student', 'admin')),
  subject    text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked    boolean not null default false
);
create index if not exists sessions_subject_idx on quiz.sessions (kind, subject);
alter table quiz.sessions add column if not exists device text;

create table if not exists quiz.login_failures (
  id        bigserial primary key,
  subject   text not null,
  failed_at timestamptz not null default now()
);
create index if not exists login_failures_idx on quiz.login_failures (subject, failed_at);

create table if not exists quiz.audit_log (
  id         bigserial primary key,
  actor      text not null,
  action     text not null,
  target     text,
  detail     jsonb,
  created_at timestamptz not null default now()
);

alter table quiz.admins         enable row level security;
alter table quiz.sessions       enable row level security;
alter table quiz.login_failures enable row level security;
alter table quiz.audit_log      enable row level security;

create or replace function quiz.admin_from_token(p_token uuid)
returns text language plpgsql security definer set search_path = quiz, public as $$
declare v text;
begin
  select subject into v from quiz.sessions
   where token = p_token and kind = 'admin' and not revoked and expires_at > now();
  if v is null then raise exception 'ADMIN_SESSION_INVALID'; end if;
  -- presence heartbeat: every admin call marks them active
  update quiz.admins set last_seen_at = now() where username = v;
  return v;
end $$;

create or replace function quiz.hash_password(p_plain text)
returns text language sql security definer set search_path = quiz, extensions, public as $$
  select extensions.crypt(p_plain, extensions.gen_salt('bf', 8));
$$;

create or replace function quiz.check_password(p_plain text, p_hash text)
returns boolean language sql security definer set search_path = quiz, extensions, public as $$
  select p_hash = extensions.crypt(p_plain, p_hash);
$$;

create or replace function quiz.audit(p_actor text, p_action text, p_target text, p_detail jsonb default null)
returns void language sql security definer set search_path = quiz, public as $$
  insert into quiz.audit_log (actor, action, target, detail) values (p_actor, p_action, p_target, p_detail);
$$;

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

create or replace function public.admin_logout(p_token uuid)
returns void language sql security definer set search_path = quiz, public as $$
  update quiz.sessions set revoked = true where token = p_token and kind = 'admin';
$$;

-- ---------- permissions: the browser reaches nothing in schema quiz directly ----------
revoke all on all tables    in schema quiz from public;
revoke all on all sequences in schema quiz from public;
revoke execute on all functions in schema quiz from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema quiz from anon, authenticated';
  end if;
end $$;
grant execute on function public.admin_login(text, text) to anon, authenticated;
grant execute on function public.admin_logout(uuid)      to anon, authenticated;

-- ---------- admin accounts (run separately; never commit real passwords) ----------
-- insert into quiz.admins (username, password_hash, display_name)
-- values ('admin', quiz.hash_password('CHOOSE_A_PASSWORD'), 'PRIMUS admin')
-- on conflict (username) do update set password_hash = excluded.password_hash;
