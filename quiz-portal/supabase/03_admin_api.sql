-- =====================================================================
-- LEAD Quiz Portal — 03: admin API + permissions
-- =====================================================================

create or replace function quiz.audit(p_actor text, p_action text, p_target text, p_detail jsonb default null)
returns void language sql security definer set search_path = quiz, public as $$
  insert into quiz.audit_log (actor, action, target, detail) values (p_actor, p_action, p_target, p_detail);
$$;

-- ---------- login ----------
create or replace function public.admin_login(p_username text, p_password text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare a quiz.admins; v_token uuid;
begin
  -- returns instead of raising, so the recorded failure survives (see student_login)
  if (select count(*) from quiz.login_failures
       where subject = 'admin:' || trim(p_username)
         and failed_at > now() - interval '10 minutes') >= 8 then
    return json_build_object('ok', false, 'code', 'TOO_MANY_ATTEMPTS');
  end if;

  select * into a from quiz.admins where username = trim(p_username);
  if a.username is null or not quiz.check_password(p_password, a.password_hash) then
    insert into quiz.login_failures (subject) values ('admin:' || trim(p_username));
    return json_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;
  delete from quiz.login_failures where subject = 'admin:' || trim(p_username);
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

-- ---------- dashboard: every student, live ----------
create or replace function public.admin_overview(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_cfg quiz.config; v_rows json;
begin
  -- safety net: end anyone whose timer ran out while their browser was closed
  perform quiz.sweep_expired();

  -- hand over any thread whose owner has gone offline, and pick up unassigned ones
  perform quiz.rebalance_threads();

  select * into v_cfg from quiz.config where id = 1;

  -- Single pass over answers and messages instead of per-student subqueries.
  -- This runs every 5 seconds for every admin, so it is the hottest query in the system.
  select coalesce(json_agg(r order by r.unread desc, r.roll_no), '[]'::json) into v_rows from (
    with ans as (
      select attempt_id,
             count(*) filter (where selected_index is not null or length(coalesce(code, '')) > 0) as answered
        from quiz.answers group by attempt_id
    ), msg as (
      select roll_no,
             count(*) filter (where sender = 'student' and not read_by_admin) as unread,
             max(created_at) as last_message_at,
             max(created_at) filter (where sender = 'student') as last_student_message_at
        from quiz.messages group by roll_no
    )
    select s.roll_no, s.full_name, s.email, s.batch_id, s.banned, s.banned_reason, b.name as batch_name,
           coalesce(a.status, 'not_started') as status,
           a.id as attempt_id, a.flag_count, a.started_at, a.deadline_at, a.submitted_at,
           a.submit_reason, a.mcq_score, a.coding_score, a.total_score, a.unblock_count,
           coalesce(array_length(a.question_ids, 1), 0) as total_questions,
           coalesce(ans.answered, 0) as answered,
           coalesce(msg.unread, 0) as unread,
           msg.last_message_at, msg.last_student_message_at,
           th.assigned_to, coalesce(th.resolved, true) as thread_resolved,
           exists (select 1 from quiz.id_documents d where d.roll_no = s.roll_no) as has_id
      from quiz.students s
      left join quiz.attempts a on a.roll_no = s.roll_no
      left join quiz.batches  b on b.id = s.batch_id
      left join quiz.threads  th on th.roll_no = s.roll_no
      left join ans on ans.attempt_id = a.id
      left join msg on msg.roll_no = s.roll_no
  ) r;

  return json_build_object(
    'server_now', now(),
    'me', v_admin,
    'config', row_to_json(v_cfg),
    'registration', json_build_object(
      'allowlisted', (select count(*) from quiz.allowlist),
      'registered',  (select count(*) from quiz.allowlist where claimed_by is not null),
      'pending',     (select count(*) from quiz.allowlist where claimed_by is null)),
    'admins', coalesce((select json_agg(json_build_object(
        'username', a.username, 'display_name', a.display_name,
        'active', quiz.admin_is_active(a.username), 'last_seen_at', a.last_seen_at,
        'open_threads', (select count(*) from quiz.threads t
                          where t.assigned_to = a.username and not t.resolved),
        'unread', (select count(*) from quiz.messages m
                     join quiz.threads t2 on t2.roll_no = m.roll_no
                    where t2.assigned_to = a.username and not t2.resolved
                      and m.sender = 'student' and not m.read_by_admin)
      ) order by a.username) from quiz.admins a), '[]'::json),
    'batches', coalesce((select json_agg(json_build_object(
        'id', b.id, 'name', b.name, 'is_open', b.is_open,
        'duration_minutes', b.duration_minutes, 'opened_at', b.opened_at,
        'window_minutes', b.window_minutes, 'closes_at', b.closes_at,
        'students', (select count(*) from quiz.students s where s.batch_id = b.id),
        'not_started', (select count(*) from quiz.students s where s.batch_id = b.id
                          and not exists (select 1 from quiz.attempts a where a.roll_no = s.roll_no)),
        'in_progress', (select count(*) from quiz.attempts a join quiz.students s on s.roll_no = a.roll_no
                         where s.batch_id = b.id and a.status = 'in_progress'),
        'finished', (select count(*) from quiz.attempts a join quiz.students s on s.roll_no = a.roll_no
                      where s.batch_id = b.id and a.status in ('submitted', 'blocked'))
      ) order by b.id) from quiz.batches b), '[]'::json),
    'students', v_rows);
end $$;

-- ---------- camera review ----------
-- Images are transient: cleared on decision, and purged if nobody looks within 30 minutes.
create or replace function quiz.expire_detections()
returns int language plpgsql security definer set search_path = quiz, public as $$
declare n int;
begin
  update quiz.detections set status = 'expired', image_b64 = null
   where status = 'pending' and created_at < now() - interval '30 minutes';
  get diagnostics n = row_count;
  return n;
end $$;

-- The list deliberately excludes the images; fetch one at a time to view it.
create or replace function public.admin_review_queue(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  perform quiz.expire_detections();
  return coalesce((
    select json_agg(json_build_object(
      'id', d.id, 'roll_no', d.roll_no, 'full_name', s.full_name,
      'batch_name', (select b.name from quiz.batches b where b.id = s.batch_id),
      'kind', d.kind, 'detail', d.detail, 'created_at', d.created_at,
      'attempt_status', a.status, 'flag_count', a.flag_count,
      'max_flags', (select max_flags from quiz.config where id = 1))
      order by d.created_at)
    from quiz.detections d
    join quiz.students s on s.roll_no = d.roll_no
    left join quiz.attempts a on a.id = d.attempt_id
   where d.status = 'pending'), '[]'::json);
end $$;

create or replace function public.admin_review_image(p_token uuid, p_id bigint)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); d quiz.detections;
begin
  select * into d from quiz.detections where id = p_id;
  if d.id is null or d.image_b64 is null then return json_build_object('found', false); end if;
  return json_build_object('found', true, 'mime', d.mime, 'image_b64', d.image_b64);
end $$;

-- Approve  -> records a counted violation, exactly like a screen violation.
-- Dismiss  -> nothing happens to the student at all.
-- Either way the image is destroyed immediately.
create or replace function public.admin_decide_detection(p_token uuid, p_id bigint,
                                                         p_approve boolean, p_note text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin text := quiz.admin_from_token(p_token);
  d quiz.detections; v_att quiz.attempts; v_cfg quiz.config; v_blocked boolean := false;
begin
  select * into d from quiz.detections where id = p_id;
  if d.id is null then raise exception 'NO_SUCH_ITEM'; end if;
  if d.status <> 'pending' then raise exception 'ALREADY_REVIEWED'; end if;

  update quiz.detections
     set status = case when p_approve then 'approved' else 'dismissed' end,
         image_b64 = null,                       -- the picture is gone either way
         reviewed_by = v_admin, reviewed_at = now()
   where id = p_id;

  if not p_approve then
    perform quiz.audit(v_admin, 'DISMISS_DETECTION', d.roll_no, json_build_object('kind', d.kind)::jsonb);
    return json_build_object('ok', true, 'flagged', false);
  end if;

  select * into v_cfg from quiz.config where id = 1;
  select * into v_att from quiz.attempts where id = d.attempt_id;
  if v_att.id is null then
    return json_build_object('ok', true, 'flagged', false, 'note', 'attempt no longer exists');
  end if;

  insert into quiz.flags (attempt_id, kind, detail, counted)
  values (v_att.id, d.kind, coalesce(p_note, 'confirmed by ' || v_admin), true);

  update quiz.attempts set flag_count = flag_count + 1 where id = v_att.id returning * into v_att;

  if v_att.flag_count >= v_cfg.max_flags and v_att.status = 'in_progress' then
    -- session deliberately left alive so they can reach a proctor immediately
    perform quiz.finalize_attempt(v_att.id, 'blocked', 'FLAG_LIMIT');
    v_blocked := true;
  end if;

  perform quiz.audit(v_admin, 'APPROVE_DETECTION', d.roll_no,
                     json_build_object('kind', d.kind, 'flag_count', v_att.flag_count,
                                       'blocked', v_blocked)::jsonb);
  return json_build_object('ok', true, 'flagged', true,
                           'flag_count', v_att.flag_count, 'max_flags', v_cfg.max_flags,
                           'blocked', v_blocked);
end $$;

-- ---------- Student Live: who is online and what still needs attention ----------
-- "Notifications" are unread student messages and unresolved violations. Resolving is
-- shared state, so once any proctor clears one it is gone for everybody.
create or replace function public.admin_live(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_rows json;
begin
  perform quiz.sweep_expired();
  perform quiz.rebalance_threads();
  perform quiz.expire_detections();

  -- students needing attention first: unread chats, open violations, then camera trouble
  select coalesce(json_agg(x order by (x.unread + x.open_flags + x.pending_camera) desc,
                           (x.status = 'in_progress' and x.camera_ok is false) desc,
                           x.active desc, x.roll_no), '[]'::json)
    into v_rows from (
    with fl as (
      select at.roll_no,
             count(*) as open_flags,
             json_agg(json_build_object('id', f.id, 'kind', f.kind, 'detail', f.detail,
                                        'created_at', f.created_at) order by f.created_at desc) as flags
        from quiz.flags f
        join quiz.attempts at on at.id = f.attempt_id
       where f.counted and not f.resolved
       group by at.roll_no
    ), msg as (
      select roll_no,
             count(*) filter (where sender = 'student' and not read_by_admin) as unread,
             max(created_at) filter (where sender = 'student') as last_student_message_at,
             (array_agg(body order by id desc) filter (where sender = 'student'))[1] as last_student_message
        from quiz.messages group by roll_no
    ), det as (
      select roll_no, count(*) as pending_camera,
             (array_agg(kind order by created_at desc))[1] as last_camera_kind
        from quiz.detections where status = 'pending' group by roll_no
    )
    select s.roll_no, s.full_name, s.banned,
           b.name as batch_name,
           coalesce(a.status, 'not_started') as status,
           a.deadline_at, a.flag_count, a.submitted_at, a.camera_ok, a.camera_note,
           coalesce(s.last_seen_at > now() - interval '30 seconds', false) as active,
           s.last_seen_at,
           coalesce(msg.unread, 0) as unread,
           msg.last_student_message, msg.last_student_message_at,
           coalesce(fl.open_flags, 0) as open_flags,
           coalesce(fl.flags, '[]'::json) as flags,
           coalesce(det.pending_camera, 0) as pending_camera, det.last_camera_kind,
           th.assigned_to, coalesce(th.resolved, true) as thread_resolved
      from quiz.students s
      left join quiz.attempts a on a.roll_no = s.roll_no
      left join quiz.batches  b on b.id = s.batch_id
      left join quiz.threads  th on th.roll_no = s.roll_no
      left join fl on fl.roll_no = s.roll_no
      left join msg on msg.roll_no = s.roll_no
      left join det on det.roll_no = s.roll_no
  ) x;

  return json_build_object('server_now', now(), 'me', v_admin, 'students', v_rows);
end $$;

-- Clear one violation, or every open one for a student. Shared across all admins.
create or replace function public.admin_resolve_flags(p_token uuid, p_roll text,
                                                      p_flag_id bigint default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_n int;
begin
  update quiz.flags f
     set resolved = true, resolved_by = v_admin, resolved_at = now()
    from quiz.attempts a
   where a.id = f.attempt_id and a.roll_no = p_roll and not f.resolved
     and (p_flag_id is null or f.id = p_flag_id);
  get diagnostics v_n = row_count;
  perform quiz.audit(v_admin, 'RESOLVE_FLAGS', p_roll, json_build_object('count', v_n)::jsonb);
  return json_build_object('ok', true, 'count', v_n);
end $$;

-- ---------- one student: answers (with keys), flags, chat ----------
create or replace function public.admin_student_detail(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts; v_student quiz.students;
begin
  select * into v_student from quiz.students where roll_no = p_roll;
  if v_student.roll_no is null then raise exception 'NO_SUCH_STUDENT'; end if;
  select * into v_att from quiz.attempts where roll_no = p_roll;

  return json_build_object(
    'student', json_build_object('roll_no', v_student.roll_no, 'full_name', v_student.full_name,
                                 'email', v_student.email, 'banned', v_student.banned,
                                 'banned_reason', v_student.banned_reason,
                                 'consented_at', v_student.consented_at,
                                 'consent_version', v_student.consent_version),
    'attempt', row_to_json(v_att),
    'questions', coalesce((
      select json_agg(json_build_object(
        'id', q.id, 'kind', q.kind, 'title', q.title, 'body', q.body, 'marks', q.marks,
        'options', q.options, 'correct_index', q.correct_index,
        'selected_index', a.selected_index, 'code', a.code, 'language', a.language,
        'coding_marks', a.coding_marks, 'updated_at', a.updated_at,
        'auto_passed', a.auto_passed, 'auto_total', a.auto_total, 'auto_report', a.auto_report,
        'graded_by', a.graded_by,
        -- admins get ALL tests (including hidden) so grading can re-run the code
        'tests', case when q.kind = 'coding' then (
            select coalesce(json_agg(json_build_object('id', t.id, 'ord', t.ord, 'stdin', t.stdin,
                     'expected_output', t.expected_output, 'is_sample', t.is_sample, 'points', t.points)
                   order by t.ord), '[]'::json)
              from quiz.question_tests t where t.question_id = q.id) end) order by u.pos)
      from unnest(v_att.question_ids) with ordinality as u(qid, pos)
      join quiz.questions q on q.id = u.qid
      left join quiz.answers a on a.attempt_id = v_att.id and a.question_id = q.id), '[]'::json),
    'flags', coalesce((
      select json_agg(json_build_object('kind', kind, 'detail', detail, 'counted', counted,
                                        'created_at', created_at, 'resolved', resolved,
                                        'resolved_by', resolved_by) order by created_at)
      from quiz.flags where attempt_id = v_att.id), '[]'::json)
  );
end $$;

-- ---------- unblock (the release valve) ----------
-- Restores the attempt and gives back the time the student had left when blocked,
-- plus optional extra minutes. Flags are reset to p_reset_flags_to (default 2 = one strike left).
create or replace function public.admin_unblock(p_token uuid, p_roll text,
                                                p_extra_minutes int default 0,
                                                p_reset_flags_to int default 2,
                                                p_reason text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin text := quiz.admin_from_token(p_token);
  v_att quiz.attempts; v_cfg quiz.config; v_remaining interval;
begin
  select * into v_cfg from quiz.config where id = 1;
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if v_att.status <> 'blocked' then raise exception 'NOT_BLOCKED'; end if;

  v_remaining := greatest(v_att.deadline_at - coalesce(v_att.submitted_at, now()), interval '0');

  update quiz.attempts set
    status = 'in_progress', submitted_at = null, submit_reason = null,
    deadline_at = now() + v_remaining + make_interval(mins => greatest(coalesce(p_extra_minutes, 0), 0)),
    flag_count = least(greatest(coalesce(p_reset_flags_to, 0), 0), v_cfg.max_flags - 1),
    unblock_count = unblock_count + 1,
    mcq_score = null, coding_score = null, total_score = null
  where id = v_att.id;

  perform quiz.audit(v_admin, 'UNBLOCK', p_roll, json_build_object(
    'reason', p_reason, 'extra_minutes', p_extra_minutes,
    'restored_seconds', extract(epoch from v_remaining)::int, 'flags_reset_to', p_reset_flags_to)::jsonb);

  insert into quiz.messages (roll_no, sender, sender_name, body)
  values (p_roll, 'admin', v_admin, 'Your test has been restored by a proctor. Sign in again to continue.');

  return json_build_object('ok', true, 'restored_seconds', extract(epoch from v_remaining)::int);
end $$;

create or replace function public.admin_extend_time(p_token uuid, p_roll text, p_minutes int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  update quiz.attempts set deadline_at = greatest(deadline_at, now()) + make_interval(mins => p_minutes)
   where roll_no = p_roll and status = 'in_progress';
  if not found then raise exception 'NOT_IN_PROGRESS'; end if;
  perform quiz.audit(v_admin, 'EXTEND_TIME', p_roll, json_build_object('minutes', p_minutes)::jsonb);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_force_submit(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_id uuid;
begin
  select id into v_id from quiz.attempts where roll_no = p_roll and status = 'in_progress';
  if v_id is null then raise exception 'NOT_IN_PROGRESS'; end if;
  perform quiz.finalize_attempt(v_id, 'submitted', 'ADMIN');
  perform quiz.audit(v_admin, 'FORCE_SUBMIT', p_roll);
  return json_build_object('ok', true);
end $$;

-- ---------- pause / resume ----------
-- Freezes the clock. The student keeps their answers and sees a "paused" screen;
-- nothing they do counts as a violation while paused.
create or replace function public.admin_pause_attempt(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if v_att.status <> 'in_progress' then raise exception 'NOT_IN_PROGRESS'; end if;

  update quiz.attempts set status = 'paused', paused_at = now() where id = v_att.id;
  insert into quiz.messages (roll_no, sender, sender_name, body, read_by_admin)
  values (p_roll, 'admin', v_admin, 'A proctor has paused your test. Your time is frozen — please wait.', true);
  perform quiz.audit(v_admin, 'PAUSE_ATTEMPT', p_roll,
    json_build_object('remaining_seconds', extract(epoch from (v_att.deadline_at - now()))::int)::jsonb);
  return json_build_object('ok', true);
end $$;

-- Gives back exactly the time they had left when paused.
create or replace function public.admin_resume_attempt(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts; v_left interval;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if v_att.status <> 'paused' then raise exception 'NOT_PAUSED'; end if;

  v_left := greatest(v_att.deadline_at - coalesce(v_att.paused_at, now()), interval '0');
  update quiz.attempts
     set status = 'in_progress', deadline_at = now() + v_left, paused_at = null
   where id = v_att.id;

  insert into quiz.messages (roll_no, sender, sender_name, body, read_by_admin)
  values (p_roll, 'admin', v_admin, 'Your test has been resumed. Return to fullscreen to continue.', true);
  perform quiz.audit(v_admin, 'RESUME_ATTEMPT', p_roll,
                     json_build_object('restored_seconds', extract(epoch from v_left)::int)::jsonb);
  return json_build_object('ok', true, 'restored_seconds', extract(epoch from v_left)::int);
end $$;

-- ---------- ban / unban ----------
-- Disqualifies the student: ends any live attempt, signs them out, and refuses
-- every future sign-in (password AND Google) until an admin lifts it.
create or replace function public.admin_ban_student(p_token uuid, p_roll text, p_reason text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_id uuid;
begin
  update quiz.students set banned = true, banned_reason = p_reason, banned_at = now()
   where roll_no = p_roll;
  if not found then raise exception 'NO_SUCH_STUDENT'; end if;

  select id into v_id from quiz.attempts where roll_no = p_roll;
  if v_id is not null then
    update quiz.attempts
       set status = 'banned', submitted_at = coalesce(submitted_at, now()),
           submit_reason = 'BANNED', paused_at = null
     where id = v_id and status in ('in_progress', 'paused');
    perform quiz.recompute_scores(v_id);   -- keep the record of what they had done
  end if;

  update quiz.sessions set revoked = true where kind = 'student' and subject = p_roll;
  perform quiz.audit(v_admin, 'BAN_STUDENT', p_roll, json_build_object('reason', p_reason)::jsonb);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_unban_student(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  update quiz.students set banned = false, banned_reason = null, banned_at = null
   where roll_no = p_roll;
  if not found then raise exception 'NO_SUCH_STUDENT'; end if;
  perform quiz.audit(v_admin, 'UNBAN_STUDENT', p_roll);
  -- their attempt stays 'banned'; use Reset attempt to let them sit the test again
  return json_build_object('ok', true);
end $$;

-- Close out a whole round at once (end of the slot, or an evacuation).
create or replace function public.admin_force_submit_batch(p_token uuid, p_batch_id int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); r record; n int := 0;
begin
  for r in select a.id from quiz.attempts a
             join quiz.students s on s.roll_no = a.roll_no
            where s.batch_id = p_batch_id and a.status in ('in_progress', 'paused')
  loop
    update quiz.attempts set status = 'in_progress', paused_at = null where id = r.id;
    perform quiz.finalize_attempt(r.id, 'submitted', 'ADMIN');
    n := n + 1;
  end loop;
  perform quiz.audit(v_admin, 'FORCE_SUBMIT_BATCH', p_batch_id::text,
                     json_build_object('submitted', n)::jsonb);
  return json_build_object('ok', true, 'submitted', n);
end $$;

-- Deletes the attempt entirely: the student can start again with a NEW random paper.
create or replace function public.admin_reset_attempt(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  delete from quiz.attempts where roll_no = p_roll;
  perform quiz.audit(v_admin, 'RESET_ATTEMPT', p_roll);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_grade_coding(p_token uuid, p_roll text, p_question_id int, p_marks numeric)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts; v_max numeric;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  select marks into v_max from quiz.questions where id = p_question_id and kind = 'coding';
  if v_max is null then raise exception 'NOT_A_CODING_QUESTION'; end if;
  if p_marks < 0 or p_marks > v_max then raise exception 'MARKS_OUT_OF_RANGE'; end if;

  insert into quiz.answers (attempt_id, question_id, coding_marks)
  values (v_att.id, p_question_id, p_marks)
  on conflict (attempt_id, question_id) do update set coding_marks = excluded.coding_marks;

  perform quiz.recompute_scores(v_att.id);
  perform quiz.audit(v_admin, 'GRADE_CODING', p_roll,
                     json_build_object('question_id', p_question_id, 'marks', p_marks)::jsonb);
  return json_build_object('ok', true);
end $$;

-- ---------- coding auto-grade (admin re-runs the student's code, sends which tests passed) ----------
-- Marks are computed HERE from the test points, not taken from the caller.
create or replace function public.admin_save_auto_grade(p_token uuid, p_roll text, p_question_id int,
                                                        p_passed_ids int[], p_report jsonb)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin text := quiz.admin_from_token(p_token);
  v_att quiz.attempts; v_max numeric; v_total numeric; v_got numeric; v_marks numeric; v_n int;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  select marks into v_max from quiz.questions where id = p_question_id and kind = 'coding';
  if v_max is null then raise exception 'NOT_A_CODING_QUESTION'; end if;

  select coalesce(sum(points), 0), count(*) into v_total, v_n
    from quiz.question_tests where question_id = p_question_id;
  select coalesce(sum(points), 0) into v_got
    from quiz.question_tests where question_id = p_question_id and id = any (coalesce(p_passed_ids, '{}'));

  v_marks := case when v_total > 0 then round(v_max * v_got / v_total, 2) else 0 end;

  insert into quiz.answers (attempt_id, question_id, coding_marks, auto_passed, auto_total, auto_report, graded_by)
  values (v_att.id, p_question_id, v_marks, coalesce(array_length(p_passed_ids, 1), 0), v_n, p_report, v_admin)
  on conflict (attempt_id, question_id) do update
    set coding_marks = excluded.coding_marks, auto_passed = excluded.auto_passed,
        auto_total = excluded.auto_total, auto_report = excluded.auto_report,
        graded_by = excluded.graded_by;

  perform quiz.recompute_scores(v_att.id);
  return json_build_object('ok', true, 'marks', v_marks,
                           'passed', coalesce(array_length(p_passed_ids, 1), 0), 'total', v_n);
end $$;

-- Everything needed to grade every pending coding answer in one call.
create or replace function public.admin_pending_coding(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
      'roll_no', at.roll_no, 'question_id', q.id, 'title', q.title, 'marks', q.marks,
      'language', a.language, 'code', a.code,
      'tests', (select coalesce(json_agg(json_build_object('id', t.id, 'stdin', t.stdin,
                        'expected_output', t.expected_output) order by t.ord), '[]'::json)
                  from quiz.question_tests t where t.question_id = q.id))
      order by at.roll_no, q.id)
    from quiz.attempts at
    join quiz.answers a on a.attempt_id = at.id
    join quiz.questions q on q.id = a.question_id and q.kind = 'coding'
   where at.status in ('submitted', 'blocked')
     and length(coalesce(a.code, '')) > 0
     and a.graded_by is null
     and exists (select 1 from quiz.question_tests t where t.question_id = q.id)
  ), '[]'::json);
end $$;

-- Flat export of every stored answer — the permanent record.
create or replace function public.admin_export_answers(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  perform quiz.audit(v_admin, 'EXPORT_ANSWERS', null);
  return coalesce((
    select json_agg(json_build_object(
      'roll_no', s.roll_no, 'full_name', s.full_name,
      'batch', (select b.name from quiz.batches b where b.id = s.batch_id),
      'status', at.status, 'submitted_at', at.submitted_at,
      'question_id', q.id, 'kind', q.kind, 'title', q.title, 'marks', q.marks,
      'chosen', case when q.kind = 'mcq' then q.options ->> a.selected_index end,
      'correct', case when q.kind = 'mcq' then q.options ->> q.correct_index end,
      'is_correct', case when q.kind = 'mcq' then (a.selected_index = q.correct_index) end,
      'code', a.code, 'language', a.language,
      'tests_passed', a.auto_passed, 'tests_total', a.auto_total,
      'awarded', case when q.kind = 'mcq' then (case when a.selected_index = q.correct_index then q.marks else 0 end)
                      else a.coding_marks end,
      'graded_by', a.graded_by)
      order by s.roll_no, q.id)
    from quiz.students s
    join quiz.attempts at on at.roll_no = s.roll_no
    join quiz.answers a on a.attempt_id = at.id
    join quiz.questions q on q.id = a.question_id
  ), '[]'::json);
end $$;

-- ---------- chat ----------
create or replace function public.admin_get_messages(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v json;
begin
  update quiz.messages set read_by_admin = true
   where roll_no = p_roll and sender = 'student' and not read_by_admin;
  select coalesce(json_agg(json_build_object('id', id, 'sender', sender, 'sender_name', sender_name,
           'body', body, 'created_at', created_at) order by id), '[]'::json)
    into v from quiz.messages where roll_no = p_roll;
  return v;
end $$;

-- Take a thread off a colleague (or pick up an unassigned one).
create or replace function public.admin_claim_thread(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  if not exists (select 1 from quiz.students where roll_no = p_roll) then raise exception 'NO_SUCH_STUDENT'; end if;
  insert into quiz.threads (roll_no) values (p_roll) on conflict (roll_no) do nothing;
  update quiz.threads
     set assigned_to = v_admin, assigned_at = now(), resolved = false, updated_at = now()
   where roll_no = p_roll;
  perform quiz.audit(v_admin, 'CLAIM_THREAD', p_roll);
  return json_build_object('ok', true, 'assigned_to', v_admin);
end $$;

-- Done with this student: frees the proctor's capacity so new queries route elsewhere.
create or replace function public.admin_resolve_thread(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  update quiz.threads set resolved = true, updated_at = now() where roll_no = p_roll;
  update quiz.messages set read_by_admin = true
   where roll_no = p_roll and sender = 'student' and not read_by_admin;
  perform quiz.audit(v_admin, 'RESOLVE_THREAD', p_roll);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_send_message(p_token uuid, p_roll text, p_body text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  if length(trim(coalesce(p_body, ''))) = 0 then raise exception 'EMPTY_MESSAGE'; end if;
  if not exists (select 1 from quiz.students where roll_no = p_roll) then raise exception 'NO_SUCH_STUDENT'; end if;
  insert into quiz.messages (roll_no, sender, sender_name, body, read_by_admin)
  values (p_roll, 'admin', v_admin, left(trim(p_body), 2000), true);
  return json_build_object('ok', true);
end $$;

-- Broadcast to every student (e.g. "Q5 has a typo").
create or replace function public.admin_broadcast(p_token uuid, p_body text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_n int;
begin
  if length(trim(coalesce(p_body, ''))) = 0 then raise exception 'EMPTY_MESSAGE'; end if;
  insert into quiz.messages (roll_no, sender, sender_name, body, read_by_admin)
  select roll_no, 'admin', v_admin || ' (broadcast)', left(trim(p_body), 2000), true from quiz.students;
  get diagnostics v_n = row_count;
  perform quiz.audit(v_admin, 'BROADCAST', null, json_build_object('recipients', v_n)::jsonb);
  return json_build_object('ok', true, 'recipients', v_n);
end $$;

-- ---------- settings ----------
drop function if exists public.admin_update_config(uuid, boolean, int, text);
drop function if exists public.admin_update_config(uuid, boolean, int, text, int, int);
drop function if exists public.admin_update_config(uuid, boolean, int, text, int, int, boolean);
drop function if exists public.admin_update_config(uuid, boolean, int, text, int, int, boolean, int);
drop function if exists public.admin_update_config(uuid, boolean, int, text, int, int, boolean, int, boolean);
create or replace function public.admin_update_config(p_token uuid, p_exam_open boolean,
                                                      p_duration_minutes int, p_exam_title text,
                                                      p_mcq_count int default null,
                                                      p_coding_count int default null,
                                                      p_require_mic boolean default null,
                                                      p_max_concurrent int default null,
                                                      p_require_camera boolean default null,
                                                      p_detect_phone boolean default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  update quiz.config set
    exam_open        = coalesce(p_exam_open, exam_open),
    duration_minutes = coalesce(p_duration_minutes, duration_minutes),
    exam_title       = coalesce(nullif(trim(p_exam_title), ''), exam_title),
    mcq_count        = coalesce(p_mcq_count, mcq_count),
    coding_count     = greatest(coalesce(p_coding_count, coding_count), 0),  -- 0 = MCQ-only exam
    require_mic      = coalesce(p_require_mic, require_mic),
    max_concurrent   = greatest(coalesce(p_max_concurrent, max_concurrent), 1),
    require_camera   = coalesce(p_require_camera, require_camera),
    detect_phone     = coalesce(p_detect_phone, detect_phone)
  where id = 1;
  perform quiz.audit(v_admin, 'UPDATE_CONFIG', null, json_build_object(
    'exam_open', p_exam_open, 'duration_minutes', p_duration_minutes)::jsonb);
  return (select row_to_json(c) from quiz.config c where id = 1);
end $$;

-- ---------- batches ----------
create or replace function public.admin_create_batch(p_token uuid, p_name text,
                                                     p_duration_minutes int default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_b quiz.batches;
begin
  if length(trim(coalesce(p_name, ''))) = 0 then raise exception 'EMPTY_NAME'; end if;
  insert into quiz.batches (name, is_open, duration_minutes)
  values (trim(p_name), false, p_duration_minutes)
  on conflict (name) do nothing
  returning * into v_b;
  if v_b.id is null then raise exception 'BATCH_EXISTS'; end if;
  perform quiz.audit(v_admin, 'CREATE_BATCH', v_b.name);
  return row_to_json(v_b);
end $$;

-- Opening a batch is what lets its students press Start.
-- Closing stops new starts; students already writing are NOT interrupted.
create or replace function public.admin_set_batch_open(p_token uuid, p_batch_id int, p_open boolean)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_b quiz.batches;
begin
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

drop function if exists public.admin_update_batch(uuid, int, text, int);
create or replace function public.admin_update_batch(p_token uuid, p_batch_id int,
                                                     p_name text default null,
                                                     p_duration_minutes int default null,
                                                     p_window_minutes int default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_b quiz.batches;
begin
  update quiz.batches
     set name = coalesce(nullif(trim(p_name), ''), name),
         duration_minutes = coalesce(p_duration_minutes, duration_minutes),
         window_minutes = coalesce(p_window_minutes, window_minutes),
         -- extending the window while the round is live pushes the closing time out
         closes_at = case when is_open and p_window_minutes is not null
                          then coalesce(opened_at, now()) + make_interval(mins => p_window_minutes)
                          else closes_at end
   where id = p_batch_id
  returning * into v_b;
  if v_b.id is null then raise exception 'NO_SUCH_BATCH'; end if;
  perform quiz.audit(v_admin, 'UPDATE_BATCH', v_b.name);
  return row_to_json(v_b);
end $$;

create or replace function public.admin_delete_batch(p_token uuid, p_batch_id int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_name text;
begin
  select name into v_name from quiz.batches where id = p_batch_id;
  if v_name is null then raise exception 'NO_SUCH_BATCH'; end if;
  if exists (select 1 from quiz.students where batch_id = p_batch_id) then raise exception 'BATCH_NOT_EMPTY'; end if;
  if (select count(*) from quiz.batches) <= 1 then raise exception 'LAST_BATCH'; end if;
  delete from quiz.batches where id = p_batch_id;
  perform quiz.audit(v_admin, 'DELETE_BATCH', v_name);
  return json_build_object('ok', true);
end $$;

-- p_rolls: ["1025030923", "1025030924", ...]
create or replace function public.admin_assign_batch(p_token uuid, p_rolls jsonb, p_batch_id int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_n int;
begin
  if not exists (select 1 from quiz.batches where id = p_batch_id) then raise exception 'NO_SUCH_BATCH'; end if;
  update quiz.students set batch_id = p_batch_id
   where roll_no in (select trim(value) from jsonb_array_elements_text(p_rolls));
  get diagnostics v_n = row_count;
  perform quiz.audit(v_admin, 'ASSIGN_BATCH', null,
                     json_build_object('batch_id', p_batch_id, 'count', v_n)::jsonb);
  return json_build_object('ok', true, 'count', v_n);
end $$;

-- ---------- registration allowlist ----------
-- p_rows: ["a@gmail.com", ...] or [{"email":"a@gmail.com","full_name":"X","roll_hint":"123"}, ...]
create or replace function public.admin_add_allowlist(p_token uuid, p_rows jsonb,
                                                      p_batch_id int default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_n int;
begin
  insert into quiz.allowlist (email, batch_id, full_name, roll_hint)
  select lower(trim(case when jsonb_typeof(r) = 'string' then r #>> '{}' else r ->> 'email' end)),
         p_batch_id,
         nullif(trim(coalesce(r ->> 'full_name', '')), ''),
         nullif(trim(coalesce(r ->> 'roll_hint', '')), '')
    from jsonb_array_elements(p_rows) r
   where position('@' in coalesce(case when jsonb_typeof(r) = 'string' then r #>> '{}' else r ->> 'email' end, '')) > 1
  on conflict (email) do update
    set batch_id  = coalesce(excluded.batch_id, quiz.allowlist.batch_id),
        full_name = coalesce(excluded.full_name, quiz.allowlist.full_name),
        roll_hint = coalesce(excluded.roll_hint, quiz.allowlist.roll_hint);
  get diagnostics v_n = row_count;
  perform quiz.audit(v_admin, 'ADD_ALLOWLIST', null,
                     json_build_object('count', v_n, 'batch_id', p_batch_id)::jsonb);
  return json_build_object('ok', true, 'count', v_n);
end $$;

create or replace function public.admin_list_allowlist(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
      'email', a.email, 'batch_id', a.batch_id,
      'batch_name', (select b.name from quiz.batches b where b.id = a.batch_id),
      'full_name', a.full_name, 'roll_hint', a.roll_hint,
      'claimed_by', a.claimed_by, 'created_at', a.created_at,
      'registered_name', (select s.full_name from quiz.students s where s.roll_no = a.claimed_by),
      'has_id', exists (select 1 from quiz.id_documents d where d.roll_no = a.claimed_by))
      order by a.claimed_by nulls first, a.email)
    from quiz.allowlist a), '[]'::json);
end $$;

create or replace function public.admin_remove_allowlist(p_token uuid, p_email text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_claimed text;
begin
  select claimed_by into v_claimed from quiz.allowlist where email = lower(trim(p_email));
  if v_claimed is not null then raise exception 'ALREADY_REGISTERED'; end if;
  delete from quiz.allowlist where email = lower(trim(p_email));
  perform quiz.audit(v_admin, 'REMOVE_ALLOWLIST', p_email);
  return json_build_object('ok', true);
end $$;

create or replace function public.admin_set_allowlist_batch(p_token uuid, p_emails jsonb, p_batch_id int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_n int;
begin
  update quiz.allowlist set batch_id = p_batch_id
   where email in (select lower(trim(value)) from jsonb_array_elements_text(p_emails));
  get diagnostics v_n = row_count;
  -- keep already-registered students in step with their allowlist entry
  update quiz.students s set batch_id = p_batch_id
    from quiz.allowlist a where a.claimed_by = s.roll_no and a.batch_id = p_batch_id;
  perform quiz.audit(v_admin, 'SET_ALLOWLIST_BATCH', null,
                     json_build_object('count', v_n, 'batch_id', p_batch_id)::jsonb);
  return json_build_object('ok', true, 'count', v_n);
end $$;

-- photo ID, fetched on demand (kept out of the dashboard payload)
create or replace function public.admin_get_id_document(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); d quiz.id_documents;
begin
  select * into d from quiz.id_documents where roll_no = p_roll;
  if d.roll_no is null then return json_build_object('found', false); end if;
  perform quiz.audit(v_admin, 'VIEW_ID', p_roll);
  return json_build_object('found', true, 'mime', d.mime, 'data_b64', d.data_b64,
                           'bytes', d.bytes, 'uploaded_at', d.uploaded_at);
end $$;

-- ---------- students: bulk add / update ----------
-- p_rows: [{"roll_no":"1025030923","password":"JAILEAD","full_name":"Name"}, ...]
drop function if exists public.admin_upsert_students(uuid, jsonb);
create or replace function public.admin_upsert_students(p_token uuid, p_rows jsonb,
                                                        p_batch_id int default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_n int; v_batch int;
begin
  v_batch := coalesce(p_batch_id, (select min(id) from quiz.batches));
  if v_batch is null then raise exception 'NO_BATCH'; end if;

  insert into quiz.students (roll_no, password_hash, full_name, email, batch_id)
  select trim(r->>'roll_no'), quiz.hash_password(r->>'password'),
         nullif(trim(r->>'full_name'), ''),
         lower(nullif(trim(r->>'email'), '')), v_batch
    from jsonb_array_elements(p_rows) r
   where length(trim(coalesce(r->>'roll_no', ''))) > 0 and length(coalesce(r->>'password', '')) > 0
  on conflict (roll_no) do update
    set password_hash = excluded.password_hash,
        full_name = coalesce(excluded.full_name, quiz.students.full_name),
        email     = coalesce(excluded.email, quiz.students.email),
        batch_id  = coalesce(p_batch_id, quiz.students.batch_id);
  get diagnostics v_n = row_count;
  perform quiz.audit(v_admin, 'UPSERT_STUDENTS', null,
                     json_build_object('count', v_n, 'batch_id', v_batch)::jsonb);
  return json_build_object('ok', true, 'count', v_n);
end $$;

-- ---------- question bank (read-only view for checking) ----------
create or replace function public.admin_list_questions(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  return coalesce((select json_agg(row_to_json(q) order by q.kind desc, q.id) from quiz.questions q), '[]'::json);
end $$;

-- =====================================================================
-- Permissions: the browser (anon role) may call ONLY the public functions.
-- =====================================================================
revoke all on all tables    in schema quiz from public;
revoke all on all sequences in schema quiz from public;
revoke execute on all functions in schema quiz from public;

do $$
declare f text;
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on all tables in schema quiz from anon, authenticated';
    for f in
      select p.oid::regprocedure::text from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in (
         'student_login','student_login_google','student_register','student_logout',
         'get_exam_state','start_attempt','save_mcq_answer',
         'save_code_answer','report_flag','submit_attempt','student_heartbeat',
         'student_send_message','student_get_messages',
         'admin_login','admin_logout','admin_overview','admin_student_detail','admin_unblock',
         'admin_extend_time','admin_force_submit','admin_reset_attempt','admin_grade_coding',
         'admin_get_messages','admin_send_message','admin_broadcast','admin_update_config',
         'admin_upsert_students','admin_list_questions',
         'admin_create_batch','admin_set_batch_open','admin_update_batch','admin_delete_batch',
         'admin_assign_batch','admin_save_auto_grade','admin_pending_coding','admin_export_answers',
         'admin_live','admin_resolve_flags','student_report_detection','student_accept_consent',
         'admin_review_queue','admin_review_image','admin_decide_detection',
         'admin_force_submit_batch','admin_pause_attempt','admin_resume_attempt',
         'admin_ban_student','admin_unban_student',
         'admin_claim_thread','admin_resolve_thread','admin_add_allowlist','admin_list_allowlist',
         'admin_remove_allowlist','admin_set_allowlist_batch','admin_get_id_document','admin_roster')
    loop
      execute format('grant execute on function %s to anon, authenticated', f);
    end loop;
  end if;
end $$;
