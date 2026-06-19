-- Demo email-identity: list bookings tied to an email (guest_email or user's email).
create or replace function bookings_by_email(p_email text)
returns table (
  id bigint, status text, slot_time timestamptz, meeting_url text,
  service_title text, mentor_name text, mentor_tz text, customer_tz text,
  cost numeric, cost_currency text, mentor_earn numeric, mentor_currency text
)
language sql security definer set search_path = public as $$
  select b.id, b.status::text, b.slot_time, b.meeting_url,
         s.title, mu.first_name, coalesce(mm.app_timezone,'UTC'),
         coalesce(b.customer_timezone, cu.timezone,'UTC'),
         cp.amount, cp.currency, mp.amount, coalesce(mm.currency,'USD')
  from bookings b
  join users cu on cu.id = b.user_id
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select amount from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  where lower(coalesce(b.guest_email, cu.email)) = lower(p_email)
  order by b.slot_time desc;
$$;
grant execute on function bookings_by_email(text) to anon, authenticated;
