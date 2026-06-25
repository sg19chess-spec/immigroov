-- Lifecycle v2 — Cancel flow. >=24h free; <24h late; <2h blocked.
-- Penalties/refunds recorded in booking_ledger (mock payments).

create or replace function add_ledger(p_booking bigint, p_party text, p_kind text, p_amount numeric, p_pct int, p_reason text)
returns void language sql security definer set search_path = public as $$
  insert into booking_ledger(booking_id, party, kind, amount, pct, currency, reason)
  select p_booking, p_party, p_kind, round(coalesce(p_amount,0),2), p_pct,
         coalesce((select currency from customer_payments where booking_id = p_booking order by id desc limit 1), 'USD'),
         p_reason;
$$;

create or replace function cancel_booking(p_booking_id bigint, p_cancelled_by text default 'user')
returns bookings language plpgsql security definer set search_path = public as $$
declare b bookings; v_state text; v_cost numeric; v_payout numeric;
begin
  select * into b from bookings where id = p_booking_id;
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
grant execute on function cancel_booking(bigint, text) to anon, authenticated;
grant execute on function add_ledger(bigint, text, text, numeric, int, text) to authenticated;

create or replace function respond_booking_request(p_request_id bigint, p_accept boolean)
returns void language plpgsql security definer set search_path = public as $$
declare r booking_requests; v_cost numeric;
begin
  select * into r from booking_requests where id = p_request_id;
  if not found or r.status <> 'pending' then raise exception 'This request is no longer open'; end if;
  select amount into v_cost from customer_payments where booking_id = r.booking_id order by id desc limit 1;

  if r.kind = 'cancel' then
    update bookings set status = 'cancelled' where id = r.booking_id;
    if p_accept then
      perform add_ledger(r.booking_id, 'customer', 'refund', v_cost, 100, 'Late cancel approved — full refund');
      update booking_requests set status = 'approved', resolved_at = now() where id = p_request_id;
    else
      perform add_ledger(r.booking_id, 'customer', 'charge', v_cost * 0.5, 50, 'Late cancel rejected — 50% fee kept');
      perform add_ledger(r.booking_id, 'customer', 'refund', v_cost * 0.5, 50, 'Late cancel rejected — 50% refunded');
      update booking_requests set status = 'rejected', resolved_at = now() where id = p_request_id;
    end if;
    update reschedule_offers set status = 'superseded' where booking_id = r.booking_id and status in ('pending','mentee_selected');
    perform notify_booking_event(r.booking_id, 'cancelled');
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
grant execute on function respond_booking_request(bigint, boolean) to anon, authenticated;

create or replace function resolve_expired_requests()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from booking_requests where status = 'pending' and respond_by < now() loop
    perform respond_booking_request(r.id, true);
    update booking_requests set status = 'auto_approved' where id = r.id;
    n := n + 1;
  end loop;
  return n;
end; $$;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'resolve-requests') then perform cron.unschedule('resolve-requests'); end if;
end $$;
select cron.schedule('resolve-requests', '*/10 * * * *', $$ select resolve_expired_requests() $$);
