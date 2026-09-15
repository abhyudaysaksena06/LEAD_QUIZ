-- =====================================================================
-- LEAD Quiz Portal — MASTER SETUP
--
-- Paste this ONE file into the Supabase SQL Editor and run it.
--   1. schema, student API, admin API          (01 + 02 + 03)
--   2. admin account + placeholder questions   (04)
--   3. five proctor logins                     (08)
--   4. the four rounds                         (09)
--   5. 12 sample test students, 3 per round    (10)
--
-- Safe to re-run. Existing students, answers and chats are kept.
-- Re-running RESETS the TEST* accounts so you can rehearse repeatedly.
-- Afterwards run 11_test_access.sql for your own Google/USER/ADMIN logins.
-- =====================================================================


-- ##############################  01_schema.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 01: schema
-- Run in Supabase SQL Editor, in order: 01 → 02 → 03 → 04
--
-- Security model:
--   * All tables live in the private schema "quiz", which is NOT exposed
--     through the Supabase API. The browser cannot read or write them.
--   * The browser can only call the functions in 02/03 (public schema),
--     which validate a session token and never return answer keys.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create schema if not exists quiz;
revoke all on schema quiz from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema quiz from anon, authenticated';
  end if;
end $$;

-- ---------- exam configuration (single row) ----------
create table if not exists quiz.config (
  id               int primary key default 1 check (id = 1),
  exam_title       text    not null default 'LEAD Quiz',
  duration_minutes int     not null default 15 check (duration_minutes between 1 and 600),
  mcq_count        int     not null default 17,
  coding_count     int     not null default 3,
  max_flags        int     not null default 3,
  exam_open        boolean not null default true
);
insert into quiz.config (id) values (1) on conflict do nothing;

-- Require microphone permission before starting. Permission only: no audio is
-- recorded, transmitted or stored anywhere in this system.
alter table quiz.config add column if not exists require_mic boolean not null default true;

-- hard cap on how many students may be sitting the test at the same moment
alter table quiz.config add column if not exists max_concurrent int not null default 200;

-- camera monitoring: permission required to start, detections go to a human for review
alter table quiz.config add column if not exists require_camera boolean not null default true;

-- Phone detection is the least reliable signal (small object, often out of frame).
-- Turn it off to leave only person-count monitoring, which is far more dependable.
alter table quiz.config add column if not exists detect_phone boolean not null default true;

-- ---------- batches ----------
-- A student can only START when their batch is open. Opening a batch is how you
-- "start the quiz" for that group. Closing it stops new starts but never
-- interrupts students already writing.
create table if not exists quiz.batches (
  id               serial primary key,
  name             text not null unique,
  is_open          boolean not null default false,
  duration_minutes int,                      -- null = use quiz.config.duration_minutes
  opened_at        timestamptz,
  created_at       timestamptz not null default now()
);

-- The round stays open for window_minutes (default 30) while each student gets their own
-- duration (default 15) to answer. When the window closes EVERY attempt still open —
-- including paused ones — is submitted.
alter table quiz.batches add column if not exists window_minutes int not null default 30;
alter table quiz.batches add column if not exists closes_at timestamptz;

-- ---------- people ----------
create table if not exists quiz.students (
  roll_no       text primary key,
  password_hash text not null,
  full_name     text,
  created_at    timestamptz not null default now()
);

-- added after the fact: safe on databases created before batches existed
alter table quiz.students add column if not exists batch_id int references quiz.batches (id);
create index if not exists students_batch_idx on quiz.students (batch_id);

-- presence: refreshed by every student API call, so proctors can see who is live
alter table quiz.students add column if not exists last_seen_at timestamptz;

-- consent must be recorded before a student can start (see student_accept_consent)
alter table quiz.students add column if not exists consented_at timestamptz;
alter table quiz.students add column if not exists consent_version text;

-- a banned student cannot sign in at all, by any method
alter table quiz.students add column if not exists banned boolean not null default false;
alter table quiz.students add column if not exists banned_reason text;
alter table quiz.students add column if not exists banned_at timestamptz;

-- Google sign-in allowlist: only an address stored here can sign in with Google.
alter table quiz.students add column if not exists email text;
create unique index if not exists students_email_uidx
  on quiz.students (lower(email)) where email is not null;

-- ensure one default batch exists, and no student is left unassigned
insert into quiz.batches (name, is_open)
select 'Batch 1', true where not exists (select 1 from quiz.batches);

update quiz.students set batch_id = (select min(id) from quiz.batches) where batch_id is null;

-- Any student inserted without a batch (seed files, hand-written SQL, imports) lands in the
-- first batch rather than being unable to start at all.
create or replace function quiz.default_batch() returns trigger
language plpgsql security definer set search_path = quiz, public as $$
begin
  if new.batch_id is null then new.batch_id := (select min(id) from quiz.batches); end if;
  return new;
end $$;

drop trigger if exists students_default_batch on quiz.students;
create trigger students_default_batch before insert on quiz.students
  for each row execute function quiz.default_batch();

-- ---------- registration allowlist ----------
-- Admins add the Gmail addresses that are allowed to sit the test. A student row is
-- created only once the student signs in with Google and completes registration
-- (name + roll number + photo ID), which is why this is separate from quiz.students.
create table if not exists quiz.allowlist (
  email      text primary key,                         -- stored lowercased
  batch_id   int references quiz.batches (id),
  full_name  text,                                     -- optional hint from your sheet
  roll_hint  text,
  claimed_by text references quiz.students (roll_no) on delete set null,
  created_at timestamptz not null default now()
);

-- ---------- uploaded photo ID ----------
create table if not exists quiz.id_documents (
  roll_no     text primary key references quiz.students (roll_no) on delete cascade,
  mime        text not null,
  data_b64    text not null,
  bytes       int,
  uploaded_at timestamptz not null default now()
);

-- WebP at ~900px is 40-80 KB for a readable ID card. Cap well under that ceiling so a
-- crafted request can't fill the database, and only allow real image types.
alter table quiz.id_documents drop constraint if exists id_documents_data_b64_check;
alter table quiz.id_documents add constraint id_documents_data_b64_check
  check (length(data_b64) between 100 and 900000);          -- ~675 KB of image
alter table quiz.id_documents drop constraint if exists id_documents_mime_check;
alter table quiz.id_documents add constraint id_documents_mime_check
  check (mime in ('image/webp', 'image/jpeg', 'image/png'));

create table if not exists quiz.admins (
  username      text primary key,
  password_hash text not null,
  display_name  text,
  created_at    timestamptz not null default now()
);

-- presence: refreshed on every admin API call, used to share chat load fairly
alter table quiz.admins add column if not exists last_seen_at timestamptz;

-- one chat thread per student, owned by whichever admin it is assigned to
create table if not exists quiz.threads (
  roll_no     text primary key references quiz.students (roll_no) on delete cascade,
  assigned_to text references quiz.admins (username) on delete set null,
  assigned_at timestamptz,
  resolved    boolean not null default false,
  updated_at  timestamptz not null default now()
);
create index if not exists threads_assigned_idx on quiz.threads (assigned_to) where not resolved;

create table if not exists quiz.sessions (
  token      uuid primary key default gen_random_uuid(),
  kind       text not null check (kind in ('student', 'admin')),
  subject    text not null,               -- roll_no or admin username
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked    boolean not null default false
);
create index if not exists sessions_subject_idx on quiz.sessions (kind, subject);

-- the browser that signed in; a second browser reusing this token is kicked out
alter table quiz.sessions add column if not exists device text;

-- failed sign-ins, for throttling
create table if not exists quiz.login_failures (
  id        bigserial primary key,
  subject   text not null,
  failed_at timestamptz not null default now()
);
create index if not exists login_failures_idx on quiz.login_failures (subject, failed_at);

-- ---------- question bank ----------
create table if not exists quiz.questions (
  id            serial primary key,
  kind          text not null check (kind in ('mcq', 'coding')),
  title         text,
  body          text not null,
  options       jsonb,                    -- mcq: ["A text","B text",...]
  correct_index int,                      -- mcq: 0-based index into options. NEVER sent to students.
  marks         numeric not null default 1,
  starter_code  text,                     -- coding: optional template
  language      text default 'python',    -- coding: default language
  active        boolean not null default true,
  created_at    timestamptz not null default now(),
  constraint mcq_shape check (
    kind <> 'mcq' or (
      jsonb_typeof(options) = 'array'
      and jsonb_array_length(options) >= 2
      and correct_index >= 0
      and correct_index < jsonb_array_length(options)
    )
  )
);

-- ---------- coding test cases (output comparison) ----------
-- is_sample = true  -> shown to the student, they can run it themselves
-- is_sample = false -> HIDDEN. Expected output is never sent to a student.
create table if not exists quiz.question_tests (
  id              serial primary key,
  question_id     int not null references quiz.questions (id) on delete cascade,
  ord             int not null default 1,
  stdin           text not null default '',
  expected_output text not null,
  is_sample       boolean not null default false,
  points          numeric not null default 1
);
create index if not exists question_tests_q_idx on quiz.question_tests (question_id, ord);

-- ---------- attempts (one per student) ----------
create table if not exists quiz.attempts (
  id             uuid primary key default gen_random_uuid(),
  roll_no        text not null unique references quiz.students (roll_no) on delete cascade,
  status         text not null default 'in_progress'
                 check (status in ('in_progress', 'submitted', 'blocked')),
  question_ids   int[] not null,          -- this student's random paper, in order
  started_at     timestamptz not null default now(),
  deadline_at    timestamptz not null,    -- individual timer; server is the authority
  submitted_at   timestamptz,
  submit_reason  text,                    -- MANUAL | TIME_UP | FLAG_LIMIT | ADMIN
  flag_count     int not null default 0,
  mcq_score      numeric,
  coding_score   numeric,
  total_score    numeric,
  unblock_count  int not null default 0
);

-- paused = clock frozen by a proctor; banned = disqualified
alter table quiz.attempts add column if not exists paused_at timestamptz;

-- camera health, reported on every heartbeat, so proctors can see a camera that has
-- been switched off, denied, or whose detector failed to load
alter table quiz.attempts add column if not exists camera_ok boolean;
alter table quiz.attempts add column if not exists camera_note text;
alter table quiz.attempts drop constraint if exists attempts_status_check;
alter table quiz.attempts add constraint attempts_status_check
  check (status in ('in_progress', 'submitted', 'blocked', 'paused', 'banned'));

create table if not exists quiz.answers (
  attempt_id     uuid not null references quiz.attempts (id) on delete cascade,
  question_id    int  not null references quiz.questions (id),
  selected_index int,                     -- mcq: original (unshuffled) option index
  code           text,                    -- coding
  language       text,
  revision       int not null default 0,  -- stale retries can never overwrite newer work
  coding_marks   numeric,                 -- set by an admin when grading
  updated_at     timestamptz not null default now(),
  primary key (attempt_id, question_id)
);

-- results of re-running a student's code against the test cases (graded by an admin)
alter table quiz.answers add column if not exists auto_passed int;
alter table quiz.answers add column if not exists auto_total  int;
alter table quiz.answers add column if not exists auto_report jsonb;
alter table quiz.answers add column if not exists graded_by   text;

create table if not exists quiz.flags (
  id         bigserial primary key,
  attempt_id uuid not null references quiz.attempts (id) on delete cascade,
  kind       text not null,
  detail     text,
  counted    boolean not null default false,  -- did this one count toward max_flags?
  created_at timestamptz not null default now()
);
create index if not exists flags_attempt_idx on quiz.flags (attempt_id, created_at);

-- a proctor can clear a violation; once resolved it disappears for EVERY admin
alter table quiz.flags add column if not exists resolved boolean not null default false;
alter table quiz.flags add column if not exists resolved_by text;
alter table quiz.flags add column if not exists resolved_at timestamptz;
create index if not exists flags_open_idx on quiz.flags (attempt_id) where not resolved;

-- ---------- camera review queue ----------
-- A snapshot is held here ONLY until a proctor looks at it. The image is deleted the
-- moment it is approved or dismissed, and anything unreviewed is purged after 30 minutes.
-- Nothing is archived and no image is ever attached to a student's permanent record.
create table if not exists quiz.detections (
  id          bigserial primary key,
  roll_no     text not null references quiz.students (roll_no) on delete cascade,
  attempt_id  uuid references quiz.attempts (id) on delete cascade,
  kind        text not null,                 -- PHONE_DETECTED | MULTIPLE_PEOPLE | NO_PERSON
  detail      jsonb,                         -- what the detector saw, with confidences
  image_b64   text check (image_b64 is null or length(image_b64) between 100 and 500000),
  mime        text not null default 'image/webp',
  status      text not null default 'pending'
              check (status in ('pending', 'approved', 'dismissed', 'expired')),
  created_at  timestamptz not null default now(),
  reviewed_by text,
  reviewed_at timestamptz
);
create index if not exists detections_pending_idx on quiz.detections (created_at) where status = 'pending';
alter table quiz.detections enable row level security;

-- ---------- chat ----------
create table if not exists quiz.messages (
  id              bigserial primary key,
  roll_no         text not null references quiz.students (roll_no) on delete cascade,
  sender          text not null check (sender in ('student', 'admin')),
  sender_name     text,
  body            text not null check (length(body) between 1 and 2000),
  read_by_admin   boolean not null default false,
  read_by_student boolean not null default false,
  created_at      timestamptz not null default now()
);
create index if not exists messages_roll_idx on quiz.messages (roll_no, id);

-- ---------- audit ----------
create table if not exists quiz.audit_log (
  id         bigserial primary key,
  actor      text not null,
  action     text not null,
  target     text,
  detail     jsonb,
  created_at timestamptz not null default now()
);

-- Belt and braces: RLS on, no policies. Even if the schema were ever exposed,
-- anon/authenticated would get nothing.
alter table quiz.config    enable row level security;
alter table quiz.batches   enable row level security;
alter table quiz.students  enable row level security;
alter table quiz.admins    enable row level security;
alter table quiz.threads   enable row level security;
alter table quiz.allowlist enable row level security;
alter table quiz.id_documents enable row level security;
alter table quiz.sessions  enable row level security;
alter table quiz.questions enable row level security;
alter table quiz.question_tests enable row level security;
alter table quiz.attempts  enable row level security;
alter table quiz.answers   enable row level security;
alter table quiz.flags     enable row level security;
alter table quiz.messages  enable row level security;
alter table quiz.audit_log enable row level security;

-- =====================================================================
-- Internal helpers (schema quiz — not callable from the browser)
-- =====================================================================

create or replace function quiz.student_from_token(p_token uuid)
returns text language plpgsql security definer set search_path = quiz, public as $$
declare v text;
begin
  select subject into v from quiz.sessions
   where token = p_token and kind = 'student' and not revoked and expires_at > now();
  if v is null then raise exception 'SESSION_INVALID'; end if;
  update quiz.students set last_seen_at = now() where roll_no = v;   -- presence
  return v;
end $$;

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

-- An admin counts as "active" while their portal is polling (it refreshes every 5s).
create or replace function quiz.admin_is_active(p_username text)
returns boolean language sql stable security definer set search_path = quiz, public as $$
  select exists (select 1 from quiz.admins
                  where username = p_username and last_seen_at > now() - interval '45 seconds');
$$;

-- Give the thread to the ACTIVE admin with the fewest open threads.
-- Keeps the current owner while they stay active, so a conversation isn't handed around.
create or replace function quiz.assign_thread(p_roll text)
returns text language plpgsql security definer set search_path = quiz, public as $$
declare v_cur text; v_admin text;
begin
  insert into quiz.threads (roll_no) values (p_roll) on conflict (roll_no) do nothing;
  select assigned_to into v_cur from quiz.threads where roll_no = p_roll;

  if v_cur is not null and quiz.admin_is_active(v_cur) then
    update quiz.threads set resolved = false, updated_at = now() where roll_no = p_roll;
    return v_cur;
  end if;

  select a.username into v_admin
    from quiz.admins a
   where a.last_seen_at > now() - interval '45 seconds'
   order by (select count(*) from quiz.threads t
              where t.assigned_to = a.username and not t.resolved) asc,
            a.last_seen_at desc
   limit 1;

  -- v_admin stays null when nobody is online; the thread shows as unassigned
  -- and is picked up automatically as soon as an admin appears.
  update quiz.threads
     set assigned_to = v_admin,
         assigned_at = case when v_admin is null then null else now() end,
         resolved = false, updated_at = now()
   where roll_no = p_roll;
  return v_admin;
end $$;

-- Reassign anything owned by an admin who has gone offline (closed laptop, lost wifi).
create or replace function quiz.rebalance_threads()
returns int language plpgsql security definer set search_path = quiz, public as $$
declare r record; n int := 0;
begin
  for r in
    select t.roll_no from quiz.threads t
     where not t.resolved
       and (t.assigned_to is null or not quiz.admin_is_active(t.assigned_to))
  loop
    perform quiz.assign_thread(r.roll_no);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Grade MCQs + sum coding marks. Safe to call repeatedly.
create or replace function quiz.recompute_scores(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
declare v_mcq numeric; v_cod numeric;
begin
  select coalesce(sum(q.marks), 0) into v_mcq
    from quiz.answers a join quiz.questions q on q.id = a.question_id
   where a.attempt_id = p_attempt and q.kind = 'mcq' and a.selected_index = q.correct_index;

  select coalesce(sum(a.coding_marks), 0) into v_cod
    from quiz.answers a join quiz.questions q on q.id = a.question_id
   where a.attempt_id = p_attempt and q.kind = 'coding';

  update quiz.attempts
     set mcq_score = v_mcq, coding_score = v_cod, total_score = v_mcq + v_cod
   where id = p_attempt;
end $$;

-- End an attempt. Answers are always kept and graded — never discarded.
create or replace function quiz.finalize_attempt(p_attempt uuid, p_status text, p_reason text)
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  update quiz.attempts
     set status = p_status, submitted_at = now(), submit_reason = p_reason
   where id = p_attempt and status = 'in_progress';
  perform quiz.recompute_scores(p_attempt);
end $$;

-- Server-side timer enforcement. The 5s grace only absorbs network latency for a save
-- that left the student's browser just before the deadline.
create or replace function quiz.expire_if_needed(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  if exists (select 1 from quiz.attempts
              where id = p_attempt and status = 'in_progress'
                and now() > deadline_at + interval '5 seconds') then
    perform quiz.finalize_attempt(p_attempt, 'submitted', 'TIME_UP');
  end if;
end $$;

-- Ends every attempt whose time is up, even if that student's browser is gone
-- (closed laptop, dead battery, no network). Run on a schedule; also called by the
-- admin dashboard so the sweep still happens if pg_cron is unavailable.
create or replace function quiz.sweep_expired()
returns int language plpgsql security definer set search_path = quiz, public as $$
declare r record; n int := 0;
begin
  -- 1. individual timers
  for r in select id from quiz.attempts
            where status = 'in_progress' and now() > deadline_at + interval '5 seconds'
  loop
    perform quiz.finalize_attempt(r.id, 'submitted', 'TIME_UP');
    n := n + 1;
  end loop;

  -- 2. the round window closing ends EVERYTHING still open, paused attempts included
  for r in
    select a.id from quiz.attempts a
      join quiz.students s on s.roll_no = a.roll_no
      join quiz.batches  b on b.id = s.batch_id
     where a.status in ('in_progress', 'paused')
       and b.closes_at is not null and now() > b.closes_at
  loop
    update quiz.attempts set status = 'in_progress', paused_at = null where id = r.id;
    perform quiz.finalize_attempt(r.id, 'submitted', 'ROUND_ENDED');
    n := n + 1;
  end loop;
  return n;
end $$;

-- Schedule it once a minute. Harmless if pg_cron isn't enabled on this project.
do $sched$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    begin perform cron.unschedule('lead-quiz-expire'); exception when others then null; end;
    perform cron.schedule('lead-quiz-expire', '* * * * *', 'select quiz.sweep_expired()');
  end if;
exception when others then
  raise notice 'pg_cron not scheduled (%). The admin dashboard sweep still ends expired attempts.', sqlerrm;
end $sched$;

create or replace function quiz.hash_password(p_plain text)
returns text language sql security definer set search_path = quiz, extensions, public as $$
  select extensions.crypt(p_plain, extensions.gen_salt('bf', 8));
$$;

create or replace function quiz.check_password(p_plain text, p_hash text)
returns boolean language sql security definer set search_path = quiz, extensions, public as $$
  select p_hash = extensions.crypt(p_plain, p_hash);
$$;


-- ##############################  02_student_api.sql  ##############################

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
    -- same rule as password sign-in: only one device once the test is under way
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
       'require_mic', v_cfg.require_mic, 'require_camera', v_cfg.require_camera,
       'detect_phone', v_cfg.detect_phone),
    'student', json_build_object('roll_no', v_student.roll_no, 'full_name', v_student.full_name,
                                 'consented', (v_student.consented_at is not null),
                                 'consented_at', v_student.consented_at),
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

  -- checked last, so a student whose round is closed gets that message instead
  if not exists (select 1 from quiz.students
                  where roll_no = v_roll and consented_at is not null) then
    raise exception 'CONSENT_REQUIRED';
  end if;

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

  -- The test is now live: close every other device this student left signed in.
  -- From here until they finish, this token is the only one that works.
  update quiz.sessions set revoked = true
   where kind = 'student' and subject = v_roll and not revoked and token <> p_token;

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
      -- Their paper is submitted, but the session stays alive: they land on the
      -- "locked" screen and can message a proctor straight away rather than
      -- having to sign in again.
      perform quiz.finalize_attempt(v_att.id, 'blocked', 'FLAG_LIMIT');
      select * into v_att from quiz.attempts where id = v_att.id;
    end if;
  end if;

  return json_build_object('status', v_att.status, 'flag_count', v_att.flag_count,
                           'max_flags', v_cfg.max_flags, 'counted', v_counted);
end $$;

-- ---------- consent ----------
-- Recorded once per student, with a timestamp and the version of the notice they saw,
-- so there is a defensible record of what they agreed to.
create or replace function public.student_accept_consent(p_token uuid, p_version text default 'v1')
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_roll text := quiz.student_from_token(p_token);
begin
  update quiz.students
     set consented_at = coalesce(consented_at, now()),
         consent_version = coalesce(consent_version, left(p_version, 40))
   where roll_no = v_roll;
  return (select json_build_object('ok', true, 'consented_at', consented_at,
                                   'consent_version', consent_version)
            from quiz.students where roll_no = v_roll);
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

  -- one item per student per kind per 30s, and never more than 5 waiting
  if exists (select 1 from quiz.detections
              where roll_no = v_roll and kind = p_kind and status = 'pending'
                and created_at > now() - interval '30 seconds') then
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
drop function if exists public.student_heartbeat(uuid, text);
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


-- ##############################  03_admin_api.sql  ##############################

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
         'admin_remove_allowlist','admin_set_allowlist_batch','admin_get_id_document')
    loop
      execute format('grant execute on function %s to anon, authenticated', f);
    end loop;
  end if;
end $$;


-- ##############################  04_seed.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 04: seed data
--   * test student   1025030923 / JAILEAD
--   * admin          admin / LEADADMIN        <-- CHANGE THIS before exam day
--   * placeholder question bank: 40 MCQ + 8 coding
--     (each student randomly gets 17 MCQ + 3 coding from this pool)
-- Safe to re-run.
-- =====================================================================

-- placeholder accounts always use 5-DIGIT roll numbers so they can never collide
-- with a real student's roll number
delete from quiz.students where roll_no = '1025030923';   -- retired earlier placeholder

insert into quiz.students (roll_no, password_hash, full_name)
values ('58204', quiz.hash_password('JAILEAD'), 'Seed Test Student')
on conflict (roll_no) do update set password_hash = excluded.password_hash;

insert into quiz.admins (username, password_hash, display_name)
values ('admin', quiz.hash_password('LEADADMIN'), 'Admin')
on conflict (username) do update set password_hash = excluded.password_hash;

-- ---------- placeholder questions (only inserted if the bank is empty) ----------
do $$
begin
  if not exists (select 1 from quiz.questions) then

    insert into quiz.questions (kind, title, body, options, correct_index, marks)
    select 'mcq',
           'Placeholder MCQ ' || n,
           'This is placeholder multiple-choice question #' || n ||
             '. The real question text will replace this. Which option is correct?',
           jsonb_build_array('Option A for Q' || n, 'Option B for Q' || n,
                             'Option C for Q' || n, 'Option D for Q' || n),
           (n % 4),
           1
      from generate_series(1, 40) as n;

    insert into quiz.questions (kind, title, body, starter_code, language, marks)
    select 'coding',
           'Placeholder coding problem ' || n,
           'Placeholder coding problem #' || n || E'.\n\n' ||
           E'Read an integer N from input and print the sum of the numbers from 1 to N.\n\n' ||
           E'Example input:\n5\n\nExample output:\n15',
           E'n = int(input())\n# write your solution below\n',
           'python',
           5
      from generate_series(1, 8) as n;

  end if;
end $$;

-- test cases for the placeholder coding questions ("print the sum 1..N")
-- ord 1 is a SAMPLE (students can run it); the rest are hidden.
insert into quiz.question_tests (question_id, ord, stdin, expected_output, is_sample, points)
select q.id, v.ord, v.stdin, v.expected, v.sample, 1
  from quiz.questions q
 cross join (values (1, '5', '15', true), (2, '10', '55', false), (3, '1', '1', false)) as v(ord, stdin, expected, sample)
 where q.kind = 'coding'
   and not exists (select 1 from quiz.question_tests t where t.question_id = q.id);


-- ##############################  08_proctors.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 08: five proctor logins
--
-- Creates one login per proctor station. Student chat queries are shared
-- automatically between whichever of these are signed in and active.
--
-- CHANGE THESE PASSWORDS before exam day. Safe to re-run (it resets them).
-- =====================================================================

insert into quiz.admins (username, password_hash, display_name) values
  ('proctor1', quiz.hash_password('LEAD-P1-2026'), 'Proctor 1'),
  ('proctor2', quiz.hash_password('LEAD-P2-2026'), 'Proctor 2'),
  ('proctor3', quiz.hash_password('LEAD-P3-2026'), 'Proctor 3'),
  ('proctor4', quiz.hash_password('LEAD-P4-2026'), 'Proctor 4'),
  ('proctor5', quiz.hash_password('LEAD-P5-2026'), 'Proctor 5')
on conflict (username) do update
  set password_hash = excluded.password_hash,
      display_name  = excluded.display_name;

-- change one password later:
-- update quiz.admins set password_hash = quiz.hash_password('NEW-PASSWORD') where username = 'proctor3';

-- add a sixth station:
-- insert into quiz.admins (username, password_hash, display_name)
-- values ('proctor6', quiz.hash_password('...'), 'Proctor 6');

select username, display_name, last_seen_at from quiz.admins order by username;


-- ##############################  09_rounds.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 09: the four rounds
--
--   Round 1, Round 2, Round 3   — ~60 students each
--   Round 4 (Backup)            — spare slot for anyone who missed their round,
--                                 had a technical problem, or needs a re-sit
--
-- All four start CLOSED with a 30-minute window; each student gets their own
-- 15 minutes inside it. You open one at a time from Admin -> Rounds.
--
-- Leaves EXACTLY these four batches. Anyone sitting in an old batch is moved to
-- Round 4 first, so nobody is stranded. Safe to re-run.
-- =====================================================================

-- 1. the four rounds
insert into quiz.batches (name, is_open, window_minutes) values
  ('Round 1',          false, 30),
  ('Round 2',          false, 30),
  ('Round 3',          false, 30),
  ('Round 4 (Backup)', false, 30)
on conflict (name) do nothing;

update quiz.batches set window_minutes = 30
 where name in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)');

-- 2. move anyone left in an older batch into the backup round
update quiz.students s
   set batch_id = (select id from quiz.batches where name = 'Round 4 (Backup)')
 where s.batch_id is not null
   and s.batch_id not in (select id from quiz.batches
                           where name in ('Round 1','Round 2','Round 3','Round 4 (Backup)'));

update quiz.allowlist a
   set batch_id = (select id from quiz.batches where name = 'Round 4 (Backup)')
 where a.batch_id is not null
   and a.batch_id not in (select id from quiz.batches
                           where name in ('Round 1','Round 2','Round 3','Round 4 (Backup)'));

-- 3. remove every other batch (now guaranteed empty)
delete from quiz.batches
 where name not in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)');

-- 4. confirm: this must show exactly four rows
select b.name, b.is_open, b.window_minutes,
       (select count(*) from quiz.allowlist a where a.batch_id = b.id) as emails_authorised,
       (select count(*) from quiz.students  s where s.batch_id = b.id) as registered
  from quiz.batches b
 order by b.name;


-- ##############################  10_test_students.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 10: sample test students (3 per round, 5-digit roll numbers)
--
-- Roll number = username. Run AFTER 09_rounds.sql.
-- Re-running RESETS them completely (attempts, violations, chats, bans cleared),
-- so you can rehearse a round as many times as you like.
--
-- DELETE THEM BEFORE THE REAL EXAM:
--   delete from quiz.students where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- =====================================================================

-- retire every earlier placeholder (they used non-numeric or 10-digit roll numbers)
delete from quiz.students where roll_no like 'TESTB%' or roll_no like 'TEST%' or roll_no = '1025030923';

insert into quiz.students (roll_no, password_hash, full_name, batch_id)
select v.roll, quiz.hash_password(v.pass), v.name, b.id
from (values
  ('41729', 'JAILEAD', 'Tester A - Round 1', 'Round 1'),
  ('60853', 'JAILEAD', 'Tester B - Round 1', 'Round 1'),
  ('27164', 'JAILEAD', 'Tester C - Round 1', 'Round 1'),

  ('39508', 'JAILEAD', 'Tester A - Round 2', 'Round 2'),
  ('72641', 'JAILEAD', 'Tester B - Round 2', 'Round 2'),
  ('18395', 'JAILEAD', 'Tester C - Round 2', 'Round 2'),

  ('84072', 'JAILEAD', 'Tester A - Round 3', 'Round 3'),
  ('53619', 'JAILEAD', 'Tester B - Round 3', 'Round 3'),
  ('26748', 'JAILEAD', 'Tester C - Round 3', 'Round 3'),

  ('91536', 'JAILEAD', 'Tester A - Backup', 'Round 4 (Backup)'),
  ('47280', 'JAILEAD', 'Tester B - Backup', 'Round 4 (Backup)'),
  ('65913', 'JAILEAD', 'Tester C - Backup', 'Round 4 (Backup)')
) as v(roll, pass, name, batch_name)
join quiz.batches b on b.name = v.batch_name
on conflict (roll_no) do update
  set password_hash = excluded.password_hash,
      full_name     = excluded.full_name,
      batch_id      = excluded.batch_id;

-- full reset so every rehearsal starts clean
update quiz.students set banned = false, banned_reason = null, banned_at = null
 where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.attempts   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');   -- cascades answers + violations
delete from quiz.detections where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.messages   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.threads    where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
delete from quiz.sessions   where kind = 'student' and subject in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');

select s.roll_no as username, b.name as round, s.full_name
  from quiz.students s join quiz.batches b on b.id = s.batch_id
 where s.roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204')
 order by b.name, s.roll_no;


-- =====================================================================
-- FINAL CHECK — read the NOTICE and the table below
-- =====================================================================
do $chk$
declare v text;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is NOT enabled. Auto-submit will only run while an admin has the dashboard open. Enable pg_cron in Database > Extensions, then run this file again.';
  else
    execute 'select count(*)::text from cron.job where jobname = ''lead-quiz-expire''' into v;
    if v = '0' then raise notice 'pg_cron is enabled but the timer job was not created - run this file again.';
    else raise notice 'Timer job scheduled: auto-submit runs every minute.';
    end if;
  end if;
end $chk$;

select 'rounds'                as item, count(*)::text as value from quiz.batches
union all select 'admin + proctor logins', count(*)::text from quiz.admins
union all select 'questions in bank',      count(*)::text from quiz.questions
union all select 'test students',          count(*)::text from quiz.students where roll_no like 'TEST%'
union all select 'camera monitoring',      (select require_camera::text from quiz.config where id = 1)
union all select 'mic required',           (select require_mic::text from quiz.config where id = 1)
union all select 'minutes per student',    (select duration_minutes::text from quiz.config where id = 1)
union all select 'round window (minutes)', (select max(window_minutes)::text from quiz.batches);
