-- =============================================================================
-- Immigroov — Cal.com-style availability + service category
--   * services.category
--   * specific_availability.is_blackout  (a "day off" marker)
--   * get_available_slots precedence:  blackout > date-override > weekly default
-- =============================================================================

alter table services add column if not exists category varchar(100);
alter table specific_availability add column if not exists is_blackout boolean not null default false;

-- Slot engine with Cal.com precedence per day:
--   1. if the date is blacked out  -> no slots
--   2. else if the date has override windows -> use ONLY those
--   3. else -> use the weekly default windows
create or replace function get_available_slots(
  p_mentor_id bigint, p_service_id bigint, p_from date, p_to date
)
returns table (slot_start timestamptz, slot_end timestamptz)
language plpgsql stable security definer set search_path = public as $$
declare
  v_tz text; v_buffer interval; v_min interval; v_window interval;
  v_duration interval; v_step interval;
  d date; rec record; s timestamptz; e timestamptz; win_end timestamptz;
  has_override boolean;
begin
  select coalesce(app_timezone,'UTC'), coalesce(app_buffertime, interval '0'),
         coalesce(app_minimum_notice, interval '0'), coalesce(app_booking_window, interval '365 days')
    into v_tz, v_buffer, v_min, v_window
  from mentors where id = p_mentor_id;

  select make_interval(mins => duration) into v_duration
  from services where id = p_service_id and is_active;
  if v_duration is null then
    raise exception 'Active service % not found', p_service_id;
  end if;
  v_step := v_duration + v_buffer;

  for d in select generate_series(p_from, p_to, interval '1 day')::date loop
    -- (1) whole-day blackout
    if exists (select 1 from specific_availability sa
               where sa.mentor_id = p_mentor_id and sa.slot_date = d and sa.is_blackout) then
      continue;
    end if;

    -- (2) does this date have custom override windows?
    select exists (select 1 from specific_availability sa
                   where sa.mentor_id = p_mentor_id and sa.slot_date = d and not sa.is_blackout)
      into has_override;

    for rec in
      select sa.start_time st, sa.end_time en
      from specific_availability sa
      where sa.mentor_id = p_mentor_id and sa.slot_date = d and not sa.is_blackout
      union all
      select wa.start_time, wa.end_time
      from weekly_availability wa
      where wa.mentor_id = p_mentor_id and wa.is_active and not has_override
        and trim(wa.weekday) = trim(to_char(d, 'FMDay'))
    loop
      s       := (d::text || ' ' || rec.st::text)::timestamp at time zone v_tz;
      win_end := (d::text || ' ' || rec.en::text)::timestamp at time zone v_tz;
      while (s + v_duration) <= win_end loop
        e := s + v_duration;
        if s >= now() + v_min
           and s <= now() + v_window
           and not exists (
             select 1 from bookings b
             where b.mentor_id = p_mentor_id
               and b.status not in ('cancelled','no_show')
               and b.slot_range && tstzrange(s, e))
        then
          slot_start := s; slot_end := e; return next;
        end if;
        s := s + v_step;
      end loop;
    end loop;
  end loop;
end;
$$;
grant execute on function get_available_slots(bigint,bigint,date,date) to anon, authenticated;
