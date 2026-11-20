-- =====================================================================
-- PRIMUS 2026 screening portal — 03: AI judging
--
-- The AI judge runs in a Vercel function (api/judge.js) that holds the
-- Anthropic API key. It acts with the signed-in admin's session token:
--   1. admin_screening_judge_input  → one submitted response, anonymised
--      (no team name, email, leader name or phone), plus its track's
--      mandate, screener signals, prompts and the rubric;
--   2. admin_screening_save_judgement → stores the scores.
-- The database re-checks every score against the rubric maximum and adds
-- up the total itself. A judgement records a hash of the answers it saw,
-- so if a team is reopened and edits its answers the score shows as stale.
-- Safe to re-run.
-- =====================================================================

create table if not exists quiz.screening_judgements (
  email          text primary key references quiz.screening_teams (email) on delete cascade,
  scores         jsonb not null,          -- {criterion_key: {score, max, rationale}}
  total          int   not null,
  max_total      int   not null,
  recommendation text  not null check (recommendation in ('advance', 'borderline', 'reject')),
  summary        text,
  strengths      text,
  concerns       text,
  question_feedback jsonb not null default '[]'::jsonb,
  integrity_flags   jsonb not null default '[]'::jsonb,
  answers_hash   text  not null,
  model          text,
  usage          jsonb,
  judged_by      text,
  judged_at      timestamptz not null default now()
);
alter table quiz.screening_judgements enable row level security;
revoke all on quiz.screening_judgements from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on quiz.screening_judgements from anon, authenticated';
  end if;
end $$;

-- Machine keys for the four rubric criteria, in the order of quiz.screening_config.rubric.
create or replace function quiz.rubric_keys()
returns text[] language sql immutable as $$
  select array['evidence_discipline', 'track_depth', 'investor_call', 'clarity'];
$$;

create or replace function quiz.answers_hash(p text[])
returns text language sql immutable as $$
  select md5(array_to_string(coalesce(p, '{}'::text[]), E'\x1f', ''));
$$;

-- ---------- what the judge reads ----------
create or replace function public.admin_screening_judge_input(p_token uuid, p_email text)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); t quiz.screening_teams;
        tr quiz.screening_tracks; c quiz.screening_config;
begin
  perform quiz.screening_expire();
  select * into t from quiz.screening_teams where email = quiz.normalize_email(p_email);
  if t.email is null then raise exception 'SCREENING_NOT_REGISTERED'; end if;
  if t.submitted_at is null then raise exception 'NOT_SUBMITTED'; end if;
  select * into tr from quiz.screening_tracks where id = t.track;
  select * into c from quiz.screening_config where id = 1;
  return json_build_object(
    'email', t.email,                         -- for saving the result; never sent to the model
    'track', tr.id, 'track_label', tr.label, 'track_subtitle', tr.subtitle,
    'case_title', c.case_title, 'case_facts', c.case_facts, 'duration_minutes', c.duration_minutes,
    'role_brief', tr.role_brief, 'prompts', tr.prompts,
    'mandate', tr.mandate, 'signals', tr.signals,
    'rubric', (select json_agg(json_build_object('key', (quiz.rubric_keys())[r.i], 'title', r.v ->> 'title',
                                                 'max', (r.v ->> 'points')::int, 'question', r.v ->> 'body')
                               order by r.i)
                 from jsonb_array_elements(c.rubric) with ordinality as r(v, i)),
    'answers', to_json(t.answers),
    'submit_reason', t.submit_reason,
    'answers_hash', quiz.answers_hash(t.answers));
end $$;

-- ---------- storing a judgement ----------
-- p_result: {scores: {key: {score, rationale}}, recommendation, summary, strengths, concerns,
--            question_feedback: [{question, feedback}], integrity_flags: [text]}
create or replace function public.admin_screening_save_judgement(p_token uuid, p_email text, p_result jsonb,
                                                                 p_answers_hash text, p_model text,
                                                                 p_usage jsonb default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); v_email text := quiz.normalize_email(p_email);
        t quiz.screening_teams; c quiz.screening_config;
        v_scores jsonb := '{}'::jsonb; v_total int := 0; v_max int := 0;
        r record; v_key text; v_score int; v_rec text;
begin
  select * into t from quiz.screening_teams where email = v_email;
  if t.email is null then raise exception 'SCREENING_NOT_REGISTERED'; end if;
  if t.submitted_at is null then raise exception 'NOT_SUBMITTED'; end if;
  -- the answers must be exactly the ones the judge read
  if quiz.answers_hash(t.answers) <> coalesce(p_answers_hash, '') then raise exception 'ANSWERS_CHANGED'; end if;

  select * into c from quiz.screening_config where id = 1;
  for r in select v, i from jsonb_array_elements(c.rubric) with ordinality as x(v, i) loop
    v_key := (quiz.rubric_keys())[r.i];
    -- coalesce: a missing score must fail here (NULL <> 'number' would quietly pass)
    if coalesce(jsonb_typeof(p_result -> 'scores' -> v_key -> 'score'), 'missing') <> 'number' then
      raise exception 'JUDGEMENT_INVALID: missing score for %', v_key;
    end if;
    -- clamp to 0..max: the model's number is never trusted beyond the rubric
    v_score := greatest(0, least((r.v ->> 'points')::int,
                                 round((p_result -> 'scores' -> v_key ->> 'score')::numeric)::int));
    v_scores := v_scores || jsonb_build_object(v_key, jsonb_build_object(
                  'title', r.v ->> 'title', 'score', v_score, 'max', (r.v ->> 'points')::int,
                  'rationale', left(coalesce(p_result -> 'scores' -> v_key ->> 'rationale', ''), 2000)));
    v_total := v_total + v_score;
    v_max := v_max + (r.v ->> 'points')::int;
  end loop;

  v_rec := p_result ->> 'recommendation';
  if v_rec not in ('advance', 'borderline', 'reject') then raise exception 'JUDGEMENT_INVALID: recommendation'; end if;

  insert into quiz.screening_judgements as j
    (email, scores, total, max_total, recommendation, summary, strengths, concerns,
     question_feedback, integrity_flags, answers_hash, model, usage, judged_by, judged_at)
  values (v_email, v_scores, v_total, v_max, v_rec,
          left(p_result ->> 'summary', 3000), left(p_result ->> 'strengths', 3000), left(p_result ->> 'concerns', 3000),
          coalesce(case when jsonb_typeof(p_result -> 'question_feedback') = 'array' then p_result -> 'question_feedback' end, '[]'::jsonb),
          coalesce(case when jsonb_typeof(p_result -> 'integrity_flags') = 'array' then p_result -> 'integrity_flags' end, '[]'::jsonb),
          p_answers_hash, left(p_model, 100), p_usage, v_admin, now())
  on conflict (email) do update set
    scores = excluded.scores, total = excluded.total, max_total = excluded.max_total,
    recommendation = excluded.recommendation, summary = excluded.summary, strengths = excluded.strengths,
    concerns = excluded.concerns, question_feedback = excluded.question_feedback,
    integrity_flags = excluded.integrity_flags, answers_hash = excluded.answers_hash,
    model = excluded.model, usage = excluded.usage, judged_by = excluded.judged_by, judged_at = now();

  perform quiz.audit(v_admin, 'SCREENING_AI_JUDGED', v_email,
                     json_build_object('total', v_total, 'recommendation', v_rec, 'model', p_model)::jsonb);
  return json_build_object('ok', true, 'total', v_total, 'max_total', v_max, 'recommendation', v_rec);
end $$;

-- ---------- the admin list, now with AI scores ----------
create or replace function public.admin_screening(p_token uuid)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare v_admin text := quiz.admin_from_token(p_token); c quiz.screening_config;
begin
  perform quiz.screening_expire();
  select * into c from quiz.screening_config where id = 1;
  return json_build_object(
    'server_now', now(),
    'config', json_build_object('is_open', c.is_open, 'duration_minutes', c.duration_minutes,
                                'event_title', c.event_title, 'case_title', c.case_title,
                                'case_facts', c.case_facts, 'rubric', c.rubric),
    'tracks', (select json_agg(json_build_object('id', x.id, 'label', x.label, 'subtitle', x.subtitle,
                                                 'role_brief', x.role_brief, 'prompts', x.prompts,
                                                 'mandate', x.mandate, 'signals', x.signals)
                               order by x.sort) from quiz.screening_tracks x),
    'teams', coalesce((select json_agg(json_build_object(
        'email', t.email, 'leader_name', t.leader_name, 'leader_phone', t.leader_phone,
        'team_name', t.team_name, 'track', t.track, 'status', quiz.screening_status(t),
        'registered_at', t.registered_at, 'started_at', t.started_at, 'deadline', t.deadline,
        'submitted_at', t.submitted_at, 'submit_reason', t.submit_reason,
        'last_saved_at', t.last_saved_at, 'save_count', t.save_count,
        'reopened_count', t.reopened_count, 'answers', to_json(t.answers),
        'ai', case when j.email is null then null else json_build_object(
            'total', j.total, 'max_total', j.max_total, 'recommendation', j.recommendation,
            'scores', j.scores, 'summary', j.summary, 'strengths', j.strengths, 'concerns', j.concerns,
            'question_feedback', j.question_feedback, 'integrity_flags', j.integrity_flags,
            'model', j.model, 'judged_by', j.judged_by, 'judged_at', j.judged_at,
            'stale', j.answers_hash <> quiz.answers_hash(t.answers)) end)
        order by t.registered_at)
      from quiz.screening_teams t left join quiz.screening_judgements j on j.email = t.email), '[]'::json),
    'incomplete', coalesce((select json_agg(json_build_object('email', a.email, 'created_at', a.created_at)
                                            order by a.created_at desc)
      from quiz.screening_accounts a
     where not exists (select 1 from quiz.screening_teams t where t.email = a.email)), '[]'::json));
end $$;

-- ---------- permissions ----------
revoke execute on all functions in schema quiz from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke execute on all functions in schema quiz from anon, authenticated';
  end if;
end $$;
revoke execute on function public.admin_screening(uuid),
  public.admin_screening_judge_input(uuid, text),
  public.admin_screening_save_judgement(uuid, text, jsonb, text, text, jsonb) from public;
grant execute on function public.admin_screening(uuid)                                      to anon, authenticated;
grant execute on function public.admin_screening_judge_input(uuid, text)                   to anon, authenticated;
grant execute on function public.admin_screening_save_judgement(uuid, text, jsonb, text, text, jsonb) to anon, authenticated;
