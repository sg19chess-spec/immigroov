-- Demo helper: the mentor console lets you act as a chosen mentor, so the chat needs that
-- mentor's email to identify them as a participant. (Demo-ungated, like the other demo_* RPCs.)
create or replace function demo_mentor_email(p_mentor_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select mu.email from mentors mm join users mu on mu.id = mm.user_id where mm.id = p_mentor_id;
$$;
grant execute on function demo_mentor_email(bigint) to anon, authenticated;
