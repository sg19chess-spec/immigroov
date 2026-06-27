-- =============================================================================
-- 0065 — Server-side pricing engine (PPP + FX hardening, pre-Razorpay).
--
-- Before this migration ALL money math (PPP discount, FX conversion, platform
-- fee) ran in the browser and the final price + PPP factor + FX rates were
-- passed into book_session_guest, which trusted them. This migration moves the
-- entire pricing engine server-side:
--   • FX rates live in fx_rates (refreshed by the `fx-refresh` Edge Function).
--   • get_fx() RAISES `FX_UNAVAILABLE` if a rate is missing or older than 24h —
--     never silently falls back to 1 (which would corrupt the INR ledger).
--   • compute_booking_price() is THE single engine. Versioned (pricing_version,
--     ppp_version, fx_provider) so historical bookings never recompute.
--   • get_booking_quote() issues a 10-minute BINDING quote (pricing_quotes).
--   • book_session_guest() now takes only a quote_id (+ identity/slot) and
--     commits the stored snapshot verbatim — it accepts no money/FX/PPP inputs.
--   • Every booking freezes a full snapshot into booking_pricing (immutable).
--   • The stale book_session() RPC (no fee/PPP/FX) is dropped.
-- =============================================================================

-- 1) Tables --------------------------------------------------------------------

-- Live FX rates, pivot model (one Frankfurter call: base=EUR -> all quotes).
create table if not exists fx_rates (
  base       text not null,            -- always 'EUR'
  quote      text not null,            -- ISO currency code
  rate       numeric not null,         -- quote units per 1 base unit
  as_of      date,                     -- provider's published date
  fetched_at timestamptz not null default now(),
  primary key (base, quote)
);

-- Audit log of every fx-refresh run (keeps the raw provider payload).
create table if not exists fx_refresh_log (
  id         bigserial primary key,
  provider   text default 'frankfurter',
  as_of      date,
  raw_json   jsonb,
  success    boolean,
  error      text,
  created_at timestamptz not null default now()
);

-- Binding price quotes. A quote is a 10-minute offer; booking commits it verbatim.
create table if not exists pricing_quotes (
  id                uuid primary key default gen_random_uuid(),
  service_id        bigint not null,
  mentor_id         bigint not null,
  customer_country  text,
  customer_currency text,
  pricing_version   int,
  ppp_version       int,
  fx_provider       text,
  snapshot          jsonb not null,    -- full BookingPrice record (the contract)
  pricing_hash      text not null,     -- SHA-256 of canonical snapshot JSON
  used              boolean not null default false,
  booking_id        bigint,
  created_at        timestamptz not null default now(),
  expires_at        timestamptz not null default now() + interval '10 minutes'
);
create index if not exists pricing_quotes_expires_idx on pricing_quotes(expires_at);

-- Immutable per-booking pricing snapshot (1:1 with bookings).
create table if not exists booking_pricing (
  booking_id         bigint primary key references bookings(id) on delete cascade,
  pricing_version    int not null,
  ppp_version        int,
  fx_provider        text,
  mentor_currency    text,
  customer_currency  text,
  set_price          numeric,
  ppp_multiplier     numeric,
  fx_mentor_customer numeric,
  fx_customer_inr    numeric,
  fx_mentor_inr      numeric,
  gross_customer     numeric,
  fee_pct            numeric,
  fee_amount         numeric,
  net_customer       numeric,
  net_mentor         numeric,
  calculated_at      timestamptz not null default now()
);

-- Customer currency frozen on the booking (so a later country->ccy map change
-- can never mutate an existing booking).
alter table bookings add column if not exists customer_currency text;

-- 2) FX helpers ----------------------------------------------------------------

-- Cross-rate via the EUR pivot. Returns NULL if either leg is missing or older
-- than fx_max_age_minutes (default 1440 = 24h). No silent fallback to 1.
create or replace function get_fx_or_null(p_from text, p_to text)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare
  v_from text := upper(coalesce(p_from,'')); v_to text := upper(coalesce(p_to,''));
  v_max int := coalesce((select value::numeric from platform_settings where key='fx_max_age_minutes'), 1440);
  r_from numeric; r_to numeric; f_from timestamptz; f_to timestamptz;
begin
  if v_from = '' or v_to = '' then return null; end if;
  if v_from = v_to then return 1; end if;

  if v_from = 'EUR' then r_from := 1; f_from := now();
  else select rate, fetched_at into r_from, f_from from fx_rates where base='EUR' and quote=v_from; end if;

  if v_to = 'EUR' then r_to := 1; f_to := now();
  else select rate, fetched_at into r_to, f_to from fx_rates where base='EUR' and quote=v_to; end if;

  if r_from is null or r_to is null then return null; end if;                 -- missing
  if least(f_from, f_to) < now() - make_interval(mins => v_max) then return null; end if; -- stale
  return r_to / r_from;
end; $$;
grant execute on function get_fx_or_null(text, text) to anon, authenticated;

-- Strict variant used by the booking engine: aborts rather than mis-price.
create or replace function get_fx(p_from text, p_to text)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare v numeric := get_fx_or_null(p_from, p_to);
begin
  if v is null then
    raise exception 'FX_UNAVAILABLE: no fresh exchange rate for %->%', upper(p_from), upper(p_to)
      using errcode = 'P0001';
  end if;
  return v;
end; $$;
grant execute on function get_fx(text, text) to anon, authenticated;

-- Country -> display currency (server-side port of COUNTRY_CCY in web/lib/format.ts).
-- Only currencies Frankfurter supports; anything else falls back to USD.
create or replace function currency_for_country(p_cc text)
returns text language sql immutable set search_path = public as $$
  select coalesce(
    (case upper(coalesce(p_cc,''))
      when 'US' then 'USD' when 'GB' then 'GBP' when 'IN' then 'INR'
      when 'DE' then 'EUR' when 'FR' then 'EUR' when 'NL' then 'EUR' when 'IE' then 'EUR'
      when 'ES' then 'EUR' when 'IT' then 'EUR' when 'PT' then 'EUR'
      when 'CA' then 'CAD' when 'AU' then 'AUD' when 'NZ' then 'NZD' when 'SG' then 'SGD'
      when 'HK' then 'HKD' when 'JP' then 'JPY' when 'KR' then 'KRW' when 'CN' then 'CNY'
      when 'MX' then 'MXN' when 'BR' then 'BRL' when 'ZA' then 'ZAR' when 'CH' then 'CHF'
      when 'SE' then 'SEK' when 'NO' then 'NOK' when 'DK' then 'DKK' when 'PL' then 'PLN'
      when 'RO' then 'RON' when 'CZ' then 'CZK' when 'HU' then 'HUF' when 'BG' then 'BGN'
      when 'IL' then 'ILS' when 'ID' then 'IDR' when 'PH' then 'PHP' when 'MY' then 'MYR'
      when 'TH' then 'THB' when 'TR' then 'TRY'
      else null end), 'USD');
$$;
grant execute on function currency_for_country(text) to anon, authenticated;

-- 3) The single pricing engine -------------------------------------------------
-- Returns the canonical BookingPrice as jsonb. Raises FX_UNAVAILABLE if rates
-- are missing/stale. ppp_floor (0.40) intentionally governs IN/PK/NP/EG/etc via
-- get_ppp_factor — the seeded 0.30 IN row is dominated by the floor (by design).
create or replace function compute_booking_price(p_service_id bigint, p_customer_country text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_pricing_version constant int := 1;
  v_ppp_version     constant int := 1;
  v_provider        constant text := 'frankfurter';
  v_mentor_id bigint; v_set numeric; v_ment_ccy text; v_is_ppp boolean; v_fee_pct numeric;
  v_cust_ccy text; v_ppp numeric;
  v_fx_mc numeric; v_fx_c_inr numeric; v_fx_m_inr numeric;
  v_gross numeric; v_fee numeric; v_net_cust numeric; v_net_mentor numeric;
begin
  -- NOTE: services.platform_fee is an ABSOLUTE commission amount in the mentor's
  -- currency (e.g. set_price 2500 -> platform_fee 375 = 15%), NOT a percentage.
  -- We convert it to a percentage of set_price so the fee applies correctly to the
  -- PPP-adjusted, FX-converted customer gross. Falls back to the admin global pct.
  select s.mentor_id, s.set_price, coalesce(s.set_currency,'USD'), s.is_ppp,
         coalesce(
           case when s.set_price > 0 and nullif(s.platform_fee,0) is not null
                then round(s.platform_fee / s.set_price * 100.0, 4) end,
           (select value::numeric from platform_settings where key='immigroov_commission_pct'),
           15)
    into v_mentor_id, v_set, v_ment_ccy, v_is_ppp, v_fee_pct
  from services s where s.id = p_service_id and s.is_active;
  if v_set is null then raise exception 'Service not available' using errcode='P0001'; end if;

  v_cust_ccy := currency_for_country(p_customer_country);
  v_ppp := case when v_is_ppp then get_ppp_factor(p_customer_country) else 1 end;

  v_fx_mc    := get_fx(v_ment_ccy, v_cust_ccy);   -- customer units per 1 mentor unit
  v_fx_c_inr := get_fx(v_cust_ccy, 'INR');
  v_fx_m_inr := get_fx(v_ment_ccy, 'INR');

  v_gross     := round(v_set * v_ppp * v_fx_mc, 2);
  v_fee       := round(v_gross * v_fee_pct / 100.0, 2);
  v_net_cust  := round(v_gross - v_fee, 2);
  v_net_mentor:= round(v_net_cust / v_fx_mc, 2);  -- divide: customer-net -> mentor currency

  return jsonb_build_object(
    'pricing_version', v_pricing_version, 'ppp_version', v_ppp_version, 'fx_provider', v_provider,
    'service_id', p_service_id, 'mentor_id', v_mentor_id, 'customer_country', upper(coalesce(p_customer_country,'')),
    'mentor_currency', v_ment_ccy, 'customer_currency', v_cust_ccy,
    'set_price', v_set, 'ppp_multiplier', v_ppp,
    'fx_mentor_customer', v_fx_mc, 'fx_customer_inr', v_fx_c_inr, 'fx_mentor_inr', v_fx_m_inr,
    'gross_customer', v_gross, 'fee_pct', v_fee_pct, 'fee_amount', v_fee,
    'net_customer', v_net_cust, 'net_mentor', v_net_mentor);
end; $$;
grant execute on function compute_booking_price(bigint, text) to anon, authenticated;

-- 4) get_booking_quote — issue a binding 10-minute quote -----------------------
create or replace function get_booking_quote(p_service_id bigint, p_customer_country text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_snap jsonb; v_hash text; v_id uuid; v_exp timestamptz;
begin
  v_snap := compute_booking_price(p_service_id, p_customer_country);
  v_hash := encode(extensions.digest(v_snap::text, 'sha256'), 'hex');
  insert into pricing_quotes(service_id, mentor_id, customer_country, customer_currency,
      pricing_version, ppp_version, fx_provider, snapshot, pricing_hash)
    values (p_service_id, (v_snap->>'mentor_id')::bigint, upper(coalesce(p_customer_country,'')),
      v_snap->>'customer_currency', (v_snap->>'pricing_version')::int, (v_snap->>'ppp_version')::int,
      v_snap->>'fx_provider', v_snap, v_hash)
    returning id, expires_at into v_id, v_exp;
  return v_snap || jsonb_build_object('quote_id', v_id, 'expires_at', v_exp, 'pricing_hash', v_hash);
end; $$;
grant execute on function get_booking_quote(bigint, text) to anon, authenticated;

-- 5) convert_prices — read-only DISPLAY pricing (soft FX fallback) -------------
-- For browsing (homepage cards, service lists). No quote row, no fee. If FX is
-- unavailable it shows the mentor-currency price (fx_ok=false) rather than
-- failing the page; the binding quote/booking still enforces fresh FX.
-- p_items: [{ "key": "<any>", "amount": <num>, "from": "<ccy>", "is_ppp": <bool> }]
create or replace function convert_prices(p_customer_country text, p_items jsonb)
returns table(key text, you numeric, you0 numeric, customer_currency text, fx_ok boolean)
language plpgsql stable security definer set search_path = public as $$
declare it jsonb; v_amt numeric; v_from text; v_ppp_on boolean; v_cust text; v_ppp numeric; v_rate numeric;
begin
  v_cust := currency_for_country(p_customer_country);
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_amt := coalesce((it->>'amount')::numeric, 0);
    v_from := coalesce(it->>'from', 'USD');
    v_ppp_on := coalesce((it->>'is_ppp')::boolean, false);
    v_ppp := case when v_ppp_on then get_ppp_factor(p_customer_country) else 1 end;
    v_rate := get_fx_or_null(v_from, v_cust);
    if v_rate is null then
      key := it->>'key'; you0 := round(v_amt, 2); you := round(v_amt * v_ppp, 2);
      customer_currency := upper(v_from); fx_ok := false;
    else
      key := it->>'key'; you0 := round(v_amt * v_rate, 2); you := round(v_amt * v_ppp * v_rate, 2);
      customer_currency := v_cust; fx_ok := true;
    end if;
    return next;
  end loop;
end; $$;
grant execute on function convert_prices(text, jsonb) to anon, authenticated;

-- 6) book_session_guest — commit a binding quote verbatim ----------------------
-- New signature: NO money/FX/PPP inputs. Loads the quote, asserts it is fresh
-- and unused, then persists the stored snapshot exactly.
drop function if exists book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb,numeric,text,text,numeric,numeric,numeric);

create or replace function book_session_guest(
  p_quote_id uuid, p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_email text, p_name text default null, p_timezone text default 'UTC',
  p_answers jsonb default '[]'::jsonb, p_target_country text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  q pricing_quotes%rowtype;
  s jsonb;
  v_user_id bigint; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;

  -- Load & lock the quote; validate it is a fresh, unused, matching offer.
  select * into q from pricing_quotes where id = p_quote_id for update;
  if q.id is null then raise exception 'QUOTE_EXPIRED: quote not found' using errcode='P0001'; end if;
  if q.used then raise exception 'QUOTE_EXPIRED: quote already used' using errcode='P0001'; end if;
  if q.expires_at < now() then raise exception 'QUOTE_EXPIRED: quote has expired — please refresh the price' using errcode='P0001'; end if;
  if q.service_id <> p_service_id or q.mentor_id <> p_mentor_id then
    raise exception 'QUOTE_EXPIRED: quote does not match this booking' using errcode='P0001'; end if;

  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then
    raise exception 'That time is not available — please choose another slot'; end if;

  select id into v_user_id from users where email = v_email;
  if v_user_id is null then
    insert into users(email, first_name, role, timezone) values (v_email, p_name, 'user', v_tz) returning id into v_user_id;
  end if;

  s := q.snapshot;  -- the binding contract; committed verbatim, no recompute

  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email,
      target_country, customer_country, customer_currency, fx_customer_inr, fx_mentor_inr)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', v_tz, v_email,
      nullif(trim(coalesce(p_target_country,'')),''), q.customer_country, s->>'customer_currency',
      nullif((s->>'fx_customer_inr')::numeric,0), nullif((s->>'fx_mentor_inr')::numeric,0))
    returning id into v_booking;

  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, (s->>'gross_customer')::numeric, upper(s->>'customer_currency'), 'paid', 'mock_'||gen_random_uuid());

  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at,
      gross_amount, fee_pct, platform_fee_amount, net_amount_customer_currency, net_amount_mentor_currency,
      exchange_rate_used, customer_currency, mentor_currency, ppp_multiplier)
    values (p_mentor_id, v_booking,
      round((s->>'set_price')::numeric * (s->>'ppp_multiplier')::numeric, 2),  -- legacy amount (mentor ccy, pre-fee)
      s->>'mentor_currency', 'pending', now(),
      (s->>'gross_customer')::numeric, (s->>'fee_pct')::numeric, (s->>'fee_amount')::numeric,
      (s->>'net_customer')::numeric, (s->>'net_mentor')::numeric, (s->>'fx_mentor_customer')::numeric,
      upper(s->>'customer_currency'), s->>'mentor_currency', (s->>'ppp_multiplier')::numeric);

  insert into booking_pricing(booking_id, pricing_version, ppp_version, fx_provider,
      mentor_currency, customer_currency, set_price, ppp_multiplier,
      fx_mentor_customer, fx_customer_inr, fx_mentor_inr,
      gross_customer, fee_pct, fee_amount, net_customer, net_mentor)
    values (v_booking, (s->>'pricing_version')::int, (s->>'ppp_version')::int, s->>'fx_provider',
      s->>'mentor_currency', s->>'customer_currency', (s->>'set_price')::numeric, (s->>'ppp_multiplier')::numeric,
      (s->>'fx_mentor_customer')::numeric, (s->>'fx_customer_inr')::numeric, (s->>'fx_mentor_inr')::numeric,
      (s->>'gross_customer')::numeric, (s->>'fee_pct')::numeric, (s->>'fee_amount')::numeric,
      (s->>'net_customer')::numeric, (s->>'net_mentor')::numeric);

  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text'
    from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';

  update pricing_quotes set used = true, booking_id = v_booking where id = p_quote_id;  -- one-time use
  return v_booking;
end; $$;
grant execute on function book_session_guest(uuid,bigint,bigint,timestamptz,text,text,text,jsonb,text) to anon, authenticated;

-- 7) Drop the stale, unfee'd book_session() (no PPP/FX/commission; was exploitable).
drop function if exists book_session(bigint,bigint,timestamptz,text,numeric,jsonb,text);

-- 8) Settings + schedules ------------------------------------------------------
insert into platform_settings(key, value, description)
values ('fx_max_age_minutes','1440','Max age (minutes) of an FX rate before bookings fail with FX_UNAVAILABLE (default 24h)')
on conflict (key) do nothing;

-- pg_cron: refresh FX every 6h (engine tolerates 24h, so ~3 missed runs are safe)
-- and GC expired quotes daily. The fx-refresh call reads the project URL + a
-- bearer key from Vault so this migration carries no secrets and stays portable.
-- If the Vault secrets are absent (e.g. a fresh clone), the FX cron is skipped.
do $$
declare v_url text; v_key text;
begin
  begin select decrypted_secret into v_url from vault.decrypted_secrets where name = 'project_url'; exception when others then v_url := null; end;
  begin select decrypted_secret into v_key from vault.decrypted_secrets where name = 'fx_cron_bearer'; exception when others then v_key := null; end;

  perform cron.unschedule('fx-refresh-6h')   where exists (select 1 from cron.job where jobname='fx-refresh-6h');
  perform cron.unschedule('pricing-quotes-gc') where exists (select 1 from cron.job where jobname='pricing-quotes-gc');

  if v_url is not null and v_key is not null then
    perform cron.schedule('fx-refresh-6h', '0 */6 * * *', format($cron$
      select net.http_post(
        url := %L,
        headers := jsonb_build_object('Authorization', %L, 'Content-Type','application/json'),
        body := '{}'::jsonb)
    $cron$, v_url || '/functions/v1/fx-refresh', 'Bearer ' || v_key));
  else
    raise notice 'fx-refresh cron skipped: set vault secrets project_url and fx_cron_bearer, then re-run section 8.';
  end if;

  perform cron.schedule('pricing-quotes-gc', '30 3 * * *',
    $gc$ delete from pricing_quotes where expires_at < now() - interval '1 day' $gc$);
end $$;
