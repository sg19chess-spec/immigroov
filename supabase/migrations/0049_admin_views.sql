-- Admin read views: a cross-mentor activity feed + the full ledger.
-- Like the other demo_* RPCs these are SECURITY DEFINER and bypass auth — they MUST be
-- gated to an admin role before production.

-- Every booking across all mentors, newest first, with money + negotiation context.
create or replace function admin_bookings()
returns table (
  id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentor_name text, mentee_email text,
  cost numeric, cost_currency text, mentor_payout numeric,
  reschedule_count int, no_show_by text, ledger_summary text
) language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time,
         s.title, mu.first_name, coalesce(b.guest_email, cu.email),
         cp.amount, cp.currency, mp.amount,
         b.reschedule_count, b.no_show_by, lg.txt
  from bookings b
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join users cu on cu.id = b.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select amount from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  left join lateral (
    select string_agg(initcap(kind)||coalesce(' '||pct||'%','')
           ||case when amount is not null then ' ('||to_char(amount,'FM999990.00')||' '||currency||')' else '' end, ' · ' order by id) as txt
    from booking_ledger where booking_id=b.id) lg on true
  order by b.created_at desc, b.id desc;
$$;
grant execute on function admin_bookings() to anon, authenticated;

-- Every ledger entry (refund / credit / charge / penalty) with booking context, newest first.
create or replace function admin_ledger()
returns table (
  id bigint, created_at timestamptz, booking_id bigint, party text, kind text, pct int,
  amount numeric, currency text, reason text,
  service_title text, mentor_name text, mentee_email text, booking_status text
) language sql security definer set search_path = public as $$
  select l.id, l.created_at, l.booking_id, l.party, l.kind, l.pct, l.amount, l.currency, l.reason,
         s.title, mu.first_name, coalesce(b.guest_email, cu.email), b.status::text
  from booking_ledger l
  join bookings b on b.id = l.booking_id
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join users cu on cu.id = b.user_id
  order by l.id desc;
$$;
grant execute on function admin_ledger() to anon, authenticated;
