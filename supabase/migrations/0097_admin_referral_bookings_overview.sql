-- Admin-facing detail view for every referred booking (upcoming and settled),
-- so an admin can see in one place: who referred the customer, the discount
-- applied, the incentive (commission) owed to the affiliate, and the net
-- amount going to the mentor for that same session. Complements the
-- affiliate's own "upcoming referrals" (0095) with the admin-side equivalent
-- plus the full money breakdown.

create or replace function admin_referral_bookings_overview()
returns table (
  booking_id bigint,
  status text,
  slot_time timestamptz,
  customer_email text,
  affiliate_id bigint,
  affiliate_email text,
  referral_code text,
  discount_pct numeric,
  customer_paid numeric,
  customer_currency text,
  commission_amount_inr numeric,
  commission_status text,
  mentor_net_amount numeric,
  mentor_currency text
)
language sql stable security definer set search_path = public as $$
  select
    b.id, b.status, b.slot_time,
    coalesce(b.guest_email, u.email),
    aff.id, au.email,
    b.referral_code, b.referral_discount_applied_pct,
    cp.amount, cp.currency,
    cl.commission_amount_inr, cl.status,
    mp.net_amount_mentor_currency, mp.mentor_currency
  from bookings b
  left join users u on u.id = b.user_id
  left join commission_ledger cl on cl.booking_id = b.id
  left join referral_codes rc on rc.code_string = b.referral_code
  left join lateral (
    select affiliate_id from referral_click_events where session_token = b.referral_session_token limit 1
  ) rce on true
  left join affiliates aff on aff.id = coalesce(cl.affiliate_id, rc.affiliate_id, rce.affiliate_id)
  left join users au on au.id = aff.user_id
  left join lateral (
    select amount, currency from customer_payments where booking_id = b.id order by id desc limit 1
  ) cp on true
  left join lateral (
    select net_amount_mentor_currency, mentor_currency from mentor_payouts where booking_id = b.id order by id desc limit 1
  ) mp on true
  where b.referral_code is not null or b.referral_session_token is not null
  order by b.slot_time desc nulls last;
$$;
grant execute on function admin_referral_bookings_overview() to authenticated;
