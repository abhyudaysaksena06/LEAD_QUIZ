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
