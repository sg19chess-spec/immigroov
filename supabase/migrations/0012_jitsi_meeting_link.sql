-- =============================================================================
-- Immigroov — Jitsi meeting links (the "Attend" stage)
--   * each video booking gets a unique, stable Jitsi room at creation
--   * link survives reschedules (same room, new time)
--   * included in confirmation / reschedule / reminder emails
--   * 'dm' services get no link (handled in-app)
-- =============================================================================

alter table bookings add column if not exists meeting_url text;

-- -----------------------------------------------------------------------------
-- Assign a Jitsi room on insert for video services (before-insert so the email
-- trigger sees it). Room name is unguessable; reschedules keep the same room.
-- -----------------------------------------------------------------------------
create or replace function set_meeting_url()
returns trigger
language plpgsql as $$
declare v_type service_type;
begin
  if new.meeting_url is null then
    select type into v_type from services where id = new.service_id;
    if v_type = 'video' then
      new.meeting_url := 'https://meet.jit.si/Immigroov-'
        || replace(gen_random_uuid()::text, '-', '');
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_set_meeting_url on bookings;
create trigger trg_set_meeting_url
  before insert on bookings
  for each row execute function set_meeting_url();

-- Backfill any existing video bookings that predate this.
update bookings b
  set meeting_url = 'https://meet.jit.si/Immigroov-' || replace(gen_random_uuid()::text, '-', '')
  from services s
  where s.id = b.service_id and s.type = 'video' and b.meeting_url is null;

-- -----------------------------------------------------------------------------
-- Emails now include the join link when present.
-- -----------------------------------------------------------------------------
create or replace function trg_booking_status_email()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_email text;
  v_first text;
  d        record;
  when_txt text;
  link_txt text := '';
begin
  select u.email, u.first_name into v_email, v_first from users u where u.id = new.user_id;
  if v_email is null then return new; end if;

  select * into d from booking_times_display(new.id);
  when_txt := to_char(d.customer_local, 'FMDay, FMMonth DD YYYY at HH12:MI AM')
              || ' (' || d.customer_tz || ')';
  if new.meeting_url is not null then
    link_txt := '<p>Join your video session here: <a href="' || new.meeting_url
                || '">' || new.meeting_url || '</a></p>';
  end if;

  if new.status = 'confirmed'
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform app_send_email(v_email, 'Your Immigroov session is confirmed',
      '<p>Hi ' || coalesce(v_first,'') || ',</p><p>Your session is confirmed for <b>'
      || when_txt || '</b>.</p>' || link_txt);

  elsif new.status = 'rescheduled' and tg_op = 'UPDATE'
        and (old.status is distinct from new.status or old.slot_time is distinct from new.slot_time) then
    perform app_send_email(v_email, 'Your Immigroov session was rescheduled',
      '<p>Hi ' || coalesce(v_first,'') || ',</p><p>Your session has been moved to <b>'
      || when_txt || '</b>.</p>' || link_txt);

  elsif new.status = 'cancelled' and tg_op = 'UPDATE'
        and old.status is distinct from new.status then
    perform app_send_email(v_email, 'Your Immigroov session was cancelled',
      '<p>Hi ' || coalesce(v_first,'') || ',</p><p>Your session for ' || when_txt
      || ' has been cancelled.</p>');

  elsif new.status = 'completed' and tg_op = 'UPDATE'
        and old.status is distinct from new.status then
    perform app_send_email(v_email, 'How was your Immigroov session?',
      '<p>Hi ' || coalesce(v_first,'') || ',</p><p>Thanks for your session! '
      || 'We''d love your feedback — please leave a review.</p>');
  end if;
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Reminders carry the join link too. (DROP first: adding an output column
-- changes the return type, which CREATE OR REPLACE can't do. Drop the dependent
-- function first.)
-- -----------------------------------------------------------------------------
drop function if exists process_due_reminders(text, interval, interval);
drop function if exists due_reminders(text, interval, interval);

create function due_reminders(p_kind text, p_lo interval, p_hi interval)
returns table (
  booking_id  bigint,
  email       text,
  first_name  text,
  slot_utc    timestamptz,
  customer_tz text,
  meeting_url text
)
language sql stable as $$
  select b.id, u.email, u.first_name, b.slot_time,
         coalesce(b.customer_timezone, u.timezone, 'UTC'), b.meeting_url
  from bookings b
  join users u on u.id = b.user_id
  where b.status in ('confirmed', 'rescheduled')
    and b.slot_time between now() + p_lo and now() + p_hi
    and not exists (
      select 1 from booking_reminders r
      where r.booking_id = b.id and r.kind = p_kind
    );
$$;

create function process_due_reminders(p_kind text, p_lo interval, p_hi interval)
returns int
language plpgsql security definer set search_path = public as $$
declare
  r     record;
  n     int := 0;
  label text := case p_kind when '1h' then 'in about an hour' else 'in 24 hours' end;
  link  text;
begin
  for r in select * from due_reminders(p_kind, p_lo, p_hi) loop
    link := case when r.meeting_url is not null
                 then '<p>Join: <a href="' || r.meeting_url || '">' || r.meeting_url || '</a></p>'
                 else '' end;
    perform app_send_email(
      r.email, 'Reminder: your Immigroov session is ' || label,
      '<p>Hi ' || coalesce(r.first_name,'') || ', your session is ' || label || ' — <b>' ||
      to_char(r.slot_utc at time zone r.customer_tz, 'FMDay, FMMonth DD at HH12:MI AM') ||
      ' (' || r.customer_tz || ')</b>.</p>' || link);
    insert into booking_reminders (booking_id, kind) values (r.booking_id, p_kind)
      on conflict (booking_id, kind) do nothing;
    n := n + 1;
  end loop;
  return n;
end;
$$;
