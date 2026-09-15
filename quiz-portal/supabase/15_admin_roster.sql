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
            and coalesce(btrim(given_name), '') <> ''
            and has_id)                                    as complete
      from r
  )
  select json_agg(json_build_object(
           'email', email, 'round_name', round_name, 'batch_id', batch_id,
           'listed_name', listed_name, 'roll_hint', roll_hint,
           'roll_no', roll_no, 'full_name', given_name,
           'registered', registered, 'has_id', has_id, 'complete', complete,
           'banned', coalesce(banned, false),
           'consented', consented_at is not null,
           'last_seen_at', last_seen_at,
           'attempt_status', attempt_status)
           order by round_name nulls last, complete, email),
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
                                              and coalesce(btrim(s.full_name), '') <> ''
                                              and exists (select 1 from quiz.id_documents d
                                                           where d.roll_no = a.claimed_by))) as x
                                   from quiz.allowlist a
                                   left join quiz.batches  b on b.id      = a.batch_id
                                   left join quiz.students s on s.roll_no = a.claimed_by
                                  group by coalesce(b.name, 'Unassigned')
                               ) t), '[]'::json));
end $$;

grant execute on function public.admin_roster(uuid) to anon, authenticated;
