-- =====================================================================
-- LEAD Quiz Portal — 25: headroom for 400+ candidates at once
--
-- 1. Housekeeping (ending expired papers, handing over chats, expiring old
--    camera items) used to run on EVERY proctor refresh — five proctors
--    polling two screens every 5 seconds ran it about twice a second. It now
--    runs at most once every 10 seconds, and never twice at the same moment.
--    pg_cron still sweeps every minute, and a student's own heartbeat ends
--    their paper the moment their time is used, so nothing waits longer.
-- 2. "Last seen" was written to the students table on every click and
--    heartbeat. It is now written at most every 10 seconds per student.
-- 3. Student Live can load a single round instead of everyone.
-- 4. Capacity ceiling raised to 1000 simultaneous papers.
-- 5. Stale live-view rows are cleaned up.
-- Safe to re-run. No existing data is changed.
-- =====================================================================

alter table quiz.config add column if not exists housekeeping_at timestamptz;

create or replace function quiz.housekeeping()
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  -- one caller at a time; everyone else just carries on
  if not pg_try_advisory_xact_lock(hashtext('lead-quiz-housekeeping')) then return; end if;
  update quiz.config set housekeeping_at = now()
   where id = 1 and (housekeeping_at is null or housekeeping_at < now() - interval '10 seconds');
  if not found then return; end if;

  perform quiz.sweep_expired();
  perform quiz.rebalance_threads();
  perform quiz.expire_detections();
  delete from quiz.live_watch where requested_at < now() - interval '2 minutes';
end $$;

create or replace function quiz.student_from_token(p_token uuid)
returns text language plpgsql security definer set search_path = quiz, public as $$
declare v text;
begin
  select subject into v from quiz.sessions
   where token = p_token and kind = 'student' and not revoked and expires_at > now();
  if v is null then raise exception 'SESSION_INVALID'; end if;
  -- presence, written at most every 10 seconds instead of on every click
  update quiz.students set last_seen_at = now()
   where roll_no = v and (last_seen_at is null or last_seen_at < now() - interval '10 seconds');
  return v;
end $$;

drop function if exists public.admin_live(uuid);
create or replace function public.admin_live(p_token uuid, p_batch_id int default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_rows json;
begin
  perform quiz.housekeeping();

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
           th.assigned_to, coalesce(th.resolved, true) as thread_resolved,
           (select w.watcher from quiz.live_watch w where w.roll_no = s.roll_no
               and w.requested_at > now() - interval '15 seconds') as watched_by
      from quiz.students s
      left join quiz.attempts a on a.roll_no = s.roll_no
      left join quiz.batches  b on b.id = s.batch_id
      left join quiz.threads  th on th.roll_no = s.roll_no
      left join fl on fl.roll_no = s.roll_no
      left join msg on msg.roll_no = s.roll_no
      left join det on det.roll_no = s.roll_no
     where p_batch_id is null or s.batch_id = p_batch_id
  ) x;

  return json_build_object('server_now', now(), 'me', v_admin, 'students', v_rows);
end $$;

create or replace function public.admin_overview(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_cfg quiz.config; v_rows json;
begin
  -- timers, chat hand-over and old camera items, at most once every 10 seconds
  perform quiz.housekeeping();

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

grant execute on function public.admin_live(uuid, int) to anon, authenticated;
grant execute on function public.admin_overview(uuid)  to anon, authenticated;

create index if not exists attempts_status_idx     on quiz.attempts (status);
create index if not exists detections_roll_pending on quiz.detections (roll_no) where status = 'pending';

alter table quiz.config alter column max_concurrent set default 1000;
update quiz.config set max_concurrent = greatest(max_concurrent, 1000) where id = 1;
