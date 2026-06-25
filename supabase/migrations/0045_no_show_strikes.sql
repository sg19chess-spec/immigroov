-- No-show handling (report-based) + mentor strike ladder.
alter table bookings add column if not exists no_show_by text;            -- 'mentor' | 'customer'
alter table mentors  add column if not exists no_show_strikes int not null default 0;
alter table mentors  add column if not exists last_no_show_at timestamptz;

-- record a mentor no-show strike (90-day reset; 3rd+ = 25% payout penalty)
create or replace function apply_mentor_strike(p_mentor_id bigint, p_booking_id bigint)
returns int language plpgsql security definer set search_path = public as $$
declare v_str int; v_last timestamptz; v_payout numeric;
begin
  select no_show_strikes, last_no_show_at into v_str, v_last from mentors where id = p_mentor_id;
  if v_last is null or v_last < now() - interval '90 days' then v_str := 0; end if;
  v_str := coalesce(v_str,0) + 1;
  update mentors set no_show_strikes = v_str, last_no_show_at = now() where id = p_mentor_id;
  if v_str >= 3 then
    select amount into v_payout from mentor_payouts where booking_id = p_booking_id order by id desc limit 1;
    perform add_ledger(p_booking_id, 'mentor', 'penalty', v_payout * 0.25, 25, 'No-show strike '||v_str||' — 25% payout deducted');
  else
    perform add_ledger(p_booking_id, 'mentor', 'penalty', 0, 0, 'No-show strike '||v_str||(case when v_str=2 then ' — warning + ops check-in' else ' — warning only' end));
  end if;
  return v_str;
end; $$;

create or replace function flag_no_show(p_booking_id bigint, p_no_show_party text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if p_no_show_party not in ('mentor','customer') then raise exception 'no_show_party must be mentor or customer'; end if;
  select * into b from bookings where id = p_booking_id;
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
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'credit', v_cost, 100, 'Mentor no-show — credit to rebook another mentor');
  elsif p_choice = 'refund' then
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'refund', v_cost, 100, 'Mentor no-show — full refund');
  else raise exception 'Unknown choice %', p_choice; end if;
end; $$;

create or replace function resolve_customer_no_show(p_booking_id bigint, p_choice text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; v_payout numeric;
begin
  select * into b from bookings where id = p_booking_id;
  if b.no_show_by is distinct from 'customer' or b.status <> 'no_show' then raise exception 'Not a customer no-show awaiting resolution'; end if;
  if p_choice = 'accept_rebook' then
    update bookings set status = 'confirmed', no_show_by = null where id = p_booking_id;
  elsif p_choice = 'reject' then
    select amount into v_payout from mentor_payouts where booking_id = p_booking_id order by id desc limit 1;
    update bookings set status = 'completed' where id = p_booking_id;
    perform add_ledger(p_booking_id, 'mentor', 'credit', v_payout, 100, 'Customer no-show — session closed, mentor paid in full');
  else raise exception 'Unknown choice %', p_choice; end if;
end; $$;

grant execute on function flag_no_show(bigint, text) to anon, authenticated;
grant execute on function resolve_mentor_no_show(bigint, text) to anon, authenticated;
grant execute on function resolve_customer_no_show(bigint, text) to anon, authenticated;
