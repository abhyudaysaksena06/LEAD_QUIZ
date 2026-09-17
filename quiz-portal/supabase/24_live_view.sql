-- =====================================================================
-- LEAD Quiz Portal — 24: proctor live view (one student at a time)
--
-- A proctor picks one student and sees their camera at about one frame per
-- second. Nothing is recorded: the student's browser overwrites a single
-- frame in place, only while a proctor is actually watching, and the row is
-- deleted when the proctor stops or leaves.
--
-- Frames go through the database rather than peer-to-peer video because it
-- works on every home network and firewall with no extra server; the cost is
-- about one frame a second instead of smooth video.
-- Safe to re-run.
-- =====================================================================

create table if not exists quiz.live_watch (
  roll_no      text primary key references quiz.students (roll_no) on delete cascade,
  watcher      text not null,
  requested_at timestamptz not null default now(),
  mime         text,
  frame        text,
  frame_at     timestamptz
);
create index if not exists live_watch_watcher_idx on quiz.live_watch (watcher);
revoke all on quiz.live_watch from public;

-- proctor: start watching this student (stops whoever you were watching before)
create or replace function public.admin_watch_start(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  if not exists (select 1 from quiz.students where roll_no = p_roll) then
    raise exception 'NO_SUCH_STUDENT';
  end if;
  delete from quiz.live_watch where watcher = v_admin and roll_no <> p_roll;
  insert into quiz.live_watch (roll_no, watcher, requested_at)
  values (p_roll, v_admin, now())
  on conflict (roll_no) do update
    set watcher = excluded.watcher, requested_at = now();
  perform quiz.audit(v_admin, 'WATCH_LIVE', p_roll);
  return json_build_object('ok', true);
end $$;

-- proctor: fetch the latest frame (also keeps the view alive)
create or replace function public.admin_watch_frame(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); w quiz.live_watch;
begin
  update quiz.live_watch set requested_at = now()
   where roll_no = p_roll and watcher = v_admin
  returning * into w;
  if w.roll_no is null then
    return json_build_object('watching', false,
      'taken_by', (select watcher from quiz.live_watch where roll_no = p_roll));
  end if;
  return json_build_object('watching', true, 'server_now', now(),
    'mime', w.mime, 'frame', w.frame, 'frame_at', w.frame_at,
    'status', (select status from quiz.attempts where roll_no = p_roll));
end $$;

-- proctor: stop watching
create or replace function public.admin_watch_stop(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  delete from quiz.live_watch where watcher = v_admin;
  return json_build_object('ok', true);
end $$;

-- student: send one frame. Accepted only while someone is watching.
create or replace function public.student_live_frame(p_token uuid, p_mime text, p_b64 text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token);
begin
  if p_b64 is null or length(p_b64) > 90000 then
    return json_build_object('watching', true, 'skipped', 'size');
  end if;
  if coalesce(p_mime, '') not in ('image/webp', 'image/jpeg') then
    return json_build_object('watching', false);
  end if;
  update quiz.live_watch
     set frame = p_b64, mime = p_mime, frame_at = now()
   where roll_no = v_roll and requested_at > now() - interval '15 seconds';
  return json_build_object('watching', found);
end $$;

create or replace function public.student_heartbeat(p_token uuid, p_device text default null,
                                                    p_camera_ok boolean default null,
                                                    p_camera_note text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token); v_att quiz.attempts; v_unread int;
        v_device text;
begin
  select * into v_att from quiz.attempts where roll_no = v_roll;

  -- Device lock applies only while the test is live. Before it starts, the same
  -- account may be open on several devices; during it, a token appearing from a
  -- second browser kills the session (returns rather than raises, so it commits).
  if v_att.status in ('in_progress', 'paused') then
    select device into v_device from quiz.sessions where token = p_token;
    if v_device is not null and p_device is not null and v_device <> p_device then
      update quiz.sessions set revoked = true where token = p_token;
      return json_build_object('ok', false, 'code', 'SESSION_TAKEN');
    end if;
    if v_device is null and p_device is not null then
      update quiz.sessions set device = p_device where token = p_token;
    end if;
  end if;

  select * into v_att from quiz.attempts where roll_no = v_roll;
  if v_att.id is not null then
    perform quiz.expire_if_needed(v_att.id);
    select * into v_att from quiz.attempts where id = v_att.id;
  end if;
  if v_att.id is not null and p_camera_ok is not null then
    update quiz.attempts set camera_ok = p_camera_ok, camera_note = left(p_camera_note, 120)
     where id = v_att.id;
  end if;

  select count(*) into v_unread from quiz.messages
   where roll_no = v_roll and sender = 'admin' and not read_by_student;
  return json_build_object('server_now', now(), 'status', v_att.status,
    'deadline_at', v_att.deadline_at, 'flag_count', v_att.flag_count, 'unread', v_unread,
    -- a proctor has this student open in the live view: start sending frames
    'watch', exists (select 1 from quiz.live_watch w
                      where w.roll_no = v_roll and w.requested_at > now() - interval '15 seconds'));
end $$;

grant execute on function public.admin_watch_start(uuid, text)        to anon, authenticated;
grant execute on function public.admin_watch_frame(uuid, text)        to anon, authenticated;
grant execute on function public.admin_watch_stop(uuid)               to anon, authenticated;
grant execute on function public.student_live_frame(uuid, text, text) to anon, authenticated;
