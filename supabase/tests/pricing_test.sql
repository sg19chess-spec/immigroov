-- =============================================================================
-- pgTAP regression tests for the server-side pricing engine (migration 0065).
-- Run with:  supabase test db        (or psql -f against a DB with pgtap)
--
-- Covers the financial matrix: currency pairs, PPP on/off + floor, platform fee,
-- the rate-DIRECTION guard (net_mentor must DIVIDE by fx_mentor_customer),
-- binding-quote one-time-use / expiry, and FX missing/stale -> FX_UNAVAILABLE.
-- Everything runs in one transaction and is rolled back by finish().
-- =============================================================================
begin;
select plan(20);

-- pgTAP must be available.
create extension if not exists pgtap with schema extensions;

-- --- Fixtures ----------------------------------------------------------------
-- Fresh FX (EUR pivot): EUR->USD=1.08, EUR->INR=90  =>  USD->INR = 90/1.08 ≈ 83.3333
insert into fx_rates(base, quote, rate, as_of, fetched_at) values
  ('EUR','USD',1.08,current_date, now()),
  ('EUR','INR',90.0,current_date, now())
on conflict (base,quote) do update set rate=excluded.rate, fetched_at=excluded.fetched_at;

-- Commission = 15%, PPP floor = 0.40 (0023). Ensure both present.
insert into platform_settings(key,value,description) values ('immigroov_commission_pct','15','test')
  on conflict (key) do update set value='15';
insert into platform_settings(key,value,description) values ('ppp_floor','0.40','test')
  on conflict (key) do update set value='0.40';

-- A mentor + two services (USD PPP, INR non-PPP).
insert into users(id, email, role, timezone) values (900001,'mentor-pricing-test@x.local','mentor','UTC')
  on conflict (id) do nothing;
insert into mentors(id, user_id, is_available, avg_rating, review_count, cancel_notice_hours, no_show_strikes)
  values (900001, 900001, true, 0, 0, 24, 0) on conflict (id) do nothing;
insert into services(id, mentor_id, title, type, duration, is_ppp, is_active, set_price, set_currency)
  values (900001, 900001, 'USD PPP svc', 'video', 60, true,  true, 100,  'USD') on conflict (id) do nothing;
insert into services(id, mentor_id, title, type, duration, is_ppp, is_active, set_price, set_currency)
  values (900002, 900001, 'INR flat svc','video', 60, false, true, 5000, 'INR') on conflict (id) do nothing;

-- --- Helpers / PPP + currency ------------------------------------------------
select is( get_ppp_factor('IN'), 0.40, 'India PPP is floored to 0.40 (seeded 0.30 is dominated)');
select is( get_ppp_factor('US'), 1.00, 'US PPP factor is 1.00 (no discount)');
select is( currency_for_country('IN'), 'INR', 'IN -> INR');
select is( currency_for_country('ZZ'), 'USD', 'unknown country -> USD fallback');

-- --- FX cross-rate -----------------------------------------------------------
select is( get_fx('USD','USD'), 1::numeric, 'same-currency FX is 1');
select ok( abs(get_fx('USD','INR') - 83.3333) < 0.01, 'USD->INR cross-rate ≈ 83.33 via EUR pivot');

-- --- Engine: USD mentor -> IN customer (PPP on) ------------------------------
select is( (compute_booking_price(900001,'IN')->>'ppp_multiplier')::numeric, 0.40, 'USD/IN: PPP 0.40 applied');
select is( (compute_booking_price(900001,'IN')->>'gross_customer')::numeric, 3333.33, 'USD/IN: gross = 100*0.40*83.3333');
select is( (compute_booking_price(900001,'IN')->>'fee_amount')::numeric, 500.00, 'USD/IN: 15% fee on gross');
select is( (compute_booking_price(900001,'IN')->>'net_customer')::numeric, 2833.33, 'USD/IN: net customer = gross - fee');
-- RATE-DIRECTION GUARD: net_mentor = net_customer / fx_mentor_customer ≈ 100*0.40*0.85 = 34.
-- A '*' instead of '/' here would yield ~236k and fail loudly.
select ok( (compute_booking_price(900001,'IN')->>'net_mentor')::numeric between 33.9 and 34.1,
           'USD/IN: net_mentor DIVIDES by fx (≈34, not multiplied)');

-- --- Engine: USD mentor -> US customer (PPP=1, FX=1) -------------------------
select is( (compute_booking_price(900001,'US')->>'gross_customer')::numeric, 100.00, 'USD/US: gross = set_price (no PPP, no FX)');

-- --- Engine: INR mentor -> IN customer (flat, no PPP) ------------------------
select is( (compute_booking_price(900002,'IN')->>'gross_customer')::numeric, 5000.00, 'INR/IN: gross = set_price');
select is( (compute_booking_price(900002,'IN')->>'net_mentor')::numeric, 4250.00, 'INR/IN: mentor nets 85% (fx=1)');

-- --- Quote issuance ----------------------------------------------------------
select ok( (get_booking_quote(900001,'IN')->>'quote_id') is not null, 'get_booking_quote returns a quote_id');
select ok( (get_booking_quote(900001,'IN')->>'pricing_hash') ~ '^[0-9a-f]{64}$', 'pricing_hash is a SHA-256 hex digest');

-- --- Binding-quote guards: one-time use + expiry -----------------------------
insert into pricing_quotes(id, service_id, mentor_id, customer_country, customer_currency,
    pricing_version, ppp_version, fx_provider, snapshot, pricing_hash, used, expires_at)
  values ('11111111-1111-1111-1111-111111111111', 900001, 900001, 'IN','INR',1,1,'frankfurter',
    '{}'::jsonb,'x', true, now()+interval '5 min');         -- already used
insert into pricing_quotes(id, service_id, mentor_id, customer_country, customer_currency,
    pricing_version, ppp_version, fx_provider, snapshot, pricing_hash, used, expires_at)
  values ('22222222-2222-2222-2222-222222222222', 900001, 900001, 'IN','INR',1,1,'frankfurter',
    '{}'::jsonb,'x', false, now()-interval '1 min');        -- expired

select throws_like(
  $$ select book_session_guest('11111111-1111-1111-1111-111111111111'::uuid, 900001, 900001, now()+interval '2 days', 'buyer@x.local') $$,
  '%QUOTE_EXPIRED%', 'reusing a used quote is rejected');
select throws_like(
  $$ select book_session_guest('22222222-2222-2222-2222-222222222222'::uuid, 900001, 900001, now()+interval '2 days', 'buyer@x.local') $$,
  '%QUOTE_EXPIRED%', 'an expired quote is rejected');

-- --- FX unavailable / stale --> hard failure (never rate=1) -------------------
select is( get_fx_or_null('USD','ZZZ'), null, 'missing FX pair -> NULL (no fallback)');
update fx_rates set fetched_at = now() - interval '2 days';  -- age all rates past 24h
select throws_like( $$ select get_fx('USD','INR') $$, '%FX_UNAVAILABLE%', 'stale FX (>24h) raises FX_UNAVAILABLE');

select * from finish();
rollback;
