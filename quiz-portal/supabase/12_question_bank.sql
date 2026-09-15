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
