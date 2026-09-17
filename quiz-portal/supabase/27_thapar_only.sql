-- =====================================================================
-- LEAD Quiz Portal — 27: open quiz is for @thapar.edu accounts only
--
-- The address must BOTH end with @thapar.edu AND contain be26 or btech26.
-- A Gmail such as anything.be26@gmail.com is refused.
-- Existing registrations are not touched. Safe to re-run.
-- =====================================================================

alter table quiz.config add column if not exists public_email_domain text not null default 'thapar.edu';

create or replace function quiz.public_email_ok(p_email text)
returns boolean language sql stable security definer set search_path = quiz, public as $$
  select lower(coalesce(p_email, '')) like '%@' || lower(c.public_email_domain)
     and coalesce((select bool_or(position(lower(p) in lower(coalesce(p_email, ''))) > 0)
                     from unnest(c.public_email_patterns) p), false)
    from quiz.config c
   where c.id = 1;
$$;

select 'open quiz rule' as step,
       '@' || public_email_domain as must_end_with,
       public_email_patterns::text as must_contain_one_of
  from quiz.config where id = 1;
