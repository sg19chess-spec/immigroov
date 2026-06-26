-- Dedicated audit log so every lifecycle transition has an exact timestamp + actor.
-- Functions below are re-created from their verified bodies with log_event() calls added;
-- behaviour is unchanged otherwise. admin_booking_detail prefers this table and falls
-- back to reconstruction for legacy bookings created before it existed.

create table if not exists booking_events (
  id bigserial primary key,
  booking_id bigint not null references bookings(id) on delete cascade,
  at timestamptz not null default now(),
  actor text,                 -- 'customer' | 'mentor' | 'system'
  event text not null,        -- short human label
  detail text
);
create index if not exists booking_events_booking_idx on booking_events(booking_id, at);

create or replace function log_event(p_booking bigint, p_actor text, p_event text, p_detail text default null)
returns void language sql security definer set search_path = public as $$
  insert into booking_events(booking_id, actor, event, detail) values (p_booking, p_actor, p_event, p_detail);
$$;

-- ---------- cancel ----------
create or replace function cancel_booking(p_booking_id bigint, p_cancelled_by text default 'user')
returns bookings language plpgsql security definer set search_path = public as $$
declare b bookings; v_state text; v_cost numeric; v_payout numeric;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'Booking % not found', p_booking_id; end if;
  if b.status in ('cancelled','completed','no_show') then raise exception 'Booking % is already %', p_booking_id, b.status; end if;
  v_state := booking_deadline_state(b.slot_time);
  if v_state = 'buffer' then raise exception 'Within 2 hours of the session — it can no longer be cancelled here. Please contact the other party.'; end if;
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
    perform log_event(p_booking_id, 'mentor', case when v_state='late' then 'Mentor cancelled (late — 25% penalty)' else 'Mentor cancelled (free)' end);
    return b;
  end if;

  if v_state = 'free' then
    update bookings set status = 'cancelled' where id = p_booking_id returning * into b;
    perform add_ledger(p_booking_id, 'customer', 'refund', v_cost, 100, 'Customer cancelled (>=24h) — full refund');
    update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
    perform log_event(p_booking_id, 'customer', 'Customer cancelled (free)');
    return b;
  else
    update booking_requests set status = 'withdrawn', resolved_at = now() where booking_id = p_booking_id and status = 'pending';
    insert into booking_requests(booking_id, kind, initiated_by, status, respond_by, note)
      values (p_booking_id, 'cancel', 'customer', 'pending', response_window(b.slot_time), 'Customer requested late cancellation');
    perform notify_booking_event(p_booking_id, 'cancel_requested');
    perform log_event(p_booking_id, 'customer', 'Cancellation requested', 'Awaiting mentor — auto-approves at the deadline');
    return b;
  end if;
end; $$;

drop function if exists respond_booking_request(bigint, boolean);
create or replace function respond_booking_request(p_request_id bigint, p_accept boolean, p_actor text default 'mentor')
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
    perform log_event(r.booking_id, p_actor, case when p_accept then 'Cancellation approved (full refund)' else 'Cancellation rejected (50% kept)' end,
                      case when p_actor='system' then 'No response in window — auto-approved' else null end);
  elsif r.kind = 'reschedule' then
    if p_accept then
      update booking_requests set status = 'approved', resolved_at = now() where id = p_request_id;
      perform notify_booking_event(r.booking_id, 'reschedule_approved');
    else
      update booking_requests set status = 'rejected', resolved_at = now() where id = p_request_id;
      perform notify_booking_event(r.booking_id, 'reschedule_rejected');
    end if;
    perform log_event(r.booking_id, p_actor, case when p_accept then 'Reschedule approved' else 'Reschedule rejected' end,
                      case when p_actor='system' then 'No response in window — auto-approved' else null end);
  end if;
end; $$;
grant execute on function respond_booking_request(bigint, boolean, text) to anon, authenticated;

create or replace function resolve_expired_requests()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from booking_requests where status = 'pending' and respond_by < now() loop
    perform respond_booking_request(r.id, true, 'system');
    update booking_requests set status = 'auto_approved' where id = r.id;
    n := n + 1;
  end loop;
  update reschedule_offers set status = 'expired'
    where status in ('pending','mentee_selected') and proposed_by = 'mentor'
      and respond_by is not null and respond_by < now();
  return n;
end; $$;

-- ---------- reschedule ----------
create or replace function customer_reschedule(p_booking_id bigint, p_slot_time timestamptz)
returns text language plpgsql security definer set search_path = public as $$
declare b bookings; v_state text; v_approved boolean; v_tz text;
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
  select coalesce(b.customer_timezone, (select timezone from users where id = b.user_id), 'UTC') into v_tz;
  perform log_event(p_booking_id, 'customer', 'Rescheduled by customer', 'New time '||to_char(p_slot_time at time zone v_tz,'FMMon DD, HH12:MI AM')||' ('||v_tz||')');
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
  perform log_event(p_booking_id, 'customer', 'Reschedule requested', 'Awaiting mentor — auto-approves at the deadline');
  return v_id;
end; $$;

create or replace function mentor_propose_reschedule(p_booking_id bigint, p_date date, p_start timestamptz, p_end timestamptz)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; b bookings; v_tz text;
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
  select coalesce(b.customer_timezone, (select timezone from users where id = b.user_id), 'UTC') into v_tz;
  perform log_event(p_booking_id, 'mentor', 'Proposed a new time window',
    to_char(p_date,'FMDay, FMMon DD')||': '||to_char(p_start at time zone v_tz,'HH12:MI AM')||' – '||to_char(p_end at time zone v_tz,'HH12:MI AM')||' ('||v_tz||')'
    ||case when booking_deadline_state(b.slot_time)='late' then ' · past-deadline' else '' end);
  return v_id;
end; $$;

create or replace function mentee_accept_reschedule(p_offer_id bigint, p_slot_time timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; b bookings; v_payout numeric; v_tz text;
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
  select coalesce(b.customer_timezone, (select timezone from users where id = b.user_id), 'UTC') into v_tz;
  perform log_event(o.booking_id, 'customer', 'Accepted the mentor''s proposal',
    'Picked '||to_char(p_slot_time at time zone v_tz,'FMMon DD, HH12:MI AM')||' ('||v_tz||')'||case when o.was_late then ' · past-deadline, 25% mentor penalty' else '' end);
end; $$;

create or replace function mentee_request_other_date(p_booking_id bigint, p_date date)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
  insert into reschedule_offers(booking_id, proposed_by, requested_date, status)
    values (p_booking_id, 'user', p_date, 'pending') returning id into v_id;
  perform notify_booking_event(p_booking_id, 'counter');
  perform log_event(p_booking_id, 'customer', 'Asked for a different date', to_char(p_date,'FMDay, FMMon DD'));
  return v_id;
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
  perform log_event(o.booking_id, 'customer', case when o.was_late then 'Rejected reschedule (late) — refund + mentor penalty' else 'Rejected reschedule — credit issued' end);
end; $$;

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
  perform log_event(p_booking, p_initiator, 'Auto-cancelled — 3rd reschedule attempt', '100% penalty on the '||p_initiator);
end; $$;

-- ---------- no-show ----------
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
  perform log_event(p_booking_id, case when p_no_show_party='mentor' then 'customer' else 'mentor' end,
                    'Reported a no-show', 'Marked the '||p_no_show_party||' as not attending');
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
  perform log_event(p_booking_id, 'customer', 'Mentor no-show resolved: '||p_choice);
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
  perform log_event(p_booking_id, 'mentor', 'Customer no-show resolved: '||p_choice);
end; $$;

-- ---------- auto-complete (cron) ----------
create or replace function mark_past_bookings_completed()
returns integer language plpgsql security definer set search_path = public as $$
declare n int;
begin
  with upd as (
    update bookings set status = 'completed'
      where status in ('confirmed','rescheduled') and slot_end is not null and slot_end < now()
      returning id)
  insert into booking_events(booking_id, actor, event, detail)
  select id, 'system', 'Auto-completed', 'Session end time passed' from upd;
  get diagnostics n = row_count;
  return n;
end; $$;

-- ---------- admin detail: prefer events table, fall back to reconstruction ----------
create or replace function admin_booking_detail(p_booking_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_tz text; v_has boolean; v_res jsonb;
begin
  select coalesce(b.customer_timezone, cu.timezone, 'UTC') into v_tz
  from bookings b join users cu on cu.id = b.user_id where b.id = p_booking_id;
  if not found then return null; end if;
  v_has := exists (select 1 from booking_events where booking_id = p_booking_id);

  with b as (select * from bookings where id = p_booking_id),
  cp as (select amount, currency, status from customer_payments where booking_id = p_booking_id order by id desc limit 1),
  mp as (select amount, currency, status from mentor_payouts where booking_id = p_booking_id order by id desc limit 1),
  ev as (
    select b.created_at as at, 'customer'::text as actor, 'Booking created & paid'::text as title,
           (select 'Paid '||to_char(amount,'FM999990.00')||' '||currency from cp)::text as detail from b
    union all
    select b.mentor_confirmed_at, 'mentor', 'Mentor confirmed availability', null::text from b where b.mentor_confirmed_at is not null
    union all
    -- canonical: the audit log
    select e.at, e.actor, e.event, e.detail from booking_events e where e.booking_id = p_booking_id
    union all
    -- legacy fallback only when there is no audit log for this booking
    select r.created_at, case when r.initiated_by='user' then 'customer' else r.initiated_by end,
           initcap(r.kind)||' requested', r.note
      from booking_requests r where r.booking_id = p_booking_id and not v_has
    union all
    select r.resolved_at, case when r.initiated_by='user' then 'customer' else r.initiated_by end,
           initcap(r.kind)||' request '||r.status, null
      from booking_requests r where r.booking_id = p_booking_id and r.resolved_at is not null and not v_has
    union all
    select o.created_at, case when o.proposed_by='mentor' then 'mentor' else 'customer' end,
           case when o.proposed_by='mentor' then 'Mentor proposed a new time window'
                when o.requested_date is not null then 'Customer asked for a different date'
                else 'Reschedule offer' end,
           (case when o.proposed_by='mentor'
                 then to_char(o.offer_date,'FMDay, FMMon DD')||': '
                      ||to_char(o.range_start at time zone v_tz,'HH12:MI AM')||' – '||to_char(o.range_end at time zone v_tz,'HH12:MI AM')
                      ||' · status: '||o.status
                 when o.requested_date is not null then to_char(o.requested_date,'FMDay, FMMon DD')||' · status: '||o.status
                 else 'status: '||o.status end)::text
      from reschedule_offers o where o.booking_id = p_booking_id and not v_has
    union all
    -- money entries always
    select l.created_at, l.party, initcap(l.kind)||' '||coalesce(l.pct::text||'%','')
           ||case when l.amount is not null then ' — '||to_char(l.amount,'FM999990.00')||' '||l.currency else '' end,
           l.reason
      from booking_ledger l where l.booking_id = p_booking_id
  )
  select jsonb_build_object(
    'booking', (select jsonb_build_object(
        'id', b.id, 'status', b.status, 'created_at', b.created_at, 'slot_time', b.slot_time, 'slot_end', b.slot_end,
        'reschedule_count', b.reschedule_count, 'no_show_by', b.no_show_by, 'mentor_confirmed_at', b.mentor_confirmed_at,
        'meeting_url', b.meeting_url,
        'service', (select title from services where id = b.service_id),
        'duration', (select duration from services where id = b.service_id),
        'mentor', (select mu.first_name from mentors mm join users mu on mu.id = mm.user_id where mm.id = b.mentor_id),
        'mentee', coalesce(b.guest_email, (select email from users where id = b.user_id)),
        'mentee_tz', v_tz,
        'mentor_tz', (select coalesce(app_timezone,'UTC') from mentors where id = b.mentor_id)) from b),
    'payment', (select jsonb_build_object('amount', amount, 'currency', currency, 'status', status) from cp),
    'payout',  (select jsonb_build_object('amount', amount, 'currency', currency, 'status', status) from mp),
    'totals', jsonb_build_object(
        'paid', (select amount from cp), 'currency', (select currency from cp),
        'customer_refund',  (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='refund'),
        'customer_credit',  (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='credit'),
        'customer_charge',  (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='charge'),
        'customer_penalty', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='penalty'),
        'mentor_penalty',   (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='mentor' and kind='penalty'),
        'mentor_credit',    (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='mentor' and kind='credit')),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at',at,'actor',actor,'title',title,'detail',detail) order by at), '[]'::jsonb)
                 from ev where at is not null)
  ) into v_res;
  return v_res;
end $$;
