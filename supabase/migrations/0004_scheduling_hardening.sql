-- =============================================================================
-- Immigroov — Scheduling hardening
--   A) Prevent double-booking (typed time range + GiST exclusion + slot FK)
--   B) Slot-generation function get_available_slots(...)
--   C) Make app_* rules computable (varchar -> interval)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- C) Computable booking rules
--    buffer / minimum_notice / booking_window become real intervals so the
--    backend does math, not string parsing. cancellation/reschedule policies
--    stay as descriptive text.
-- -----------------------------------------------------------------------------
alter table mentors
  alter column app_buffertime     type interval using nullif(app_buffertime, '')::interval,
  alter column app_minimum_notice type interval using nullif(app_minimum_notice, '')::interval,
  alter column app_booking_window type interval using nullif(app_booking_window, '')::interval;

alter table mentors
  alter column app_buffertime     set default '15 minutes',
  alter column app_minimum_notice set default '2 hours',
  alter column app_booking_window set default '30 days';

-- -----------------------------------------------------------------------------
-- A) Double-booking guard
-- -----------------------------------------------------------------------------
create extension if not exists btree_gist;

-- Link a booking to the one-off slot it consumes (nullable: recurring slots
-- don't have a row to point at).
alter table bookings
  add column if not exists specific_availability_id uuid
    references specific_availability(id) on delete set null;

-- Materialize the booking's end + time range (end derived from service duration).
alter table bookings add column if not exists slot_end timestamptz;

alter table bookings add column if not exists slot_range tstzrange
  generated always as (
    case when slot_time is not null and slot_end is not null
         then tstzrange(slot_time, slot_end)
         else null end
  ) stored;

-- Populate slot_end from the service duration on insert/update.
create or replace function bookings_set_slot_end()
returns trigger language plpgsql as $$
begin
  if new.slot_time is not null and new.slot_end is null then
    select new.slot_time + make_interval(mins => s.duration)
      into new.slot_end
    from services s where s.id = new.service_id;
  end if;
  return new;
end;
$$;

create trigger trg_bookings_set_slot_end
  before insert or update of slot_time, service_id, slot_end on bookings
  for each row execute function bookings_set_slot_end();

-- Keep specific_availability.is_booked in sync with the booking that holds it.
create or replace function bookings_sync_slot_lock()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    if old.specific_availability_id is not null then
      update specific_availability set is_booked = false where id = old.specific_availability_id;
    end if;
    return old;
  end if;

  -- free a slot that was released (slot changed or booking cancelled)
  if tg_op = 'UPDATE' and old.specific_availability_id is not null
     and old.specific_availability_id is distinct from new.specific_availability_id then
    update specific_availability set is_booked = false where id = old.specific_availability_id;
  end if;

  if new.specific_availability_id is not null then
    update specific_availability
      set is_booked = (new.status not in ('cancelled', 'no_show'))
      where id = new.specific_availability_id;
  end if;
  return new;
end;
$$;

create trigger trg_bookings_sync_slot_lock
  after insert or update or delete on bookings
  for each row execute function bookings_sync_slot_lock();

-- The actual guarantee: no two ACTIVE bookings for the same mentor may overlap.
alter table bookings add constraint bookings_no_overlap
  exclude using gist (
    mentor_id with =,
    slot_range with &&
  )
  where (status not in ('cancelled', 'no_show') and slot_range is not null);

-- -----------------------------------------------------------------------------
-- B) Slot-generation function
--    Returns bookable [start, end) instants (timestamptz = absolute moments;
--    the client/Lambda formats them into the customer's timezone for display).
-- -----------------------------------------------------------------------------
create or replace function get_available_slots(
  p_mentor_id  bigint,
  p_service_id bigint,
  p_from       date,
  p_to         date
)
returns table (slot_start timestamptz, slot_end timestamptz)
language plpgsql stable as $$
declare
  v_tz         text;
  v_buffer     interval;
  v_min_notice interval;
  v_window     interval;
  v_duration   interval;
  v_step       interval;
  d            date;
  rec          record;
  s            timestamptz;
  e            timestamptz;
  win_end      timestamptz;
begin
  select coalesce(app_timezone, 'UTC'),
         coalesce(app_buffertime, interval '0'),
         coalesce(app_minimum_notice, interval '0'),
         coalesce(app_booking_window, interval '365 days')
    into v_tz, v_buffer, v_min_notice, v_window
  from mentors where id = p_mentor_id;

  select make_interval(mins => duration) into v_duration
  from services where id = p_service_id and is_active;

  if v_duration is null then
    raise exception 'Active service % not found (or has no duration)', p_service_id;
  end if;

  v_step := v_duration + v_buffer;

  for d in select generate_series(p_from, p_to, interval '1 day')::date loop
    for rec in
      -- recurring weekly windows for this weekday ...
      select wa.start_time, wa.end_time
      from weekly_availability wa
      where wa.mentor_id = p_mentor_id and wa.is_active
        and trim(wa.weekday) = trim(to_char(d, 'FMDay'))
      union all
      -- ... plus one-off windows still open on this date
      select sa.start_time, sa.end_time
      from specific_availability sa
      where sa.mentor_id = p_mentor_id and sa.is_booked = false
        and sa.slot_date = d
    loop
      s       := (d::text || ' ' || rec.start_time::text)::timestamp at time zone v_tz;
      win_end := (d::text || ' ' || rec.end_time::text)::timestamp   at time zone v_tz;

      while (s + v_duration) <= win_end loop
        e := s + v_duration;
        if s >= now() + v_min_notice
           and s <= now() + v_window
           and not exists (
             select 1 from bookings b
             where b.mentor_id = p_mentor_id
               and b.status not in ('cancelled', 'no_show')
               and b.slot_range && tstzrange(s, e)
           )
        then
          slot_start := s;
          slot_end   := e;
          return next;
        end if;
        s := s + v_step;
      end loop;
    end loop;
  end loop;
end;
$$;

comment on function get_available_slots(bigint, bigint, date, date) is
  'Returns bookable [start,end) timestamptz slots for a mentor+service over a '
  'date range, honoring weekly + specific availability, service duration, '
  'buffer, minimum notice, booking window, and existing non-cancelled bookings.';
