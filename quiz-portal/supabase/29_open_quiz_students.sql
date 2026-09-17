-- =====================================================================
-- LEAD Quiz Portal — 29: open quiz student register (separate table)
--
-- quiz.open_quiz_students keeps one row per Google account that has tried
-- the open quiz, whether or not they finished registering:
--   email, Google name, name they entered, roll number, PHONE NUMBER,
--   status, first/last sign-in, number of sign-ins, when they registered.
--
-- status is one of
--   signed_in            signed in with Google, has not finished registering
--   registered           completed name + roll number + phone
--   not_eligible         tried with an address the open quiz does not accept
--   recruitment_student  is on the recruitment list and was sent there
--
-- Registration now requires a phone number. The recruitment quiz and every
-- existing record are unchanged. Safe to re-run.
-- =====================================================================

create table if not exists quiz.open_quiz_students (
  email               text primary key,              -- stored lowercased
  google_name         text,
  full_name           text,
  roll_no             text references quiz.students (roll_no) on delete set null,
  phone               text,
  status              text not null default 'signed_in'
                      check (status in ('signed_in', 'registered', 'not_eligible', 'recruitment_student')),
  first_signed_in_at  timestamptz not null default now(),
  last_signed_in_at   timestamptz not null default now(),
  sign_in_count       int not null default 1,
  registered_at       timestamptz
);
create index if not exists open_quiz_students_status_idx on quiz.open_quiz_students (status);
revoke all on quiz.open_quiz_students from public;

-- anyone who registered for the open quiz before this table existed
insert into quiz.open_quiz_students (email, full_name, roll_no, status, first_signed_in_at,
                                     last_signed_in_at, registered_at)
select lower(s.email), s.full_name, s.roll_no, 'registered', s.created_at, s.created_at, s.created_at
  from quiz.students s join quiz.batches b on b.id = s.batch_id
 where b.name = 'Open Quiz' and s.email is not null
on conflict (email) do nothing;

-- record a sign-in; a registered row never slides back to an earlier status
create or replace function quiz.track_open_signin(p_email text, p_google_name text, p_status text)
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  insert into quiz.open_quiz_students (email, google_name, status)
  values (p_email, p_google_name, p_status)
  on conflict (email) do update
     set last_signed_in_at = now(),
         sign_in_count     = quiz.open_quiz_students.sign_in_count + 1,
         google_name       = coalesce(excluded.google_name, quiz.open_quiz_students.google_name),
         status            = case when quiz.open_quiz_students.status = 'registered'
                                  then 'registered' else excluded.status end;
end $$;

-- Indian mobile number -> 10 digits, or null if it is not one
create or replace function quiz.normalize_phone(p text)
returns text language sql immutable as $$
  select case when d ~ '^[6-9][0-9]{9}$' then d end
    from (select regexp_replace(regexp_replace(coalesce(p, ''), '[^0-9]', '', 'g'),
                                '^(91|0)(?=[6-9][0-9]{9}$)', '') as d) x;
$$;

-- ---------- sign-in from the open quiz page ----------
create or replace function public.public_quiz_login_google(p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_claims jsonb; v_email text; v_name text; s quiz.students; v_token uuid; v_cfg quiz.config;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null;
  end;
  v_email := lower(trim(coalesce(v_claims ->> 'email', '')));
  if v_email = '' then raise exception 'NOT_SIGNED_IN'; end if;
  if coalesce(v_claims -> 'user_metadata' ->> 'email_verified',
              v_claims ->> 'email_verified', 'true') = 'false' then
    raise exception 'EMAIL_NOT_VERIFIED';
  end if;
  v_name := nullif(trim(coalesce(v_claims ->> 'name', '')), '');

  select * into s from quiz.students where lower(email) = v_email;
  if s.roll_no is not null and s.banned then raise exception 'BANNED'; end if;

  if s.roll_no is not null then
    if exists (select 1 from quiz.open_quiz_students where email = v_email) then
      perform quiz.track_open_signin(v_email, v_name, 'registered');
    end if;
    if exists (select 1 from quiz.attempts
                where roll_no = s.roll_no and status in ('in_progress', 'paused')) then
      update quiz.sessions set revoked = true
       where kind = 'student' and subject = s.roll_no and not revoked;
    end if;
    insert into quiz.sessions (kind, subject, expires_at, device)
    values ('student', s.roll_no, now() + interval '12 hours', p_device)
    returning token into v_token;
    return json_build_object('token', v_token, 'roll_no', s.roll_no,
                             'full_name', s.full_name, 'email', s.email,
                             'needs_registration', false);
  end if;

  -- Refusals return (rather than raise) so the attempt is still recorded.
  if exists (select 1 from quiz.allowlist where email = v_email) then
    perform quiz.track_open_signin(v_email, v_name, 'recruitment_student');
    return json_build_object('ok', false, 'code', 'USE_MAIN_PAGE');
  end if;

  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.public_quiz_enabled then
    return json_build_object('ok', false, 'code', 'PUBLIC_QUIZ_CLOSED');
  end if;
  if not quiz.public_email_ok(v_email) then
    perform quiz.track_open_signin(v_email, v_name, 'not_eligible');
    return json_build_object('ok', false, 'code', 'PUBLIC_EMAIL_NOT_ELIGIBLE');
  end if;

  perform quiz.track_open_signin(v_email, v_name, 'signed_in');
  return json_build_object('needs_registration', true, 'email', v_email,
                           'full_name', v_name, 'roll_hint', null, 'public', true);
end $$;

-- ---------- one-time registration: name, roll number, phone ----------
drop function if exists public.public_quiz_register(text, text, text);
create or replace function public.public_quiz_register(p_roll text, p_full_name text,
                                                       p_device text default null,
                                                       p_phone text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_claims jsonb; v_email text; v_roll text; v_token uuid; v_batch int;
        v_cfg quiz.config; v_phone text;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null;
  end;
  v_email := lower(trim(coalesce(v_claims ->> 'email', '')));
  if v_email = '' then raise exception 'NOT_SIGNED_IN'; end if;
  if coalesce(v_claims -> 'user_metadata' ->> 'email_verified',
              v_claims ->> 'email_verified', 'true') = 'false' then
    raise exception 'EMAIL_NOT_VERIFIED';
  end if;

  if exists (select 1 from quiz.students where lower(email) = v_email) then
    raise exception 'ALREADY_REGISTERED';
  end if;
  if exists (select 1 from quiz.allowlist where email = v_email) then
    raise exception 'USE_MAIN_PAGE';
  end if;
  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.public_quiz_enabled then raise exception 'PUBLIC_QUIZ_CLOSED'; end if;
  if not quiz.public_email_ok(v_email) then raise exception 'PUBLIC_EMAIL_NOT_ELIGIBLE'; end if;

  v_roll := upper(trim(coalesce(p_roll, '')));
  if length(v_roll) < 3 then raise exception 'ROLL_TOO_SHORT'; end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then raise exception 'NAME_REQUIRED'; end if;
  v_phone := quiz.normalize_phone(p_phone);
  if v_phone is null then raise exception 'PHONE_REQUIRED'; end if;

  select id into v_batch from quiz.batches where name = 'Open Quiz';
  if v_batch is null then raise exception 'PUBLIC_QUIZ_CLOSED'; end if;

  begin
    insert into quiz.students (roll_no, password_hash, full_name, email, batch_id)
    values (v_roll, quiz.hash_password(gen_random_uuid()::text), trim(p_full_name), v_email, v_batch);
  exception when unique_violation then
    if exists (select 1 from quiz.students where roll_no = v_roll) then
      raise exception 'ROLL_ALREADY_USED: %', v_roll;
    end if;
    raise exception 'ALREADY_REGISTERED';
  end;

  insert into quiz.allowlist (email, batch_id, full_name, claimed_by)
  values (v_email, v_batch, trim(p_full_name), v_roll)
  on conflict (email) do nothing;

  insert into quiz.open_quiz_students (email, google_name, full_name, roll_no, phone, status, registered_at)
  values (v_email, nullif(trim(coalesce(v_claims ->> 'name', '')), ''), trim(p_full_name), v_roll,
          v_phone, 'registered', now())
  on conflict (email) do update
     set full_name = excluded.full_name, roll_no = excluded.roll_no, phone = excluded.phone,
         status = 'registered', registered_at = now(), last_signed_in_at = now();

  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', v_roll, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('token', v_token, 'roll_no', v_roll,
                           'full_name', trim(p_full_name), 'email', v_email,
                           'needs_registration', false, 'public', true);
end $$;

-- ---------- admin: the open quiz register ----------
create or replace function public.admin_open_quiz_students(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  return json_build_object(
    'summary', (select json_build_object(
        'total',               count(*),
        'registered',          count(*) filter (where o.status = 'registered'),
        'signed_in',           count(*) filter (where o.status = 'signed_in'),
        'not_eligible',        count(*) filter (where o.status = 'not_eligible'),
        'recruitment_student', count(*) filter (where o.status = 'recruitment_student'),
        'started',             count(*) filter (where a.status is not null),
        'submitted',           count(*) filter (where a.status in ('submitted', 'blocked')))
      from quiz.open_quiz_students o left join quiz.attempts a on a.roll_no = o.roll_no),
    'students', coalesce((select json_agg(json_build_object(
        'email', o.email, 'google_name', o.google_name, 'full_name', o.full_name,
        'roll_no', o.roll_no, 'phone', o.phone, 'status', o.status,
        'first_signed_in_at', o.first_signed_in_at, 'last_signed_in_at', o.last_signed_in_at,
        'sign_in_count', o.sign_in_count, 'registered_at', o.registered_at,
        'attempt_status', a.status, 'score', a.total_score, 'submitted_at', a.submitted_at)
        order by o.last_signed_in_at desc)
      from quiz.open_quiz_students o left join quiz.attempts a on a.roll_no = o.roll_no), '[]'::json));
end $$;

grant execute on function public.public_quiz_login_google(text)                  to anon, authenticated;
grant execute on function public.public_quiz_register(text, text, text, text)    to anon, authenticated;
grant execute on function public.admin_open_quiz_students(uuid)                  to anon, authenticated;

select 'open quiz register' as step, status, count(*) from quiz.open_quiz_students group by status;
