-- Money model hardening (pre-Razorpay). Decisions:
--  • Platform fee is charged on the CUSTOMER GROSS; the mentor receives the remainder.
--  • Mentor absorbs the PPP discount (Option A) — we store ppp_multiplier for audit.
--  • Reporting currency = INR: every ledger row stores normalized_inr_amount at write time.
--  • mentor_payouts gains authoritative columns; legacy `amount` (= set_price×ppp) is still
--    written so existing readers keep working, but the new columns are the source of truth.

-- 1) Schema --------------------------------------------------------------------
alter table mentor_payouts
  add column if not exists gross_amount numeric,                    -- customer currency
  add column if not exists fee_pct numeric,
  add column if not exists platform_fee_amount numeric,             -- customer currency
  add column if not exists net_amount_customer_currency numeric,    -- customer currency (Razorpay payout basis if INR)
  add column if not exists net_amount_mentor_currency numeric,      -- mentor currency (informational)
  add column if not exists exchange_rate_used numeric,              -- customer units per 1 mentor unit
  add column if not exists customer_currency text,
  add column if not exists mentor_currency text,
  add column if not exists ppp_multiplier numeric;

alter table bookings
  add column if not exists fx_customer_inr numeric,                 -- INR per 1 customer-currency unit
  add column if not exists fx_mentor_inr numeric;                   -- INR per 1 mentor-currency unit

alter table booking_ledger
  add column if not exists normalized_inr_amount numeric;

-- 2) add_ledger: correct per-party currency + INR normalization ----------------
create or replace function add_ledger(p_booking bigint, p_party text, p_kind text, p_amount numeric, p_pct integer, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cust_ccy text; v_ment_ccy text; v_fxc numeric; v_fxm numeric; v_ccy text; v_fx numeric;
begin
  select coalesce(mp.customer_currency, cp.currency, 'INR'),
         coalesce(mp.mentor_currency, mp.currency, 'INR'),
         b.fx_customer_inr, b.fx_mentor_inr
    into v_cust_ccy, v_ment_ccy, v_fxc, v_fxm
  from bookings b
  left join lateral (select customer_currency, mentor_currency, currency from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  left join lateral (select currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  where b.id = p_booking;

  if p_party = 'mentor' then v_ccy := v_ment_ccy; v_fx := coalesce(v_fxm, 1);
  else                       v_ccy := v_cust_ccy; v_fx := coalesce(v_fxc, 1); end if;

  insert into booking_ledger(booking_id, party, kind, amount, pct, currency, reason, normalized_inr_amount)
    values (p_booking, p_party, p_kind, round(coalesce(p_amount,0),2), p_pct, v_ccy, p_reason,
            round(coalesce(p_amount,0) * v_fx, 2));
end; $$;

-- 3) book_session_guest: store all authoritative payout numbers ----------------
drop function if exists book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb,numeric,text,text);
create or replace function book_session_guest(
  p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz, p_mentee_currency text, p_mentee_cost numeric,
  p_email text, p_name text default null, p_timezone text default 'UTC', p_answers jsonb default '[]'::jsonb,
  p_ppp_factor numeric default 1.0, p_target_country text default null, p_customer_country text default null,
  p_fx_mentor_customer numeric default null, p_fx_customer_inr numeric default null, p_fx_mentor_inr numeric default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_user_id bigint; v_set numeric; v_cur text; v_fee_pct numeric; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
  v_f numeric := coalesce(p_ppp_factor, 1.0);
  v_gross numeric; v_fee numeric; v_net_cust numeric; v_net_mentor numeric; v_rate numeric;
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;
  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then raise exception 'That time is not available — please choose another slot'; end if;
  select id into v_user_id from users where email = v_email;
  if v_user_id is null then insert into users(email, first_name, role, timezone) values (v_email, p_name, 'user', v_tz) returning id into v_user_id; end if;
  select s.set_price, coalesce(s.set_currency,'USD'),
         coalesce(nullif(s.platform_fee,0), (select value::numeric from platform_settings where key='immigroov_commission_pct'), 15)
    into v_set, v_cur, v_fee_pct
  from services s where s.id = p_service_id and s.is_active;
  if v_set is null then raise exception 'Service not available'; end if;

  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email, target_country, customer_country, fx_customer_inr, fx_mentor_inr)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', v_tz, v_email,
            nullif(trim(coalesce(p_target_country,'')),''), nullif(trim(coalesce(p_customer_country,'')),''),
            nullif(p_fx_customer_inr,0), nullif(p_fx_mentor_inr,0))
    returning id into v_booking;

  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), 'paid', 'mock_'||gen_random_uuid());

  v_gross := round(p_mentee_cost, 2);
  v_fee   := round(v_gross * v_fee_pct / 100.0, 2);
  v_net_cust := round(v_gross - v_fee, 2);
  v_rate  := nullif(p_fx_mentor_customer, 0);
  v_net_mentor := case when v_rate is not null then round(v_net_cust / v_rate, 2) else null end;

  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at,
      gross_amount, fee_pct, platform_fee_amount, net_amount_customer_currency, net_amount_mentor_currency,
      exchange_rate_used, customer_currency, mentor_currency, ppp_multiplier)
    values (p_mentor_id, v_booking, round(v_set * v_f, 2), v_cur, 'pending', now(),
      v_gross, v_fee_pct, v_fee, v_net_cust, v_net_mentor, v_rate, upper(p_mentee_currency), v_cur, v_f);

  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text' from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';
  return v_booking;
end; $$;
grant execute on function book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb,numeric,text,text,numeric,numeric,numeric) to anon, authenticated;

-- 4) admin_payouts: read the stored authoritative numbers (fallback for legacy) -
create or replace function admin_payouts()
returns table(booking_id bigint, created_at timestamptz, status text, slot_time timestamptz,
  service_title text, mentor_name text, mentee_email text, gross numeric, currency text,
  fee_pct numeric, deduction numeric, net_payout numeric, payout_status text)
language sql security definer set search_path = public as $$
  select b.id, b.created_at, b.status::text, b.slot_time, s.title, mu.first_name, coalesce(b.guest_email, cu.email),
         coalesce(mp.gross_amount, cp.amount),
         coalesce(mp.customer_currency, cp.currency),
         coalesce(mp.fee_pct, fee.pct),
         coalesce(mp.platform_fee_amount, round(coalesce(cp.amount,0) * fee.pct / 100.0, 2)),
         coalesce(mp.net_amount_customer_currency, round(coalesce(cp.amount,0) * (1 - fee.pct / 100.0), 2)),
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

-- 5) admin_ledger: expose normalized INR so the admin can total in one currency -
drop function if exists admin_ledger();
create or replace function admin_ledger()
returns table (
  id bigint, created_at timestamptz, booking_id bigint, party text, kind text, pct int,
  amount numeric, currency text, normalized_inr numeric, reason text,
  service_title text, mentor_name text, mentee_email text, booking_status text
) language sql security definer set search_path = public as $$
  select l.id, l.created_at, l.booking_id, l.party, l.kind, l.pct, l.amount, l.currency, l.normalized_inr_amount, l.reason,
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

-- 6) Backfill existing bookings (best-effort; INR customers exact, others approximate) -
update mentor_payouts mp set
  customer_currency = coalesce(mp.customer_currency, cp.currency),
  mentor_currency   = coalesce(mp.mentor_currency, mp.currency),
  gross_amount      = coalesce(mp.gross_amount, cp.amount),
  fee_pct           = coalesce(mp.fee_pct, fb.pct),
  platform_fee_amount = coalesce(mp.platform_fee_amount, round(cp.amount * fb.pct/100.0, 2)),
  net_amount_customer_currency = coalesce(mp.net_amount_customer_currency, round(cp.amount * (1 - fb.pct/100.0), 2)),
  exchange_rate_used = coalesce(mp.exchange_rate_used, case when mp.amount > 0 then round(cp.amount / mp.amount, 6) else null end),
  net_amount_mentor_currency = coalesce(mp.net_amount_mentor_currency,
      case when mp.amount > 0 then round(round(cp.amount * (1 - fb.pct/100.0), 2) / (cp.amount / mp.amount), 2) else null end)
from bookings b
join services s on s.id = b.service_id
left join lateral (select amount, currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
cross join lateral (select coalesce(nullif(s.platform_fee,0), (select value::numeric from platform_settings where key='immigroov_commission_pct'), 15)::numeric as pct) fb
where mp.booking_id = b.id and mp.net_amount_customer_currency is null and cp.amount is not null;

-- For INR-customer bookings, fx_customer_inr=1 and fx_mentor_inr equals the booking's rate.
update bookings b set
  fx_customer_inr = coalesce(b.fx_customer_inr, case when upper(mp.customer_currency)='INR' then 1 else null end),
  fx_mentor_inr   = coalesce(b.fx_mentor_inr, case when upper(mp.customer_currency)='INR' then mp.exchange_rate_used else null end)
from mentor_payouts mp
where mp.booking_id = b.id and (b.fx_customer_inr is null or b.fx_mentor_inr is null);
