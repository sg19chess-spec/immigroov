-- Phase 6 of the attendance tracking plan ("replace existing logic"), built as
-- a single switch rather than a future rewrite. Off by default — zero change
-- to current production behavior. Flip 'attendance_engine_enabled' to 'true'
-- only after the join-link UI and reminder emails (Phases 2-4) are live, at
-- the same time you enable the evaluate_attendance_after_grace_period() cron
-- job (see the commented-out schedule in 0079_attendance_tracking.sql).
--
-- What flipping it does: mark_past_bookings_completed() stops trusting time
-- alone — a booking only auto-completes once both mentor_joined and
-- customer_joined are true. This also closes the short-session race condition
-- noted in 0079 (a session shorter than the 10-minute grace period could
-- otherwise complete before the grace-period job had a chance to evaluate it).

insert into platform_settings (key, value, description) values
  ('attendance_engine_enabled', 'false', 'When true, session completion requires verified join-attendance instead of just elapsed time. Keep false until the join-link UI and reminder emails are live.')
on conflict (key) do nothing;

create or replace function mark_past_bookings_completed()
returns int
language plpgsql security definer set search_path = public as $$
declare n int; v_enabled boolean;
begin
  v_enabled := coalesce(referral_setting('attendance_engine_enabled')::boolean, false);
  update bookings
    set status = 'completed'
    where status in ('confirmed', 'rescheduled')
      and slot_end is not null
      and slot_end < now()
      and (not v_enabled or (mentor_joined and customer_joined));
  get diagnostics n = row_count;
  return n;
end;
$$;
