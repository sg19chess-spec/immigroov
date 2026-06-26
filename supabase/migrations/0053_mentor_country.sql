-- Country is a mentor attribute (the destination they advise on); booking a mentor
-- implies it, so the customer is no longer asked. admin_bookings derives the country
-- from the mentor (falling back to any explicit bookings.target_country if ever set).
alter table mentors add column if not exists country text;

create or replace function demo_get_mentor_country(p_mentor_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select country from mentors where id = p_mentor_id;
$$;
grant execute on function demo_get_mentor_country(bigint) to anon, authenticated;

create or replace function demo_set_mentor_country(p_mentor_id bigint, p_country text)
returns void language sql security definer set search_path = public as $$
  update mentors set country = nullif(trim(coalesce(p_country,'')),'') where id = p_mentor_id;
$$;
grant execute on function demo_set_mentor_country(bigint, text) to anon, authenticated;

-- Activity feed: country now comes from the mentor.
drop function if exists admin_bookings();
create or replace function admin_bookings()
returns table (
  id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentor_name text, mentor_email text, mentee_email text, target_country text,
  cost numeric, cost_currency text, mentor_payout numeric,
  reschedule_count int, no_show_by text, ledger_summary text
) language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time,
         s.title, mu.first_name, mu.email, coalesce(b.guest_email, cu.email),
         coalesce(b.target_country, mm.country),
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
