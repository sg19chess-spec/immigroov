-- =============================================================================
-- 0067 — resolve_mentor_no_show: close the 'no_show' status window on every
-- branch, not just rebook_same.
--
-- Bug: rebook_different and refund applied the mentor strike + ledger credit/
-- refund but left bookings.status = 'no_show' and no_show_by = 'mentor'. The
-- guard at the top of the function only checks (no_show_by='mentor' AND
-- status='no_show') — since neither branch changed either field, a duplicate
-- call (double-click, retried request) passes the guard a second time and
-- re-applies the strike and re-credits/re-refunds the ledger.
--
-- Fix: both branches now set status='cancelled' (the booking is void either
-- way — rebook_different sends the customer to book a NEW session with a
-- different mentor; refund closes it out) and clear no_show_by, matching the
-- existing single-source-of-truth pattern (0048) where the status UPDATE
-- alone drives the cancellation email via trg_booking_status_email, with no
-- explicit notify call needed. This both closes the idempotency window and
-- correctly notifies the customer their booking is now cancelled/refunded.
--
-- Verified: zero bookings have ever been flagged no_show in production, so
-- this is a pure logic fix — no historical data needs correction.
-- =============================================================================
create or replace function resolve_mentor_no_show(p_booking_id bigint, p_choice text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; v_cost numeric;
begin
  select * into b from bookings where id = p_booking_id;
  if b.no_show_by is distinct from 'mentor' or b.status <> 'no_show' then raise exception 'Not a mentor no-show awaiting resolution'; end if;
  select amount into v_cost from customer_payments where booking_id = p_booking_id order by id desc limit 1;
  if p_choice = 'rebook_same' then
    update bookings set status = 'confirmed', no_show_by = null where id = p_booking_id;
  elsif p_choice = 'rebook_different' then
    update bookings set status = 'cancelled', no_show_by = null where id = p_booking_id;  -- trigger sends 'cancelled'
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'credit', v_cost, 100, 'Mentor no-show — credit to rebook another mentor');
  elsif p_choice = 'refund' then
    update bookings set status = 'cancelled', no_show_by = null where id = p_booking_id;  -- trigger sends 'cancelled'
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'refund', v_cost, 100, 'Mentor no-show — full refund');
  else raise exception 'Unknown choice %', p_choice; end if;
end; $$;
