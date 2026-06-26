-- Feature 1: admin filters (mentor email + target country) + Mentor Payout view.

-- Target immigration country, captured per booking (customer's destination goal).
alter table bookings add column if not exists target_country text;

-- Public list of countries for the booking selector (from the KB country docs).
create or replace function list_countries()
returns table(country_code text, country_name text)
language sql stable security definer set search_path = public as $$
  select country_code, country_name from country_docs
  where coalesce(is_published, true) and coalesce(nullif(trim(country_name),''),'') <> ''
  order by country_name;
$$;
grant execute on function list_countries() to anon, authenticated;

-- Booking creation now stores the target country (param added at the end; frontend passes it).
drop function if exists book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb,numeric);
create or replace function book_session_guest(
  p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz, p_mentee_currency text, p_mentee_cost numeric,
  p_email text, p_name text default null, p_timezone text default 'UTC', p_answers jsonb default '[]'::jsonb,
  p_ppp_factor numeric default 1.0, p_target_country text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_user_id bigint; v_set numeric; v_cur text; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
  v_f numeric := coalesce(p_ppp_factor, 1.0);
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;
  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then raise exception 'That time is not available — please choose another slot'; end if;
  select id into v_user_id from users where email = v_email;
  if v_user_id is null then insert into users(email, first_name, role, timezone) values (v_email, p_name, 'user', v_tz) returning id into v_user_id; end if;
  select s.set_price, coalesce(s.set_currency,'USD') into v_set, v_cur from services s where s.id = p_service_id and s.is_active;
  if v_set is null then raise exception 'Service not available'; end if;
  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email, target_country)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', v_tz, v_email, nullif(trim(coalesce(p_target_country,'')),''))
    returning id into v_booking;
  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), 'paid', 'mock_'||gen_random_uuid());
  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at)
    values (p_mentor_id, v_booking, round(v_set * v_f, 2), v_cur, 'pending', now());
  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text' from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';
  return v_booking;
end; $$;
grant execute on function book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb,numeric,text) to anon, authenticated;

-- Activity feed gains mentor_email + target_country so the admin can filter on them.
drop function if exists admin_bookings();
create or replace function admin_bookings()
returns table (
  id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentor_name text, mentor_email text, mentee_email text, target_country text,
  cost numeric, cost_currency text, mentor_payout numeric,
  reschedule_count int, no_show_by text, ledger_summary text
) language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time,
         s.title, mu.first_name, mu.email, coalesce(b.guest_email, cu.email), b.target_country,
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

-- Mentor Payout View: gross, platform fee %, deduction, net payout, payout status.
-- Fee resolves to the service's platform_fee, else platform_settings.immigroov_commission_pct, else 15.
create or replace function admin_payouts()
returns table (
  booking_id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentor_name text, mentee_email text,
  gross numeric, currency text, fee_pct numeric, deduction numeric, net_payout numeric, payout_status text
) language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time,
         s.title, mu.first_name, coalesce(b.guest_email, cu.email),
         cp.amount, cp.currency, fee.pct,
         round(coalesce(cp.amount,0) * fee.pct / 100.0, 2),
         round(coalesce(cp.amount,0) * (1 - fee.pct / 100.0), 2),
         coalesce(mp.status::text, 'pending')
  from bookings b
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join users cu on cu.id = b.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select status from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  cross join lateral (select coalesce(nullif(s.platform_fee,0),
                                      (select value::numeric from platform_settings where key='immigroov_commission_pct'),
                                      15)::numeric as pct) fee
  where b.status in ('confirmed','rescheduled','completed','no_show')
  order by b.created_at desc, b.id desc;
$$;
grant execute on function admin_payouts() to anon, authenticated;
