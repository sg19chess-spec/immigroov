-- =============================================================================
-- Immigroov — Guest bookings via Supabase Anonymous Auth (Option A)
-- =============================================================================
-- Flow (frontend):
--   1. const { data } = await supabase.auth.signInAnonymously()   // real auth.uid()
--   2. const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
--   3. await supabase.rpc('create_guest_booking', { ... , p_timezone: tz, p_email })
--
-- Because the guest has a genuine auth.uid(), RLS, cancel_booking() and
-- reschedule_booking() all keep working for them with no special-casing.
-- They can later upgrade to a full account (supabase.auth.updateUser) and the
-- same users row (linked by auth_id) carries their history forward.
-- =============================================================================

create or replace function create_guest_booking(
  p_mentor_id                bigint,
  p_service_id               bigint,
  p_slot_time                timestamptz,
  p_email                    text,
  p_first_name               text default null,
  p_timezone                 text default 'UTC',
  p_specific_availability_id uuid default null
)
returns bookings
language plpgsql security definer set search_path = public as $$
declare
  v_uid     uuid := auth.uid();
  v_user_id bigint;
  b         bookings;
begin
  if v_uid is null then
    raise exception 'No session: call supabase.auth.signInAnonymously() before booking';
  end if;
  if not is_valid_timezone(p_timezone) then
    raise exception 'Invalid timezone: %', p_timezone;
  end if;

  -- Re-use this auth user's profile row if it already exists.
  select id into v_user_id from users where auth_id = v_uid;

  if v_user_id is null then
    -- Don't silently hijack an existing account's email.
    if exists (select 1 from users where email = p_email and auth_id is distinct from v_uid) then
      raise exception 'An account already exists for %; please log in to book', p_email
        using errcode = 'unique_violation';
    end if;

    insert into users (auth_id, first_name, email, role, timezone, is_verified)
    values (v_uid, p_first_name, p_email, 'user', p_timezone, false)
    returning id into v_user_id;
  else
    update users
      set first_name = coalesce(p_first_name, first_name),
          email      = coalesce(p_email, email),
          timezone   = p_timezone
      where id = v_user_id;
  end if;

  -- Insert the booking. Triggers fill slot_end + customer_timezone and lock the
  -- one-off slot; the bookings_no_overlap constraint blocks any clash.
  insert into bookings (user_id, mentor_id, service_id, slot_time, status,
                        customer_timezone, specific_availability_id)
  values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'pending',
          p_timezone, p_specific_availability_id)
  returning * into b;

  return b;
end;
$$;

comment on function create_guest_booking(bigint, bigint, timestamptz, text, text, text, uuid) is
  'Atomically links the current (anonymous) auth user to a users row and creates '
  'a pending booking. Requires an active Supabase session (anonymous or full).';

grant execute on function
  create_guest_booking(bigint, bigint, timestamptz, text, text, text, uuid)
  to anon, authenticated;
