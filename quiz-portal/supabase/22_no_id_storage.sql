-- =====================================================================
-- LEAD Quiz Portal — 22: photo IDs are no longer stored
--
-- Registration still asks for a photo, but the browser never sends it and
-- the database never keeps it. Stored ID images were using up database
-- space ("memory low" during upload), so they are cleared here.
--
-- Already-registered students are NOT affected: their registration, name,
-- roll number, round, answers and attempts all stay exactly as they are.
-- Only the ID images are removed.
-- Safe to re-run.
-- =====================================================================

create or replace function public.student_register(p_roll text, p_full_name text,
                                                   p_id_mime text, p_id_b64 text,
                                                   p_device text default null)
returns json language plpgsql security definer set search_path = quiz, public as $$
declare
  v_claims jsonb; v_email text; a quiz.allowlist; v_roll text; v_token uuid;
begin
  begin
    v_claims := nullif(current_setting('request.jwt.claims', true), '')::jsonb;
  exception when others then v_claims := null;
  end;
  v_email := lower(trim(coalesce(v_claims ->> 'email', '')));
  if v_email = '' then raise exception 'NOT_SIGNED_IN'; end if;

  select * into a from quiz.allowlist where email = v_email;
  if a.email is null then raise exception 'EMAIL_NOT_REGISTERED: %', v_email; end if;
  if a.claimed_by is not null then raise exception 'ALREADY_REGISTERED'; end if;

  v_roll := upper(trim(coalesce(p_roll, '')));
  if length(v_roll) < 3 then raise exception 'ROLL_TOO_SHORT'; end if;
  if length(trim(coalesce(p_full_name, ''))) < 2 then raise exception 'NAME_REQUIRED'; end if;
  if exists (select 1 from quiz.students where roll_no = v_roll) then
    raise exception 'ROLL_ALREADY_USED: %', v_roll;
  end if;
  -- p_id_mime / p_id_b64 are accepted for compatibility and deliberately ignored.

  insert into quiz.students (roll_no, password_hash, full_name, email, batch_id)
  values (v_roll, quiz.hash_password(gen_random_uuid()::text),   -- no password: Google only
          trim(p_full_name), v_email, a.batch_id);

  update quiz.allowlist set claimed_by = v_roll where email = v_email;

  insert into quiz.sessions (kind, subject, expires_at, device)
  values ('student', v_roll, now() + interval '12 hours', p_device)
  returning token into v_token;

  return json_build_object('token', v_token, 'roll_no', v_roll,
                           'full_name', trim(p_full_name), 'email', v_email,
                           'needs_registration', false);
end $$;

grant execute on function public.student_register(text, text, text, text, text) to anon, authenticated;

-- clear the images already stored (students themselves are untouched)
delete from quiz.id_documents;

select 'id images stored' as step, count(*) as remaining from quiz.id_documents
union all
select 'registered students kept', count(*) from quiz.students where email is not null;
