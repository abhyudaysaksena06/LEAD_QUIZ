-- Run this on its own in the Supabase SQL Editor to free the space used by
-- stored photo IDs. Registered students, rounds, answers are NOT touched.
delete from quiz.id_documents;

select count(*) as id_images_left from quiz.id_documents;
select count(*) as registered_students_kept from quiz.students where email is not null;
