-- PRIMUS 2026 screening round: every team and every response, one row per team.
-- Read-only — changes nothing. Run in Supabase -> SQL Editor, then use "Export -> CSV".
-- (Admin -> Screening -> "Download CSV" gives the same file from the browser.)
select
  t.team_name,
  t.leader_name,
  t.leader_phone,
  t.email                                                        as leader_email,
  tr.label                                                       as track,
  case when t.submitted_at is not null then 'submitted'
       when t.started_at  is not null then 'writing'
       else 'registered (not started)' end                       as status,
  case t.submit_reason when 'MANUAL' then 'submitted by team'
                       when 'TIME_UP' then 'time ran out' end   as how_submitted,
  to_char(t.registered_at at time zone interval '+05:30', 'DD-MM-YYYY HH24:MI:SS') as registered_at_ist,
  to_char(t.started_at    at time zone interval '+05:30', 'DD-MM-YYYY HH24:MI:SS') as started_at_ist,
  to_char(t.submitted_at  at time zone interval '+05:30', 'DD-MM-YYYY HH24:MI:SS') as submitted_at_ist,
  tr.prompts -> 0 ->> 'title'                                    as q1_prompt,
  t.answers[1]                                                   as q1_answer,
  tr.prompts -> 1 ->> 'title'                                    as q2_prompt,
  t.answers[2]                                                   as q2_answer,
  tr.prompts -> 2 ->> 'title'                                    as q3_prompt,
  t.answers[3]                                                   as q3_answer,
  t.reopened_count                                               as times_reopened,
  t.paste_attempts, t.copy_attempts, t.bulk_inserts as large_inserts, t.tab_switches as left_tab, t.fullscreen_exits
from quiz.screening_teams t
join quiz.screening_tracks tr on tr.id = t.track
order by tr.sort, t.team_name;
