-- 0077 — admin_booking_detail: make the first timeline event payment-aware.
-- Post-Razorpay, bookings start 'pending' (unpaid) and only become 'paid' on the
-- capture webhook. The old hardcoded "Booking created & paid / Paid X" label was
-- misleading for pending/failed bookings. Now it reflects customer_payments.status.
create or replace function admin_booking_detail(p_booking_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_tz text; v_res jsonb;
begin
  select coalesce(b.customer_timezone, cu.timezone, 'UTC') into v_tz
  from bookings b join users cu on cu.id = b.user_id where b.id = p_booking_id;
  if not found then return null; end if;

  with b as (select * from bookings where id = p_booking_id),
  cp as (select amount, currency, status from customer_payments where booking_id = p_booking_id order by id desc limit 1),
  mp as (select * from mentor_payouts where booking_id = p_booking_id order by id desc limit 1),
  fee as (
    select coalesce((select mp.fee_pct from mp),
      case when s.set_price > 0 and nullif(s.platform_fee,0) is not null then round(s.platform_fee / s.set_price * 100.0, 4) end,
      (select value::numeric from platform_settings where key='immigroov_commission_pct'), 15) as pct
    from b join services s on s.id = b.service_id
  ),
  ev as (
    select b.created_at as at, 'customer'::text as actor,
           case when (select status from cp)='paid' then 'Booking created & paid'
                when (select status from cp)='refunded' then 'Booking created (later refunded)'
                else 'Booking created — awaiting payment' end as title,
           (select case when status='paid' then 'Paid '||to_char(amount,'FM999990.00')||' '||currency
                        when status='failed' then 'Payment not completed ('||to_char(amount,'FM999990.00')||' '||currency||')'
                        else 'Reserved '||to_char(amount,'FM999990.00')||' '||currency||' — awaiting payment' end from cp)::text as detail
    from b
    union all
    select b.mentor_confirmed_at, 'mentor', 'Mentor confirmed availability', null::text from b where b.mentor_confirmed_at is not null
    union all
    select r.created_at, case when r.initiated_by='user' then 'customer' else r.initiated_by end, initcap(r.kind)||' requested', r.note
      from booking_requests r where r.booking_id = p_booking_id
    union all
    select r.resolved_at, case when r.initiated_by='user' then 'customer' else r.initiated_by end, initcap(r.kind)||' request '||r.status,
           case when r.status in ('auto_approved') then 'No response in time — auto-approved' else null end
      from booking_requests r where r.booking_id = p_booking_id and r.resolved_at is not null
    union all
    select o.created_at, case when o.proposed_by='mentor' then 'mentor' else 'customer' end,
           case when o.proposed_by='mentor' then 'Mentor proposed a new time window'
                when o.requested_date is not null then 'Customer asked for a different date' else 'Reschedule offer' end,
           (case when o.proposed_by='mentor'
                 then to_char(o.offer_date,'FMDay, FMMon DD')||': '||to_char(o.range_start at time zone v_tz,'HH12:MI AM')||' – '||to_char(o.range_end at time zone v_tz,'HH12:MI AM')||' ('||v_tz||') · status: '||o.status||case when o.was_late then ' · past-deadline' else '' end||case when o.selected_time is not null then ' · picked '||to_char(o.selected_time at time zone v_tz,'FMMon DD HH12:MI AM') else '' end
                 when o.requested_date is not null then to_char(o.requested_date,'FMDay, FMMon DD')||' · status: '||o.status
                 else 'status: '||o.status end)::text
      from reschedule_offers o where o.booking_id = p_booking_id
    union all
    select l.created_at, l.party, initcap(l.kind)||' '||coalesce(l.pct::text||'%','')||case when l.amount is not null then ' — '||to_char(l.amount,'FM999990.00')||' '||l.currency else '' end, l.reason
      from booking_ledger l where l.booking_id = p_booking_id
  )
  select jsonb_build_object(
    'booking', (select jsonb_build_object('id', b.id, 'status', b.status, 'created_at', b.created_at, 'slot_time', b.slot_time, 'slot_end', b.slot_end,
        'reschedule_count', b.reschedule_count, 'no_show_by', b.no_show_by, 'mentor_confirmed_at', b.mentor_confirmed_at, 'meeting_url', b.meeting_url,
        'service', (select title from services where id = b.service_id), 'duration', (select duration from services where id = b.service_id),
        'mentor', (select mu.first_name from mentors mm join users mu on mu.id = mm.user_id where mm.id = b.mentor_id),
        'mentee', coalesce(b.guest_email, (select email from users where id = b.user_id)), 'mentee_tz', v_tz,
        'mentor_tz', (select coalesce(app_timezone,'UTC') from mentors where id = b.mentor_id)) from b),
    'payment', (select jsonb_build_object('amount', amount, 'currency', currency, 'status', status) from cp),
    'payout',  (select jsonb_build_object('amount', coalesce((select net_amount_mentor_currency from mp), amount), 'currency', coalesce((select mentor_currency from mp), currency), 'status', status) from mp),
    'totals', jsonb_build_object('paid', (select amount from cp), 'currency', (select currency from cp), 'fee_pct', (select pct from fee),
        'platform_take', coalesce((select platform_fee_amount from mp), round((select amount from cp) * (select pct from fee) / 100.0, 2)),
        'net_to_mentor', coalesce((select net_amount_mentor_currency from mp), (select amount from mp)),
        'mentor_currency', coalesce((select mentor_currency from mp), (select currency from mp)), 'ppp_multiplier', (select ppp_multiplier from mp),
        'customer_refund', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='refund'),
        'customer_credit', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='credit'),
        'customer_charge', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='charge'),
        'customer_penalty', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='penalty'),
        'mentor_penalty', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='mentor' and kind='penalty'),
        'mentor_credit', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='mentor' and kind='credit')),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at',at,'actor',actor,'title',title,'detail',detail) order by at), '[]'::jsonb) from ev where at is not null)
  ) into v_res;
  return v_res;
end $$;
grant execute on function admin_booking_detail(bigint) to anon, authenticated;
