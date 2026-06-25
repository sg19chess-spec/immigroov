-- Lifecycle v2 — Reschedule. Cap = 2; 3rd attempt -> auto-cancel + full refund + 100% penalty on initiator.
alter table reschedule_offers add column if not exists was_late boolean not null default false;
alter table reschedule_offers add column if not exists respond_by timestamptz;

create or replace function force_autocancel(p_booking bigint, p_initiator text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cost numeric; v_payout numeric;
begin
  select amount into v_cost   from customer_payments where booking_id = p_booking order by id desc limit 1;
  select amount into v_payout from mentor_payouts   where booking_id = p_booking order by id desc limit 1;
  update bookings set status = 'cancelled' where id = p_booking;
  perform add_ledger(p_booking, 'customer', 'refund', v_cost, 100, '3rd reschedule attempt — auto-cancel, full refund');
  if p_initiator = 'mentor' then
    perform add_ledger(p_booking, 'mentor', 'penalty', v_payout, 100, '3rd reschedule attempt — 100% penalty');
  else
    perform add_ledger(p_booking, 'customer', 'penalty', v_cost, 100, '3rd reschedule attempt — 100% penalty');
  end if;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking and status in ('pending','mentee_selected');
  perform notify_booking_event(p_booking, 'cancelled');
end; $$;

create or replace function mentor_propose_reschedule(p_booking_id bigint, p_date date, p_start timestamptz, p_end timestamptz)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; b bookings;
begin
  select * into b from bookings where id = p_booking_id;
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

create or replace function mentee_accept_reschedule(p_offer_id bigint, p_slot_time timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; v_payout numeric;
begin
  select * into o from reschedule_offers where id = p_offer_id;
  if not found or o.status <> 'pending' or o.proposed_by <> 'mentor' then raise exception 'This proposal is no longer open'; end if;
  if p_slot_time < o.range_start or p_slot_time >= o.range_end then raise exception 'Please pick a time inside the proposed range'; end if;
  if p_slot_time <= now() then raise exception 'Please pick a future time'; end if;
  update reschedule_offers set status = 'accepted', selected_time = p_slot_time where id = p_offer_id;
  update bookings set slot_time = p_slot_time, slot_end = null, status = 'rescheduled', reschedule_count = reschedule_count + 1 where id = o.booking_id;
  delete from booking_reminders where booking_id = o.booking_id;
  if o.was_late then
    select amount into v_payout from mentor_payouts where booking_id = o.booking_id order by id desc limit 1;
    perform add_ledger(o.booking_id, 'mentor', 'penalty', v_payout * 0.25, 25, 'Late mentor reschedule (<24h)');
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
  update bookings set status = 'cancelled' where id = o.booking_id;
  if o.was_late then
    perform add_ledger(o.booking_id, 'customer', 'refund', v_cost, 100, 'Rejected late mentor reschedule — full refund');
    perform add_ledger(o.booking_id, 'mentor', 'penalty', v_payout * 0.25, 25, 'Customer rejected late reschedule');
  else
    perform add_ledger(o.booking_id, 'customer', 'credit', v_cost, 100, 'Rejected reschedule — credit for a future booking');
  end if;
  perform notify_booking_event(o.booking_id, 'cancelled');
end; $$;

create or replace function customer_reschedule(p_booking_id bigint, p_slot_time timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare b bookings; v_state text; v_approved boolean;
begin
  select * into b from bookings where id = p_booking_id;
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

create or replace function request_reschedule(p_booking_id bigint)
returns bigint language plpgsql security definer set search_path = public as $$
declare b bookings; v_id bigint;
begin
  select * into b from bookings where id = p_booking_id;
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

create or replace function resolve_expired_requests()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from booking_requests where status = 'pending' and respond_by < now() loop
    perform respond_booking_request(r.id, true);
    update booking_requests set status = 'auto_approved' where id = r.id;
    n := n + 1;
  end loop;
  update reschedule_offers set status = 'expired'
    where status in ('pending','mentee_selected') and proposed_by = 'mentor'
      and respond_by is not null and respond_by < now();
  return n;
end; $$;

grant execute on function force_autocancel(bigint, text) to authenticated;
grant execute on function mentee_reject_reschedule(bigint) to anon, authenticated;
grant execute on function customer_reschedule(bigint, timestamptz) to anon, authenticated;
grant execute on function request_reschedule(bigint) to anon, authenticated;
