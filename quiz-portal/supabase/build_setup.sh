#!/bin/sh
# Rebuilds SETUP.sql from the numbered files. Run after editing any of them.
{
cat <<'HDR'
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
HDR
for f in 01_schema.sql 02_student_api.sql 03_admin_api.sql 04_seed.sql 08_proctors.sql 09_rounds.sql 10_test_students.sql 12_question_bank.sql 13_paper_template.sql 15_admin_roster.sql 14_roster.sql 17_round_pools.sql; do
  printf '\n\n-- ##############################  %s  ##############################\n\n' "$f"; cat "$f"
done
cat <<'FTR'


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
FTR
cat 16_preflight.sql
} > SETUP.sql
