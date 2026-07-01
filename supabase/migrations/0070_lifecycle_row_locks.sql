-- =============================================================================
-- 0070 — Concurrency hardening for the booking lifecycle family.
--
-- Every state-mutating lifecycle RPC read its gating row (bookings /
-- booking_requests / reschedule_offers) WITHOUT `for update`, then checked a
-- status guard, then wrote booking_ledger. Two concurrent calls (double-click,
-- or the resolve-requests cron racing a user) both read the pre-update status,
-- both pass the guard, and both write — a real double-refund / double-penalty /
-- double-credit (TOCTOU), because none re-checks status after taking the write
-- lock.
--
-- Fix: take `for update` on the gating row read. The second concurrent call now
-- BLOCKS at the SELECT until the first commits, then reads the updated status
-- and the existing guard rejects it cleanly. No logic/schema change — bodies are
-- the current live definitions (0048 supersedes 0041/0042 for the four it
-- redefined; 0067 for resolve_mentor_no_show) with the lock added. `create or
-- replace` preserves existing grants. resolve_expired_requests' cron cursor gets
-- `for update skip locked` so it never fights a user mid-action.
-- =============================================================================

-- cancel_booking (base: 0041) --------------------------------------------------
create or replace function cancel_booking(p_booking_id bigint, p_cancelled_by text default 'user')
returns bookings language plpgsql security definer set search_path = public as $$
declare b bookings; v_state text; v_cost numeric; v_payout numeric;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking % not found', p_booking_id; end if;
  if b.status in ('cancelled','completed','no_show') then raise exception 'Booking % is already %', p_booking_id, b.status; end if;

  v_state := booking_deadline_state(b.slot_time);
  if v_state = 'buffer' then
    raise exception 'Within 2 hours of the session — it can no longer be cancelled here. Please contact the other party.';
  end if;
  select amount into v_cost   from customer_payments where booking_id = p_booking_id order by id desc limit 1;
  select amount into v_payout from mentor_payouts   where booking_id = p_booking_id order by id desc limit 1;

  if p_cancelled_by = 'mentor' then
    update bookings set status = 'cancelled' where id = p_booking_id returning * into b;
    perform add_ledger(p_booking_id, 'customer', 'refund', v_cost, 100, 'Mentor cancelled — full refund');
    if v_state = 'late' then
      perform add_ledger(p_booking_id, 'mentor', 'penalty', v_payout * 0.25, 25, 'Late mentor cancel (<24h)');
      perform bump_mentor_cancellation(b.mentor_id);
    end if;
    update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
    return b;
  end if;

  if v_state = 'free' then
    update bookings set status = 'cancelled' where id = p_booking_id returning * into b;
    perform add_ledger(p_booking_id, 'customer', 'refund', v_cost, 100, 'Customer cancelled (>=24h) — full refund');
    update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
    return b;
  else
    update booking_requests set status = 'withdrawn', resolved_at = now() where booking_id = p_booking_id and status = 'pending';
    insert into booking_requests(booking_id, kind, initiated_by, status, respond_by, note)
      values (p_booking_id, 'cancel', 'customer', 'pending', response_window(b.slot_time), 'Customer requested late cancellation');
    perform notify_booking_event(p_booking_id, 'cancel_requested');
    return b;
  end if;
end; $$;

-- respond_booking_request (base: 0048) -----------------------------------------
create or replace function respond_booking_request(p_request_id bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r booking_requests; v_cost numeric;
begin
  select * into r from booking_requests where id = p_request_id for update;
  if not found or r.status <> 'pending' then raise exception 'This request is no longer open'; end if;
  select amount into v_cost from customer_payments where booking_id = r.booking_id order by id desc limit 1;

  if r.kind = 'cancel' then
    update bookings set status = 'cancelled' where id = r.booking_id;  -- trigger sends 'cancelled'
    if p_accept then
      perform add_ledger(r.booking_id, 'customer', 'refund', v_cost, 100, 'Late cancel approved — full refund');
      update booking_requests set status = 'approved', resolved_at = now() where id = p_request_id;
    else
      perform add_ledger(r.booking_id, 'customer', 'charge', v_cost * 0.5, 50, 'Late cancel rejected — 50% fee kept');
      perform add_ledger(r.booking_id, 'customer', 'refund', v_cost * 0.5, 50, 'Late cancel rejected — 50% refunded');
      update booking_requests set status = 'rejected', resolved_at = now() where id = p_request_id;
    end if;
    update reschedule_offers set status = 'superseded' where booking_id = r.booking_id and status in ('pending','mentee_selected');
  elsif r.kind = 'reschedule' then
    if p_accept then
      update booking_requests set status = 'approved', resolved_at = now() where id = p_request_id;
      perform notify_booking_event(r.booking_id, 'reschedule_approved');
    else
      update booking_requests set status = 'rejected', resolved_at = now() where id = p_request_id;
      perform notify_booking_event(r.booking_id, 'reschedule_rejected');
    end if;
  end if;
end; $$;

-- force_autocancel (base: 0048) — lock the booking so concurrent cap-hits serialize
create or replace function force_autocancel(p_booking bigint, p_initiator text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cost numeric; v_payout numeric; v_status booking_status;
begin
  select status into v_status from bookings where id = p_booking for update;
  if v_status is null or v_status in ('cancelled','completed','no_show') then return; end if;  -- already terminal: no double-write
  select amount into v_cost   from customer_payments where booking_id = p_booking order by id desc limit 1;
  select amount into v_payout from mentor_payouts   where booking_id = p_booking order by id desc limit 1;
  update bookings set status = 'cancelled' where id = p_booking;  -- trigger sends 'cancelled'
  perform add_ledger(p_booking, 'customer', 'refund', v_cost, 100, '3rd reschedule attempt — auto-cancel, full refund');
  if p_initiator = 'mentor' then
    perform add_ledger(p_booking, 'mentor', 'penalty', v_payout, 100, '3rd reschedule attempt — 100% penalty');
  else
    perform add_ledger(p_booking, 'customer', 'penalty', v_cost, 100, '3rd reschedule attempt — 100% penalty');
  end if;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking and status in ('pending','mentee_selected');
end; $$;

-- mentor_propose_reschedule (base: 0042) ---------------------------------------
create or replace function mentor_propose_reschedule(p_booking_id bigint, p_date date, p_start timestamptz, p_end timestamptz)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; b bookings;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status in ('cancelled','completed','no_show') then raise exception 'Cannot reschedule (status %)', b.status; end if;
  if b.reschedule_count >= 2 then perform force_autocancel(p_booking_id, 'mentor'); return -1; end if;
  if p_end <= p_start then raise exception 'Range end must be after start'; end if;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
  insert into reschedule_offers(booking_id, proposed_by, offer_date, range_start, range_end, status, was_late, respond_by)
    values (p_booking_id, 'mentor', p_date, p_start, p_end, 'pending',
            booking_deadline_state(b.slot_time) = 'late', response_window(b.slot_time))
    returning id into v_id;
  perform notify_booking_event(p_booking_id, 'proposed');
  return v_id;
end; $$;

-- mentee_accept_reschedule (base: 0048, has is_slot_available) ------------------
create or replace function mentee_accept_reschedule(p_offer_id bigint, p_slot_time timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; b bookings; v_payout numeric;
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
  update bookings set slot_time = p_slot_time, slot_end = null, status = 'rescheduled', reschedule_count = reschedule_count + 1 where id = o.booking_id;
  delete from booking_reminders where booking_id = o.booking_id;
  if o.was_late then
    select amount into v_payout from mentor_payouts where booking_id = o.booking_id order by id desc limit 1;
    perform add_ledger(o.booking_id, 'mentor', 'penalty', v_payout * 0.25, 25, 'Late mentor reschedule (<24h)');
  end if;
end; $$;

-- mentee_reject_reschedule (base: 0048) ----------------------------------------
create or replace function mentee_reject_reschedule(p_offer_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; v_cost numeric; v_payout numeric;
begin
  select * into o from reschedule_offers where id = p_offer_id for update;
  if not found or o.status not in ('pending','mentee_selected') or o.proposed_by <> 'mentor' then raise exception 'This proposal is no longer open'; end if;
  select amount into v_cost   from customer_payments where booking_id = o.booking_id order by id desc limit 1;
  select amount into v_payout from mentor_payouts   where booking_id = o.booking_id order by id desc limit 1;
  update reschedule_offers set status = 'rejected' where id = p_offer_id;
  update bookings set status = 'cancelled' where id = o.booking_id;  -- trigger sends 'cancelled'
  if o.was_late then
    perform add_ledger(o.booking_id, 'customer', 'refund', v_cost, 100, 'Rejected late mentor reschedule — full refund');
    perform add_ledger(o.booking_id, 'mentor', 'penalty', v_payout * 0.25, 25, 'Customer rejected late reschedule');
  else
    perform add_ledger(o.booking_id, 'customer', 'credit', v_cost, 100, 'Rejected reschedule — credit for a future booking');
  end if;
end; $$;

-- customer_reschedule (base: 0042) ---------------------------------------------
create or replace function customer_reschedule(p_booking_id bigint, p_slot_time timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare b bookings; v_state text; v_approved boolean;
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
  update bookings set slot_time = p_slot_time, slot_end = null, status = 'rescheduled', reschedule_count = reschedule_count + 1 where id = p_booking_id;
  delete from booking_reminders where booking_id = p_booking_id;
  update booking_requests set status = 'completed', resolved_at = now() where booking_id = p_booking_id and kind = 'reschedule' and status in ('approved','auto_approved');
  return 'rescheduled';
end; $$;

-- request_reschedule (base: 0042) ----------------------------------------------
create or replace function request_reschedule(p_booking_id bigint)
returns bigint language plpgsql security definer set search_path = public as $$
declare b bookings; v_id bigint;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status in ('cancelled','completed','no_show') then raise exception 'Cannot reschedule (status %)', b.status; end if;
  if b.reschedule_count >= 2 then perform force_autocancel(p_booking_id, 'customer'); return -1; end if;
  if booking_deadline_state(b.slot_time) = 'buffer' then raise exception 'Within 2 hours of the session — cannot reschedule.'; end if;
  update booking_requests set status = 'withdrawn', resolved_at = now() where booking_id = p_booking_id and status = 'pending';
  insert into booking_requests(booking_id, kind, initiated_by, status, respond_by, note)
    values (p_booking_id, 'reschedule', 'customer', 'pending', response_window(b.slot_time), 'Customer requested reschedule')
    returning id into v_id;
  perform notify_booking_event(p_booking_id, 'reschedule_requested');
  return v_id;
end; $$;

-- resolve_expired_requests (base: 0042) — SKIP LOCKED so it never fights a user
create or replace function resolve_expired_requests()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from booking_requests where status = 'pending' and respond_by < now() for update skip locked loop
    perform respond_booking_request(r.id, true);
    update booking_requests set status = 'auto_approved' where id = r.id;
    n := n + 1;
  end loop;
  update reschedule_offers set status = 'expired'
    where status in ('pending','mentee_selected') and proposed_by = 'mentor'
      and respond_by is not null and respond_by < now();
  return n;
end; $$;

-- flag_no_show (base: 0045) ----------------------------------------------------
create or replace function flag_no_show(p_booking_id bigint, p_no_show_party text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if p_no_show_party not in ('mentor','customer') then raise exception 'no_show_party must be mentor or customer'; end if;
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status not in ('confirmed','rescheduled') then raise exception 'Only an active session can be reported as a no-show'; end if;
  if b.slot_time is null or now() < b.slot_time + interval '10 minutes' then
    raise exception 'No-shows can only be reported 10 minutes after the start time';
  end if;
  update bookings set status = 'no_show', no_show_by = p_no_show_party where id = p_booking_id;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
  update booking_requests set status = 'withdrawn', resolved_at = now() where booking_id = p_booking_id and status = 'pending';
  perform notify_booking_event(p_booking_id, 'no_show');
end; $$;

-- resolve_mentor_no_show (base: 0067) ------------------------------------------
create or replace function resolve_mentor_no_show(p_booking_id bigint, p_choice text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; v_cost numeric;
begin
  select * into b from bookings where id = p_booking_id for update;
  if b.no_show_by is distinct from 'mentor' or b.status <> 'no_show' then raise exception 'Not a mentor no-show awaiting resolution'; end if;
  select amount into v_cost from customer_payments where booking_id = p_booking_id order by id desc limit 1;
  if p_choice = 'rebook_same' then
    update bookings set status = 'confirmed', no_show_by = null where id = p_booking_id;
  elsif p_choice = 'rebook_different' then
    update bookings set status = 'cancelled', no_show_by = null where id = p_booking_id;
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'credit', v_cost, 100, 'Mentor no-show — credit to rebook another mentor');
  elsif p_choice = 'refund' then
    update bookings set status = 'cancelled', no_show_by = null where id = p_booking_id;
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'refund', v_cost, 100, 'Mentor no-show — full refund');
  else raise exception 'Unknown choice %', p_choice; end if;
end; $$;

-- resolve_customer_no_show (base: 0045) ----------------------------------------
create or replace function resolve_customer_no_show(p_booking_id bigint, p_choice text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; v_payout numeric;
begin
  select * into b from bookings where id = p_booking_id for update;
  if b.no_show_by is distinct from 'customer' or b.status <> 'no_show' then raise exception 'Not a customer no-show awaiting resolution'; end if;
  if p_choice = 'accept_rebook' then
    update bookings set status = 'confirmed', no_show_by = null where id = p_booking_id;
  elsif p_choice = 'reject' then
    select amount into v_payout from mentor_payouts where booking_id = p_booking_id order by id desc limit 1;
    update bookings set status = 'completed' where id = p_booking_id;
    perform add_ledger(p_booking_id, 'mentor', 'credit', v_payout, 100, 'Customer no-show — session closed, mentor paid in full');
  else raise exception 'Unknown choice %', p_choice; end if;
end; $$;
