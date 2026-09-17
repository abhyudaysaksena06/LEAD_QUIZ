-- =====================================================================
-- LEAD Quiz Portal — 33: invalid emails are not recorded or listed
--
-- Sign-ins with an address the open quiz doesn't accept (Gmail etc.) are
-- still refused, but are no longer saved, and any already saved are removed
-- from the Open quiz list. Nobody who registered is affected.
-- Safe to re-run.
-- =====================================================================

delete from quiz.open_quiz_students where status = 'not_eligible' and roll_no is null;

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
    return json_build_object('ok', false, 'code', 'PUBLIC_EMAIL_NOT_ELIGIBLE');
  end if;

  perform quiz.track_open_signin(v_email, v_name, 'signed_in');
  return json_build_object('needs_registration', true, 'email', v_email,
                           'full_name', v_name, 'roll_hint', null, 'public', true,
                           'needs_approval', not quiz.public_email_ok(v_email));
end $$;

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
      from quiz.open_quiz_students o left join quiz.attempts a on a.roll_no = o.roll_no
       where o.status <> 'not_eligible'),
    'students', coalesce((select json_agg(json_build_object(
        'email', o.email, 'google_name', o.google_name, 'full_name', o.full_name,
        'roll_no', o.roll_no, 'phone', o.phone, 'status', o.status,
        'approval', o.approval, 'approved_by', o.approved_by, 'approved_at', o.approved_at,
        'first_signed_in_at', o.first_signed_in_at, 'last_signed_in_at', o.last_signed_in_at,
        'sign_in_count', o.sign_in_count, 'registered_at', o.registered_at,
        'attempt_status', a.status, 'score', a.total_score, 'submitted_at', a.submitted_at)
        order by (o.approval = 'pending') desc, o.last_signed_in_at desc)
      from quiz.open_quiz_students o left join quiz.attempts a on a.roll_no = o.roll_no
       where o.status <> 'not_eligible'), '[]'::json));
end $$;

grant execute on function public.public_quiz_login_google(text) to anon, authenticated;
grant execute on function public.admin_open_quiz_students(uuid) to anon, authenticated;
