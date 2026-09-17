-- Everyone who has submitted the test: name, roll number, phone, email, quiz, score.
-- Read-only — changes nothing. Run in Supabase -> SQL Editor, then use "Export -> CSV".
select
  coalesce(o.full_name, s.full_name)                            as name,
  replace(s.roll_no, '-OQ', '')                                 as roll_number,
  o.phone                                                       as phone,
  coalesce(o.email, s.email)                                    as email,
  case when b.name like 'Open Quiz%' then 'Open quiz' else 'Recruitment' end as quiz,
  b.name                                                        as round,
  a.total_score                                                 as score,
  case a.submit_reason
       when 'MANUAL'      then 'submitted by student'
       when 'TIME_UP'     then 'time ran out'
       when 'ROUND_ENDED' then 'round closed'
       when 'FLAG_LIMIT'  then 'auto-submitted (violations)'
       when 'ADMIN'       then 'submitted by proctor'
       else a.submit_reason end                                 as how_submitted,
  to_char(a.submitted_at at time zone interval '+05:30', 'DD-MM-YYYY HH12:MI AM') as submitted_at_ist
from quiz.attempts a
join quiz.students s  on s.roll_no = a.roll_no
join quiz.batches  b  on b.id = s.batch_id
left join quiz.open_quiz_students o on o.roll_no = s.roll_no
where a.status in ('submitted', 'blocked')
  and s.roll_no !~ '^[0-9]{5}$'          -- leave out the 5-digit demo/test accounts
order by quiz, round, name;
