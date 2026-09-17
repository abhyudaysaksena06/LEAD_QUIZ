-- =====================================================================
-- LEAD Quiz Portal — 31: other @thapar.edu accounts need admin approval
--
-- Who can take the open quiz:
--   @thapar.edu containing be26 or btech26  -> straight in, as before
--   any other @thapar.edu address           -> may sign in and register, then
--                                              waits: "pending admin approval"
--   anything else (Gmail etc.)              -> refused
--
-- A pending student is placed in the round "Open Quiz (pending approval)",
-- which can never be opened, so they cannot start. When an admin approves
-- them (Admin -> Open quiz) they move into the Open Quiz round and their
-- Start button unlocks by itself. An admin can also approve someone who has
-- only signed in; they then go straight in when they finish registering.
-- Safe to re-run. Nobody already registered is moved.
-- =====================================================================

insert into quiz.batches (name, is_open, window_minutes)
values ('Open Quiz (pending approval)', false, 60)
on conflict (name) do nothing;
update quiz.batches set pool_no = 0, paper_mcq = null, paper_coding = null, is_open = false
 where name = 'Open Quiz (pending approval)';

alter table quiz.open_quiz_students add column if not exists approval text not null default 'not_needed';
alter table quiz.open_quiz_students add column if not exists approved_by text;
alter table quiz.open_quiz_students add column if not exists approved_at timestamptz;
do $$ begin
  alter table quiz.open_quiz_students add constraint open_quiz_students_approval_ck
    check (approval in ('not_needed', 'pending', 'approved', 'rejected'));
exception when duplicate_object then null; end $$;

-- the address is from the college domain (the approval rule's first half)
create or replace function quiz.open_quiz_domain_ok(p_email text)
returns boolean language sql stable security definer set search_path = quiz, public as $$
  select lower(coalesce(p_email, '')) like '%@' || lower(c.public_email_domain)
    from quiz.config c where c.id = 1;
$$;

-- record a sign-in; approval is decided once, on first sight, from the address
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
                                   and quiz.open_quiz_students.status = 'not_eligible'
                                  then 'pending' else quiz.open_quiz_students.approval end;
end $$;

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

  if exists (select 1 from quiz.allowlist where email = v_email) then
    perform quiz.track_open_signin(v_email, v_name, 'recruitment_student');
    return json_build_object('ok', false, 'code', 'USE_MAIN_PAGE');
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
        v_cfg quiz.config; v_phone text; v_auto boolean; v_approval text;
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
  if not quiz.open_quiz_domain_ok(v_email) then raise exception 'PUBLIC_EMAIL_NOT_ELIGIBLE'; end if;

  v_roll := upper(trim(coalesce(p_roll, '')));
  if length(v_roll) < 3 then raise exception 'ROLL_TOO_SHORT'; end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then raise exception 'NAME_REQUIRED'; end if;
  v_phone := quiz.normalize_phone(p_phone);
  if v_phone is null then raise exception 'PHONE_REQUIRED'; end if;

  -- be26/btech26 go straight in; other college addresses wait unless already approved
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

-- ---------- admin: approve or reject (one or many) ----------
create or replace function public.admin_open_quiz_approve(p_token uuid, p_emails text[], p_approve boolean)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
        v_open int; v_pending int; v_n int;
begin
  select id into v_open    from quiz.batches where name = 'Open Quiz';
  select id into v_pending from quiz.batches where name = 'Open Quiz (pending approval)';

  update quiz.open_quiz_students
     set approval = case when p_approve then 'approved' else 'rejected' end,
         approved_by = v_admin, approved_at = now()
   where email = any (select lower(trim(e)) from unnest(p_emails) e)
     and approval <> 'not_needed';
  get diagnostics v_n = row_count;

  -- move registered students between the holding round and the Open Quiz round
  update quiz.students s
     set batch_id = case when p_approve then v_open else v_pending end
    from quiz.open_quiz_students o
   where o.roll_no = s.roll_no
     and o.email = any (select lower(trim(e)) from unnest(p_emails) e)
     and o.approval in ('approved', 'rejected')
     and s.batch_id in (v_open, v_pending)
     and not exists (select 1 from quiz.attempts a where a.roll_no = s.roll_no);
  update quiz.allowlist a
     set batch_id = s.batch_id
    from quiz.students s
   where a.claimed_by = s.roll_no
     and a.email = any (select lower(trim(e)) from unnest(p_emails) e);

  perform quiz.audit(v_admin, case when p_approve then 'OPEN_QUIZ_APPROVE' else 'OPEN_QUIZ_REJECT' end,
                     null, json_build_object('emails', p_emails)::jsonb);
  return json_build_object('ok', true, 'updated', v_n);
end $$;

-- ---------- the holding round can never be opened ----------
create or replace function public.admin_set_batch_open(p_token uuid, p_batch_id int, p_open boolean)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_b quiz.batches;
begin
  if p_open and exists (select 1 from quiz.batches
                        where id = p_batch_id and name = 'Open Quiz (pending approval)') then
    raise exception 'PENDING_ROUND_CANNOT_OPEN';
  end if;
  -- Opening ALWAYS restarts the window from now. (Keeping an old closing time would
  -- mean a round opened by mistake earlier in the day could never be started properly.)
  update quiz.batches
     set is_open = p_open,
         opened_at = case when p_open then now() else opened_at end,
         closes_at = case when p_open then now() + make_interval(mins => window_minutes)
                          else closes_at end
   where id = p_batch_id
  returning * into v_b;
  if v_b.id is null then raise exception 'NO_SUCH_BATCH'; end if;
  perform quiz.audit(v_admin, case when p_open then 'OPEN_BATCH' else 'CLOSE_BATCH' end, v_b.name);
  return row_to_json(v_b);
end $$;

-- ---------- admin list, now with approval ----------
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
        'pending',             count(*) filter (where o.approval = 'pending'),
        'approved',            count(*) filter (where o.approval = 'approved'),
        'rejected',            count(*) filter (where o.approval = 'rejected'),
        'started',             count(*) filter (where a.status is not null),
        'submitted',           count(*) filter (where a.status in ('submitted', 'blocked')))
      from quiz.open_quiz_students o left join quiz.attempts a on a.roll_no = o.roll_no),
    'students', coalesce((select json_agg(json_build_object(
        'email', o.email, 'google_name', o.google_name, 'full_name', o.full_name,
        'roll_no', o.roll_no, 'phone', o.phone, 'status', o.status,
        'approval', o.approval, 'approved_by', o.approved_by, 'approved_at', o.approved_at,
        'first_signed_in_at', o.first_signed_in_at, 'last_signed_in_at', o.last_signed_in_at,
        'sign_in_count', o.sign_in_count, 'registered_at', o.registered_at,
        'attempt_status', a.status, 'score', a.total_score, 'submitted_at', a.submitted_at)
        order by (o.approval = 'pending') desc, o.last_signed_in_at desc)
      from quiz.open_quiz_students o left join quiz.attempts a on a.roll_no = o.roll_no), '[]'::json));
end $$;

grant execute on function public.public_quiz_login_google(text)               to anon, authenticated;
grant execute on function public.public_quiz_register(text, text, text, text) to anon, authenticated;
grant execute on function public.admin_open_quiz_approve(uuid, text[], boolean) to anon, authenticated;
grant execute on function public.admin_open_quiz_students(uuid)               to anon, authenticated;

select 'open quiz approval' as step, approval, count(*) from quiz.open_quiz_students group by approval;
