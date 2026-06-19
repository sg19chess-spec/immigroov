-- =============================================================================
-- Immigroov — Close the reschedule + completion gaps in the core workflow
--   1) Emails on reschedule (+ review request on completion)
--   2) Reminders include 'rescheduled' bookings
--   3) Rescheduling clears old reminder records so new-time reminders re-fire
--   4) Auto-complete bookings whose time has passed (drives reviews + payouts)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Status-change emails: confirmed / rescheduled / cancelled / completed
--    Now also fires when slot_time changes (repeat reschedules).
-- -----------------------------------------------------------------------------
create or replace function trg_booking_status_email()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_email text;
  v_first text;
  d       record;
  when_txt text;
begin
  select u.email, u.first_name into v_email, v_first from users u where u.id = new.user_id;
  if v_email is null then return new; end if;

  select * into d from booking_times_display(new.id);
  when_txt := to_char(d.customer_local, 'FMDay, FMMonth DD YYYY at HH12:MI AM')
              || ' (' || d.customer_tz || ')';

  if new.status = 'confirmed'
     and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform app_send_email(v_email, 'Your Immigroov session is confirmed',
      '<p>Hi ' || coalesce(v_first,'') || ',</p><p>Your session is confirmed for <b>'
      || when_txt || '</b>.</p>');

  elsif new.status = 'rescheduled' and tg_op = 'UPDATE'
        and (old.status is distinct from new.status or old.slot_time is distinct from new.slot_time) then
    perform app_send_email(v_email, 'Your Immigroov session was rescheduled',
      '<p>Hi ' || coalesce(v_first,'') || ',</p><p>Your session has been moved to <b>'
      || when_txt || '</b>.</p>');

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

drop trigger if exists booking_status_email on bookings;
create trigger booking_status_email
  after insert or update of status, slot_time on bookings
  for each row execute function trg_booking_status_email();

-- -----------------------------------------------------------------------------
-- 2) Reminders should cover rescheduled (still-active) bookings, not just confirmed
-- -----------------------------------------------------------------------------
create or replace function due_reminders(p_kind text, p_lo interval, p_hi interval)
returns table (
  booking_id  bigint,
  email       text,
  first_name  text,
  slot_utc    timestamptz,
  customer_tz text
)
language sql stable as $$
  select b.id, u.email, u.first_name, b.slot_time,
         coalesce(b.customer_timezone, u.timezone, 'UTC')
  from bookings b
  join users u on u.id = b.user_id
  where b.status in ('confirmed', 'rescheduled')
    and b.slot_time between now() + p_lo and now() + p_hi
    and not exists (
      select 1 from booking_reminders r
      where r.booking_id = b.id and r.kind = p_kind
    );
$$;

-- -----------------------------------------------------------------------------
-- 3) Rescheduling clears prior reminder records so the new time re-triggers them
-- -----------------------------------------------------------------------------
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
    set slot_time = p_new_slot_time, slot_end = null, status = 'rescheduled'
    where id = p_booking_id
    returning * into b;

  -- new time => let reminders fire again
  delete from booking_reminders where booking_id = p_booking_id;
  return b;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4) Auto-complete elapsed sessions (so reviews + payouts can proceed).
--    Marks confirmed/rescheduled bookings whose end time has passed.
-- -----------------------------------------------------------------------------
create or replace function mark_past_bookings_completed()
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  update bookings
    set status = 'completed'
    where status in ('confirmed', 'rescheduled')
      and slot_end is not null
      and slot_end < now();
  get diagnostics n = row_count;
  return n;
end;
$$;

do $$
begin
  if exists (select 1 from cron.job where jobname = 'auto-complete') then
    perform cron.unschedule('auto-complete');
  end if;
end $$;

select cron.schedule('auto-complete', '*/15 * * * *',
  $$ select mark_past_bookings_completed() $$);
