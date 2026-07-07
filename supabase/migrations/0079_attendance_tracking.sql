-- Attendance tracking (MVP), per the founder's spec: join tokens/links, join
-- recording, and a grace-period attendance decision. No duration/leave/rejoin
-- tracking. Data model + backend logic only — the actual join-link redirect
-- page is UI work, built later, same as the rest of the referral system.
--
-- This directly fixes the gap found while reviewing 0078_referral_system.sql:
-- commission eligibility was relying on a purely time-based "completed" status
-- with no verification that anyone actually attended. Once this migration is
-- live, a booking only reaches 'completed' after both parties are confirmed to
-- have joined — which is exactly what the referral commission calculator reads.

-- ---------------------------------------------------------------------------
-- 1. Join tokens + attendance columns on the existing bookings table.
-- ---------------------------------------------------------------------------

alter table bookings
  add column if not exists mentor_join_token   uuid not null default extensions.gen_random_uuid(),
  add column if not exists customer_join_token uuid not null default extensions.gen_random_uuid(),
  add column if not exists mentor_click_at     timestamptz,
  add column if not exists mentor_joined       boolean not null default false,
  add column if not exists mentor_joined_at    timestamptz,
  add column if not exists customer_click_at   timestamptz,
  add column if not exists customer_joined     boolean not null default false,
  add column if not exists customer_joined_at  timestamptz;

-- ---------------------------------------------------------------------------
-- 2. A booking under manual review because NEITHER party joined. Per the
--    founder's decision, this case is never auto-decided — it always goes to
--    a human, unlike the one-joined case which reuses the existing no-show
--    machinery automatically (see Section 4 below).
-- ---------------------------------------------------------------------------

create table attendance_manual_reviews (
  id          bigint generated always as identity primary key,
  booking_id  bigint not null references bookings(id) on delete cascade,
  reason      text not null check (reason in ('neither_joined')),
  status      text not null default 'pending' check (status in ('pending', 'resolved')),
  outcome     text check (outcome in ('mentor_fault', 'customer_fault', 'no_fault')),
  note        text,
  created_at  timestamptz not null default now(),
  resolved_at timestamptz
);
alter table attendance_manual_reviews enable row level security; -- no policies: admin RPCs only

-- ---------------------------------------------------------------------------
-- 3. Join link validation + recording. Each link is single-participant,
--    single-booking (the token check enforces this), and only valid in a
--    window from 2 minutes before the scheduled start to 10 minutes after —
--    matching the founder's grace-period example exactly.
-- ---------------------------------------------------------------------------

create or replace function record_session_join(p_booking_id bigint, p_role text, p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if p_role not in ('mentor', 'customer') then raise exception 'role must be mentor or customer'; end if;
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status not in ('confirmed', 'rescheduled') then raise exception 'This session is not currently joinable'; end if;
  if (p_role = 'mentor' and b.mentor_join_token <> p_token) or (p_role = 'customer' and b.customer_join_token <> p_token) then
    raise exception 'Invalid join link';
  end if;
  if b.slot_time is null or now() < b.slot_time - interval '2 minutes' then
    raise exception 'Too early to join — check back closer to the start time';
  end if;
  if now() > b.slot_time + interval '10 minutes' then
    raise exception 'The join window for this session has closed';
  end if;

  if p_role = 'mentor' then
    update bookings set
      mentor_click_at = coalesce(mentor_click_at, now()),
      mentor_joined = true,
      mentor_joined_at = coalesce(mentor_joined_at, now())
    where id = p_booking_id;
  else
    update bookings set
      customer_click_at = coalesce(customer_click_at, now()),
      customer_joined = true,
      customer_joined_at = coalesce(customer_joined_at, now())
    where id = p_booking_id;
  end if;

  return jsonb_build_object('booking_id', p_booking_id, 'role', p_role, 'ok', true, 'meeting_url', b.meeting_url);
end; $$;

-- Read-only status check for the join page's "waiting room" experience
-- (Phase 2). Never records anything — opening the link early must not count
-- as attendance. Only record_session_join() above records a join, and only
-- once this reports state = 'open' and the participant actually proceeds.
create or replace function check_join_window(p_booking_id bigint, p_role text, p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare b bookings; v_state text;
begin
  if p_role not in ('mentor', 'customer') then raise exception 'role must be mentor or customer'; end if;
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'Booking not found'; end if;
  if (p_role = 'mentor' and b.mentor_join_token <> p_token) or (p_role = 'customer' and b.customer_join_token <> p_token) then
    raise exception 'Invalid join link';
  end if;

  if b.status = 'cancelled' then v_state := 'cancelled';
  elsif b.status in ('no_show', 'completed') or b.slot_time is null then v_state := 'closed';
  elsif now() < b.slot_time - interval '2 minutes' then v_state := 'waiting';
  elsif now() <= b.slot_time + interval '10 minutes' then v_state := 'open';
  else v_state := 'closed';
  end if;

  return jsonb_build_object(
    'state', v_state, -- 'waiting' | 'open' | 'closed' | 'cancelled'
    'slot_time', b.slot_time,
    'window_opens_at', b.slot_time - interval '2 minutes',
    'window_closes_at', b.slot_time + interval '10 minutes',
    'already_joined', case when p_role = 'mentor' then b.mentor_joined else b.customer_joined end,
    'meeting_url', b.meeting_url
  );
end; $$;

-- ---------------------------------------------------------------------------
-- 3a. Token-only wrappers for the /join/:token route (a single opaque token,
--     not booking_id+role+token separately). Each join token is already
--     unique per participant per booking, so the role and booking can be
--     resolved from the token alone. These do not change check_join_window()
--     or record_session_join()'s contracts — they call them unmodified.
-- ---------------------------------------------------------------------------

create or replace function resolve_join_token(p_token uuid)
returns table (booking_id bigint, role text)
language plpgsql stable security definer set search_path = public as $$
begin
  return query select id, 'mentor'::text from bookings where mentor_join_token = p_token;
  if found then return; end if;
  return query select id, 'customer'::text from bookings where customer_join_token = p_token;
end; $$;

create or replace function check_join_window_by_token(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v record;
begin
  select * into v from resolve_join_token(p_token);
  if not found then raise exception 'Invalid join link'; end if;
  return check_join_window(v.booking_id, v.role, p_token);
end; $$;

create or replace function record_session_join_by_token(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v record;
begin
  select * into v from resolve_join_token(p_token);
  if not found then raise exception 'Invalid join link'; end if;
  return record_session_join(v.booking_id, v.role, p_token);
end; $$;

-- ---------------------------------------------------------------------------
-- 4. The attendance decision, run 10 minutes after the scheduled start:
--      both joined      -> leave it alone; the existing auto-complete job
--                           (mark_past_bookings_completed) marks it 'completed'
--                           once slot_end passes, same as always.
--      one joined       -> automatically reuse the EXISTING no-show flow
--                           (flag_no_show), unchanged — the missing party is
--                           clearly at fault.
--      neither joined   -> never auto-decided (founder's choice): move the
--                           booking to 'no_show' with no party assigned yet
--                           (no_show_by stays null, which is deliberate — it's
--                           what routes it away from the existing single-party
--                           resolution RPCs and into admin_resolve_attendance_
--                           review below instead) and create a manual review.
-- ---------------------------------------------------------------------------

create or replace function evaluate_attendance_after_grace_period()
returns void language plpgsql security definer set search_path = public as $$
declare r record;
begin
  for r in
    select b.id, b.mentor_joined, b.customer_joined
    from bookings b
    where b.status in ('confirmed', 'rescheduled')
      and b.slot_time is not null
      and now() >= b.slot_time + interval '10 minutes'
  loop
    if r.mentor_joined and r.customer_joined then
      continue; -- both attended — let the normal completion timer handle it
    elsif r.mentor_joined and not r.customer_joined then
      perform flag_no_show(r.id, 'customer');
    elsif r.customer_joined and not r.mentor_joined then
      perform flag_no_show(r.id, 'mentor');
    else
      update bookings set status = 'no_show', no_show_by = null where id = r.id;
      insert into attendance_manual_reviews (booking_id, reason) values (r.id, 'neither_joined');
      perform log_event(r.id, 'system', 'Attendance review created', 'Neither participant joined within the grace period');
    end if;
  end loop;
end; $$;

-- Admin resolution for the "neither joined" case. mentor_fault/customer_fault
-- hand off to your existing resolve_mentor_no_show/resolve_customer_no_show
-- flow unchanged (by finally setting no_show_by, which those functions require).
-- no_fault is new: a no-blame cancellation, full refund if paid, no mentor
-- strike, and — since the booking never becomes 'completed' — no referral
-- commission is created either.
create or replace function admin_resolve_attendance_review(p_review_id bigint, p_outcome text, p_note text)
returns void language plpgsql security definer set search_path = public as $$
declare rev attendance_manual_reviews; v_cost numeric;
begin
  if p_outcome not in ('mentor_fault', 'customer_fault', 'no_fault') then
    raise exception 'Outcome must be mentor_fault, customer_fault, or no_fault';
  end if;
  if p_note is null or trim(p_note) = '' then raise exception 'A note is required to resolve an attendance review'; end if;

  select * into rev from attendance_manual_reviews where id = p_review_id for update;
  if not found or rev.status <> 'pending' then raise exception 'Review not found or already resolved'; end if;

  if p_outcome = 'mentor_fault' then
    update bookings set no_show_by = 'mentor' where id = rev.booking_id;
  elsif p_outcome = 'customer_fault' then
    update bookings set no_show_by = 'customer' where id = rev.booking_id;
  else
    select amount into v_cost from customer_payments where booking_id = rev.booking_id order by id desc limit 1;
    update bookings set status = 'cancelled' where id = rev.booking_id;
    if v_cost is not null then
      perform add_ledger(rev.booking_id, 'customer', 'refund', v_cost, 100, 'Neither party attended — no-fault cancellation, full refund');
    end if;
  end if;

  update attendance_manual_reviews set status = 'resolved', outcome = p_outcome, note = p_note, resolved_at = now() where id = p_review_id;
end; $$;

create or replace function admin_attendance_review_queue()
returns table (review_id bigint, booking_id bigint, reason text, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select id, booking_id, reason, created_at from attendance_manual_reviews where status = 'pending' order by created_at asc;
$$;

-- ---------------------------------------------------------------------------
-- 5. Reset attendance state on reschedule — "joined" must reflect the CURRENT
--    scheduled time, not a slot that got moved. Bodies below are otherwise
--    byte-for-byte the existing functions from 0071_lifecycle_consolidation.sql;
--    only the bookings UPDATE gains the extra reset columns (marked).
-- ---------------------------------------------------------------------------

create or replace function customer_reschedule(p_booking_id bigint, p_slot_time timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare b bookings; v_state text; v_approved boolean; v_tz text;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status in ('cancelled','completed','no_show') then raise exception 'Cannot reschedule (status %)', b.status; end if;
  if b.reschedule_count >= 2 then perform force_autocancel(p_booking_id, 'customer'); return 'autocancelled'; end if;
  v_state := booking_deadline_state(b.slot_time);
  if v_state = 'buffer' then raise exception 'Within 2 hours of the session — cannot reschedule.'; end if;
  v_approved := exists (select 1 from booking_requests where booking_id = p_booking_id and kind = 'reschedule' and status in ('approved','auto_approved'));
  if v_state <> 'free' and not v_approved then raise exception 'A late reschedule needs mentor approval first — send a request.'; end if;
  if not is_slot_available(b.mentor_id, b.service_id, p_slot_time) then raise exception 'That time is not available — pick another slot.'; end if;
  update bookings set slot_time = p_slot_time, slot_end = null, status = 'rescheduled', reschedule_count = reschedule_count + 1,
    mentor_click_at = null, mentor_joined = false, mentor_joined_at = null,
    customer_click_at = null, customer_joined = false, customer_joined_at = null -- ADDED: reset attendance for the new slot
    where id = p_booking_id;
  delete from booking_reminders where booking_id = p_booking_id;
  update booking_requests set status = 'completed', resolved_at = now() where booking_id = p_booking_id and kind = 'reschedule' and status in ('approved','auto_approved');
  select coalesce(b.customer_timezone, (select timezone from users where id = b.user_id), 'UTC') into v_tz;
  perform log_event(p_booking_id, 'customer', 'Rescheduled by customer', 'New time '||to_char(p_slot_time at time zone v_tz,'FMMon DD, HH12:MI AM')||' ('||v_tz||')');
  return 'rescheduled';
end; $$;

create or replace function mentee_accept_reschedule(p_offer_id bigint, p_slot_time timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; b bookings; v_payout numeric; v_tz text;
begin
  select * into o from reschedule_offers where id = p_offer_id for update;
  if not found or o.status <> 'pending' or o.proposed_by <> 'mentor' then raise exception 'This proposal is no longer open'; end if;
  if p_slot_time < o.range_start or p_slot_time >= o.range_end then raise exception 'Please pick a time inside the proposed range'; end if;
  if p_slot_time <= now() then raise exception 'Please pick a future time'; end if;
  select * into b from bookings where id = o.booking_id;
  if not is_slot_available(b.mentor_id, b.service_id, p_slot_time) then
    raise exception 'That time is no longer available — pick another slot inside the range.';
  end if;
  update reschedule_offers set status = 'accepted', selected_time = p_slot_time where id = p_offer_id;
  update bookings set slot_time = p_slot_time, slot_end = null, status = 'rescheduled', reschedule_count = reschedule_count + 1,
    mentor_click_at = null, mentor_joined = false, mentor_joined_at = null,
    customer_click_at = null, customer_joined = false, customer_joined_at = null -- ADDED: reset attendance for the new slot
    where id = o.booking_id;
  delete from booking_reminders where booking_id = o.booking_id;
  if o.was_late then
    select amount into v_payout from mentor_payouts where booking_id = o.booking_id order by id desc limit 1;
    perform add_ledger(o.booking_id, 'mentor', 'penalty', v_payout * 0.25, 25, 'Late mentor reschedule (<24h)');
  end if;
  select coalesce(b.customer_timezone, (select timezone from users where id = b.user_id), 'UTC') into v_tz;
  perform log_event(o.booking_id, 'customer', 'Accepted the mentor''s proposal',
    'Picked '||to_char(p_slot_time at time zone v_tz,'FMMon DD, HH12:MI AM')||' ('||v_tz||')'||case when o.was_late then ' · past-deadline, 25% mentor penalty' else '' end);
end; $$;

-- ---------------------------------------------------------------------------
-- 6. NOT scheduled yet — deliberately.
--
-- evaluate_attendance_after_grace_period() only works once real people are
-- actually clicking real join links, which needs the join-link pages/redirect
-- flow and the booking-reminder emails to be updated to send those links —
-- neither exists yet (that's the UI work we agreed to hold off on). If this
-- job runs today, mentor_joined/customer_joined will be false for every
-- booking (nobody has a link to click), so EVERY session would get dumped
-- into "neither joined" manual review — flooding you with false alarms
-- instead of fixing anything.
--
-- Turn this on only after the join-link UI + reminder emails are live:
--   select cron.schedule('attendance-grace-period', '*/5 * * * *',
--     $$ select evaluate_attendance_after_grace_period() $$);
--
-- Same reasoning is why mark_past_bookings_completed() (0011) is left
-- completely untouched by this migration — tightening it now to require
-- attendance would strand every booking in 'confirmed' forever, for the same
-- reason. The referral commission gap from 0078 is only closed in principle
-- right now; it becomes real once this job is switched on.
-- ---------------------------------------------------------------------------
