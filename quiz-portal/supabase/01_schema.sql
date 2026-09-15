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
