-- =====================================================================
-- LEAD Quiz Portal — 32: recruitment students can take the open quiz too
--
-- Before: anyone on the recruitment list who signed in on the open quiz page
-- was sent back to the recruitment page.
--
-- Now they are treated like everyone else on the open quiz page (the same
-- @thapar.edu and approval rules apply), and get a SEPARATE open-quiz
-- account linked to their email:
--   * their recruitment registration, attempt and score are untouched
--   * the open-quiz account's roll number is their roll number + "-OQ",
--     so the two attempts can never mix
--   * signing in on the recruitment page still opens the recruitment record;
--     signing in on the open quiz page opens the open-quiz one
-- Safe to re-run. No existing data is changed.
-- =====================================================================

-- is this email already used by the recruitment quiz (list or registration)?
create or replace function quiz.is_recruitment_email(p_email text)
returns boolean language sql stable security definer set search_path = quiz, public as $$
  select exists (select 1 from quiz.allowlist a
                  where a.email = lower(p_email)
                    and a.batch_id not in (select id from quiz.batches
                                            where name in ('Open Quiz', 'Open Quiz (pending approval)')))
      or exists (select 1 from quiz.students s join quiz.batches b on b.id = s.batch_id
                  where lower(s.email) = lower(p_email)
                    and b.name not in ('Open Quiz', 'Open Quiz (pending approval)'));
$$;

-- a recruitment student who was sent away earlier becomes a normal sign-in now
create or replace function quiz.track_open_signin(p_email text, p_google_name text, p_status text)
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  insert into quiz.open_quiz_students (email, google_name, status, approval)
  values (p_email, p_google_name, p_status,
          case when p_status in ('signed_in', 'registered') and not quiz.public_email_ok(p_email)
               then 'pending' else 'not_needed' end)
  on conflict (email) do update
     set last_signed_in_at = now(),
         sign_in_count     = quiz.open_quiz_students.sign_in_count + 1,
         google_name       = coalesce(excluded.google_name, quiz.open_quiz_students.google_name),
         status            = case when quiz.open_quiz_students.status = 'registered'
                                  then 'registered' else excluded.status end,
         approval          = case when quiz.open_quiz_students.approval = 'not_needed'
                                   and excluded.approval = 'pending'
                                   and quiz.open_quiz_students.status in ('not_eligible', 'recruitment_student')
                                  then 'pending' else quiz.open_quiz_students.approval end;
end $$;

-- ---------- sign-in from the open quiz page ----------
create or replace function public.public_quiz_login_google(p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_claims jsonb; v_email text; v_name text; v_roll text; s quiz.students;
        v_token uuid; v_cfg quiz.config;
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

  -- the open-quiz account for this email, if they have one
  select o.roll_no into v_roll from quiz.open_quiz_students o
   where o.email = v_email and o.roll_no is not null;
  if v_roll is null then
    -- registered before the open-quiz table existed
    select s2.roll_no into v_roll from quiz.students s2 join quiz.batches b on b.id = s2.batch_id
     where lower(s2.email) = v_email and b.name in ('Open Quiz', 'Open Quiz (pending approval)');
  end if;

  if v_roll is not null then
    select * into s from quiz.students where roll_no = v_roll;
    if s.banned then raise exception 'BANNED'; end if;
    perform quiz.track_open_signin(v_email, v_name, 'registered');
    if exists (select 1 from quiz.attempts
                where roll_no = s.roll_no and status in ('in_progress', 'paused')) then
      update quiz.sessions set revoked = true
       where kind = 'student' and subject = s.roll_no and not revoked;
    end if;
    insert into quiz.sessions (kind, subject, expires_at, device)
    values ('student', s.roll_no, now() + interval '12 hours', p_device)
    returning token into v_token;
    return json_build_object('token', v_token, 'roll_no', s.roll_no,
                             'full_name', s.full_name, 'email', v_email,
                             'needs_registration', false, 'public', true);
  end if;

  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.public_quiz_enabled then
    return json_build_object('ok', false, 'code', 'PUBLIC_QUIZ_CLOSED');
  end if;
  if not quiz.open_quiz_domain_ok(v_email) then
    perform quiz.track_open_signin(v_email, v_name, 'not_eligible');
    return json_build_object('ok', false, 'code', 'PUBLIC_EMAIL_NOT_ELIGIBLE');
  end if;

  perform quiz.track_open_signin(v_email, v_name, 'signed_in');
  return json_build_object('needs_registration', true, 'email', v_email,
                           'full_name', v_name, 'roll_hint', null, 'public', true,
                           'needs_approval', not quiz.public_email_ok(v_email));
end $$;

-- ---------- one-time registration: name, roll number, phone ----------
create or replace function public.public_quiz_register(p_roll text, p_full_name text,
                                                       p_device text default null,
                                                       p_phone text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_claims jsonb; v_email text; v_roll text; v_token uuid; v_batch int;
        v_cfg quiz.config; v_phone text; v_auto boolean; v_approval text; v_recruit boolean;
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
  if exists (select 1 from quiz.open_quiz_students where email = v_email and roll_no is not null)
     or exists (select 1 from quiz.students s join quiz.batches b on b.id = s.batch_id
                 where lower(s.email) = v_email
                   and b.name in ('Open Quiz', 'Open Quiz (pending approval)')) then
    raise exception 'ALREADY_REGISTERED';
  end if;
  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.public_quiz_enabled then raise exception 'PUBLIC_QUIZ_CLOSED'; end if;
  if not quiz.open_quiz_domain_ok(v_email) then raise exception 'PUBLIC_EMAIL_NOT_ELIGIBLE'; end if;

  v_roll := upper(trim(coalesce(p_roll, '')));
  if length(v_roll) < 3 then raise exception 'ROLL_TOO_SHORT'; end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then raise exception 'NAME_REQUIRED'; end if;
  v_phone := quiz.normalize_phone(p_phone);
  if v_phone is null then raise exception 'PHONE_REQUIRED'; end if;

  -- a recruitment student gets a separate open-quiz account: roll + "-OQ", no email on the row
  v_recruit := quiz.is_recruitment_email(v_email);
  if v_recruit then
    v_roll := v_roll || '-OQ';
  end if;

  v_auto := quiz.public_email_ok(v_email);
  select approval into v_approval from quiz.open_quiz_students where email = v_email;
  v_approval := case when v_auto then 'not_needed'
                     when v_approval in ('approved', 'rejected') then v_approval
                     else 'pending' end;
  select id into v_batch from quiz.batches
   where name = case when v_approval in ('not_needed', 'approved') then 'Open Quiz'
                     else 'Open Quiz (pending approval)' end;
  if v_batch is null then raise exception 'PUBLIC_QUIZ_CLOSED'; end if;

  begin
    insert into quiz.students (roll_no, password_hash, full_name, email, batch_id)
    values (v_roll, quiz.hash_password(gen_random_uuid()::text), trim(p_full_name),
            case when v_recruit then null else v_email end, v_batch);
  exception when unique_violation then
    if exists (select 1 from quiz.students where roll_no = v_roll) then
      raise exception 'ROLL_ALREADY_USED: %', v_roll;
    end if;
    raise exception 'ALREADY_REGISTERED';
  end;

  if not v_recruit then
    insert into quiz.allowlist (email, batch_id, full_name, claimed_by)
    values (v_email, v_batch, trim(p_full_name), v_roll)
    on conflict (email) do nothing;
  end if;

  insert into quiz.open_quiz_students (email, google_name, full_name, roll_no, phone, status,
                                       registered_at, approval)
  values (v_email, nullif(trim(coalesce(v_claims ->> 'name', '')), ''), trim(p_full_name), v_roll,
          v_phone, 'registered', now(), v_approval)
  on conflict (email) do update
     set full_name = excluded.full_name, roll_no = excluded.roll_no, phone = excluded.phone,
         status = 'registered', registered_at = now(), last_signed_in_at = now(),
         approval = excluded.approval;

  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', v_roll, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('token', v_token, 'roll_no', v_roll,
                           'full_name', trim(p_full_name), 'email', v_email,
                           'needs_registration', false, 'public', true,
                           'pending_approval', v_approval not in ('not_needed', 'approved'));
end $$;

grant execute on function public.public_quiz_login_google(text)               to anon, authenticated;
grant execute on function public.public_quiz_register(text, text, text, text) to anon, authenticated;
