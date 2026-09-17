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
