-- Mentor-side reminders (1h and 10m before start), added per the founder's
-- Phase 7 review: attendance now depends on both parties joining, so only
-- reminding the customer skews risk toward mentor no-shows. No 24h mentor
-- reminder, per the founder's call — just close to the meeting.
-- Mirrors the existing customer due_reminders()/process_due_reminders()
-- pattern (0012), reusing the same booking_reminders dedup table with
-- mentor-specific kind values so they never collide with the customer kinds.

create function mentor_due_reminders(p_kind text, p_lo interval, p_hi interval)
returns table (
  booking_id bigint,
  email      text,
  first_name text,
  slot_utc   timestamptz,
  mentor_tz  text,
  mentor_join_token uuid
)
language sql stable as $$
  select b.id, mu.email, mu.first_name, b.slot_time,
         coalesce(mm.app_timezone, 'UTC'), b.mentor_join_token
  from bookings b
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  where b.status in ('confirmed', 'rescheduled')
    and b.slot_time between now() + p_lo and now() + p_hi
    and not exists (
      select 1 from booking_reminders r
      where r.booking_id = b.id and r.kind = p_kind
    );
$$;

create function process_mentor_reminders(p_kind text, p_lo interval, p_hi interval)
returns int
language plpgsql security definer set search_path = public as $$
declare
  r     record;
  n     int := 0;
  site  text;
  label text := case p_kind when 'mentor_10m' then 'in about 10 minutes' else 'in about an hour' end;
  link  text;
begin
  select value into site from platform_settings where key = 'site_url';
  site := coalesce(nullif(site,''), 'https://immigroov.vercel.app');
  for r in select * from mentor_due_reminders(p_kind, p_lo, p_hi) loop
    link := case when r.mentor_join_token is not null
                 then '<p>Join: <a href="' || site || '/join/' || r.mentor_join_token || '">' || site || '/join/' || r.mentor_join_token || '</a></p>'
                 else '' end;
    perform app_send_email(
      r.email, 'Reminder: your Immigroov session is ' || label,
      '<p>Hi ' || coalesce(r.first_name,'') || ', your session is ' || label || ' — <b>' ||
      to_char(r.slot_utc at time zone r.mentor_tz, 'FMDay, FMMonth DD at HH12:MI AM') ||
      ' (' || r.mentor_tz || ')</b>.</p>' || link);
    insert into booking_reminders (booking_id, kind) values (r.booking_id, p_kind)
      on conflict (booking_id, kind) do nothing;
    n := n + 1;
  end loop;
  return n;
end;
$$;

select cron.schedule('mentor-reminders-1h', '*/5 * * * *',
  $$ select process_mentor_reminders('mentor_1h', '30 minutes'::interval, '90 minutes'::interval) $$);
select cron.schedule('mentor-reminders-10m', '*/5 * * * *',
  $$ select process_mentor_reminders('mentor_10m', '5 minutes'::interval, '15 minutes'::interval) $$);
