-- =============================================================================
-- Immigroov — per-range weekly availability RPCs (for the availability editor)
-- =============================================================================
create or replace function demo_add_weekly(p_mentor_id bigint, p_day text, p_start time, p_end time)
returns void language sql security definer set search_path = public as $$
  insert into weekly_availability(mentor_id, weekday, start_time, end_time, timezone, is_active)
  values (p_mentor_id, p_day, p_start, p_end,
          (select coalesce(app_timezone,'UTC') from mentors where id=p_mentor_id), true);
$$;

create or replace function demo_remove_weekly(p_id uuid)
returns void language sql security definer set search_path = public as $$
  delete from weekly_availability where id = p_id;
$$;

drop function if exists demo_list_weekly(bigint);
create function demo_list_weekly(p_mentor_id bigint)
returns table(id uuid, weekday text, start_time time, end_time time, timezone text)
language sql security definer set search_path = public as $$
  select id, weekday, start_time, end_time, timezone
  from weekly_availability where mentor_id = p_mentor_id
  order by array_position(array['Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'], weekday), start_time;
$$;

grant execute on function demo_add_weekly(bigint,text,time,time) to anon, authenticated;
grant execute on function demo_remove_weekly(uuid) to anon, authenticated;
grant execute on function demo_list_weekly(bigint) to anon, authenticated;
