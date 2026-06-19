-- =============================================================================
-- Fix: magic-link / email sign-in 500 ("Database error saving new user")
-- The signup trigger used `on conflict (auth_id)`, which does NOT catch a
-- collision on the email unique constraint. If a public.users row already
-- existed for that email (guest booking, seed), the INSERT aborted the whole
-- auth transaction. Now we link the existing profile to the new auth user.
-- =============================================================================
create or replace function handle_new_auth_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_anonymous is true then
    return new;
  end if;
  if exists (select 1 from public.users where auth_id = new.id) then
    return new;
  end if;
  update public.users set auth_id = new.id
   where email = new.email and auth_id is null;
  if found then return new; end if;
  if exists (select 1 from public.users where email = new.email) then
    return new;  -- email already tied to another account; don't crash auth
  end if;
  insert into public.users (auth_id, email, first_name, last_name, role)
  values (
    new.id, new.email,
    new.raw_user_meta_data ->> 'first_name',
    new.raw_user_meta_data ->> 'last_name',
    case when (new.raw_user_meta_data ->> 'role') in ('mentor','user')
         then (new.raw_user_meta_data ->> 'role')::user_role else 'user' end
  )
  on conflict (auth_id) do nothing;
  return new;
end; $$;
