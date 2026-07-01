-- 0074 — admin_payouts: restore the mentor-currency/FX/PPP columns that 0066
-- inadvertently dropped, and surface payout method + canonical payout_state.
-- Keeps the 0066 fee_pct fix (services.platform_fee is an ABSOLUTE amount, so
-- fee% is derived as platform_fee/set_price*100, falling back to the global pct).
drop function if exists admin_payouts();

create function admin_payouts()
returns table(booking_id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentor_name text, mentee_email text, gross numeric, currency text,
  fee_pct numeric, deduction numeric, net_payout numeric,
  mentor_net numeric, mentor_currency text, fx_rate numeric, ppp numeric,
  method text, payout_status text)
language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time, s.title, mu.first_name, coalesce(b.guest_email, cu.email),
         coalesce(mp.gross_amount, cp.amount),
         coalesce(mp.customer_currency, cp.currency),
         coalesce(mp.fee_pct, fee.pct),
         coalesce(mp.platform_fee_amount, round(coalesce(cp.amount,0) * fee.pct / 100.0, 2)),
         coalesce(mp.net_amount_customer_currency, round(coalesce(cp.amount,0) * (1 - fee.pct / 100.0), 2)),
         mp.net_amount_mentor_currency, mp.mentor_currency, mp.exchange_rate_used, mp.ppp_multiplier,
         coalesce(mp.method, case when upper(coalesce(mp.mentor_currency, cp.currency))='INR' then 'auto_inr' else 'manual' end),
         coalesce(mp.payout_state, mp.status::text, 'pending')
  from bookings b
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join users cu on cu.id = b.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select * from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  cross join lateral (select coalesce(
      case when s.set_price > 0 and nullif(s.platform_fee,0) is not null
           then round(s.platform_fee / s.set_price * 100.0, 4) end,
      (select value::numeric from platform_settings where key='immigroov_commission_pct'),
      15)::numeric as pct) fee
  where b.status in ('confirmed','rescheduled','completed','no_show')
  order by b.created_at desc, b.id desc;
$$;
grant execute on function admin_payouts() to anon, authenticated;
