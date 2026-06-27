-- Admin-editable platform settings + mentor Earnings data + enriched admin payouts.

create or replace function admin_get_settings()
returns table(commission_pct numeric, ppp_floor numeric, default_currency text, test_redirect text)
language sql security definer set search_path = public as $$
  select (select value::numeric from platform_settings where key='immigroov_commission_pct'),
         (select value::numeric from platform_settings where key='ppp_floor'),
         (select value from platform_settings where key='default_currency'),
         (select value from platform_settings where key='test_redirect_email');
$$;
grant execute on function admin_get_settings() to anon, authenticated;

create or replace function admin_set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_key not in ('immigroov_commission_pct','ppp_floor','default_currency','test_redirect_email') then
    raise exception 'Setting % is not editable here', p_key;
  end if;
  update platform_settings set value = p_value where key = p_key;
  if not found then insert into platform_settings(key, value) values (p_key, p_value); end if;
end; $$;
grant execute on function admin_set_setting(text,text) to anon, authenticated;

drop function if exists admin_payouts();
create or replace function admin_payouts()
returns table(booking_id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentor_name text, mentee_email text, gross numeric, currency text,
  fee_pct numeric, deduction numeric, net_payout numeric,
  mentor_net numeric, mentor_currency text, fx_rate numeric, ppp numeric, payout_status text)
language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time, s.title, mu.first_name, coalesce(b.guest_email, cu.email),
         coalesce(mp.gross_amount, cp.amount),
         coalesce(mp.customer_currency, cp.currency),
         coalesce(mp.fee_pct, fee.pct),
         coalesce(mp.platform_fee_amount, round(coalesce(cp.amount,0) * fee.pct / 100.0, 2)),
         coalesce(mp.net_amount_customer_currency, round(coalesce(cp.amount,0) * (1 - fee.pct / 100.0), 2)),
         mp.net_amount_mentor_currency, mp.mentor_currency, mp.exchange_rate_used, mp.ppp_multiplier,
         coalesce(mp.status::text, 'pending')
  from bookings b
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join users cu on cu.id = b.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select * from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  cross join lateral (select coalesce(nullif(s.platform_fee,0), (select value::numeric from platform_settings where key='immigroov_commission_pct'), 15)::numeric as pct) fee
  where b.status in ('confirmed','rescheduled','completed','no_show')
  order by b.created_at desc, b.id desc;
$$;
grant execute on function admin_payouts() to anon, authenticated;

create or replace function mentor_earnings(p_mentor_id bigint)
returns table(
  booking_id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentee_name text,
  gross_amount numeric, customer_currency text, fee_pct numeric, platform_fee_amount numeric,
  net_amount_customer_currency numeric, net_amount_mentor_currency numeric, mentor_currency text,
  exchange_rate_used numeric, ppp_multiplier numeric,
  net_inr numeric, penalty_inr numeric, payout_status text)
language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time, s.title,
         coalesce(nullif(cu.first_name,''), b.guest_email, cu.email),
         mp.gross_amount, mp.customer_currency, mp.fee_pct, mp.platform_fee_amount,
         mp.net_amount_customer_currency, mp.net_amount_mentor_currency, mp.mentor_currency,
         mp.exchange_rate_used, mp.ppp_multiplier,
         round(coalesce(mp.net_amount_customer_currency,0) * coalesce(b.fx_customer_inr,1), 2),
         coalesce((select sum(normalized_inr_amount) from booking_ledger where booking_id=b.id and party='mentor' and kind='penalty'),0),
         coalesce(mp.status::text,'pending')
  from bookings b
  join services s on s.id = b.service_id
  join users cu on cu.id = b.user_id
  left join lateral (select * from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  where b.mentor_id = p_mentor_id and b.status in ('confirmed','rescheduled','completed','no_show')
  order by b.created_at desc, b.id desc;
$$;
grant execute on function mentor_earnings(bigint) to anon, authenticated;
