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
