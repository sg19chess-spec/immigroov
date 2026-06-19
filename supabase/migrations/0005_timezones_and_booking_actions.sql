-- =============================================================================
-- Immigroov — Timezones + booking lifecycle actions
--   1) Per-user timezone (mentee tz was missing) + validation
--   2) booking_times_display(): render a booking in BOTH parties' local time
--   3) cancel_booking() / reschedule_booking() (auto-bumps cancellation counter)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Timezones
-- -----------------------------------------------------------------------------
-- Validate IANA tz names against the server catalog.
create or replace function is_valid_timezone(tz text)
returns boolean language sql immutable as $$
  select exists (select 1 from pg_timezone_names where name = tz);
$$;

-- Every user has a home timezone (IANA, e.g. 'America/New_York').
alter table users
  add column if not exists timezone text not null default 'UTC'
  check (is_valid_timezone(timezone));

-- Snapshot the customer's tz onto the booking (so a reminder still renders
-- correctly even if the user later changes their profile timezone).
alter table bookings
  add column if not exists customer_timezone text
  check (customer_timezone is null or is_valid_timezone(customer_timezone));

-- Default the snapshot from the user's profile at insert time.
create or replace function bookings_set_slot_end()
returns trigger language plpgsql as $$
begin
  if new.slot_time is not null and new.slot_end is null then
    select new.slot_time + make_interval(mins => s.duration)
      into new.slot_end
    from services s where s.id = new.service_id;
  end if;

  if new.customer_timezone is null then
    select timezone into new.customer_timezone from users where id = new.user_id;
  end if;
  return new;
end;
$$;
-- (trigger trg_bookings_set_slot_end from 0004 already points at this function)

-- -----------------------------------------------------------------------------
-- 2) Render a booking in both parties' local wall-clock time (for UI / emails)
-- -----------------------------------------------------------------------------
create or replace function booking_times_display(p_booking_id bigint)
returns table (
  slot_utc        timestamptz,
  mentor_tz       text,
  mentor_local    timestamp,
  customer_tz     text,
  customer_local  timestamp
)
language sql stable as $$
  select
    b.slot_time,
    coalesce(m.app_timezone, 'UTC'),
    b.slot_time at time zone coalesce(m.app_timezone, 'UTC'),
    coalesce(b.customer_timezone, cu.timezone, 'UTC'),
    b.slot_time at time zone coalesce(b.customer_timezone, cu.timezone, 'UTC')
  from bookings b
  join mentors m on m.id = b.mentor_id
  join users   cu on cu.id = b.user_id
  where b.id = p_booking_id;
$$;

-- -----------------------------------------------------------------------------
-- 3) Booking lifecycle actions
-- -----------------------------------------------------------------------------
-- Monthly cancellation counter bump (upsert).
create or replace function bump_mentor_cancellation(p_mentor_id bigint)
returns void language plpgsql as $$
begin
  insert into mentor_cancellation_policy (mentor_id, month_year, cancel_count, last_updated)
  values (p_mentor_id, to_char(now(), 'YYYY-MM'), 1, now())
  on conflict (mentor_id, month_year)
  do update set cancel_count = mentor_cancellation_policy.cancel_count + 1,
                last_updated = now();
end;
$$;

-- Cancel. SECURITY DEFINER so it can write the counter + bypass RLS, but it
-- authorizes the caller first (a participant, or the backend/service_role where
-- auth.uid() is null). Bumps the mentor's monthly counter ONLY when the mentor
-- cancels (so mentee cancellations don't penalize the mentor).
create or replace function cancel_booking(
  p_booking_id  bigint,
  p_cancelled_by text default 'user'   -- 'user' | 'mentor' | 'system'
)
returns bookings
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'Booking % not found', p_booking_id;
  end if;

  if auth.uid() is not null
     and b.user_id   is distinct from current_user_id()
     and b.mentor_id is distinct from current_mentor_id() then
    raise exception 'Not authorized to cancel booking %', p_booking_id;
  end if;

  if b.status in ('cancelled', 'completed') then
    raise exception 'Booking % is already %', p_booking_id, b.status;
  end if;

  update bookings set status = 'cancelled' where id = p_booking_id returning * into b;

  if p_cancelled_by = 'mentor' then
    perform bump_mentor_cancellation(b.mentor_id);
  end if;
  return b;
end;
$$;

-- Reschedule to a new absolute instant. slot_end is reset so the 0004 trigger
-- recomputes it; the bookings_no_overlap constraint rejects any clash.
create or replace function reschedule_booking(
  p_booking_id   bigint,
  p_new_slot_time timestamptz
)
returns bookings
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then
    raise exception 'Booking % not found', p_booking_id;
  end if;

  if auth.uid() is not null
     and b.user_id   is distinct from current_user_id()
     and b.mentor_id is distinct from current_mentor_id() then
    raise exception 'Not authorized to reschedule booking %', p_booking_id;
  end if;

  if b.status in ('cancelled', 'completed', 'no_show') then
    raise exception 'Booking % cannot be rescheduled (status %)', p_booking_id, b.status;
  end if;

  update bookings
    set slot_time = p_new_slot_time,
        slot_end  = null,            -- recomputed by trg_bookings_set_slot_end
        status    = 'rescheduled'
    where id = p_booking_id
    returning * into b;
  return b;
end;
$$;

grant execute on function get_available_slots(bigint, bigint, date, date) to authenticated, anon;
grant execute on function booking_times_display(bigint) to authenticated;
grant execute on function cancel_booking(bigint, text)        to authenticated;
grant execute on function reschedule_booking(bigint, timestamptz) to authenticated;
