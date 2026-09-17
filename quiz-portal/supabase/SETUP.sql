-- =====================================================================
-- LEAD Quiz Portal — MASTER SETUP
--
-- Paste this ONE file into the Supabase SQL Editor and run it.
--   1. schema, student API, admin API          (01 + 02 + 03)
--   2. admin account + placeholder questions   (04)
--   3. five proctor logins                     (08)
--   4. the four rounds                         (09)
--   5. 12 sample test students, 3 per round    (10)
--   6. the real question bank, 280 MCQ + 32 coding (12)
--   7. paper template 4/3/3/7 MCQ + 3 coding   (13)
--   8. Students tab / formalities tracker      (15)
--   9. the 165 recruits allowlisted by round   (14)
--  10. round pools, 20-min papers, coding remarks (17)
--  11. a pre-flight report — read the STATUS column (16)
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

-- the scheduled date and time shown to students while they wait
alter table quiz.batches add column if not exists starts_at timestamptz;

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

-- serial number from the recruitment sheet, so a row can be matched back to it
alter table quiz.allowlist add column if not exists serial_no int;

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
       'starts_at', v_batch.starts_at,
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
  -- Only the first counted flag in any 3-second window counts.
  v_counted := quiz.is_counted_flag(p_kind) and not exists (
    select 1 from quiz.flags where attempt_id = v_att.id and counted
       and created_at > now() - interval '3 seconds');

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
        'coding_marks', a.coding_marks, 'remark', a.remark, 'updated_at', a.updated_at,
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
      'awarded', case when q.kind = 'mcq' then (case when a.selected_index = q.correct_index then q.marks else 0 end) end,
      'remark', case when q.kind = 'coding' then a.remark end,
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
      'email', a.email, 'batch_id', a.batch_id, 'serial_no', a.serial_no,
      'batch_name', (select b.name from quiz.batches b where b.id = a.batch_id),
      'full_name', a.full_name, 'roll_hint', a.roll_hint,
      'claimed_by', a.claimed_by, 'created_at', a.created_at,
      'registered_name', (select s.full_name from quiz.students s where s.roll_no = a.claimed_by),
      'has_id', exists (select 1 from quiz.id_documents d where d.roll_no = a.claimed_by))
      order by (select b.name from quiz.batches b where b.id = a.batch_id) nulls last,
               a.serial_no nulls last, a.email)
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
-- p_rows: [{"roll_no":"1025030923","password":"<password>","full_name":"Name"}, ...]
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
         'admin_remove_allowlist','admin_set_allowlist_batch','admin_get_id_document','admin_roster','admin_remark_coding','admin_offline_report')
    loop
      execute format('grant execute on function %s to anon, authenticated', f);
    end loop;
  end if;
end $$;


-- ##############################  04_seed.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 04: seed data
--   * test student 58204 and the 'admin' login (passwords: PASSWORDS.local.sql)
--   * placeholder question bank: 40 MCQ + 8 coding
--     (each student randomly gets 17 MCQ + 3 coding from this pool)
-- Safe to re-run.
-- =====================================================================

-- placeholder accounts always use 5-DIGIT roll numbers so they can never collide
-- with a real student's roll number
delete from quiz.students where roll_no = '1025030923';   -- retired earlier placeholder

insert into quiz.students (roll_no, password_hash, full_name)
values ('58204', quiz.hash_password(gen_random_uuid()::text), 'Seed Test Student')
on conflict (roll_no) do nothing;   -- never overwrite a password you have set

insert into quiz.admins (username, password_hash, display_name)
values ('admin', quiz.hash_password(gen_random_uuid()::text), 'Admin')
on conflict (username) do nothing;  -- never overwrite a password you have set

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
--   proctor1..proctor5. No password is set here: run PASSWORDS.local.sql.
--
-- Creates one login per proctor station. Student chat queries are shared
-- automatically between whichever of these are signed in and active.
--
-- Safe to re-run: existing passwords are never overwritten.
-- =====================================================================

insert into quiz.admins (username, password_hash, display_name) values
  ('proctor1', quiz.hash_password(gen_random_uuid()::text), 'Proctor 1'),
  ('proctor2', quiz.hash_password(gen_random_uuid()::text), 'Proctor 2'),
  ('proctor3', quiz.hash_password(gen_random_uuid()::text), 'Proctor 3'),
  ('proctor4', quiz.hash_password(gen_random_uuid()::text), 'Proctor 4'),
  ('proctor5', quiz.hash_password(gen_random_uuid()::text), 'Proctor 5')
on conflict (username) do update
  set display_name = excluded.display_name;

-- change one password later:
-- update quiz.admins set password_hash = quiz.hash_password('NEW-PASSWORD') where username = 'proctor3';

-- add a sixth station:
-- insert into quiz.admins (username, password_hash, display_name)
-- values ('proctor6', quiz.hash_password('<choose one>'), 'Proctor 6');

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
                           where name in ('Round 1','Round 2','Round 3','Round 4 (Backup)','Public Quiz','Open Quiz'));

update quiz.allowlist a
   set batch_id = (select id from quiz.batches where name = 'Round 4 (Backup)')
 where a.batch_id is not null
   and a.batch_id not in (select id from quiz.batches
                           where name in ('Round 1','Round 2','Round 3','Round 4 (Backup)','Public Quiz','Open Quiz'));

-- 3. remove every other batch (now guaranteed empty)
delete from quiz.batches
 where name not in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)', 'Public Quiz', 'Open Quiz');

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
-- Roll number = username. Passwords are set by PASSWORDS.local.sql, never here.
-- Re-running does NOT reset them (see the commented block below).
--
-- DELETE THEM BEFORE THE REAL EXAM:
--   delete from quiz.students where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- =====================================================================

-- retire every earlier placeholder (they used non-numeric or 10-digit roll numbers)
delete from quiz.students where roll_no like 'TESTB%' or roll_no like 'TEST%' or roll_no = '1025030923';

insert into quiz.students (roll_no, password_hash, full_name, batch_id)
select v.roll, quiz.hash_password(gen_random_uuid()::text), v.name, b.id
from (values
  ('41729', 'Tester A - Round 1', 'Round 1'),
  ('60853', 'Tester B - Round 1', 'Round 1'),
  ('27164', 'Tester C - Round 1', 'Round 1'),

  ('39508', 'Tester A - Round 2', 'Round 2'),
  ('72641', 'Tester B - Round 2', 'Round 2'),
  ('18395', 'Tester C - Round 2', 'Round 2'),

  ('84072', 'Tester A - Round 3', 'Round 3'),
  ('53619', 'Tester B - Round 3', 'Round 3'),
  ('26748', 'Tester C - Round 3', 'Round 3'),

  ('91536', 'Tester A - Backup', 'Round 4 (Backup)'),
  ('47280', 'Tester B - Backup', 'Round 4 (Backup)'),
  ('65913', 'Tester C - Backup', 'Round 4 (Backup)')
) as v(roll, name, batch_name)
join quiz.batches b on b.name = v.batch_name
on conflict (roll_no) do update
  set full_name     = excluded.full_name,
      batch_id      = excluded.batch_id;

-- RESET IS OFF so re-running SETUP.sql during a live exam changes nothing.
-- Uncomment to wipe the demo accounts for a fresh rehearsal:
-- -- full reset so every rehearsal starts clean
-- update quiz.students set banned = false, banned_reason = null, banned_at = null
--  where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.attempts   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');   -- cascades answers + violations
-- delete from quiz.detections where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.messages   where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.threads    where roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');
-- delete from quiz.sessions   where kind = 'student' and subject in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204');


select s.roll_no as username, b.name as round, s.full_name
  from quiz.students s join quiz.batches b on b.id = s.batch_id
 where s.roll_no in ('41729','60853','27164','39508','72641','18395','84072','53619','26748','91536','47280','65913','58204')
 order by b.name, s.roll_no;


-- ##############################  12_question_bank.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 12: real question bank
--   Generated from LEAD_FINAL_Question_Bank.md — do not hand-edit.
--   280 MCQ  (A 85 logical reasoning / B 58 design / C 62 marketing+events / TECH 75)
--    32 coding tasks (Section 5B live-terminal pool)
--   Answer keys live only in quiz.questions.correct_index, inside the private
--   `quiz` schema. They are never returned by get_exam_state.
-- Safe to re-run: matched on ext_code.
-- =====================================================================

alter table quiz.questions add column if not exists section  text;
alter table quiz.questions add column if not exists ext_code text;

do $$ begin
  alter table quiz.questions add constraint questions_section_ck
    check (section is null or section in ('A','B','C','TECH'));
exception when duplicate_object then null; end $$;

-- not partial: ON CONFLICT (ext_code) needs to infer it. Nulls stay unconstrained.
create unique index if not exists questions_ext_code_uq on quiz.questions (ext_code);

-- drop any earlier wording of the language note before the bodies are rewritten
update quiz.questions
   set body = btrim(regexp_replace(body,
         'You may (use any programming language|answer in Python).*$', '', 'n'))
 where kind = 'coding';

-- ---------- remove the placeholder bank from 04_seed.sql ----------
-- Deleted outright, unless a placeholder is still attached to an attempt or an
-- answer (a rehearsal run) — those are only deactivated, so old papers stay
-- readable and nothing cascades away underneath them.
delete from quiz.questions q
 where q.ext_code is null
   and q.title like 'Placeholder%'
   and not exists (select 1 from quiz.answers  a where a.question_id = q.id)
   and not exists (select 1 from quiz.attempts t where q.id = any (t.question_ids));

update quiz.questions set active = false
 where ext_code is null and title like 'Placeholder%';

-- ---------- MCQ ----------
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A1', 'A1', 'Find the next number: 2, 5, 11, 23, 47, ?', '["95", "91", "93", "89"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A2', 'A2', 'Each letter is shifted +2. MANGO becomes OCPIQ. How is GRAPE written?', '["ITCRG", "ITDSG", "IUCSG", "HTCRG"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A3', 'A3', 'Thermometer is to Temperature as Barometer is to ?', '["Humidity", "Pressure", "Wind", "Rain"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A4', 'A4', '121, 144, 169, 170, 196', '["121", "144", "170", "196"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A5', 'A5', 'A says to B, "Your mother is the wife of my father''s only brother." How is B related to A?', '["Brother", "Cousin", "Uncle", "Nephew"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A6', 'A6', 'A person walks 4 km north, turns left and walks 3 km, turns left again and walks 4 km. How far is he from the starting point?', '["7 km", "5 km", "3 km", "1 km"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A7', 'A7', 'Statements: Some apples are oranges. Some oranges are bananas. Conclusion: "Some apples are bananas."', '["Definitely true", "Definitely false", "Cannot be determined", "True only sometimes"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A8', 'A8', 'What is the angle between the hands of a clock at 3:30?', '["90°", "75°", "60°", "105°"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A9', 'A9', 'If every person in a room shakes hands with every other person exactly once, and there are 45 handshakes, how many people are there?', '["9", "10", "8", "12"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A10', 'A10', 'Statement: "If it rains, the match will be cancelled." It did not rain. Can we conclude the match was not cancelled?', '["Yes, definitely", "No — it could still be cancelled for other reasons", "The match was definitely held", "Insufficient data"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A11', 'A11', '1, 4, 27, 256, ?', '["3025", "3125", "3225", "2925"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A12', 'A12', '3, 8, 15, 24, 35, ?', '["46", "50", "48", "44"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A13', 'A13', '6, 11, 21, 36, 56, ?', '["78", "81", "76", "85"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A14', 'A14', '1, 2, 6, 24, 120, ?', '["600", "720", "840", "480"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A15', 'A15', '0, 1, 1, 2, 3, 5, 8, 13, 21, ?', '["32", "34", "29", "36"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A16', 'A16', '1, 8, 27, 64, 125, ?', '["196", "256", "216", "225"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A17', 'A17', '1, 3, 7, 15, 31, ?', '["47", "62", "63", "61"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A18', 'A18', '9, 16, 25, 36, 49, ?', '["56", "81", "72", "64"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A19', 'A19', '1, 4, 10, 22, 46, ?', '["94", "92", "90", "96"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A20', 'A20', '256, 128, 64, 32, 16, ?', '["4", "12", "10", "8"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A21', 'A21', '3, 4, 7, 11, 18, 29, ?', '["47", "40", "45", "42"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A22', 'A22', '2, 6, 12, 20, 30, ?', '["42", "40", "44", "38"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A23', 'A23', '100, 98, 94, 86, 70, ?', '["38", "42", "46", "54"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A24', 'A24', '5, 10, 13, 26, 29, 58, ?', '["61", "63", "64", "116"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A25', 'A25', '2, 9, 28, 65, 126, ?', '["215", "217", "220", "225"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A26', 'A26', 'If C=3, L=4, O=5, U=6, D=7 (CLOUD = 34567), what is the code for COLD?', '["3547", "3457", "3574", "3745"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A27', 'A27', 'Each letter shifted −1: SISTER → RHRSDQ. How is CANDLE written?', '["DBOEMF", "BZMCKD", "BZMBKD", "BZMCJD"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A28', 'A28', 'Using letter positions (A=1…Z=26), what word is 8-5-1-18-20?', '["HEARD", "HEART", "HEATH", "HEAPS"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A29', 'A29', '"si po re" = "book is thick", "ti na re" = "bag is heavy", "si na ka" = "book and bag". What does "re" mean?', '["book", "is", "thick", "bag"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A30', 'A30', 'Each letter shifted +3: SEND → VHQG. How is HELP coded?', '["KHOS", "KHOP", "KHOR", "KHPS"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A31', 'A31', 'Each letter shifted +2: EARTH → GCTVJ. What is OCEAN?', '["SEGCP", "QEGCL", "QFGCP", "QEGCP"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A32', 'A32', '"red blue green" = "4 7 2", "blue yellow pink" = "7 5 9", "green pink white" = "2 9 1". Code for "white"?', '["1", "2", "9", "5"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A33', 'A33', '"come and help me" = "1 2 3 4", "always come on time" = "5 6 2 7", "help on demand" = "8 9 6 3". Code for "come"?', '["1", "2", "3", "6"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A34', 'A34', 'In a mirror cipher (A↔Z, B↔Y, C↔X…), PLANE is written as?', '["KOZMP", "KOZMV", "KOZRM", "KLZMV"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A35', 'A35', 'Marathon : Race :: Hamlet : ?', '["Shakespeare", "Play", "Novel", "Poem"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A36', 'A36', 'Telescope : Stars :: Microscope : ?', '["Lens", "Laboratory", "Cells", "Doctor"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A37', 'A37', 'Carpenter : Wood :: Mason : ?', '["Hammer", "Building", "Bricks", "Cement"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A38', 'A38', 'Flock : Birds :: Pack : ?', '["Cards", "Wolves", "Fish", "Bees"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A39', 'A39', 'Chapter : Book :: Scene : ?', '["Actor", "Stage", "Play", "Dialogue"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A40', 'A40', 'Canvas : Painter :: Stage : ?', '["Actor", "Audience", "Curtain", "Director"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A41', 'A41', 'Glove : Hand :: Sock : ?', '["Shoe", "Leg", "Cotton", "Foot"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A42', 'A42', 'Library : Books :: Arsenal : ?', '["Soldiers", "Weapons", "Army", "Bullets"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A43', 'A43', '2, 3, 5, 9, 11, 13', '["3", "5", "9", "11"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A44', 'A44', 'Eagle, Hawk, Penguin, Falcon', '["Eagle", "Penguin", "Hawk", "Falcon"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A45', 'A45', 'Saturn, Mars, Moon, Jupiter', '["Saturn", "Mars", "Moon", "Jupiter"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A46', 'A46', 'Copper, Iron, Brass, Aluminium', '["Copper", "Iron", "Brass", "Aluminium"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A47', 'A47', '8, 27, 64, 100, 125', '["8", "64", "100", "125"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A48', 'A48', 'Whale, Shark, Dolphin, Bat', '["Shark", "Whale", "Dolphin", "Bat"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A49', 'A49', 'ABCD, EFGH, IJKL, MNOP, QRSU', '["ABCD", "EFGH", "IJKL", "QRSU"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A50', 'A50', '36, 49, 81, 90, 121', '["49", "81", "90", "121"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A51', 'A51', 'Pointing to a man, a woman says, "His brother''s father is the only son of my grandfather." How is the woman related to the man?', '["Mother", "Aunt", "Sister", "Cousin"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A52', 'A52', 'If A + B = "A is the father of B", A − B = "A is the wife of B", A × B = "A is the brother of B", what does P + Q − R mean?', '["R is P''s father-in-law", "P is R''s father-in-law", "Q is R''s husband", "R is Q''s son"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A53', 'A53', 'Rahul says, "Anita''s father is my mother''s only son." How is Rahul related to Anita?', '["Uncle", "Father", "Brother", "Grandfather"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A54', 'A54', 'P is the brother of Q, Q is the sister of R, R is the father of S. How is P related to S?', '["Father", "Uncle", "Grandfather", "Brother"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A55', 'A55', 'X is the husband of Y. Z is the daughter of Y. W is the father of X. How is W related to Z?', '["Father", "Grandfather", "Uncle", "Father-in-law"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A56', 'A56', 'Kavita says, "He is the only grandson of my mother." How is he related to Kavita?', '["Son", "Brother", "Nephew", "Cousin"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A57', 'A57', 'A woman says, "That man''s mother is my mother-in-law." How is she related to the man?', '["Sister", "Mother", "Wife", "Daughter"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A58', 'A58', 'Facing south, Ravi turns 135° clockwise. Which direction now?', '["North-West", "North-East", "South-West", "South-East"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A59', 'A59', 'A man walks 2 km east, 3 km north, then 2 km west. Distance from start?', '["7 km", "5 km", "2 km", "3 km"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A60', 'A60', 'Priya walks 8 km south, turns right and walks 6 km, turns right and walks 8 km. Direction from start?', '["East", "South", "North", "West"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A61', 'A61', 'Facing north, Arun turns 90° right, then 180°, then 90° left. Facing?', '["North", "South", "East", "West"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A62', 'A62', 'Sita walks 3 km east, 4 km north, 6 km west, 4 km south. Distance from start?', '["6 km", "5 km", "3 km", "4 km"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A63', 'A63', 'A man walks 6 km south, then 8 km east. Shortest distance from start?', '["14 km", "12 km", "10 km", "2 km"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A64', 'A64', 'Neha walks 7 km north, 7 km east, 7 km south. How far and which direction?', '["7 km East", "14 km North-East", "7 km North", "7 km South-East"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A65', 'A65', 'All roses are flowers. All flowers are plants. ∴ "All roses are plants."', '["Valid", "Invalid", "Cannot be determined", "Partially true"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A66', 'A66', 'No cat is a dog. All dogs are animals. I: "No cat is an animal." II: "Some animals are dogs."', '["Only I", "Only II", "Both", "Neither"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A67', 'A67', 'Some books are pens. All pens are erasers. ∴ "Some books are erasers."', '["Valid", "Invalid", "Cannot be determined", "Only if all books are pens"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A68', 'A68', 'All metals are hard. Some hard things are expensive. ∴ "Some metals are expensive."', '["Valid", "Does not necessarily follow", "True only if all hard things are expensive", "Always false"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A69', 'A69', 'No fish is a bird. All sparrows are birds. ∴ "No sparrow is a fish."', '["Valid", "Invalid", "Partially valid", "Cannot be determined"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A70', 'A70', 'If "All politicians are honest" is false, which must be true?', '["All politicians are dishonest", "No politician is honest", "At least one politician is not honest", "Most are dishonest"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A71', 'A71', 'Some chairs are tables. All tables are furniture. No furniture is electronic. ∴ "Some chairs are not electronic."', '["Does not follow", "Cannot be determined", "Partially true", "Definitely true"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A72', 'A72', 'At what time between 4 and 5 o''clock are the hands first at right angles?', '["4:00", "4:05 5/11 min", "4:10", "4:15"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A73', 'A73', 'If Jan 1 of a non-leap year is Monday, what day is March 1?', '["Monday", "Tuesday", "Wednesday", "Thursday"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A74', 'A74', 'How many times do clock hands overlap in 12 hours?', '["12", "11", "10", "24"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A75', 'A75', 'Day before yesterday was Thursday. What day is the day after tomorrow?', '["Sunday", "Monday", "Saturday", "Tuesday"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A76', 'A76', 'Angle between hour and minute hands at 8:00?', '["120°", "150°", "240°", "60°"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A77', 'A77', 'A clock loses 5 min every hour. Set correctly at noon — what does it show when actual time is 6 PM?', '["5:30 PM", "5:00 PM", "5:15 PM", "5:40 PM"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A78', 'A78', 'In a class of 40, Ravi is 13th from top. Rank from bottom?', '["27", "28", "29", "26"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A79', 'A79', 'A is twice as old as B. Five years ago A was three times B''s age. B''s age now?', '["10", "15", "8", "12"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A80', 'A80', 'A and B together finish a task in 12 days. B alone takes 20 days. A alone?', '["30", "28", "32", "25"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A81', 'A81', 'A 150 m train passes a pole in 15 seconds. Speed?', '["36 km/h", "10 km/h", "54 km/h", "45 km/h"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A82', 'A82', 'A car covers the first half at 40 km/h and the second half at 60 km/h. Average speed?', '["50 km/h", "48 km/h", "45 km/h", "52 km/h"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A83', 'A83', 'In how many ways can 5 people be seated in a row?', '["25", "120", "60", "24"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A84', 'A84', 'A bag has 3 red and 5 blue balls. Probability of drawing red?', '["3/8", "5/8", "3/5", "1/2"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'A', 'A85', 'A85', 'A is taller than B. C is shorter than A but taller than D. B is taller than D. Who is shortest?', '["A", "B", "C", "D"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B1', 'B1', 'In Canva, what is the quickest way to start designing an Instagram post?', '["Start with a blank A4 page and manually resize it", "Search for \"Instagram Post\" in templates to get the correct dimensions automatically", "Take a screenshot of Instagram and paste it", "There is no Instagram template in Canva"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B2', 'B2', 'You want to remove the background of a photo in Canva. Which feature does this?', '["The Crop tool", "The Filter tool", "Background Remover", "The Animate button"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B3', 'B3', 'You''ve designed a poster in Canva and need to download it for printing. Which format gives the best print quality?', '["JPEG (low quality)", "GIF", "MP4", "PDF Print"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B4', 'B4', 'Your poster needs the exact shade of your society''s official blue (#1A3A5C). How do you apply it in Canva?', '["Just pick a blue that looks close enough", "Use the color picker and enter the hex code #1A3A5C", "You cannot use custom colors in Canva", "Screenshot the color and paste it"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B5', 'B5', 'What is the main difference between downloading a Canva design as PNG vs JPEG?', '["They are exactly the same", "PNG supports transparency (no background); JPEG does not and may have slightly lower quality", "JPEG supports transparency; PNG does not", "PNG only works on Mac"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B6', 'B6', 'Which file format preserves layers when saving in Photoshop?', '["JPEG", "PNG", "PSD", "GIF"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B7', 'B7', 'Which color mode should you use in Photoshop if your design is meant for digital screens?', '["CMYK", "Grayscale", "RGB", "Bitmap"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B8', 'B8', 'What resolution is typically recommended for print-quality images?', '["72 DPI", "150 DPI", "300 DPI", "50 DPI"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B9', 'B9', 'A club member submits a poster with 5 different fonts. As the design lead, what feedback do you give?', '["\"Looks creative, keep all 5 fonts\"", "\"Use even more fonts for variety\"", "\"The design looks great as-is\"", "\"Stick to 2–3 fonts maximum for a cleaner, more professional look\""]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B10', 'B10', 'Which file type is best for saving a logo used at many sizes — from a tiny favicon to a large banner?', '["JPEG", "BMP", "SVG (vector format)", "GIF"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B11', 'B11', 'Your society president asks for a poster; you want "TECH FEST 2026" to stand out. Best approach?', '["Same size as other text", "Tiny font so people lean in", "Largest text element, bold contrasting font and color", "Hide it behind an image"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B12', 'B12', 'What does the "Transparency" slider do?', '["Turns it white", "Makes the element more/less see-through", "Deletes it", "Enlarges it"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B13', 'B13', 'What happens when you "Group" elements?', '["Permanently merged forever", "They move/resize as one unit but can be ungrouped", "They''re deleted", "Only colors merge"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B14', 'B14', 'Standard Instagram post dimension?', '["1920×1080", "800×600", "1080×1080", "500×500"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B15', 'B15', 'What does "Position" let you do?', '["Change font", "Move an element forward/backward in the layer stack", "Change page size", "Add music"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B16', 'B16', 'How do you add more slides to a carousel?', '["You can''t", "Click \"Add page\" / the \"+\" button", "Screenshot different designs", "Copy the file"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B17', 'B17', 'What is "Brand Kit" useful for?', '["Ordering merch", "Saving official colors, fonts and logos for consistency", "Deleting designs", "Direct posting"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B18', 'B18', 'Dimension for a WhatsApp status story?', '["1080×1080", "1920×1080", "1080×1920", "500×500"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B19', 'B19', 'How do you make text readable over a busy background image?', '["Thin light font", "No adjustment", "Semi-transparent overlay or shape behind the text", "Delete the image"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B20', 'B20', 'What does "Magic Resize" do?', '["Improves quality", "Resizes the design for other platform dimensions in one click", "Adds magic elements", "Rotates it"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B21', 'B21', 'Best way to center a title?', '["Drag by eye", "Use alignment guides or Position → Center", "Measure pixels with a ruler", "Doesn''t matter"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B22', 'B22', 'How do you give a teammate editing access?', '["Email the file", "Send a screenshot", "Share button → link with \"Can edit\"", "Not possible"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B23', 'B23', 'What does "Lock" do to an element?', '["Password-encrypts it", "Prevents accidental moving/editing until unlocked", "Deletes it", "Hides it"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B24', 'B24', 'How do you animate an Instagram story in Canva?', '["Impossible", "Select page/elements → Animate", "Hand-make each frame", "Record a video"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B25', 'B25', 'Most efficient workflow for a consistent set of event posts?', '["From scratch each time", "One master template, duplicate pages, change only content", "Copy other societies", "Random templates"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B26', 'B26', 'Purpose of "Grids"?', '["Print grid lines", "Place photos into pre-arranged layouts/collages", "Convert to spreadsheet", "Add borders"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B27', 'B27', 'Client says the poster "feels too cramped." Fix?', '["Add more content", "Increase spacing / add white space", "Shrink all fonts", "Border every element"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B28', 'B28', 'What does "Flatten" mean?', '["Makes it 3D", "Merges all layers into a single non-editable image", "Zero file size", "Converts to video"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B29', 'B29', 'Your logo has a white background that clashes with the poster. Do what?', '["Use as-is", "Use a transparent-background PNG, or remove the background", "Delete the logo", "Make the whole poster white"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B30', 'B30', 'What is the "Elements" tab for?', '["Only text", "Shapes, icons, illustrations, stickers, lines and other graphics", "Page dimensions", "Exporting"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B31', 'B31', 'What is a "Layer"?', '["A circle tool", "A separate, independently editable level of content, like stacked transparent sheets", "A file format", "The background color"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B32', 'B32', 'Which tool selects an irregularly shaped area?', '["Crop", "Lasso", "Brush", "Gradient"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B33', 'B33', 'What does Ctrl+Z / Cmd+Z do?', '["Save", "Zoom", "Undo", "New layer"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B34', 'B34', 'What do you hold to resize an image without distorting it?', '["Alt", "Ctrl", "Tab", "Shift (constrain proportions)"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B35', 'B35', 'What is the Crop tool for?', '["Adding text", "Trimming to a size / removing outer areas", "Filters", "Color change"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B36', 'B36', 'What does the Eraser tool do?', '["Deletes the file", "Removes pixels from a layer, leaving transparency or background color", "Watermarks", "Flips the image"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B37', 'B37', 'Which tool samples a color from the image?', '["Paint Bucket", "Gradient", "Eyedropper", "Pen"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B38', 'B38', 'What does layer "Opacity" control?', '["Position", "How see-through the layer is", "File size", "Resolution"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B39', 'B39', 'What is the Clone Stamp tool for?', '["Adding stickers", "Copying a sampled area and painting it elsewhere — removing blemishes, duplicating objects", "New file", "Text"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B40', 'B40', 'Which tool places text over an image?', '["Lasso", "Brush", "Horizontal Type tool (T)", "Eraser"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B41', 'B41', 'What is the Magic Wand best for?', '["Perfect circles", "Selecting areas of similar color in one click", "Special effects", "Resizing canvas"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B42', 'B42', 'What does "Flatten Image" do?', '["Rotates 90°", "Merges all layers into one background layer", "Shrinks canvas", "Blurs"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B43', 'B43', 'Where do you increase a photo''s brightness?', '["Filter → Blur", "Image → Adjustments → Brightness/Contrast", "Edit → Paste", "File → Export"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B44', 'B44', 'Shortcut to create a new layer?', '["Ctrl+N", "Ctrl+Shift+N", "Ctrl+S", "Ctrl+P"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B45', 'B45', 'What is the Healing Brush for?', '["Painting effect", "Retouching imperfections by blending with surrounding pixels", "Straight lines", "Borders"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B46', 'B46', 'Team is making 10 posts for a week-long series. Most important FIRST decision?', '["A different style each day", "A consistent palette, font set and layout template", "Random internet templates", "Only worry about post 1"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B47', 'B47', 'Palette for a formal professional tech conference?', '["Neon pink, bright yellow, lime", "Dark navy, white, silver/grey", "Rainbow polka dots", "All red with orange text"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B48', 'B48', 'A poster shows name, date, time, venue, QR code. Which should be largest?', '["QR code", "Venue", "Event name/title", "Time"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B49', 'B49', 'White text on a light yellow background — the problem?', '["Nothing", "Very low contrast, nearly unreadable", "Wrong font", "Too big"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B50', 'B50', 'Best approach for a tech society logo?', '["Highly detailed, gradients, 10+ colors", "Copy a famous logo slightly modified", "Simple, clean, recognizable even when tiny", "Use a photograph"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B51', 'B51', 'Important text sits right at the edges of an Instagram post. Risk?', '["Looks professional", "It can get cropped/cut off across devices and Instagram''s own cropping", "Loads faster", "No risk"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B52', 'B52', 'Charity poster, mood should feel warm and hopeful. Palette?', '["Black and dark grey", "Cold blue and white", "Warm orange, soft yellow, cream", "Neon green and purple"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B53', 'B53', 'Dark blue (#00008B) text on pure black (#000000) — issue?', '["Looks perfect", "Too much blue", "Extremely poor contrast, very hard to read", "It''s a font-size problem"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B54', 'B54', 'What makes a good "Register Now" button?', '["Same color as background", "Contrasting color, clear label, large enough to tap", "Tiny hidden text", "Buried at the bottom of a long page"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B55', 'B55', 'Elements are randomly placed with no clear reading order. Which principle is violated?', '["Too few colors", "Visual hierarchy and alignment", "Poster too large", "Needs more images"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B56', 'B56', 'You need both a Facebook landscape banner and an Instagram vertical story from one design. Best approach?', '["Stretch the banner", "Create separate layouts adapted to each aspect ratio", "Crop from the center", "Skip stories"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B57', 'B57', 'Red text on a green background is hard to read — and especially problematic because:', '["It''s ugly", "Too many colors", "Red-green color blindness is common, so many people can''t read it at all", "Copyright"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'B', 'B58', 'B58', 'You need a photo but don''t have one. Safest, most legal option?', '["Google an image and use it", "Screenshot someone''s Instagram", "Use a royalty-free stock site (Unsplash, Pexels)", "Use a copyrighted image quietly"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C1', 'C1', 'What do the "4 Ps of Marketing" stand for?', '["People, Process, Product, Price", "Product, Price, Place, Promotion", "Plan, Price, Product, People", "Product, People, Process, Promotion"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C2', 'C2', 'What does "SEO" stand for?', '["Social Event Organization", "Standard Event Operation", "Search Engine Optimization", "Sales and Engagement Outreach"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C3', 'C3', 'What is a "Call to Action" (CTA) in marketing?', '["A legal requirement", "A report format", "A type of ad format", "A prompt encouraging the audience to take a specific action — \"Register Now\", \"Learn More\""]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C4', 'C4', 'What does "conversion rate" measure?', '["How fast a website loads", "Social media follower count", "The number of pages on a website", "The percentage of people who take a desired action out of total exposed"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C5', 'C5', 'What is "A/B testing" in marketing?', '["A grading system", "A type of survey", "Testing two different products simultaneously", "Comparing two versions of a marketing element to see which performs better"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C6', 'C6', 'Social media following is growing but event attendance is NOT increasing. What might be the issue?', '["You should stop using social media", "The online audience isn''t converting — CTA, event value, or registration process needs work", "Follower count is the only metric that matters", "Social media doesn''t work"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C7', 'C7', 'What is the FIRST step in planning any event?', '["Booking the venue", "Printing invitations", "Hiring performers", "Defining the objective or purpose of the event"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C8', 'C8', 'On the day of the event, the main speaker cancels 30 minutes before. What should you do?', '["Stay calm, inform your team, activate a backup plan — alternate speaker or rearranged schedule", "Cancel the entire event", "Panic and announce it with no plan", "Let the audience wait indefinitely"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C9', 'C9', 'What is the purpose of a "run sheet" on event day?', '["To list sponsors", "To outline the sequence of activities with timings for smooth execution", "To track ticket sales", "To design the stage"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C10', 'C10', 'Outdoor event with rain forecast. What should you do?', '["Hope it doesn''t rain", "Cancel immediately", "Prepare a contingency — indoor backup, tents/canopies, communicate the plan", "Ignore the forecast"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C11', 'C11', 'What does "ROI" stand for?', '["Rate of Interest", "Return on Investment", "Record of Interaction", "Range of Influence"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C12', 'C12', 'What is "content marketing"?', '["TV ads", "Email spam", "Creating and distributing valuable, relevant content to attract and retain an audience", "Buying followers"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C13', 'C13', 'Primary goal of SEO?', '["Logos", "Events", "Followers", "Improving a website''s organic visibility in search results"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C14', 'C14', 'What does "organic reach" mean?', '["Unique people who see your content without paid promotion", "Organic food marketing", "Paid-ad reach only", "Reach on a single platform"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C15', 'C15', 'What is "influencer marketing"?', '["Government marketing", "Internal employee marketing", "Partnering with people who have large engaged followings", "Newspaper ads"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C16', 'C16', 'A hashtag is primarily used to:', '["Decorate", "Block users", "Set privacy", "Categorize content so it''s discoverable by topic"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C17', 'C17', 'Managing socials for a college event — which format usually gets the most engagement?', '["Long text articles, no images", "Posts with no captions/hashtags", "Short visually appealing reels/videos", "Plain text posts"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C18', 'C18', 'What is "email marketing"?', '["Spamming random addresses", "Filing complaints", "Setting up accounts", "Sending targeted, relevant emails to a subscribed audience"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C19', 'C19', 'What is a "brand ambassador"?', '["A diplomat", "A finance officer", "A person who represents and promotes a brand positively", "An ad type"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C20', 'C20', 'Registration form getting very few sign-ups. Analyze FIRST:', '["Venue decor", "Stage design", "Catering", "Whether the form is too long, hard to find, or promotion isn''t reaching the right audience"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C21', 'C21', 'What is "guerrilla marketing"?', '["Jungle marketing", "TV advertising", "Paid search", "Unconventional, creative, low-cost tactics designed to grab attention unexpectedly"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C22', 'C22', 'What is "cross-promotion"?', '["Two brands/events promoting each other to reach wider audiences", "One product at a time", "Cancelling a promotion", "Internal meetings"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C23', 'C23', 'What is a "value proposition"?', '["A discount", "A sponsorship deal", "A clear statement of what makes your event unique and why to choose it", "An invoice"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C24', 'C24', 'Purpose of market research?', '["Copy competitors", "Reduce quality", "Raise prices randomly", "Gather info on audiences, competitors and trends for informed decisions"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C25', 'C25', 'Launching a new initiative — FIRST marketing step?', '["Make posters", "Post everywhere at once", "Define the target audience and key message", "Ask friends to share"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C26', 'C26', 'What do "analytics" help you understand?', '["Post count", "Follower count", "User behavior — visits, clicks, engagement, conversions", "Website design"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C27', 'C27', 'A competitor''s event gets more traction. Best first step?', '["Copy exactly", "Criticize publicly", "Analyze what they do differently and adapt learnings to your brand", "Ignore them"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C28', 'C28', 'SWOT analysis evaluates:', '["Logos", "Code", "Accounting", "Strengths, Weaknesses, Opportunities, Threats"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C29', 'C29', 'What is "brand recall"?', '["Product return", "Recall election", "Consumers'' ability to remember and recognize a brand", "Internal audit"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C30', 'C30', 'What is "paid media"?', '["Free press", "Word of mouth", "Internal comms", "Channels where you pay for placement — ads, sponsored posts"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C31', 'C31', 'What is "earned media"?', '["Organic publicity — press mentions, shares, word of mouth", "Paid ads", "Purchased followers", "Owned accounts"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C32', 'C32', 'What is "positioning"?', '["Shelf placement only", "Seating", "How you differentiate your brand in the audience''s mind vs competitors", "Event location"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C33', 'C33', 'What is "segmentation"?', '["Dividing a broad audience into smaller groups with shared traits for targeted messaging", "Merging all audiences", "A design technique", "Deleting customers"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C34', 'C34', 'What is "viral marketing"?', '["Computer viruses", "Flu-season marketing", "Paid search", "Content that spreads rapidly through audience sharing"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C35', 'C35', 'What is a "lead"?', '["A team leader", "A metal", "A potential customer who showed interest and whose info you captured", "A news intro"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C36', 'C36', 'What does "bounce rate" indicate?', '["Page loads", "Image speed", "The percentage of visitors who leave after viewing only one page", "Broken links"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C37', 'C37', 'What is a "contingency plan"?', '["Guest list", "A backup plan for unexpected problems", "Marketing plan", "Invitation design"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C38', 'C38', 'More attendees show up than the RSVP count. Best immediate action?', '["Turn all non-RSVPs away", "Shut it down", "Assess capacity and safety, adapt seating/resources without compromising safety", "Argue at the entrance"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C39', 'C39', 'What does "logistics" refer to?', '["Food only", "Guest list only", "Budget only", "Planning and coordination of venue, transport, equipment and manpower"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C40', 'C40', 'Two volunteers argue about responsibilities mid-event. As coordinator:', '["Hear both sides calmly, clarify responsibilities fast so the event isn''t affected", "Ignore it", "Scold both publicly", "Remove both"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C41', 'C41', 'A sponsor''s banner arrives damaged. Best approach?', '["Don''t display it and stay quiet", "Drop the sponsor", "Inform your team lead and find a quick alternative — reprint, digital display, or an honest explanation", "Blame the vendor publicly"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C42', 'C42', 'Why is a post-event feedback survey important?', '["A formality", "Only for sponsors", "No link to planning", "It shows what worked and what to improve next time"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C43', 'C43', 'Registration queue is slow and attendees are frustrated. Do what?', '["Add registration points/volunteers or start a verbal check-in", "Let it resolve itself", "Stop registrations", "Ask people to come back later"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C44', 'C44', 'What is an "RSVP"?', '["A ticket type", "A sponsor tier", "A request for guests to confirm attendance", "A sound system brand"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C45', 'C45', 'Budget runs short halfway through planning. Do what?', '["Cancel", "Reassess priorities, find cost-savings, explore extra sponsorship, communicate with the team", "Overspend quietly", "Blame finance publicly"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C46', 'C46', 'What is "crowd management"?', '["Maximize crowd size", "Everyone stands still", "Concerts only", "Planning safe entry, exit, flow and capacity"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C47', 'C47', 'A key team member falls sick on event day. Do what?', '["Cancel their part", "Redistribute responsibilities quickly and brief the replacement", "Announce the event will be subpar", "Nothing"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C48', 'C48', 'What is a "venue recce"?', '["After-party", "A pre-event visit to assess layout, facilities, technical needs and likely problems", "A ticket type", "An online survey"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C49', 'C49', 'What does an MC/Emcee do?', '["Only jokes", "Budget", "Hosts and guides the event — introductions, transitions, audience engagement", "Stage design"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C50', 'C50', 'What is a "debriefing session"?', '["A party", "A team meeting to review what went well, what went wrong, and lessons learned", "Deleting files", "A team-building game"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C51', 'C51', 'Organizing a 50-person workshop — key logistical consideration?', '["Speaker fee only", "Venue capacity, seating, AV, refreshments and materials", "Poster design", "Social media only"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C52', 'C52', 'What is "sponsorship activation"?', '["Just a logo", "Creating interactive ways for sponsors to connect with attendees — booths, branded activities", "Hiding sponsor material", "A single mention"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C53', 'C53', 'An attendee reports feeling unsafe. Immediate action?', '["Ignore", "Take it seriously, ensure their safety, involve security if needed, document the incident", "Ask them to leave", "Announce it publicly"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C54', 'C54', 'What is a "technical rider"?', '["Fee document", "A document specifying technical requirements — AV, lighting, internet, special equipment", "Travel itinerary", "A contract type"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C55', 'C55', 'Why set a registration deadline?', '["No purpose", "It helps plan logistics, manage capacity and create urgency", "Corporate events only", "To exclude latecomers"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C56', 'C56', 'What does "event branding" include?', '["Logo only", "The full visual identity — logo, colors, fonts, banners, badges, social templates", "The name only", "The invite card"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C57', 'C57', 'Wi-Fi dies during a live demo. What should happen?', '["End the event", "Blame the venue publicly", "Wait silently", "Stay calm, switch to a preloaded offline demo/slides, get tech support on it"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C58', 'C58', 'Why is time management critical during events?', '["Food only", "Opening only", "It doesn''t matter", "Staying on schedule respects attendees'' time and maintains energy"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C59', 'C59', 'What is a "floor plan"?', '["Financial plan", "A scaled diagram of venue layout — stage, seating, exits, booths", "A to-do list", "Guest list"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C60', 'C60', 'Negative feedback about your event appears on social media. Respond how?', '["Delete the comments", "Argue publicly", "Ignore it", "Respond politely, acknowledge it, apologize if warranted, use it constructively"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C61', 'C61', 'Why is a "dry run" done before an event?', '["Wastes time", "Checks food", "Finalizes the guest list", "Practices flow, tests AV, surfaces issues, confirms everyone knows their role"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'C', 'C62', 'C62', 'After a successful event, the MOST important follow-up is:', '["Plan the next one with no reflection", "Delete records", "Nothing", "Document learnings, thank stakeholders, publish post-event content, review feedback, write a report"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T1', 'T1', 'What is the output?
```c
int x = 10;
int *p = &x;
*p = *p + 5;
printf("%d %d", x, *p);
```', '["10 15", "15 15", "15 10", "10 10"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T2', 'T2', 'What happens here?
```c
char *str = "Hello";
str[0] = ''M'';
printf("%s", str);
```', '["Prints \"Mello\"", "Prints \"Hello\"", "Undefined behavior — may crash", "Compilation error"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T3', 'T3', 'What is the output?
```c
void foo(int *p) { p = p + 1; }
int main() {
    int arr[] = {10, 20, 30};
    int *ptr = arr;
    foo(ptr);
    printf("%d", *ptr);
}
```', '["10", "20", "30", "Garbage value"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T4', 'T4', 'What is wrong with this function?
```c
int* foo() {
    int x = 10;
    return &x;
}
```', '["Nothing — it works fine", "It returns a pointer to a local variable destroyed after return (dangling pointer)", "Compilation error", "It returns NULL automatically"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T5', 'T5', 'What is the output?
```c
int a = 5;
float b = a / 2;
printf("%.1f", b);
```', '["2.5", "2.0", "2", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T6', 'T6', 'What is the output?
```c
unsigned int x = -1;
printf("%u", x);
```', '["-1", "0", "4294967295", "Compilation error"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T7', 'T7', 'What is the output?
```c
char str[] = "Hello";
printf("%lu", sizeof(str));
```', '["5", "6", "4", "8"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T8', 'T8', 'What is the output?
```c
int arr[] = {10, 20, 30};
printf("%d", 2[arr]);
```', '["30", "20", "Compilation error", "10"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T9', 'T9', 'What is the output?
```c
int x = 1;
switch(x) {
    case 1: printf("One ");
    case 2: printf("Two ");
    case 3: printf("Three ");
}
```', '["One", "One Two", "One Two Three", "Compilation error"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T10', 'T10', 'What is the output?
```c
int i = 0;
while(i++ < 5);
printf("%d", i);
```', '["5", "6", "4", "Infinite loop"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T11', 'T11', 'What is the output?
```c
int count() {
    static int c = 0;
    c++;
    return c;
}
// called three times, printing each result
```', '["1 1 1", "1 2 3", "0 1 2", "3 3 3"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T12', 'T12', 'What is the output?
```c
#define SQUARE(x) x*x
printf("%d", SQUARE(3+1));
```', '["16", "7", "10", "4"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T13', 'T13', 'What is the key difference between a struct and a union?', '["Structs only hold integers; unions hold any type", "In a struct, all members have separate memory; in a union, all members share the same memory", "Unions are faster", "No difference"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T14', 'T14', 'What is the output?
```python
a = [1, 2, 3]
b = a
b.append(4)
print(len(a))
```', '["3", "4", "Error", "Depends on Python version"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T15', 'T15', 'What is the output?
```python
def add_item(item, lst=[]):
    lst.append(item)
    return lst
print(add_item(1))
print(add_item(2))
```', '["[1] then [2]", "[1] then [1, 2]", "[1, 2] then [1, 2]", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T16', 'T16', 'What is the output?
```python
funcs = []
for i in range(3):
    funcs.append(lambda: i)
print([f() for f in funcs])
```', '["[0, 1, 2]", "[2, 2, 2]", "[3, 3, 3]", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T17', 'T17', 'What is the output?
```python
class Counter:
    count = 0
    def __init__(self):
        Counter.count += 1
a = Counter(); b = Counter(); c = Counter()
print(Counter.count)
```', '["1", "0", "3", "Error"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T18', 'T18', 'What is the output?
```python
gen = (x for x in range(3))
print(list(gen))
print(list(gen))
```', '["[0, 1, 2] then [0, 1, 2]", "[0, 1, 2] then []", "[] then [0, 1, 2]", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T19', 'T19', 'A model gets 99% accuracy on training data but 60% on new data. This is most likely:', '["Underfitting", "Overfitting", "Good generalization", "A data collection error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T20', 'T20', 'A dataset has 95 negative and 5 positive examples. A model that ALWAYS predicts "negative" gets 95% accuracy. Why is accuracy misleading here?', '["It isn''t misleading", "The dataset is highly imbalanced — the model learned nothing useful and misses all positive cases, yet accuracy looks high", "Because 95% is too low", "Because negative examples don''t count"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T21', 'T21', '`int arr[]={10,20,30,40}; int *p=arr; printf("%d", *(p+2));`', '["20", "30", "40", "Address"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T22', 'T22', '`int a=5; int *p=&a; int **q=&p; printf("%d", **q);`', '["Address of p", "Address of a", "5", "Garbage"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T23', 'T23', '`int a[]={1,2,3}; printf("%d", *a + 1);`', '["1", "2", "3", "Address"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T24', 'T24', '`int a=10,b=20; int *p=&a; p=&b;` — value of `*p`?', '["10", "20", "Address of a", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T25', 'T25', '`int arr[]={5,10,15}; int *p=arr; p++; printf("%d", *p);`', '["5", "10", "15", "6"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T26', 'T26', 'For `int arr[5]`, what''s the relation between `arr` and `&arr[0]`?', '["Unrelated", "arr is greater", "Same address, different types", "Identical including type"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T27', 'T27', '`sizeof(ptr)` where `int *ptr` on a 64-bit system?', '["4", "8", "Depends on pointee", "sizeof(int)"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T28', 'T28', 'What happens if you `free(p)` twice?', '["Handled gracefully", "Undefined behavior — may crash or corrupt memory", "Compile error", "Reallocated"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T29', 'T29', '`int a=10; int *p=&a; (*p)++; printf("%d", a);`', '["10", "11", "Address", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T30', 'T30', 'Correct allocation for 10 ints?', '["`malloc(10)`", "`malloc(10*sizeof(int))`", "`malloc(sizeof(10))`", "`int p[10]=malloc(10)`"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T31', 'T31', '`char *s="ABCDE"; printf("%c", *(s+3));`', '["A", "C", "D", "E"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T32', 'T32', '`int x=10,y=20; int *p1=&x,*p2=&y; *p1=*p2; printf("%d %d",x,y);`', '["10 20", "20 20", "10 10", "20 10"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T33', 'T33', 'How can a C function modify the caller''s variable?', '["It can''t", "By passing a pointer to it", "Using `ref`", "Returning void"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T34', 'T34', '`printf("%d", (int)3.9 + (int)3.1);`', '["7", "6", "7.0", "6.0"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T35', 'T35', '`char c=''A''; printf("%d", c);`', '["A", "65", "''A''", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T36', 'T36', '`int a=5,b=2; float c=(float)a/b; printf("%.1f",c);`', '["2.0", "2.5", "3.0", "2"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T37', 'T37', '`int x=''B''-''A''; printf("%d",x);`', '["0", "1", "66", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T38', 'T38', '`int x=10; printf("%f", x);`', '["10.000000", "10", "Undefined behavior — %f expects a double", "10.0"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T39', 'T39', '`sizeof(3.14)` in C?', '["4", "8", "Compiler-dependent", "2"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T40', 'T40', '`char str[]="Hello"; printf("%lu", strlen(str));`', '["5", "6", "4", "8"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T41', 'T41', 'Difference between `char str[]="Hi"` and `char *str="Hi"`?', '["None", "The array is a modifiable stack copy; the pointer points to a read-only string literal", "The pointer is modifiable, the array isn''t", "Both read-only"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T42', 'T42', '`int a[5]={1,2}; printf("%d %d", a[2], a[4]);`', '["Garbage Garbage", "0 0", "1 2", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T43', 'T43', '`char s1[]="abc"; char s2[]="abc"; if(s1==s2)...`', '["Equal", "Not Equal", "Compile error", "Undefined"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T44', 'T44', '`char s[]="Hello\0World"; printf("%s", s);`', '["Hello World", "HelloWorld", "Hello", "Hello\\0World"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T45', 'T45', '`int i=3; printf("%d %d %d", i++, i++, i++);`', '["3 4 5", "5 4 3", "Undefined behavior", "3 3 3"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T46', 'T46', '`int a=1; if(a--) printf("True "); if(a) printf("Also True");`', '["True Also True", "True", "Also True", "Nothing"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T47', 'T47', '`int a=0; if(a=5) printf("Yes"); else printf("No");`', '["Yes", "No", "Compile error", "Undefined"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T48', 'T48', '`int x=0; if(x++ && x++) printf("%d",x); else printf("%d",x);`', '["0", "1", "2", "Undefined"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T49', 'T49', '`for(int i=0;i<5;i++){ if(i==3) continue; printf("%d ",i); }`', '["0 1 2 3 4", "0 1 2 4", "0 1 2", "3"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T50', 'T50', '`printf("%d", 5 << 1);`', '["5", "10", "2", "25"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T51', 'T51', 'Result of `5 | 3`?', '["8", "1", "15", "7"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T52', 'T52', '`int a=10,b=20; a^=b; b^=a; a^=b; printf("%d %d",a,b);`', '["10 20", "20 10", "0 0", "30 30"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T53', 'T53', '`void foo(int a){a=a+10;} int main(){int x=5; foo(x); printf("%d",x);}`', '["15", "5", "10", "Undefined"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T54', 'T54', 'What happens if a recursive function has no base case?', '["Returns 0", "Runs once", "Infinite recursion → stack overflow", "Compile error"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T55', 'T55', '`int factorial(int n){ if(n<=1) return 1; return n*factorial(n-1);} printf("%d", factorial(5));`', '["120", "24", "5", "60"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T56', 'T56', 'Difference between `#define PI 3.14` and `const float PI = 3.14;`?', '["None", "`#define` is preprocessor text replacement (no type checking); `const` creates a typed variable", "`const` is faster", "Reversed"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T57', 'T57', '`struct Node{int data; struct Node *next;}; struct Node a={10,NULL}; struct Node b={20,&a}; printf("%d", b.next->data);`', '["20", "10", "NULL", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T58', 'T58', 'Which is more efficient for passing a large struct?', '["By value", "Pass a pointer — avoids copying the whole struct", "Always equal", "Use a union"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T59', 'T59', '`a=(1,2,3); a[0]=10`', '["(10,2,3)", "[10,2,3]", "TypeError — tuples are immutable", "(1,2,3)"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T60', 'T60', '`a=[1,2,[3,4]]; b=a.copy(); b[2][0]=99; print(a[2][0])`', '["3", "99", "Error", "[3,4]"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T61', 'T61', '`x=[1,2,3]; y=[1,2,3]; print(x==y, x is y)`', '["True True", "True False", "False False", "False True"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T62', 'T62', '`s="python"; s.upper(); print(s)`', '["PYTHON", "python", "Python", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T63', 'T63', '`t=(1,2,[3,4]); t[2].append(5); print(t)`', '["TypeError", "(1, 2, [3, 4, 5])", "(1, 2, [3, 4])", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T64', 'T64', '`d={}; d[[1,2]]="hello"`', '["Key [1,2]", "Key (1,2)", "TypeError — lists are unhashable", "Key \"1, 2\""]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T65', 'T65', '`x=10` (global); `def foo(): x = x + 1; return x`', '["11", "10", "UnboundLocalError", "None"]'::jsonb, 2, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T66', 'T66', '`def make_multiplier(n): def multiply(x): return x*n; return multiply` → `make_multiplier(2)(5)`', '["10", "5", "2", "Error"]'::jsonb, 0, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T67', 'T67', 'What does `map(lambda x: x**2, [1,2,3])` return?', '["[1,4,9]", "A map object (iterator)", "(1,4,9)", "Error"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T68', 'T68', '`class A: def greet(self): return "A"` / `class B(A): pass` → `B().greet()`', '["Error", "None", "B", "A"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T69', 'T69', '`print(0.1 + 0.2 == 0.3)`', '["True", "False", "Error", "0.3"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T70', 'T70', '`print(any([0, False, None, 5]))` then `print(all([1, True, "hello", 5]))`', '["False True", "True True", "False False", "True False"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T71', 'T71', 'A model gets 50% accuracy on BOTH training and test data (binary classification). Most likely:', '["Overfitting", "Underfitting — model too simple", "Perfect", "Good generalization"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T72', 'T72', 'Customer purchase data with NO labels; you want behavior-based segments. This is:', '["Supervised", "Reinforcement", "Transfer learning", "Unsupervised learning (clustering)"]'::jsonb, 3, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T73', 'T73', 'What is a "hyperparameter"?', '["Learned during training", "A configuration set BEFORE training that controls the learning process (learning rate, layers)", "The final prediction", "A feature type"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T74', 'T74', 'What is "precision"?', '["Correct / total", "Of all items PREDICTED positive, how many are actually positive — TP/(TP+FP)", "Of all actual positives, how many were found", "Speed"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, options, correct_index, marks, active) values
  ('mcq', 'TECH', 'T75', 'T75', 'In which scenario is recall MORE important than precision?', '["Spam filtering", "Disease screening — false alarms beat missing sick patients", "Recommendations", "Weather"]'::jsonb, 1, 1, true)
on conflict (ext_code) do update set section = excluded.section, body = excluded.body, options = excluded.options, correct_index = excluded.correct_index, kind = excluded.kind, active = true;

-- ---------- coding (optional for the student; stored as plain text) ----------
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L1', 'L1', 'Print the numbers 10 down to 1, one per line.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L2', 'L2', 'Print the sum of all even numbers from 1 to 50.
Expected output: `650`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L3', 'L3', 'Take `n = 7`. Print `n` is divisible by both 3 and 5 or not.
Expected: "Not divisible". Then change n to 15 and re-run — tests whether they hardcoded the answer.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L4', 'L4', 'Print the ASCII value of the character `''K''`.
Expected: `75`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L5', 'L5', 'Given `length = 12` and `breadth = 5`, print the area and perimeter of the rectangle.
Expected: `Area 60, Perimeter 34`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L6', 'L6', 'Given `ch = ''e''`, print whether it is a vowel or a consonant.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L7', 'L7', 'Given `p = 5000, r = 8, t = 3`, print the simple interest.
Expected: `1200`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L8', 'L8', 'Print the squares of the numbers 1 to 10.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L9', 'L9', 'Given a number, print only its last digit. Use `n = 5842`.
Expected: `2`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L10', 'L10', 'Print the first 8 multiples of 5.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L11', 'L11', 'Given the array `{4, 17, 2, 9, 31, 6}`, print the smallest element.
Expected: `2`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L12', 'L12', 'Given the array `{3, 8, 1, 6, 9, 4}`, print how many are even and how many are odd.
Expected: `Even 3, Odd 3`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L13', 'L13', 'Given the array `{10, 20, 30, 40, 50}`, swap the first and last elements and print the array.
Expected: `50 20 30 40 10`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L14', 'L14', 'Given the array `{5, 3, 8, 1}`, add 1 to every element and print the result.
Expected: `6 4 9 2`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L15', 'L15', 'Given the array `{2, 5, 9, 14, 20}`, print whether it is sorted in ascending order.
Expected: `Sorted`. Then change one value and re-run.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L16', 'L16', 'Given the array `{7, 2, 8, 5, 3, 9}`, print only the elements at even indices.
Expected: `7 8 3`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L17', 'L17', 'Find the length of the string `"recruitment"` **without** using `strlen()` or `len()`.
Expected: `11`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L18', 'L18', 'Given `s = "LEAD society tech club"`, count and print the number of spaces.
Expected: `3`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L19', 'L19', 'Print the string `"HELLO"` backwards.
Expected: `OLLEH`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L20', 'L20', 'Given `a = "code"` and `b = "code"`, print whether the two strings are equal. In C, do not use `strcmp()`.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L21', 'L21', 'Given `ch = ''7''`, print whether it is an uppercase letter, a lowercase letter, or a digit.

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L22', 'L22', 'Compute `a` raised to the power `b` using a loop. Use `a = 3, b = 4`.
Expected: `81`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L23', 'L23', 'Print the sum of the squares of the first 6 natural numbers.
Expected: `91`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L24', 'L24', 'Given `seconds = 7384`, print it as hours, minutes and seconds.
Expected: `2 h 3 m 4 s`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L25', 'L25', 'Given marks `78, 65, 91` for three subjects, print the average and whether the student passed (average ≥ 40).
Expected: `78, Pass`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L26', 'L26', 'Given `n = 5`, print this pattern:
```
1
1 2
1 2 3
1 2 3 4
1 2 3 4 5
```

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L27', 'L27', 'Given `n = 49`, print whether it is a perfect square. No `sqrt()`.
Expected: `Yes`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L28', 'L28', 'Given the 3×3 array `{{1,2,3},{4,5,6},{7,8,9}}`, print the sum of the main diagonal.
Expected: `15`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L29', 'L29', 'Given `s = "programming"` and `ch = ''g''`, print how many characters come before the **first** `''g''`.
Expected: `3`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L30', 'L30', 'Given a price of `1500` and GST of `18%`, print the final price rounded to 2 decimals.
Expected: `1770.00`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L31', 'L31', 'Given the array `{6, 3, 6, 9, 3, 6}` and a target `6`, print both the count of the target and the index of its **last** occurrence.
Expected: `Count 3, Last index 5`

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;
insert into quiz.questions (kind, section, ext_code, title, body, marks, language, active) values
  ('coding', null, 'L32', 'L32', 'Given `n = 1234`, print the digits separated by spaces in the original order (`1 2 3 4`, not reversed).

You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.', 0, 'python', true)
on conflict (ext_code) do update set body = excluded.body, marks = excluded.marks, language = excluded.language, kind = excluded.kind, active = true;

-- belt and braces: every coding question names the languages on offer
update quiz.questions
   set body = body || chr(10) || chr(10) || 'You may answer in Python, JavaScript, C, C++ or Java. Python and JavaScript run in the editor; C, C++ and Java are saved and reviewed by the examiners.'
 where kind = 'coding' and active and body not like '%You may answer in Python%';

select 'question bank' as step,
       count(*) filter (where kind='mcq' and section='A'    and active) as sec_a,
       count(*) filter (where kind='mcq' and section='B'    and active) as sec_b,
       count(*) filter (where kind='mcq' and section='C'    and active) as sec_c,
       count(*) filter (where kind='mcq' and section='TECH' and active) as tech,
       count(*) filter (where kind='coding' and active)                 as coding
  from quiz.questions;


-- ##############################  13_paper_template.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 13: paper template
--   Every student gets a freshly randomised paper drawn to a fixed quota:
--     Section A  (logical reasoning)      4
--     Section B  (design)                 3
--     Section C  (marketing & events)     3
--     Technical MCQ                       7
--     Coding (optional, saved as text)    3
--   = 17 MCQ + 3 coding, same shape for everyone, different questions each.
-- Safe to re-run.
-- =====================================================================

alter table quiz.config add column if not exists sec_a_count int not null default 4;
alter table quiz.config add column if not exists sec_b_count int not null default 3;
alter table quiz.config add column if not exists sec_c_count int not null default 3;
alter table quiz.config add column if not exists tech_count  int not null default 7;

update quiz.config
   set sec_a_count = 4, sec_b_count = 3, sec_c_count = 3, tech_count = 7,
       coding_count = 3,
       mcq_count = 17            -- kept in sync; the draw below uses the quotas
 where id = 1;

-- ---------- start_attempt: sectioned, per-student random draw ----------
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
    -- one random draw per section, then the MCQ block itself is shuffled so the
    -- sections are interleaved and two students never see the same order
    with picked as (
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='A'
                       order by random() limit v_cfg.sec_a_count) a
      union all
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='B'
                       order by random() limit v_cfg.sec_b_count) b
      union all
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='C'
                       order by random() limit v_cfg.sec_c_count) c
      union all
      select id from (select id from quiz.questions
                       where kind='mcq' and active and section='TECH'
                       order by random() limit v_cfg.tech_count) t
    ),
    code as (select id from quiz.questions
              where kind='coding' and active order by random() limit v_cfg.coding_count)
    select array(select id from picked order by random())   -- MCQ first, shuffled
         || array(select id from code order by random())    -- coding always last
      into v_ids;

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

grant execute on function public.start_attempt(uuid) to anon, authenticated;

-- ---------- warn loudly if the bank cannot fill the template ----------
do $$
declare c record;
begin
  select (select count(*) from quiz.questions where kind='mcq' and active and section='A')    as a,
         (select count(*) from quiz.questions where kind='mcq' and active and section='B')    as b,
         (select count(*) from quiz.questions where kind='mcq' and active and section='C')    as c,
         (select count(*) from quiz.questions where kind='mcq' and active and section='TECH') as t,
         (select count(*) from quiz.questions where kind='coding' and active)                 as x
    into c;
  if c.a < 4 or c.b < 3 or c.c < 3 or c.t < 7 or c.x < 3 then
    raise warning 'Question bank too small for the template: A=% B=% C=% TECH=% coding=% (need 4/3/3/7/3). Run 12_question_bank.sql.',
      c.a, c.b, c.c, c.t, c.x;
  else
    raise notice 'Paper template OK — drawing 4/3/3/7 MCQ + 3 coding from A=% B=% C=% TECH=% coding=%.',
      c.a, c.b, c.c, c.t, c.x;
  end if;
end $$;


-- ##############################  15_admin_roster.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 15: Students tab (roster + formalities tracker)
--   One row per allowlisted student, plus a count of how many have
--   completed every formality: signed in with Google, entered their name,
--   entered their roll number, and uploaded a photo ID.
-- Safe to re-run.
-- =====================================================================

create or replace function public.admin_roster(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_rows json; v_sum json;
begin
  with r as (
    select a.email,
           a.batch_id,
           a.serial_no,
           b.name                                    as round_name,
           a.full_name                               as listed_name,
           a.roll_hint,
           a.claimed_by                              as roll_no,
           s.full_name                               as given_name,
           s.banned,
           s.consented_at,
           s.last_seen_at,
           exists (select 1 from quiz.id_documents d where d.roll_no = a.claimed_by) as has_id,
           at.status                                 as attempt_status
      from quiz.allowlist a
      left join quiz.batches  b  on b.id      = a.batch_id
      left join quiz.students s  on s.roll_no = a.claimed_by
      left join quiz.attempts at on at.roll_no = a.claimed_by
  ),
  f as (
    select *,
           (roll_no is not null)                           as registered,
           (roll_no is not null
            and coalesce(btrim(given_name), '') <> '')     as complete
      from r
  )
  select json_agg(json_build_object(
           'email', email, 'round_name', round_name, 'batch_id', batch_id,
           'serial_no', serial_no,
           'listed_name', listed_name, 'roll_hint', roll_hint,
           'roll_no', roll_no, 'full_name', given_name,
           'registered', registered, 'has_id', has_id, 'complete', complete,
           'banned', coalesce(banned, false),
           'consented', consented_at is not null,
           'last_seen_at', last_seen_at,
           'attempt_status', attempt_status)
           order by round_name nulls last, serial_no nulls last, email),
         json_build_object(
           'total',      count(*),
           'registered', count(*) filter (where registered),
           'named',      count(*) filter (where coalesce(btrim(given_name), '') <> ''),
           'with_id',    count(*) filter (where has_id),
           'complete',   count(*) filter (where complete),
           'pending',    count(*) filter (where not complete))
    into v_rows, v_sum
    from f;

  return json_build_object('students', coalesce(v_rows, '[]'::json),
                           'summary',  v_sum,
                           'by_round', coalesce((
                             select json_agg(x order by x->>'round_name')
                               from (
                                 select json_build_object(
                                          'round_name', coalesce(b.name, 'Unassigned'),
                                          'total',    count(*),
                                          'complete', count(*) filter (
                                            where a.claimed_by is not null
                                              and coalesce(btrim(s.full_name), '') <> '')) as x
                                   from quiz.allowlist a
                                   left join quiz.batches  b on b.id      = a.batch_id
                                   left join quiz.students s on s.roll_no = a.claimed_by
                                  group by coalesce(b.name, 'Unassigned')
                               ) t), '[]'::json));
end $$;

grant execute on function public.admin_roster(uuid) to anon, authenticated;


-- ##############################  14_roster.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 14: student roster (allowlist for Google sign-in)
--   Batch 1 -> Round 1 (60)   Batch 2 -> Round 2 (59)   Batch 3 -> Round 3 (46)
--   165 unique students. Only these Google accounts can sign in.
--
-- Cleaned before import:
--   * two mistyped addresses corrected (bgarg1_be26@gmail.com,
--     ssharma15_be26@thapar.edu)
--   * duplicate entries removed — one row per person
--   * roll numbers only kept where they are a real 10-digit roll; the
--     spreadsheet's 9.18E+11 values and rows where a phone number was pasted
--     into the roll column are left blank. Roll is a pre-fill hint only —
--     the student types their own at registration and that is what counts.
--   * phone numbers are not imported at all.
--
-- Safe to re-run: existing rows are re-pointed at the right round; a student
-- who has already registered keeps their registration (claimed_by untouched).
-- =====================================================================

-- the serial number from your batch sheet, so a row here can be matched back
-- to the line it came from (1-60 in batch 1 and 2, 1-46 in batch 3)
alter table quiz.allowlist add column if not exists serial_no int;

do $$
declare v1 int; v2 int; v3 int;
begin
  select id into v1 from quiz.batches where name = 'Round 1';
  select id into v2 from quiz.batches where name = 'Round 2';
  select id into v3 from quiz.batches where name = 'Round 3';
  if v1 is null or v2 is null or v3 is null then
    raise exception 'Rounds not found — run 09_rounds.sql first';
  end if;

  -- clear the mistyped addresses if an earlier run of this file loaded them
  delete from quiz.allowlist
   where email in ('bgarg1_be26@gmailcom', 'ssharma15_be26@thpar.edu')
     and claimed_by is null;
  update quiz.allowlist set email = 'bgarg1_be26@gmail.com'
   where email = 'bgarg1_be26@gmailcom';
  update quiz.allowlist set email = 'ssharma15_be26@thapar.edu'
   where email = 'ssharma15_be26@thpar.edu';

  -- and the duplicate person, if they were never claimed
  delete from quiz.allowlist
   where email in ('vvrinda_26@thapar.edu') and claimed_by is null;

  insert into quiz.allowlist (email, batch_id, serial_no, full_name, roll_hint) values
    ('aabhapahuja612@gmail.com', v1, 1, 'Aabha Pahuja', '1026030403'),
    ('nnandita_be26@thapar.edu', v1, 2, 'Nandita', null),
    ('gandhitushar5628@gmail.com', v1, 3, 'Tushar Gandhi', '1026250221'),
    ('ugrover_be26@thapar.edu', v1, 4, 'Uttkarsh Grover', null),
    ('agoyal6_be25@thapar.edu', v1, 5, 'Ananya', '1025060221'),
    ('gsharma4_be26@thapar.edu', v1, 6, 'Gloria Sharma', '1026030019'),
    ('jjapjot_blas26@gmail.com', v1, 7, 'Japjot', '1426000013'),
    ('vgoyal4_be26@thapar.edu', v1, 8, 'Vivaan GOYAL', '1026060002'),
    ('vn07042009@gmail.com', v1, 9, 'Kritika Garg', '1026250250'),
    ('hbhardwaj_be26@thapar.edu', v1, 10, 'Harshil bhardwaj', '1026030061'),
    ('ssengar_be26@thapar.edu', v1, 11, 'Shivam sengar', '1026030893'),
    ('sgarg8_be26@thapar.edu', v1, 12, 'Shiney Garg', '1026030828'),
    ('psingh8_be26@thapar.edu', v1, 13, 'Priyanshi Singh', '1026220060'),
    ('ygoyal1_be26@gmail.com', v1, 14, 'yachika goyal', '1026210035'),
    ('aaaditya_be26@thapar.edu', v1, 15, 'Aaditya Panghal', '1026030491'),
    ('ijain_be26@thapar.edu', v1, 16, 'Ishaan Jain', '1026030105'),
    ('ameel_be26@thapar.edu', v1, 17, 'Aditya Singh Meel', '1026170170'),
    ('apandey2_be26@thapar.edu', v1, 18, 'Ayush Pandey', '1026030588'),
    ('vjain1_be26@thapar.edu', v1, 19, 'Vidit Jain', '1026030122'),
    ('abawa1_be26@thapar.edu', v1, 20, 'Atharv Bawa', '1026030727'),
    ('jkumar_be26@thapar.edu', v1, 21, 'Jashan kumar kansal', '1026170106'),
    ('jchilkoti_be26@thapar.edu', v1, 22, 'Jayant Chilkoti', '1026190014'),
    ('aagarwal7_be26@thapar.edu', v1, 23, 'Ansh Agarwal', '1026060047'),
    ('hjain1_be26@thapar.edu', v1, 24, 'Hardik Jain', '1026220091'),
    ('vbansal1_be26@thapar.edu', v1, 25, 'Vansh Bansal', '1026030163'),
    ('nsoni_be26@thapar.edu', v1, 26, 'Nilay soni', '1026250081'),
    ('jkhurana_be26@thapar.edu', v1, 27, 'Jasleen Kaur Khurana', '1026090009'),
    ('sbatth_be26@thapar.edu', v1, 28, 'Sukhmanveer singh batth', '1026230069'),
    ('aditya2007cool@gmail.com', v1, 29, 'Aditya verma', '1026150180'),
    ('kkrishika_be26@thapar.edu', v1, 30, 'Krishika', '1026150157'),
    ('aangel1_be26@thapar.edu', v1, 31, 'Angel Garg', '1026030974'),
    ('skumar8_be26@thapar.edu', v1, 32, 'Suvansh Kumar', '1026030225'),
    ('agoyal_be26@thapar.edu', v1, 33, 'Aadil Goyal', '1026150166'),
    ('pnautiyal_be26@thapar.edu', v1, 34, 'Pragyan Nautiyal', '1026060093'),
    ('mmahajan3_be26@gmail.com', v1, 35, 'Mihir Mahajan', '1026030541'),
    ('ssimone_be26@thapar.edu', v1, 36, 'Simone', '1026190059'),
    ('sgupta11_be26@thapar.edu', v1, 37, 'Shaurya Gupta', '1026170072'),
    ('mchawla_be26@thapar.edu', v1, 38, 'Mishita chawla', '1026150321'),
    ('vvanshika1_be26@thapar.edu', v1, 39, 'Vanshika', '1026150393'),
    ('ngarg5_be26@thapar.edu', v1, 40, 'Navya garg', '1026030871'),
    ('dbhandari_be26@thapar.edu', v1, 41, 'Daksh Bhandari', '1026030749'),
    ('ssharma26_be26@thapar.edu', v1, 42, 'Sarthakk Sharma', '1026150361'),
    ('rkapur_be27@thapar.edu', v1, 43, 'Ritwik Kapur', '1026090050'),
    ('gkaur6_be26@thapar.edu', v1, 44, 'Gurpriya Kaur', '1026170540'),
    ('tkhosla_be26@thapar.edu', v1, 45, 'Tejas Khosla', '1026170150'),
    ('gchhina_be26@thapar.edu', v1, 46, 'Gurnoor Kaur Chhina', '1026150250'),
    ('gthakur_be26@thapar.edu', v1, 47, 'Gauri Thakur', '1026150123'),
    ('pbhola_be26@gmail.com', v1, 48, 'Piyush Bhola', '1026250029'),
    ('cgambhir_be26@thapar.edu', v1, 49, 'Chahat Gambhir', '1026030521'),
    ('mgoel_be26@thapar.edu', v1, 50, 'Mishthi goel', '1026170333'),
    ('dgupta_be26@thapar.edu', v1, 51, 'Daksh Gupta', null),
    ('kharshit_be26@thapar.edu', v1, 52, 'Kumar Harshit', '1026170173'),
    ('amor_be26@thapar.edu', v1, 53, 'Aryan', '1026030781'),
    ('nsingla1_be26@thapar.edu', v1, 54, 'Nandiika Singla', '1026050138'),
    ('egill_be26@thapar.edu', v1, 55, 'EKJOT GILL', '1026040143'),
    ('aarnav_be26@thapar.edu', v1, 56, 'ARNAV', '1026030043'),
    ('nvijh_be26@thapar.edu', v1, 57, 'Namya Vijh', '1026250191'),
    ('ssakshi_be26@thapar.edu', v1, 58, 'Sakshi', '1026250028'),
    ('hkumar1_be26@thapar.edu', v1, 59, 'Hiten Kumar', '1026030730'),
    ('raditya_bbamba26@thapar.edu', v1, 60, 'RENDUCHINTALA VARSHITH ADITYA', '5526000013'),
    ('ssingh33_be26@thapar.edu', v2, 1, 'Siddharth singh', '1026030395'),
    ('gkamra_be26@thapar.edu', v2, 2, 'gaurish kamra', '1026250035'),
    ('kbhardwaj1_be26@thapar.edu', v2, 3, 'Kshitij Bhardwaj', '1026030285'),
    ('sjain3_be25@thapar.edu', v2, 4, 'Sambhav jain', '1025220092'),
    ('nkaur_be26@thapar.edu', v2, 5, 'Nyamat kaur', '1026030096'),
    ('hdogra_be26@thapar.edu', v2, 6, 'Hardik Dogra', '1026030540'),
    ('jjahnavi_be26@thapar.edu', v2, 7, 'Jahnavi', '1026170176'),
    ('dyadav_1be26@thapar.edu', v2, 8, 'Divyansh Yadav', '1026190113'),
    ('agupta14_be26@gmail.com', v2, 9, 'Anvi', '1026030480'),
    ('bhav.kanu2000@gmail.com', v2, 10, 'BHAVISHYA KUMAR', '1026060038'),
    ('msekhon_be26@thapar.edu', v2, 11, 'MEHAR KAUR SEKHON', '1026030415'),
    ('gbansal_be26@thapar.edu', v2, 12, 'Gunishka bansal', '1026030878'),
    ('bgarg1_be26@gmail.com', v2, 13, 'Bhavya Garg', '1026250199'),
    ('mmadhavi_be26@thapar.edu', v2, 14, 'Madhavi', '1026170054'),
    ('ssabhaarwal_be26@thapar.edu', v2, 15, 'Sabina Sabharwal', '1026030447'),
    ('mkaur4_be26@thapar.edu', v2, 16, 'Mehraj kaur', '1026250200'),
    ('pupadhyay_be26@thapar.edu', v2, 17, 'Pratiksha Upadhyay', '1026030103'),
    ('sshreya_be26@thapar.edu', v2, 18, 'Shreya', '1026170415'),
    ('kballing_be26@thapar.edu', v2, 19, 'Karandeep Singh Balling', '1026250154'),
    ('jsingh21_be26@thapar.edu', v2, 20, 'Jasman Singh', '1026030248'),
    ('aasmi_be26@thapar.edu', v2, 21, 'Asmi', '1026030027'),
    ('mgangwal_be26@thapar.edu', v2, 22, 'Mohit Gangwal', '1026170426'),
    ('gayatria418@gmail.com', v2, 23, 'Gayatri Aggarwal', '1026060157'),
    ('rriya_be26@thapar.edu', v2, 24, 'Riya', '1026150022'),
    ('hkhator_be26@thapar.edu', v2, 25, 'Harshita Khator', '1026060150'),
    ('mgoel1_be26@thapar.edu', v2, 26, 'Mudita Goel', '1026230012'),
    ('pchadha_be26@thapar.edu', v2, 27, 'Prannav Chadha', '1026030666'),
    ('rpoonia_be26@thapar.edu', v2, 28, 'Ryan poonia', '1026030442'),
    ('dchhabra_be26@thapar.edu', v2, 29, 'Dhairya Chhabra', '1026060083'),
    ('gmahay_be26@thapar.edu', v2, 30, 'Guntas Singh Mahay', null),
    ('skaur_be26@thapar.edu', v2, 31, 'Savreen Kaur', '1026250045'),
    ('tsingla1_be26@thapar.edu', v2, 32, 'Tanshiv Singla', '1026030932'),
    ('ljindal_be26@thapar.edu', v2, 33, 'Latisha Jindal', '1026250012'),
    ('ndesai_be26@thapar.edu', v2, 34, 'Nikhil Desai', '1026170360'),
    ('djain4_be@thapar.edu', v2, 35, 'Dhruvika Jain', '1026060067'),
    ('dmalhotra_be26@thapar.edu', v2, 36, 'Devish Malhotra', '1026030250'),
    ('dhananjaygarg739@gmail.com', v2, 37, 'Dhananjay Garg', null),
    ('vvrinda_be26@thapar.edu', v2, 38, 'Vrinda', '1026170327'),
    ('ijairath_be26@thapar.edu', v2, 40, 'Inayat Jairath', '1026030980'),
    ('rsaini1_be26@thapar.edu', v2, 41, 'Raghav Saini', '1026190065'),
    ('rgahlawat_be26@thapar.edu', v2, 42, 'ROHINESH GAHLAWAT', '1026150119'),
    ('akohli_be26@thapar.edu', v2, 43, 'Akul Kohli', null),
    ('kdhand_be26@thapar.edu', v2, 44, 'Krishi Dhand', '1026190012'),
    ('agarg14_be26@thapar.edu', v2, 45, 'Akshra', '1026170212'),
    ('yyatharth1_26@thapar.edu', v2, 46, 'Yatharth', '1026040104'),
    ('rishabhagarwal1994@gmail.com', v2, 47, 'Rishabh Agarwal', '1026030603'),
    ('mkaur13_be26@thapar.edu', v2, 48, 'Mandeep Kaur', '1026030162'),
    ('divgunkaur14@gmail.com', v2, 49, 'Divgun kaur', '1026030185'),
    ('akaistha_be26@thapar.edu', v2, 50, 'Aanya Kaistha', '1026030987'),
    ('ssharma3_be26@thapar.edu', v2, 51, 'Snigdha sharma', '1026150362'),
    ('asinghal_be26@thapar.edu', v2, 52, 'Anwesh Singhal', '1026250058'),
    ('msingla_be26@thapar.edu', v2, 53, 'Moksh singla', '1026170336'),
    ('rkundal_be26@thapar.edu', v2, 54, 'Riddhiman Kundal', '1026030151'),
    ('dsingla3_be26@thapar.edu', v2, 55, 'Disha Singla', '1026170185'),
    ('vsondhi_be26@thapar.edu', v2, 56, 'Viraj sondhi', '1026030353'),
    ('jjhanvi_be26@thapar.edu', v2, 57, 'Jhanvi', '1026030057'),
    ('esingh2_be26@thapar.edu', v2, 58, 'Ekamvir Singh', '1026170504'),
    ('ychauhan_be26@thapar.edu', v2, 59, 'Yashwardhan Singh Chauhan', '1026170080'),
    ('avaid_be26@thapar.edu', v2, 60, 'Anya vaid', '1026180056'),
    ('nchawla1_be26@thapar.edu', v3, 1, 'Nikhil Chawla', '1206030157'),
    ('mbansal_be26@thapar.edu', v3, 2, 'MADHAV BANSAL', '1026170122'),
    ('ebhardwaj_be26@thapar.edu', v3, 3, 'Ehsaas Bhardwaj', '1026030369'),
    ('asharma36_be26@thapar.edu', v3, 4, 'Asmita Sharma', '1026150010'),
    ('dprothia_be26@thapar.edu', v3, 5, 'Devansh Prothia', '1026090012'),
    ('arana4_be26@thapar.edu', v3, 6, 'Aryan Rana', '1026150247'),
    ('sbhattacharya_be26@thapar.edu', v3, 7, 'SHREYAS BHATTACHARYA', '1026030086'),
    ('bjha_be26@thapar.edu', v3, 8, 'Bhavya Jha', '1026170123'),
    ('kgarg6_be26@thapar.edu', v3, 9, 'Kushal Garg', '1026030921'),
    ('rdhannani_be26@thapar.edu', v3, 10, 'Ronak dhannani', '1026170178'),
    ('dmohindru_be26@thapar.edu', v3, 11, 'Divija Mohindru', '1026150267'),
    ('averma12_be26@thapar.edu', v3, 12, 'Agrata Verma', '1026170536'),
    ('skumar3_be26@thapar.edu', v3, 13, 'Saksham Kumar', '1026030929'),
    ('aagrawal1_be26@thapar.edu', v3, 14, 'Aashi Agrawal', '1026030358'),
    ('gsakhuja_be25@thapar.edu', v3, 15, 'Gaurang', '1025210018'),
    ('graheja_be26@thapar.edu', v3, 16, 'Girisha Raheja', '1026170174'),
    ('pmahajan_be26@thapar.edu', v3, 17, 'Pujya mahajan', '1026030975'),
    ('ajha1_be26@thapar.edu', v3, 18, 'AJ', '1026040098'),
    ('akoundal_be26@thapar.edu', v3, 19, 'Arnav Koundal', '1026170279'),
    ('pkataria_be26@thapar.edu', v3, 20, 'Pearl Kataria', '1026030409'),
    ('dishita312008@gmail.com', v3, 21, 'dishita gupta', '1026030302'),
    ('ksingh1_be26@thapar.edu', v3, 22, 'Keerti Singh', '1026230009'),
    ('vgoel1_be26@thapar.edu', v3, 23, 'Vivan Goel', '1026090004'),
    ('grovertanvi08@gmail.com', v3, 24, 'Tanvi Grover', '1026170520'),
    ('jhanvinain14@gmail.com', v3, 25, 'Jhanvi', null),
    ('sgupta18_be26@thapar.edu', v3, 26, 'Siddhant Gupta', '1026030894'),
    ('aagarwal10_be26@thapar.edu', v3, 27, 'Ankita Agarwal', '1026250087'),
    ('vaibhavi.v109@gmail.com', v3, 28, 'Vaibhavi Verma', '1026250119'),
    ('ssrishty_be26@thapar.edu', v3, 29, 'srishty', '1026250053'),
    ('pprisha_be26@thapar.edu', v3, 30, 'PRISHA', '1026080073'),
    ('kbiswas_be26@thapar.edu', v3, 31, 'Kaushiki Biswas', '1026170141'),
    ('abhardwaj_be26@thapar.edu', v3, 32, 'Aditya Bhardwaj', '1026170223'),
    ('ddivyam_be26@thapar.edu', v3, 33, 'Divyam', '1026030712'),
    ('smishra2_be26@thapar.edu', v3, 34, 'Shaurya Mishra', '1026030846'),
    ('pagrahari_be26@thapar.edu', v3, 35, 'PRANEY AGRAHARI', '1026250136'),
    ('bhavyakhandelwal637@gmail.com', v3, 36, 'Bhavya Khandelwal', '1026150300'),
    ('ssarin_be26@thapar.edu', v3, 37, 'Shivangini Sarin', '1026170066'),
    ('pojha_be26@thapar.edu', v3, 38, 'Piyush Raj Ojha', '1026150238'),
    ('sratna_be26@thapar.edu', v3, 39, 'Shambhav Ratna', '1026170097'),
    ('bansalkhushi232@gmail.com', v3, 40, 'Khushi Bansal', '1026030452'),
    ('bmittal_be26@thapar.edu', v3, 41, 'Bhavi Mittal', '1026030977'),
    ('ssaxena_be26@thapar.edu', v3, 42, 'Shivangi Saxena', '1026030150'),
    ('ssharma15_be26@thapar.edu', v3, 43, 'Saksham Sharma', '1026003052'),
    ('rridhi_be26@thapar.edu', v3, 44, 'Ridhi', '1026170265'),
    ('dmittal3_be26@thapar.edu', v3, 45, 'Devangi Mittal', '1026060099'),
    ('lhanda_be26@thapar.edu', v3, 46, 'Lavya Handa', '1026250083')
  on conflict (email) do update
     -- batch_id deliberately NOT updated: a round you have changed by hand stays changed
     set serial_no = excluded.serial_no,
         full_name = coalesce(excluded.full_name, quiz.allowlist.full_name),
         roll_hint = excluded.roll_hint;

  -- a student who registered before their round was known gets placed now.
  -- Anyone an admin has deliberately moved (e.g. to Backup) is left alone.
  update quiz.students s
     set batch_id = a.batch_id
    from quiz.allowlist a
   where a.claimed_by = s.roll_no and a.batch_id is not null and s.batch_id is null;
end $$;

select 'roster' as step, b.name as round, count(*) as allowlisted,
       count(a.claimed_by) as registered,
       count(a.roll_hint)  as with_roll_hint,
       min(a.serial_no)||'-'||max(a.serial_no) as serial_range
  from quiz.allowlist a join quiz.batches b on b.id = a.batch_id
 group by b.name order by b.name;

-- every address should be a real thapar.edu or gmail.com address; this must return no rows
select 'check this address' as step, a.email, b.name as round, a.full_name
  from quiz.allowlist a left join quiz.batches b on b.id = a.batch_id
 where a.email !~ '^[^@]+@(thapar\.edu|gmail\.com)$'
 order by a.email;


-- ##############################  17_round_pools.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 17: round-specific pools, 20-minute papers,
--                        coding remarked instead of marked
--
-- 1. Every round gets its own exclusive slice of the bank. More than half
--    of each paper (10 of 17 MCQ, 2 of 3 coding) is drawn from questions
--    NO OTHER ROUND CAN SEE, so a Round 2 student briefed by a Round 1
--    friend still meets mostly fresh questions. The rest come from a
--    shared pool — those may repeat across rounds, but the paper order and
--    the option order are randomised per student, so they never arrive
--    arranged the same way.
-- 2. 20 minutes per student inside a 30-minute round window.
-- 3. Coding carries no marks. Proctors leave a written remark instead.
--
-- Safe to re-run. The pool split is deterministic — re-running does not
-- reshuffle which question belongs to which round.
-- =====================================================================

-- ---------------------------------------------------------------- 1. pools
alter table quiz.questions add column if not exists round_pool int;   -- null = shared
alter table quiz.batches   add column if not exists pool_no    int;   -- slice this round draws

do $$ begin
  alter table quiz.questions add constraint questions_round_pool_ck
    check (round_pool is null or round_pool between 1 and 4);
exception when duplicate_object then null; end $$;

update quiz.batches set pool_no = case name
         when 'Round 1' then 1 when 'Round 2' then 2
         when 'Round 3' then 3 when 'Round 4 (Backup)' then 4 end
 where name in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)');

-- Deterministic split, per section and for coding: the first ~30% by id stay
-- shared, the rest are dealt round-robin to rounds 1-4.
with ranked as (
  select id,
         row_number() over (partition by coalesce(section, 'CODING') order by id) as rn,
         ceil(count(*) over (partition by coalesce(section, 'CODING')) * 0.30)    as shared_n
    from quiz.questions
   where active and ext_code is not null
)
update quiz.questions q
   set round_pool = case when r.rn <= r.shared_n then null
                         else ((r.rn - r.shared_n - 1)::int % 4) + 1 end
  from ranked r
 where q.id = r.id;

-- how much of each paper must come from the round's own slice (the rest is shared)
alter table quiz.config add column if not exists sec_a_excl  int not null default 2;
alter table quiz.config add column if not exists sec_b_excl  int not null default 2;
alter table quiz.config add column if not exists sec_c_excl  int not null default 2;
alter table quiz.config add column if not exists tech_excl   int not null default 4;
alter table quiz.config add column if not exists coding_excl int not null default 2;

-- ------------------------------------------------- 2. 20 minutes in a 30 window
update quiz.config
   set duration_minutes = 20,
       sec_a_count = 4, sec_b_count = 3, sec_c_count = 3, tech_count = 7,
       coding_count = 3, mcq_count = 17,
       sec_a_excl = 2, sec_b_excl = 2, sec_c_excl = 2, tech_excl = 4, coding_excl = 2
 where id = 1;

-- null duration on the round = use the 20 minutes from config
update quiz.batches set window_minutes = 30, duration_minutes = null
 where name in ('Round 1', 'Round 2', 'Round 3', 'Round 4 (Backup)');

-- ------------------------------------ 3. coding is not marked, only remarked
alter table quiz.answers add column if not exists remark text;

update quiz.questions set marks = 0 where kind = 'coding';

-- Total score is the MCQ score. Coding is read and commented on, never added up.
create or replace function quiz.recompute_scores(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
declare v_mcq numeric;
begin
  select coalesce(sum(q.marks), 0) into v_mcq
    from quiz.answers a join quiz.questions q on q.id = a.question_id
   where a.attempt_id = p_attempt and q.kind = 'mcq' and a.selected_index = q.correct_index;

  update quiz.attempts
     set mcq_score = v_mcq, coding_score = 0, total_score = v_mcq
   where id = p_attempt;
end $$;

-- Written remark on one coding answer. Replaces marking it out of 5.
create or replace function public.admin_remark_coding(p_token uuid, p_roll text,
                                                      p_question_id int, p_remark text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if not exists (select 1 from quiz.questions where id = p_question_id and kind = 'coding') then
    raise exception 'NOT_A_CODING_QUESTION';
  end if;

  insert into quiz.answers (attempt_id, question_id, remark, graded_by)
  values (v_att.id, p_question_id, nullif(btrim(p_remark), ''), v_admin)
  on conflict (attempt_id, question_id)
  do update set remark = nullif(btrim(excluded.remark), ''), graded_by = excluded.graded_by;

  perform quiz.audit(v_admin, 'REMARK_CODING', p_roll,
                     json_build_object('question_id', p_question_id)::jsonb);
  return json_build_object('ok', true);
end $$;

grant execute on function public.admin_remark_coding(uuid, text, int, text) to anon, authenticated;

-- ---------------------------------------------------- the draw itself
-- Picks p_excl questions from this round's own slice, then tops the paper up
-- to p_total from the shared pool. If a slice is short, the shortfall comes
-- from shared; if the whole section is short, from whatever is left. A paper
-- is never short and never contains the same question twice.
create or replace function quiz.pick_questions(p_kind text, p_section text, p_pool int,
                                               p_excl int, p_total int)
returns table (id int) language plpgsql security definer set search_path = quiz, public as $$
declare v_ids int[] := '{}';
begin
  if p_pool is not null and p_excl > 0 then
    select array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and (p_section is null or q.section = p_section)
                    and q.round_pool = p_pool
                  order by random() limit p_excl)
      into v_ids;
  end if;

  select v_ids || array(select q.id from quiz.questions q
                where q.kind = p_kind and q.active
                  and (p_section is null or q.section = p_section)
                  and q.round_pool is null
                  and not (q.id = any (v_ids))
                order by random()
                limit greatest(p_total - coalesce(array_length(v_ids, 1), 0), 0))
    into v_ids;

  if coalesce(array_length(v_ids, 1), 0) < p_total then
    select v_ids || array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and (p_section is null or q.section = p_section)
                    and not (q.id = any (v_ids))
                  order by random()
                  limit p_total - coalesce(array_length(v_ids, 1), 0))
      into v_ids;
  end if;

  return query select unnest(v_ids);
end $$;

create or replace function public.start_attempt(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_roll  text := quiz.student_from_token(p_token);
  v_cfg   quiz.config;
  v_batch quiz.batches;
  v_pool  int;
  v_ids   int[];
  v_minutes int;
begin
  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.exam_open then raise exception 'EXAM_CLOSED'; end if;

  select b.* into v_batch from quiz.batches b
    join quiz.students s on s.batch_id = b.id
   where s.roll_no = v_roll;
  if v_batch.id is null   then raise exception 'NO_BATCH'; end if;
  if not v_batch.is_open  then raise exception 'BATCH_CLOSED'; end if;
  if v_batch.closes_at is not null and now() > v_batch.closes_at then
    raise exception 'ROUND_ENDED';
  end if;

  if (select count(*) from quiz.attempts where status in ('in_progress', 'paused'))
       >= v_cfg.max_concurrent then
    raise exception 'CAPACITY_FULL';
  end if;

  v_minutes := coalesce(v_batch.duration_minutes, v_cfg.duration_minutes);
  v_pool    := v_batch.pool_no;        -- null on a round with no slice: shared only

  if not exists (select 1 from quiz.students
                  where roll_no = v_roll and consented_at is not null) then
    raise exception 'CONSENT_REQUIRED';
  end if;

  if not exists (select 1 from quiz.attempts where roll_no = v_roll) then
    with picked as (
               select * from quiz.pick_questions('mcq', 'A',    v_pool, v_cfg.sec_a_excl, v_cfg.sec_a_count)
      union all select * from quiz.pick_questions('mcq', 'B',    v_pool, v_cfg.sec_b_excl, v_cfg.sec_b_count)
      union all select * from quiz.pick_questions('mcq', 'C',    v_pool, v_cfg.sec_c_excl, v_cfg.sec_c_count)
      union all select * from quiz.pick_questions('mcq', 'TECH', v_pool, v_cfg.tech_excl,  v_cfg.tech_count)
    ),
    code as (select * from quiz.pick_questions('coding', null, v_pool,
                                               v_cfg.coding_excl, v_cfg.coding_count))
    select array(select id from picked order by random())    -- MCQ first, shuffled
        || array(select id from code  order by random())     -- coding always last
      into v_ids;

    if coalesce(array_length(v_ids, 1), 0) = 0 then raise exception 'NO_QUESTIONS'; end if;

    insert into quiz.attempts (roll_no, question_ids, deadline_at)
    values (v_roll, v_ids,
            least(now() + make_interval(mins => v_minutes),
                  coalesce(v_batch.closes_at, now() + make_interval(mins => v_minutes))))
    on conflict (roll_no) do nothing;
  end if;

  update quiz.sessions set revoked = true
   where kind = 'student' and subject = v_roll and not revoked and token <> p_token;

  return public.get_exam_state(p_token);
end $$;

grant execute on function public.start_attempt(uuid) to anon, authenticated;

-- ---------------------------------------------------- report the split
do $$
declare r record;
begin
  for r in
    select coalesce(section, 'CODING') as sec,
           count(*) filter (where round_pool is null) as shared,
           count(*) filter (where round_pool = 1) as r1,
           count(*) filter (where round_pool = 2) as r2,
           count(*) filter (where round_pool = 3) as r3,
           count(*) filter (where round_pool = 4) as r4
      from quiz.questions where active and ext_code is not null
     group by 1 order by 1
  loop
    raise notice 'Pool split %: shared=% R1=% R2=% R3=% R4=%', r.sec, r.shared, r.r1, r.r2, r.r3, r.r4;
  end loop;
end $$;


-- ##############################  18_extend_time_fix.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 18: extending time actually works
--
-- The trap this fixes: a proctor gives a student who dropped offline 10
-- extra minutes, but the ROUND WINDOW closes first and sweep_expired()
-- force-submits them anyway with reason ROUND_ENDED. The extension looked
-- like it worked and silently did nothing. That is far more likely now
-- that students sit the test from their own homes and connections.
--
-- admin_extend_time now pushes the round's closing time out far enough to
-- cover the extension, and reports what it did. This does NOT give anyone
-- else extra time: every student still has their own deadline_at, and the
-- window is only the backstop that catches stragglers.
-- Safe to re-run.
-- =====================================================================

create or replace function public.admin_extend_time(p_token uuid, p_roll text, p_minutes int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin    text := quiz.admin_from_token(p_token);
  v_deadline timestamptz;
  v_batch    quiz.batches;
  v_pushed   boolean := false;
begin
  update quiz.attempts set deadline_at = greatest(deadline_at, now()) + make_interval(mins => p_minutes)
   where roll_no = p_roll and status = 'in_progress'
  returning deadline_at into v_deadline;
  if not found then raise exception 'NOT_IN_PROGRESS'; end if;

  select b.* into v_batch from quiz.batches b
    join quiz.students s on s.batch_id = b.id
   where s.roll_no = p_roll;

  -- keep the round open long enough for the extension to be usable
  if v_batch.id is not null and v_batch.closes_at is not null
     and v_batch.closes_at < v_deadline then
    update quiz.batches set closes_at = v_deadline + interval '1 minute'
     where id = v_batch.id;
    v_pushed := true;
  end if;

  perform quiz.audit(v_admin, 'EXTEND_TIME', p_roll,
                     json_build_object('minutes', p_minutes,
                                       'round_window_pushed', v_pushed)::jsonb);
  return json_build_object('ok', true, 'deadline_at', v_deadline,
                           'round_window_pushed', v_pushed,
                           'round_closes_at', case when v_pushed then v_deadline + interval '1 minute'
                                                   else v_batch.closes_at end);
end $$;

grant execute on function public.admin_extend_time(uuid, text, int) to anon, authenticated;


-- ##############################  19_activity_timer.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 19: the clock only runs while the student is there
--
-- Before: the deadline was a fixed wall-clock time set when they pressed
-- Start. A student whose laptop died lost that time for good.
--
-- Now: the attempt accumulates elapsed_seconds, and that only advances
-- when the student's browser actually calls in. The browser heartbeats
-- every 10 seconds, so a gap of up to 25 seconds is counted as normal
-- working time (network jitter); anything beyond that is recorded as
-- offline_seconds and costs the student nothing.
--
-- deadline_at is kept up to date as "when they would finish if they stay
-- online from here", so the countdown in the student's browser and every
-- existing screen keep working unchanged.
--
-- The ROUND WINDOW is still a hard wall: when it shuts, everyone still
-- open is submitted (ROUND_ENDED), online or not. That is the backstop
-- that stops a disconnected student sitting in limbo forever.
--
-- TRADE-OFF, stated plainly: a student can now stop their own clock by
-- pulling their network cable. offline_seconds is recorded per attempt so
-- a proctor can see exactly who did that and for how long, and the round
-- window caps the total damage.
-- Safe to re-run.
-- =====================================================================

alter table quiz.attempts add column if not exists elapsed_seconds numeric not null default 0;
alter table quiz.attempts add column if not exists offline_seconds numeric not null default 0;
alter table quiz.attempts add column if not exists last_tick_at    timestamptz;
alter table quiz.attempts add column if not exists duration_seconds int;

-- how long a silence still counts as working time (heartbeat is every 10s)
create or replace function quiz.tick_grace() returns int language sql immutable as $$ select 25 $$;

-- Every new attempt gets its own budget, taken from the round (or config).
create or replace function quiz.attempt_defaults()
returns trigger language plpgsql security definer set search_path = quiz, public as $$
begin
  if new.duration_seconds is null then
    select coalesce(b.duration_minutes, c.duration_minutes) * 60
      into new.duration_seconds
      from quiz.config c
      left join quiz.students s on s.roll_no = new.roll_no
      left join quiz.batches  b on b.id = s.batch_id
     where c.id = 1;
    new.duration_seconds := coalesce(new.duration_seconds, 20 * 60);
  end if;
  new.last_tick_at := coalesce(new.last_tick_at, now());
  return new;
end $$;

drop trigger if exists attempts_defaults on quiz.attempts;
create trigger attempts_defaults before insert on quiz.attempts
  for each row execute function quiz.attempt_defaults();

-- existing attempts keep their budget
update quiz.attempts a
   set duration_seconds = coalesce(a.duration_seconds,
         (select coalesce(b.duration_minutes, c.duration_minutes) * 60
            from quiz.config c
            left join quiz.students s on s.roll_no = a.roll_no
            left join quiz.batches  b on b.id = s.batch_id
           where c.id = 1), 1200)
 where a.duration_seconds is null;

-- Attempts that were ALREADY RUNNING before this timer existed (last_tick_at is
-- null): bill them for the time they have genuinely used, so nobody writing
-- right now gets a fresh 20 minutes. Runs once per attempt; re-running is a no-op.
update quiz.attempts a
   set elapsed_seconds = least(greatest(extract(epoch from
                           (coalesce(a.paused_at, a.submitted_at, now()) - a.started_at)), 0),
                           a.duration_seconds),
       last_tick_at    = now()
 where a.last_tick_at is null;

-- ---------------------------------------------------------------------
-- The tick. Called only from things the STUDENT does, never from the cron
-- sweep — that is what makes an offline student's clock stand still.
-- ---------------------------------------------------------------------
create or replace function quiz.tick(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
declare v quiz.attempts; v_gap numeric; v_counted numeric;
begin
  select * into v from quiz.attempts where id = p_attempt;
  if v.id is null or v.status <> 'in_progress' then return; end if;

  v_gap := greatest(extract(epoch from (now() - coalesce(v.last_tick_at, v.started_at))), 0);
  v_counted := least(v_gap, quiz.tick_grace());

  update quiz.attempts
     set elapsed_seconds = elapsed_seconds + v_counted,
         offline_seconds = offline_seconds + (v_gap - v_counted),
         last_tick_at    = now(),
         deadline_at     = now() + make_interval(secs =>
                             greatest(coalesce(duration_seconds, 1200)
                                      - (elapsed_seconds + v_counted), 0))
   where id = p_attempt;
end $$;

-- Time is up when they have USED their budget, not when a wall clock passes.
create or replace function quiz.expire_if_needed(p_attempt uuid)
returns void language plpgsql security definer set search_path = quiz, public as $$
begin
  perform quiz.tick(p_attempt);
  if exists (select 1 from quiz.attempts
              where id = p_attempt and status = 'in_progress'
                and elapsed_seconds >= coalesce(duration_seconds, 1200)) then
    perform quiz.finalize_attempt(p_attempt, 'submitted', 'TIME_UP');
  end if;
end $$;

-- The sweep deliberately does NOT tick. It only ends people who have
-- genuinely used their time, plus everyone caught by the round window.
create or replace function quiz.sweep_expired()
returns int language plpgsql security definer set search_path = quiz, public as $$
declare r record; n int := 0;
begin
  -- 1. students who have used their whole budget
  for r in select id from quiz.attempts
            where status = 'in_progress'
              and elapsed_seconds >= coalesce(duration_seconds, 1200)
  loop
    perform quiz.finalize_attempt(r.id, 'submitted', 'TIME_UP');
    n := n + 1;
  end loop;

  -- 2. the round window closing ends EVERYTHING still open, paused and
  --    disconnected attempts included. This is the hard wall.
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

-- Resuming after a pause must not bill the student for the pause.
create or replace function public.admin_resume_attempt(p_token uuid, p_roll text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_att quiz.attempts; v_left numeric;
begin
  select * into v_att from quiz.attempts where roll_no = p_roll;
  if v_att.id is null then raise exception 'NO_ATTEMPT'; end if;
  if v_att.status <> 'paused' then raise exception 'NOT_PAUSED'; end if;

  v_left := greatest(coalesce(v_att.duration_seconds, 1200) - v_att.elapsed_seconds, 0);
  update quiz.attempts
     set status = 'in_progress', paused_at = null,
         last_tick_at = now(),                       -- the pause costs nothing
         deadline_at  = now() + make_interval(secs => v_left)
   where id = v_att.id;

  insert into quiz.messages (roll_no, sender, sender_name, body, read_by_admin)
  values (p_roll, 'admin', v_admin, 'Your test has been resumed. Return to fullscreen to continue.', true);
  perform quiz.audit(v_admin, 'RESUME_ATTEMPT', p_roll,
                     json_build_object('restored_seconds', v_left::int)::jsonb);
  return json_build_object('ok', true, 'restored_seconds', v_left::int);
end $$;

-- Extending now adds to the student's BUDGET, not to a wall-clock time.
create or replace function public.admin_extend_time(p_token uuid, p_roll text, p_minutes int)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_admin    text := quiz.admin_from_token(p_token);
  v_att      quiz.attempts;
  v_deadline timestamptz;
  v_batch    quiz.batches;
  v_pushed   boolean := false;
begin
  update quiz.attempts
     set duration_seconds = coalesce(duration_seconds, 1200) + p_minutes * 60,
         deadline_at = now() + make_interval(secs =>
                         greatest(coalesce(duration_seconds, 1200) + p_minutes * 60
                                  - elapsed_seconds, 0))
   where roll_no = p_roll and status = 'in_progress'
  returning * into v_att;
  if not found then raise exception 'NOT_IN_PROGRESS'; end if;
  v_deadline := v_att.deadline_at;

  select b.* into v_batch from quiz.batches b
    join quiz.students s on s.batch_id = b.id
   where s.roll_no = p_roll;

  -- keep the round open long enough for the extension to be usable
  if v_batch.id is not null and v_batch.closes_at is not null
     and v_batch.closes_at < v_deadline then
    update quiz.batches set closes_at = v_deadline + interval '1 minute'
     where id = v_batch.id;
    v_pushed := true;
  end if;

  perform quiz.audit(v_admin, 'EXTEND_TIME', p_roll,
                     json_build_object('minutes', p_minutes,
                                       'round_window_pushed', v_pushed)::jsonb);
  return json_build_object('ok', true, 'deadline_at', v_deadline,
                           'round_window_pushed', v_pushed);
end $$;

grant execute on function public.admin_resume_attempt(uuid, text) to anon, authenticated;
grant execute on function public.admin_extend_time(uuid, text, int) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Show proctors who has been disconnected, and for how long.
-- ---------------------------------------------------------------------
create or replace function public.admin_offline_report(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  return coalesce((
    select json_agg(json_build_object(
      'roll_no', a.roll_no, 'full_name', s.full_name, 'status', a.status,
      'minutes_used',    round(a.elapsed_seconds / 60.0, 1),
      'minutes_offline', round(a.offline_seconds / 60.0, 1),
      'minutes_allowed', round(coalesce(a.duration_seconds, 1200) / 60.0, 1),
      'last_seen_at', a.last_tick_at)
      order by a.offline_seconds desc)
    from quiz.attempts a
    join quiz.students s on s.roll_no = a.roll_no
   where a.offline_seconds > 30), '[]'::json);
end $$;

grant execute on function public.admin_offline_report(uuid) to anon, authenticated;
-- NOTE: Student Live already shows who is silent right now (the green/grey dot
-- is driven by last_seen_at). admin_offline_report above is the place to see
-- accumulated lost time, so admin_live is deliberately left untouched.


-- ##############################  20_round_schedule.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 20: each round gets a scheduled date and time
--   Round 1   16 September 2026, 6:00 PM IST
--   Round 2   16 September 2026, 6:30 PM IST
--   Round 3   16 September 2026, 7:00 PM IST
--   Round 4 (Backup) — no fixed time; opened only if it is needed.
--
-- This is what the student sees on the waiting screen, next to their round.
-- It does NOT start the round: a proctor still opens each one by hand, and
-- the 30-minute window starts from the moment they do.
-- Safe to re-run.
-- =====================================================================

alter table quiz.batches add column if not exists starts_at timestamptz;

update quiz.batches set starts_at = timestamptz '2026-09-16 18:00:00+05:30' where name = 'Round 1';
update quiz.batches set starts_at = timestamptz '2026-09-16 18:30:00+05:30' where name = 'Round 2';
update quiz.batches set starts_at = timestamptz '2026-09-16 19:00:00+05:30' where name = 'Round 3';
update quiz.batches set starts_at = null                                    where name = 'Round 4 (Backup)';

-- get_exam_state hands starts_at to the student; that edit lives in
-- 02_student_api.sql, next to the rest of the batch payload.

-- Let an admin set or clear a round's scheduled time.
create or replace function public.admin_set_batch_schedule(p_token uuid, p_batch_id int,
                                                           p_starts_at timestamptz)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_b quiz.batches;
begin
  update quiz.batches set starts_at = p_starts_at where id = p_batch_id returning * into v_b;
  if v_b.id is null then raise exception 'NO_SUCH_BATCH'; end if;
  perform quiz.audit(v_admin, 'SET_BATCH_SCHEDULE', v_b.name,
                     json_build_object('starts_at', p_starts_at)::jsonb);
  return row_to_json(v_b);
end $$;

grant execute on function public.admin_set_batch_schedule(uuid, int, timestamptz) to anon, authenticated;

select 'round schedule' as step, name,
       to_char(starts_at at time zone interval '+05:30', 'DD-MM-YYYY HH12:MI AM') as starts_at_ist,
       window_minutes
  from quiz.batches order by name;


-- ##############################  21_no_round_cap.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 21: no cap on how many students a round can hold
--
-- There was never a per-round limit in the schema: a round holds however
-- many students point at it, and you can move anyone into any round at
-- any time (Registrations -> the Round dropdown on each row).
--
-- The one ceiling that existed was global: quiz.config.max_concurrent,
-- how many students may sit the test at the same MOMENT. It was 200 —
-- above your 60-per-round plan, but below the 165 + test accounts you
-- would need if you ever put everybody in one round. Raised to 400 so no
-- round size can hit it.
--
-- It is not removed entirely: it is the one thing that stops a runaway
-- loop or a mistake from opening thousands of attempts at once. 400 is
-- more than double the entire cohort.
-- Safe to re-run.
-- =====================================================================

alter table quiz.config alter column max_concurrent set default 400;
update quiz.config set max_concurrent = greatest(max_concurrent, 400) where id = 1;

select 'capacity' as step,
       max_concurrent                                  as students_at_once,
       (select count(*) from quiz.allowlist)            as students_on_roster,
       (select count(*) from quiz.batches)              as rounds
  from quiz.config where id = 1;

-- how full each round is right now — a report, never a limit
select 'round sizes' as step, b.name,
       count(a.email)                                   as allowlisted,
       count(a.claimed_by)                              as registered,
       to_char(b.starts_at at time zone interval '+05:30', 'DD-MM-YYYY HH12:MI AM') as starts_at_ist
  from quiz.batches b
  left join quiz.allowlist a on a.batch_id = b.id
 group by b.name, b.starts_at
 order by b.name;


-- ##############################  22_no_id_storage.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 22: photo IDs are no longer stored
--
-- Registration still asks for a photo, but the browser never sends it and
-- the database never keeps it. Stored ID images were using up database
-- space ("memory low" during upload), so they are cleared here.
--
-- Already-registered students are NOT affected: their registration, name,
-- roll number, round, answers and attempts all stay exactly as they are.
-- Only the ID images are removed.
-- Safe to re-run.
-- =====================================================================

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
  -- p_id_mime / p_id_b64 are accepted for compatibility and deliberately ignored.

  insert into quiz.students (roll_no, password_hash, full_name, email, batch_id)
  values (v_roll, quiz.hash_password(gen_random_uuid()::text),   -- no password: Google only
          trim(p_full_name), v_email, a.batch_id);

  update quiz.allowlist set claimed_by = v_roll where email = v_email;

  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', v_roll, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('token', v_token, 'roll_no', v_roll,
                           'full_name', trim(p_full_name), 'email', v_email,
                           'needs_registration', false);
end $$;

grant execute on function public.student_register(text, text, text, text, text) to anon, authenticated;

-- clear the images already stored (students themselves are untouched)
delete from quiz.id_documents;

select 'id images stored' as step, count(*) as remaining from quiz.id_documents
union all
select 'registered students kept', count(*) from quiz.students where email is not null;


-- ##############################  23_public_quiz.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 23: the open quiz (default sign-in page)
--
-- A separate entry page for an open quiz. There is no registration list:
-- anyone whose Google address contains "be26" or "btech26" may register,
-- and they are placed in their own round, "Open Quiz", which draws from
-- the whole question bank.
--
-- The recruitment quiz is untouched: its sign-in and registration functions
-- are not modified, its rounds and students are not moved, and nobody on the
-- recruitment list can register through the public page.
-- Safe to re-run.
-- =====================================================================

alter table quiz.config add column if not exists public_quiz_enabled   boolean not null default true;
alter table quiz.config add column if not exists public_email_patterns text[]  not null default array['be26', 'btech26'];

-- renamed from "Public Quiz": the same round, with everyone already in it
update quiz.batches set name = 'Open Quiz'
 where name = 'Public Quiz'
   and not exists (select 1 from quiz.batches where name = 'Open Quiz');

insert into quiz.batches (name, is_open, window_minutes)
values ('Open Quiz', false, 60)
on conflict (name) do nothing;
update quiz.batches set pool_no = 0 where name = 'Open Quiz';

-- Case-insensitive "does the address contain one of the patterns".
create or replace function quiz.public_email_ok(p_email text)
returns boolean language sql stable security definer set search_path = quiz, public as $$
  select coalesce(bool_or(position(lower(p) in lower(coalesce(p_email, ''))) > 0), false)
    from quiz.config c, unnest(c.public_email_patterns) p
   where c.id = 1;
$$;

create or replace function quiz.pick_questions(p_kind text, p_section text, p_pool int,
                                               p_excl int, p_total int)
returns table (id int) language plpgsql security definer set search_path = quiz, public as $$
declare v_ids int[] := '{}';
begin
  -- pool 0 = the open quiz: draw from the whole bank, no round slices
  if p_pool = 0 then
    return query select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and (p_section is null or q.section = p_section)
                  order by random() limit p_total;
    return;
  end if;

  if p_pool is not null and p_excl > 0 then
    select array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and (p_section is null or q.section = p_section)
                    and q.round_pool = p_pool
                  order by random() limit p_excl)
      into v_ids;
  end if;

  select v_ids || array(select q.id from quiz.questions q
                where q.kind = p_kind and q.active
                  and (p_section is null or q.section = p_section)
                  and q.round_pool is null
                  and not (q.id = any (v_ids))
                order by random()
                limit greatest(p_total - coalesce(array_length(v_ids, 1), 0), 0))
    into v_ids;

  if coalesce(array_length(v_ids, 1), 0) < p_total then
    select v_ids || array(select q.id from quiz.questions q
                  where q.kind = p_kind and q.active
                    and (p_section is null or q.section = p_section)
                    and not (q.id = any (v_ids))
                  order by random()
                  limit p_total - coalesce(array_length(v_ids, 1), 0))
      into v_ids;
  end if;

  return query select unnest(v_ids);
end $$;

-- ---------- sign-in from the public page ----------
create or replace function public.public_quiz_login_google(p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_claims jsonb; v_email text; s quiz.students; v_token uuid; v_cfg quiz.config;
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

  select * into s from quiz.students where lower(email) = v_email;
  if s.roll_no is not null and s.banned then raise exception 'BANNED'; end if;

  -- already registered (public or recruitment): sign in exactly as the main page does
  if s.roll_no is not null then
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

  -- on the recruitment list but not registered: keep them on their own quiz
  if exists (select 1 from quiz.allowlist where email = v_email) then
    raise exception 'USE_MAIN_PAGE';
  end if;

  select * into v_cfg from quiz.config where id = 1;
  if not v_cfg.public_quiz_enabled then raise exception 'PUBLIC_QUIZ_CLOSED'; end if;
  if not quiz.public_email_ok(v_email) then raise exception 'PUBLIC_EMAIL_NOT_ELIGIBLE'; end if;

  return json_build_object('needs_registration', true, 'email', v_email,
                           'full_name', nullif(trim(coalesce(v_claims ->> 'name', '')), ''),
                           'roll_hint', null, 'public', true);
end $$;

-- ---------- one-time registration from the public page ----------
create or replace function public.public_quiz_register(p_roll text, p_full_name text,
                                                       p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_claims jsonb; v_email text; v_roll text; v_token uuid; v_batch int; v_cfg quiz.config;
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

  -- listed alongside everyone else, so Students / Registrations / Student Live all show them
  insert into quiz.allowlist (email, batch_id, full_name, claimed_by)
  values (v_email, v_batch, trim(p_full_name), v_roll)
  on conflict (email) do nothing;

  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', v_roll, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('token', v_token, 'roll_no', v_roll,
                           'full_name', trim(p_full_name), 'email', v_email,
                           'needs_registration', false, 'public', true);
end $$;

-- ---------- admin: switch the public page on/off, change the address rule ----------
create or replace function public.admin_set_public_quiz(p_token uuid, p_enabled boolean,
                                                        p_patterns text[] default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token);
begin
  update quiz.config
     set public_quiz_enabled   = coalesce(p_enabled, public_quiz_enabled),
         public_email_patterns = coalesce(p_patterns, public_email_patterns)
   where id = 1;
  perform quiz.audit(v_admin, 'SET_PUBLIC_QUIZ', null,
                     json_build_object('enabled', p_enabled, 'patterns', p_patterns)::jsonb);
  return (select json_build_object('enabled', public_quiz_enabled, 'patterns', public_email_patterns)
            from quiz.config where id = 1);
end $$;

grant execute on function public.public_quiz_login_google(text)              to anon, authenticated;
grant execute on function public.public_quiz_register(text, text, text)      to anon, authenticated;
grant execute on function public.admin_set_public_quiz(uuid, boolean, text[]) to anon, authenticated;

select 'open quiz' as step, b.name, b.is_open, b.window_minutes, b.pool_no,
       (select public_email_patterns::text from quiz.config where id = 1) as allowed_if_email_contains,
       (select count(*) from quiz.students s where s.batch_id = b.id) as registered
  from quiz.batches b where b.name = 'Open Quiz';


-- ##############################  24_live_view.sql  ##############################

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


-- ##############################  25_scale.sql  ##############################

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


-- ##############################  26_exam_info.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 26: instructions before sign-in
--
-- The sign-in pages now show the exam instructions beside the sign-in box,
-- so the numbers in them (questions, minutes, violation limit, camera and
-- microphone) must be readable before anyone has signed in. This returns
-- only those display settings — nothing about questions, answers or people.
-- Safe to re-run.
-- =====================================================================

create or replace function public.exam_info()
returns json language sql stable security definer set search_path = quiz, public as $$
  select json_build_object(
    'exam_title',       c.exam_title,
    'mcq_count',        c.mcq_count,
    'coding_count',     c.coding_count,
    'duration_minutes', c.duration_minutes,
    'max_flags',        c.max_flags,
    'require_camera',   c.require_camera,
    'require_mic',      c.require_mic)
  from quiz.config c where c.id = 1;
$$;

grant execute on function public.exam_info() to anon, authenticated;


-- ##############################  27_thapar_only.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 27: open quiz is for @thapar.edu accounts only
--
-- The address must BOTH end with @thapar.edu AND contain be26 or btech26.
-- A Gmail such as anything.be26@gmail.com is refused.
-- Existing registrations are not touched. Safe to re-run.
-- =====================================================================

alter table quiz.config add column if not exists public_email_domain text not null default 'thapar.edu';

create or replace function quiz.public_email_ok(p_email text)
returns boolean language sql stable security definer set search_path = quiz, public as $$
  select lower(coalesce(p_email, '')) like '%@' || lower(c.public_email_domain)
     and coalesce((select bool_or(position(lower(p) in lower(coalesce(p_email, ''))) > 0)
                     from unnest(c.public_email_patterns) p), false)
    from quiz.config c
   where c.id = 1;
$$;

select 'open quiz rule' as step,
       '@' || public_email_domain as must_end_with,
       public_email_patterns::text as must_contain_one_of
  from quiz.config where id = 1;


-- ##############################  28_login_lockout.sql  ##############################

-- =====================================================================
-- LEAD Quiz Portal — 28: sign-in lockouts can't be used against real users
--
-- Before: 8 wrong passwords for a username locked that username for 10
-- minutes, whoever typed them. Anyone who knew "ADMIN1" could keep the real
-- ADMIN1 out of the portal for the whole exam with a small script.
--
-- Now failures are counted per username AND per network address, so a
-- stranger only locks themselves out. A separate cap of 60 failures per admin
-- username (from all addresses together) still bounds a distributed attack.
--
-- Stuck anyway? Run:  delete from quiz.login_failures;
-- Safe to re-run. No data changes.
-- =====================================================================

-- The caller's address as seen by Supabase's API gateway (null when unknown,
-- in which case behaviour is exactly as before).
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

create or replace function public.student_login(p_roll text, p_password text,
                                                p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare s quiz.students; v_token uuid;
        v_key text := 'student:' || trim(p_roll) || '@' || coalesce(quiz.client_ip(), '?');
begin
  -- NOTE: these paths RETURN a failure instead of raising. A raise would roll back the
  -- failure we just recorded, which would silently disable the throttle.
  if (select count(*) from quiz.login_failures
       where subject = v_key
         and failed_at > now() - interval '10 minutes') >= 8 then
    return json_build_object('ok', false, 'code', 'TOO_MANY_ATTEMPTS');
  end if;

  select * into s from quiz.students where roll_no = trim(p_roll);
  if s.roll_no is null or not quiz.check_password(p_password, s.password_hash) then
    insert into quiz.login_failures (subject) values (v_key);
    return json_build_object('ok', false, 'code', 'INVALID_CREDENTIALS');
  end if;
  if s.banned then return json_build_object('ok', false, 'code', 'BANNED'); end if;
  delete from quiz.login_failures where subject = v_key;

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

grant execute on function public.admin_login(text, text) to anon, authenticated;


-- ##############################  29_open_quiz_students.sql  ##############################

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

-- the pre-flight report is the last thing this file runs: read the STATUS column
-- =====================================================================
-- LEAD Quiz Portal — 16: pre-flight check
--   Changes nothing. Run it any time — especially on exam morning — and
--   read the STATUS column. Everything should say OK.
-- =====================================================================
with c as (select * from quiz.config where id = 1),
q as (
  select count(*) filter (where kind='mcq'    and active and section='A')    as a,
         count(*) filter (where kind='mcq'    and active and section='B')    as b,
         count(*) filter (where kind='mcq'    and active and section='C')    as c,
         count(*) filter (where kind='mcq'    and active and section='TECH') as t,
         count(*) filter (where kind='coding' and active)                    as x,
         count(*) filter (where active and ext_code is null)                 as placeholders,
         count(*) filter (where kind='mcq' and active and correct_index is null) as keyless,
         count(*) filter (where kind='coding' and active
                            and body not like '%You may answer in Python%') as nolang
    from quiz.questions
),
r as (
  select count(*) as total,
         count(*) filter (where b.name = 'Round 1') as r1,
         count(*) filter (where b.name = 'Round 2') as r2,
         count(*) filter (where b.name = 'Round 3') as r3,
         count(*) filter (where a.email !~ '^[^@]+@(thapar\.edu|gmail\.com)$') as bad_email
    from quiz.allowlist a left join quiz.batches b on b.id = a.batch_id
),
s as (
  select count(*) filter (where roll_no ~ '^\d{5}$')            as demo_students,
         count(*) filter (where roll_no !~ '^\d{5}$')           as real_students
    from quiz.students
),
t as (
  select count(*) filter (where status in ('in_progress','paused')) as live,
         count(*)                                                   as total
    from quiz.attempts
)
select * from (
  select 1 as ord, 'question bank — Section A' as check,
         case when q.a >= (select sec_a_count from c) then 'OK' else 'PROBLEM' end as status,
         q.a || ' questions, need ' || (select sec_a_count from c) as detail from q
  union all select 2, 'question bank — Section B',
         case when q.b >= (select sec_b_count from c) then 'OK' else 'PROBLEM' end,
         q.b || ' questions, need ' || (select sec_b_count from c) from q
  union all select 3, 'question bank — Section C',
         case when q.c >= (select sec_c_count from c) then 'OK' else 'PROBLEM' end,
         q.c || ' questions, need ' || (select sec_c_count from c) from q
  union all select 4, 'question bank — Technical',
         case when q.t >= (select tech_count from c) then 'OK' else 'PROBLEM' end,
         q.t || ' questions, need ' || (select tech_count from c) from q
  union all select 5, 'question bank — Coding',
         case when q.x >= (select coding_count from c) then 'OK' else 'PROBLEM' end,
         q.x || ' questions, need ' || (select coding_count from c) from q
  union all select 6, 'placeholder questions gone',
         case when q.placeholders = 0 then 'OK' else 'PROBLEM' end,
         q.placeholders || ' placeholders still active' from q
  union all select 7, 'every MCQ has an answer key',
         case when q.keyless = 0 then 'OK' else 'PROBLEM' end,
         q.keyless || ' without a key' from q
  union all select 8, 'coding lists the languages offered',
         case when q.nolang = 0 then 'OK' else 'PROBLEM' end,
         q.nolang || ' missing the note' from q
  union all select 9, 'paper template',
         case when (select sec_a_count+sec_b_count+sec_c_count+tech_count from c) = 17
               and (select coding_count from c) = 3 then 'OK' else 'CHECK' end,
         (select sec_a_count||' A + '||sec_b_count||' B + '||sec_c_count||' C + '||
                 tech_count||' technical + '||coding_count||' coding' from c)
  union all select 10, 'questions exclusive to each round',
         case when (select sec_a_excl+sec_b_excl+sec_c_excl+tech_excl from c) * 2
                    >= (select sec_a_count+sec_b_count+sec_c_count+tech_count from c)
              then 'OK' else 'CHECK' end,
         (select (sec_a_excl+sec_b_excl+sec_c_excl+tech_excl)||' of '||
                 (sec_a_count+sec_b_count+sec_c_count+tech_count)||
                 ' MCQ and '||coding_excl||' of '||coding_count||
                 ' coding come from this round''s own slice' from c)
  union all select 11, 'every round has its own slice',
         case when (select count(*) from quiz.batches where pool_no is null) = 0
              and (select count(*) from quiz.questions where active and round_pool is not null) > 0
              then 'OK' else 'PROBLEM' end,
         (select count(*) filter (where round_pool is null)||' shared, '||
                 count(*) filter (where round_pool is not null)||' round-exclusive'
            from quiz.questions where active)
  union all select 12, 'coding is remark-only',
         case when (select coalesce(sum(marks),0) from quiz.questions where kind='coding' and active) = 0
              then 'OK' else 'CHECK' end,
         'MCQ total '||(select coalesce(sum(marks),0)::text from quiz.questions
                         where kind='mcq' and active limit 1)||
         ' marks in the bank; a paper is worth '||(select mcq_count::text from c)
  union all select 13, 'students allowlisted',
         case when r.total >= 165 then 'OK' else 'CHECK' end,
         r.r1 || ' in Round 1, ' || r.r2 || ' in Round 2, ' || r.r3 || ' in Round 3, '
             || r.total || ' total' from r
  union all select 14, 'all addresses are thapar.edu or gmail.com',
         case when r.bad_email = 0 then 'OK' else 'PROBLEM' end,
         r.bad_email || ' look wrong' from r
  union all select 15, 'demo / test accounts kept',
         case when s.demo_students >= 12 then 'OK' else 'CHECK' end,
         s.demo_students || ' five-digit test students' from s
  union all select 16, 'admin + proctor logins',
         case when (select count(*) from quiz.admins) >= 6 then 'OK' else 'CHECK' end,
         (select count(*)::text from quiz.admins) || ' logins'
  union all select 17, 'rounds created',
         case when (select count(*) from quiz.batches) = 4 then 'OK' else 'PROBLEM' end,
         (select string_agg(name || case when is_open then ' (OPEN)' else '' end, ', ' order by name)
            from quiz.batches)
  union all select 18, 'exam is open for business',
         case when (select exam_open from c) then 'OK' else 'PROBLEM' end,
         'minutes per student: ' || (select duration_minutes::text from c) ||
         ', round window: ' || (select coalesce(max(window_minutes)::text,'—') from quiz.batches)
  union all select 19, 'camera monitoring',
         case when (select require_camera from c) then 'OK' else 'CHECK' end,
         'mic required: ' || (select require_mic::text from c)
  union all select 20, 'live attempts right now',
         case when t.live = 0 then 'OK' else 'CHECK' end,
         t.live || ' in progress, ' || t.total || ' attempts on record (reset these before the real run)'
         from t
  union all select 21, 'auto-submit timer (pg_cron)',
         case when to_regclass('cron.job') is null then 'PROBLEM' else 'OK' end,
         case when to_regclass('cron.job') is null
              then 'pg_cron not enabled — enable it in Database > Extensions, then re-run SETUP.sql'
              else 'scheduled' end
) x order by ord;
