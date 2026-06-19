-- =============================================================================
-- Immigroov — Phase 1: signup trigger + Storage buckets
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Auto-create a public.users profile when someone signs up via Supabase Auth
--    (Anonymous users are skipped — they get a profile through
--     create_guest_booking instead.)
-- -----------------------------------------------------------------------------
create or replace function handle_new_auth_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.is_anonymous is true then
    return new;
  end if;

  insert into public.users (auth_id, email, first_name, last_name, role)
  values (
    new.id,
    new.email,
    new.raw_user_meta_data ->> 'first_name',
    new.raw_user_meta_data ->> 'last_name',
    -- only allow self-selecting 'mentor' or 'user'; never admin via signup
    case when (new.raw_user_meta_data ->> 'role') in ('mentor', 'user')
         then (new.raw_user_meta_data ->> 'role')::user_role
         else 'user' end
  )
  on conflict (auth_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_auth_user();

-- Keep profile email in sync if the user changes it in Auth
create or replace function handle_auth_user_email_change()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is distinct from old.email then
    update public.users set email = new.email where auth_id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_email_change on auth.users;
create trigger on_auth_user_email_change
  after update of email on auth.users
  for each row execute function handle_auth_user_email_change();

-- -----------------------------------------------------------------------------
-- 2) Storage buckets
--    avatars            -> public read (profile pictures)
--    verification-docs  -> private (KYC / mentor documents)
-- -----------------------------------------------------------------------------
insert into storage.buckets (id, name, public)
values
  ('avatars', 'avatars', true),
  ('verification-docs', 'verification-docs', false)
on conflict (id) do nothing;

-- Avatars: anyone can read; a user manages only files they own.
drop policy if exists "avatars public read"   on storage.objects;
drop policy if exists "avatars owner insert"   on storage.objects;
drop policy if exists "avatars owner update"   on storage.objects;
drop policy if exists "avatars owner delete"   on storage.objects;

create policy "avatars public read" on storage.objects
  for select using (bucket_id = 'avatars');
create policy "avatars owner insert" on storage.objects
  for insert with check (bucket_id = 'avatars' and owner = auth.uid());
create policy "avatars owner update" on storage.objects
  for update using (bucket_id = 'avatars' and owner = auth.uid());
create policy "avatars owner delete" on storage.objects
  for delete using (bucket_id = 'avatars' and owner = auth.uid());

-- Verification docs: only the uploader can read/write their own files.
drop policy if exists "verif owner access" on storage.objects;
create policy "verif owner access" on storage.objects
  for all
  using (bucket_id = 'verification-docs' and owner = auth.uid())
  with check (bucket_id = 'verification-docs' and owner = auth.uid());
