-- Fix two as-built issues found in docs/BOOKING_SYSTEM.md:
--
-- 1) Duplicate "cancelled" email. respond_booking_request (cancel branch),
--    mentee_reject_reschedule, and force_autocancel each set status='cancelled'
--    AND called notify_booking_event(..., 'cancelled') explicitly, while the
--    trg_booking_status_email trigger ALSO fires 'cancelled' on that same status
--    change -> two emails. The trigger is the single source of truth for status
--    transitions, so we drop the explicit calls (matching the customer-free /
--    mentor cancel paths, which already rely on the trigger alone).
--
-- 2) mentee_accept_reschedule skipped is_slot_available, so an accepted slot inside
--    a stale proposed window could collide with another booking and only fail at
--    the bookings_no_overlap constraint. Add the same availability check
--    customer_reschedule uses, for a clean error instead of a constraint violation.

create or replace function respond_booking_request(p_request_id bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r booking_requests; v_cost numeric;
begin
  select * into r from booking_requests where id = p_request_id;
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
      perform notify_booking_event(r.booking_id, 'reschedule_approved');   -- customer may now pick a slot
    else
      update booking_requests set status = 'rejected', resolved_at = now() where id = p_request_id;
      perform notify_booking_event(r.booking_id, 'reschedule_rejected');   -- customer keeps original or pays 50% to cancel
    end if;
  end if;
end; $$;

create or replace function mentee_reject_reschedule(p_offer_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; v_cost numeric; v_payout numeric;
begin
  select * into o from reschedule_offers where id = p_offer_id;
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

create or replace function force_autocancel(p_booking bigint, p_initiator text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cost numeric; v_payout numeric;
begin
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

create or replace function mentee_accept_reschedule(p_offer_id bigint, p_slot_time timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; b bookings; v_payout numeric;
begin
  select * into o from reschedule_offers where id = p_offer_id;
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
