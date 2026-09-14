-- =====================================================================
-- LEAD Quiz Portal — 02: student API (callable from the browser via RPC)
-- =====================================================================

-- Counted flag kinds: these move a student toward auto-submit.
-- Anything else (e.g. PASTE_BLOCKED) is logged only.
create or replace function quiz.is_counted_flag(p_kind text)
returns boolean language sql immutable as $$
  select p_kind in ('FULLSCREEN_EXIT', 'TAB_HIDDEN', 'WINDOW_BLUR');
$$;

-- ---------- brute-force throttle ----------
create or replace function quiz.assert_not_throttled(p_subject text)
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  delete from quiz.login_failures where failed_at < now() - interval '1 hour';
  if (select count(*) from quiz.login_failures
       where subject = p_subject and failed_at > now() - interval '10 minutes') >= 8 then
    raise exception 'TOO_MANY_ATTEMPTS';
  end if;
end $$;

create or replace function quiz.record_login_failure(p_subject text)
returns void language sql security definer set search_path = quiz, public as $$
  insert into quiz.login_failures (subject) values (p_subject);
$$;

-- ---------- login / logout ----------
drop function if exists public.student_login(text, text);
create or replace function public.student_login(p_roll text, p_password text,
                                                p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare s quiz.students; v_token uuid;
begin
  -- NOTE: these paths RETURN a failure instead of raising. A raise would roll back the
  -- failure we just recorded, which would silently disable the throttle.
  if (select count(*) from quiz.login_failures
       where subject = 'student:' || trim(p_roll)
         and failed_at > now() - interval '10 minutes') >= 8 then
    return json_build_object('ok', false, 'code', 'TOO_MANY_ATTEMPTS');
  end if;

  select * into s from quiz.students where roll_no = trim(p_roll);
  if s.roll_no is null or not quiz.check_password(p_password, s.password_hash) then
    insert into quiz.login_failures (subject) values ('student:' || trim(p_roll));
    return json_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;
  if s.banned then return json_build_object('ok', false, 'code', 'BANNED'); end if;
  delete from quiz.login_failures where subject = 'student:' || trim(p_roll);

  -- single active session: a new login signs out any other device/tab
  update quiz.sessions set revoked = true
   where kind = 'student' and subject = s.roll_no and not revoked;

  -- 12h: students sign in hours before the test, so the session must outlive the wait
  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', s.roll_no, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('ok', true, 'token', v_token, 'roll_no', s.roll_no,
                           'full_name', s.full_name);
end $$;

-- ---------- Google sign-in ----------
-- The email is read from the VERIFIED Supabase Auth JWT (request.jwt.claims), never
-- from anything the browser passes in, so a student cannot claim someone else's address.
-- Only an email already present in quiz.students (the registration allowlist) is accepted.
drop function if exists public.student_login_google();
create or replace function public.student_login_google(p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_claims jsonb; v_email text; v_verified text; s quiz.students; v_token uuid;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null;
  end;

  v_email := lower(trim(coalesce(v_claims ->> 'email', '')));
  if v_email = '' then raise exception 'NOT_SIGNED_IN'; end if;

  v_verified := coalesce(v_claims -> 'user_metadata' ->> 'email_verified',
                         v_claims ->> 'email_verified', 'true');
  if v_verified = 'false' then raise exception 'EMAIL_NOT_VERIFIED'; end if;

  select * into s from quiz.students where lower(email) = v_email;

  if s.roll_no is not null and s.banned then raise exception 'BANNED'; end if;

  -- already registered: sign them straight in
  if s.roll_no is not null then
    update quiz.sessions set revoked = true
     where kind = 'student' and subject = s.roll_no and not revoked;
    insert into quiz.sessions (kind, subject, expires_at, device)
    values ('student', s.roll_no, now() + interval '12 hours', p_device)
    returning token into v_token;
    return json_build_object('token', v_token, 'roll_no', s.roll_no,
                             'full_name', s.full_name, 'email', s.email,
                             'needs_registration', false);
  end if;

  -- allowed but not registered yet: the client collects name, roll number and photo ID
  if exists (select 1 from quiz.allowlist where email = v_email and claimed_by is null) then
    return (select json_build_object('needs_registration', true, 'email', v_email,
                                     'full_name', a.full_name, 'roll_hint', a.roll_hint)
              from quiz.allowlist a where a.email = v_email);
  end if;

  raise exception 'EMAIL_NOT_REGISTERED: %', v_email;
end $$;

-- ---------- one-time registration after Google sign-in ----------
-- Email comes from the verified JWT; the student supplies their name, roll number and ID photo.
drop function if exists public.student_register(text, text, text, text);
create or replace function public.student_register(p_roll text, p_full_name text,
                                                   p_id_mime text, p_id_b64 text,
                                                   p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_claims jsonb; v_email text; a quiz.allowlist; v_roll text; v_token uuid;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null;
  end;
  v_email := lower(trim(coalesce(v_claims ->> 'email', '')));
  if v_email = '' then raise exception 'NOT_SIGNED_IN'; end if;

  select * into a from quiz.allowlist where email = v_email;
  if a.email is null then raise exception 'EMAIL_NOT_REGISTERED: %', v_email; end if;
  if a.claimed_by is not null then raise exception 'ALREADY_REGISTERED'; end if;

  v_roll := upper(trim(coalesce(p_roll, '')));
  if length(v_roll) < 3 then raise exception 'ROLL_TOO_SHORT'; end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then raise exception 'NAME_REQUIRED'; end if;
  if exists (select 1 from quiz.students where roll_no = v_roll) then
    raise exception 'ROLL_ALREADY_USED: %', v_roll;
  end if;
  if p_id_b64 is null or length(p_id_b64) < 100 then raise exception 'ID_REQUIRED'; end if;

  insert into quiz.students (roll_no, password_hash, full_name, email, batch_id)
  values (v_roll, quiz.hash_password(gen_random_uuid()::text),   -- no password: Google only
          trim(p_full_name), v_email, a.batch_id);

  insert into quiz.id_documents (roll_no, mime, data_b64, bytes)
  values (v_roll, coalesce(p_id_mime, 'image/webp'), p_id_b64, (length(p_id_b64) * 3) / 4);

  update quiz.allowlist set claimed_by = v_roll where email = v_email;

  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', v_roll, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('token', v_token, 'roll_no', v_roll,
                           'full_name', trim(p_full_name), 'email', v_email,
                           'needs_registration', false);
end $$;

create or replace function public.student_logout(p_token uuid)
returns void language sql security definer set search_path = quiz, public as $$
  update quiz.sessions set revoked = true where token = p_token and kind = 'student';
$$;

-- ---------- full exam state (used on load / resume) ----------
create or replace function public.get_exam_state(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_roll text := quiz.student_from_token(p_token);
  v_cfg  quiz.config;
  v_att  quiz.attempts;
  v_student quiz.students;
  v_batch quiz.batches;
  v_questions json := '[]'::json;
  v_answers   json := '{}'::json;
begin
  select * into v_cfg from quiz.config where id = 1;
  select * into v_student from quiz.students where roll_no = v_roll;
  select b.* into v_batch from quiz.batches b where b.id = v_student.batch_id;
  select * into v_att from quiz.attempts where roll_no = v_roll;

  if v_att.id is not null then
    perform quiz.expire_if_needed(v_att.id);
    select * into v_att from quiz.attempts where id = v_att.id;
  end if;

  if v_att.id is not null and v_att.status = 'in_progress' then
    -- questions in this student's order; options shuffled per student; NO correct_index
    select coalesce(json_agg(json_build_object(
             'id', q.id, 'kind', q.kind, 'title', q.title, 'body', q.body, 'marks', q.marks,
             'starter_code', q.starter_code, 'language', q.language,
             -- SAMPLE tests only. Hidden tests' expected output must never reach a student.
             'tests', case when q.kind = 'coding' then (
                 select coalesce(json_agg(json_build_object(
                          'ord', t.ord, 'stdin', t.stdin, 'expected_output', t.expected_output)
                        order by t.ord), '[]'::json)
                   from quiz.question_tests t where t.question_id = q.id and t.is_sample
               ) end,
             'options', case when q.kind = 'mcq' then (
                 select json_agg(json_build_object('i', (o.ord - 1)::int, 't', o.val)
                                 order by md5(v_att.id::text || q.id::text || o.ord::text))
                   from jsonb_array_elements_text(q.options) with ordinality as o(val, ord)
               ) end
           ) order by u.pos), '[]'::json)
      into v_questions
      from unnest(v_att.question_ids) with ordinality as u(qid, pos)
      join quiz.questions q on q.id = u.qid;

    select coalesce(json_object_agg(a.question_id, json_build_object(
             'selected_index', a.selected_index, 'code', a.code,
             'language', a.language, 'revision', a.revision)), '{}'::json)
      into v_answers
      from quiz.answers a where a.attempt_id = v_att.id;
  end if;

  return json_build_object(
    'server_now', now(),
    'config', json_build_object(
       'exam_title', v_cfg.exam_title, 'duration_minutes', v_cfg.duration_minutes,
       'mcq_count', v_cfg.mcq_count, 'coding_count', v_cfg.coding_count,
       'max_flags', v_cfg.max_flags, 'exam_open', v_cfg.exam_open,
       'require_mic', v_cfg.require_mic, 'require_camera', v_cfg.require_camera),
    'student', json_build_object('roll_no', v_student.roll_no, 'full_name', v_student.full_name),
    'batch', case when v_batch.id is null then null else json_build_object(
       'id', v_batch.id, 'name', v_batch.name, 'is_open', v_batch.is_open,
       'duration_minutes', coalesce(v_batch.duration_minutes, v_cfg.duration_minutes)) end,
    'can_start', (v_cfg.exam_open and coalesce(v_batch.is_open, false)),
    'attempt', case when v_att.id is null then null else json_build_object(
       'id', v_att.id, 'status', v_att.status, 'started_at', v_att.started_at,
       'deadline_at', v_att.deadline_at, 'submitted_at', v_att.submitted_at,
       'submit_reason', v_att.submit_reason, 'flag_count', v_att.flag_count) end,
    'questions', v_questions,
    'answers', v_answers
  );
end $$;

-- ---------- start: draws this student's random paper, starts their 15-min clock ----------
create or replace function public.start_attempt(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_roll  text := quiz.student_from_token(p_token);
  v_cfg   quiz.config;
  v_batch quiz.batches;
  v_ids   int[];
  v_minutes int;
begin
  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.exam_open then raise exception 'EXAM_CLOSED'; end if;

  -- a student may only start once THEIR batch has been opened
  select b.* into v_batch from quiz.batches b
    join quiz.students s on s.batch_id = b.id
   where s.roll_no = v_roll;
  if v_batch.id is null   then raise exception 'NO_BATCH'; end if;
  if not v_batch.is_open  then raise exception 'BATCH_CLOSED'; end if;
  if v_batch.closes_at is not null and now() > v_batch.closes_at then
    raise exception 'ROUND_ENDED';
  end if;

  -- capacity: never let more than max_concurrent students sit the test at once
  if (select count(*) from quiz.attempts where status in ('in_progress', 'paused'))
       >= v_cfg.max_concurrent then
    raise exception 'CAPACITY_FULL';
  end if;

  v_minutes := coalesce(v_batch.duration_minutes, v_cfg.duration_minutes);

  if not exists (select 1 from quiz.attempts where roll_no = v_roll) then
    with m as (select id from quiz.questions where kind = 'mcq' and active
                order by random() limit v_cfg.mcq_count),
         c as (select id from quiz.questions where kind = 'coding' and active
                order by random() limit v_cfg.coding_count)
    select array(select id from m) || array(select id from c) into v_ids;

    if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'NO_QUESTIONS'; end if;

    -- their own clock, but never past the moment the round window shuts
    insert into quiz.attempts (roll_no, question_ids, deadline_at)
    values (v_roll, v_ids,
            least(now() + make_interval(mins => v_minutes),
                  coalesce(v_batch.closes_at, now() + make_interval(mins => v_minutes))))
    on conflict (roll_no) do nothing;   -- double-click safe
  end if;

  return public.get_exam_state(p_token);
end $$;

-- internal: resolve the caller's attempt, applying timer expiry.
-- Callers MUST check v_att.status. This deliberately does not raise on a finished
-- attempt: raising would roll back the expiry performed just above.
create or replace function quiz.live_attempt(p_token uuid)
returns quiz.attempts language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token); v_att quiz.attempts;
begin
  select * into v_att from quiz.attempts where roll_no = v_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  perform quiz.expire_if_needed(v_att.id);
  select * into v_att from quiz.attempts where id = v_att.id;
  return v_att;
end $$;

-- ---------- save answers (every click / debounced keystroke) ----------
create or replace function public.save_mcq_answer(p_token uuid, p_question_id int, p_selected_index int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_att quiz.attempts := quiz.live_attempt(p_token);
begin
  if v_att.status <> 'in_progress' then
    return json_build_object('ok', false, 'status', v_att.status);   -- time up / blocked / submitted
  end if;
  if not (p_question_id = any (v_att.question_ids)) then raise exception 'NOT_YOUR_QUESTION'; end if;
  insert into quiz.answers (attempt_id, question_id, selected_index, updated_at)
  values (v_att.id, p_question_id, p_selected_index, now())
  on conflict (attempt_id, question_id)
  do update set selected_index = excluded.selected_index, updated_at = now();
  return json_build_object('ok', true);
end $$;

create or replace function public.save_code_answer(p_token uuid, p_question_id int, p_code text,
                                                   p_language text, p_revision int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_att quiz.attempts := quiz.live_attempt(p_token);
begin
  if v_att.status <> 'in_progress' then
    return json_build_object('ok', false, 'status', v_att.status);   -- time up / blocked / submitted
  end if;
  if not (p_question_id = any (v_att.question_ids)) then raise exception 'NOT_YOUR_QUESTION'; end if;
  if length(coalesce(p_code, '')) > 50000 then raise exception 'CODE_TOO_LONG'; end if;
  insert into quiz.answers (attempt_id, question_id, code, language, revision, updated_at)
  values (v_att.id, p_question_id, p_code, p_language, p_revision, now())
  on conflict (attempt_id, question_id)
  do update set code = excluded.code, language = excluded.language,
                revision = excluded.revision, updated_at = now()
  where quiz.answers.revision < excluded.revision;   -- stale retry can't overwrite newer code
  return json_build_object('ok', true);
end $$;

-- ---------- screen-control violations ----------
create or replace function public.report_flag(p_token uuid, p_kind text, p_detail text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_roll text := quiz.student_from_token(p_token);
  v_att quiz.attempts; v_cfg quiz.config; v_counted boolean;
begin
  select * into v_cfg from quiz.config where id = 1;
  select * into v_att from quiz.attempts where roll_no = v_roll;
  if v_att.id is null or v_att.status <> 'in_progress' then
    return json_build_object('status', coalesce(v_att.status, 'none'), 'flag_count', coalesce(v_att.flag_count, 0),
                             'max_flags', v_cfg.max_flags);
  end if;

  -- one real-world action often fires 2-3 browser events (blur + hidden + fullscreen exit).
  -- Only the first counted flag in any 5-second window counts.
  v_counted := quiz.is_counted_flag(p_kind) and not exists (
    select 1 from quiz.flags where attempt_id = v_att.id and counted
       and created_at > now() - interval '5 seconds');

  insert into quiz.flags (attempt_id, kind, detail, counted)
  values (v_att.id, left(p_kind, 40), left(p_detail, 300), v_counted);

  if v_counted then
    update quiz.attempts set flag_count = flag_count + 1 where id = v_att.id
    returning * into v_att;

    if v_att.flag_count >= v_cfg.max_flags then
      perform quiz.finalize_attempt(v_att.id, 'blocked', 'FLAG_LIMIT');
      update quiz.sessions set revoked = true            -- logged out
       where kind = 'student' and subject = v_roll;
      select * into v_att from quiz.attempts where id = v_att.id;
    end if;
  end if;

  return json_build_object('status', v_att.status, 'flag_count', v_att.flag_count,
                           'max_flags', v_cfg.max_flags, 'counted', v_counted);
end $$;

-- ---------- camera detections ----------
-- Creates a REVIEW ITEM only. It never flags the student, never counts toward the
-- violation limit, and the student is told nothing. A proctor decides.
create or replace function public.student_report_detection(p_token uuid, p_kind text,
                                                           p_detail jsonb default null,
                                                           p_image_b64 text default null,
                                                           p_mime text default 'image/webp')
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token); v_att quiz.attempts;
begin
  select * into v_att from quiz.attempts where roll_no = v_roll;
  if v_att.id is null or v_att.status <> 'in_progress' then
    return json_build_object('ok', true, 'skipped', 'not_in_progress');
  end if;

  -- one item per student per kind per minute, and never more than 5 waiting
  if exists (select 1 from quiz.detections
              where roll_no = v_roll and kind = p_kind and status = 'pending'
                and created_at > now() - interval '60 seconds') then
    return json_build_object('ok', true, 'skipped', 'duplicate');
  end if;
  if (select count(*) from quiz.detections where roll_no = v_roll and status = 'pending') >= 5 then
    return json_build_object('ok', true, 'skipped', 'queue_full');
  end if;

  insert into quiz.detections (roll_no, attempt_id, kind, detail, image_b64, mime)
  values (v_roll, v_att.id, left(p_kind, 40), p_detail, p_image_b64,
          coalesce(nullif(p_mime, ''), 'image/webp'));
  return json_build_object('ok', true);
end $$;

-- ---------- submit ----------
create or replace function public.submit_attempt(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token); v_att quiz.attempts;
begin
  select * into v_att from quiz.attempts where roll_no = v_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if v_att.status = 'in_progress' then
    perform quiz.finalize_attempt(v_att.id, 'submitted',
      case when now() > v_att.deadline_at then 'TIME_UP' else 'MANUAL' end);
  end if;
  return json_build_object('ok', true);
end $$;

-- ---------- lightweight poll: timer sync, status changes, unread chat ----------
drop function if exists public.student_heartbeat(uuid);
create or replace function public.student_heartbeat(p_token uuid, p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token); v_att quiz.attempts; v_unread int;
        v_device text;
begin
  -- One live browser per account. If this token turns up from a second device the
  -- session is killed for BOTH, so a copied token can't be used in parallel.
  -- returns (not raises) so the revoke is actually committed
  select device into v_device from quiz.sessions where token = p_token;
  if v_device is not null and p_device is not null and v_device <> p_device then
    update quiz.sessions set revoked = true where token = p_token;
    return json_build_object('ok', false, 'code', 'SESSION_TAKEN');
  end if;
  if v_device is null and p_device is not null then
    update quiz.sessions set device = p_device where token = p_token;
  end if;

  select * into v_att from quiz.attempts where roll_no = v_roll;
  if v_att.id is not null then
    perform quiz.expire_if_needed(v_att.id);
    select * into v_att from quiz.attempts where id = v_att.id;
  end if;
  select count(*) into v_unread from quiz.messages
   where roll_no = v_roll and sender = 'admin' and not read_by_student;
  return json_build_object('server_now', now(), 'status', v_att.status,
    'deadline_at', v_att.deadline_at, 'flag_count', v_att.flag_count, 'unread', v_unread);
end $$;

-- ---------- chat ----------
create or replace function public.student_send_message(p_token uuid, p_body text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token);
begin
  if length(trim(coalesce(p_body, ''))) = 0 then raise exception 'EMPTY_MESSAGE'; end if;
  insert into quiz.messages (roll_no, sender, sender_name, body)
  values (v_roll, 'student', v_roll, left(trim(p_body), 2000));
  -- route this student to the least-loaded proctor who is online right now
  perform quiz.assign_thread(v_roll);
  return json_build_object('ok', true);
end $$;

create or replace function public.student_get_messages(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token); v json;
begin
  update quiz.messages set read_by_student = true
   where roll_no = v_roll and sender = 'admin' and not read_by_student;
  select coalesce(json_agg(json_build_object('id', id, 'sender', sender, 'sender_name', sender_name,
           'body', body, 'created_at', created_at) order by id), '[]'::json)
    into v from quiz.messages where roll_no = v_roll;
  return v;
end $$;
