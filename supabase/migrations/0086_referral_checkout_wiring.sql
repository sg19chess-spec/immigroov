-- Wires referral attribution + the first-session discount into the real
-- checkout flow. Covers both booking-creation paths:
--   - reserve_booking (real payment: status='pending' -> confirm_booking_payment)
--   - book_session_guest (mock/no-payment path: status='confirmed' immediately)
--
-- Discount design (per founder decision):
--   - discount_pct lives on the referral_codes row (0085), not a global setting.
--   - Applied at RESERVATION time (pricing must be locked in before checkout),
--     but redemption_count only increments at CONFIRMATION time (inside
--     resolve_referral_attribution, called from confirm_booking_payment /
--     book_session_guest) — an abandoned, never-paid reservation must not
--     consume a code's redemption cap.
--   - Immigroov absorbs the discount: only the customer-facing figures
--     (customer_payments.amount, booking_pricing/mentor_payouts' informational
--     gross_customer/fee_amount/net_customer columns) are reduced. The
--     mentor's actual payout basis (set_price * ppp_multiplier, and
--     net_amount_mentor_currency) is untouched — computed from the original
--     quote snapshot exactly as before, so the mentor is paid in full
--     regardless of any discount applied.
--
-- Known duplication (accepted, not hidden): code validity (exists / not
-- expired / under cap) is checked here for pricing purposes, and again
-- implicitly inside resolve_referral_attribution's existing precedence logic
-- at confirmation time. A code could in theory hit its cap in the ~10-minute
-- gap between reservation and confirmation — rare enough to accept rather
-- than add cross-step locking for.

-- ---------------------------------------------------------------------------
-- 1. reserve_booking — real payment path.
-- ---------------------------------------------------------------------------

drop function if exists reserve_booking(uuid,bigint,bigint,timestamptz,text,text,text,jsonb,text);
create or replace function reserve_booking(
  p_quote_id uuid, p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_email text, p_name text default null, p_timezone text default 'UTC',
  p_answers jsonb default '[]'::jsonb, p_target_country text default null,
  p_referral_session_token text default null, p_referral_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q pricing_quotes%rowtype; s jsonb; v_user_id bigint; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
  v_hold_min int := 10;
  v_discount_pct numeric := 0; v_gross numeric; v_fee_amount numeric; v_net_customer numeric;
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;

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

  s := q.snapshot;

  if p_referral_code is not null and trim(p_referral_code) <> '' then
    select discount_pct into v_discount_pct from referral_codes
      where code_string = upper(trim(p_referral_code)) and expires_at > now() and redemption_count < redemption_cap;
    v_discount_pct := coalesce(v_discount_pct, 0);
  end if;
  v_gross := round((s->>'gross_customer')::numeric * (1 - v_discount_pct / 100.0), 2);
  v_fee_amount := round(v_gross * (s->>'fee_pct')::numeric / 100.0, 2);
  v_net_customer := v_gross - v_fee_amount;

  begin
    insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email,
        target_country, customer_country, customer_currency, fx_customer_inr, fx_mentor_inr, payment_hold_expires_at,
        referral_session_token, referral_code, referral_discount_applied_pct)
      values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'pending', v_tz, v_email,
        nullif(trim(coalesce(p_target_country,'')),''), q.customer_country, s->>'customer_currency',
        nullif((s->>'fx_customer_inr')::numeric,0), nullif((s->>'fx_mentor_inr')::numeric,0),
        now() + make_interval(mins => v_hold_min),
        nullif(trim(coalesce(p_referral_session_token,'')),''), nullif(trim(coalesce(p_referral_code,'')),''), v_discount_pct)
      returning id into v_booking;
  exception when exclusion_violation or unique_violation then
    raise exception 'That time was just taken — please choose another slot' using errcode='P0001';
  end;

  insert into customer_payments(booking_id, amount, currency, status)
    values (v_booking, v_gross, upper(s->>'customer_currency'), 'initiated');

  -- Mentor payout basis (amount, net_amount_mentor_currency, etc.) is computed
  -- from the ORIGINAL quote snapshot only — the discount never reaches here.
  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at,
      gross_amount, fee_pct, platform_fee_amount, net_amount_customer_currency, net_amount_mentor_currency,
      exchange_rate_used, customer_currency, mentor_currency, ppp_multiplier)
    values (p_mentor_id, v_booking,
      round((s->>'set_price')::numeric * (s->>'ppp_multiplier')::numeric, 2), s->>'mentor_currency', 'pending', now(),
      v_gross, (s->>'fee_pct')::numeric, v_fee_amount,
      v_net_customer, (s->>'net_mentor')::numeric, (s->>'fx_mentor_customer')::numeric,
      upper(s->>'customer_currency'), s->>'mentor_currency', (s->>'ppp_multiplier')::numeric);

  insert into booking_pricing(booking_id, pricing_version, ppp_version, fx_provider,
      mentor_currency, customer_currency, set_price, ppp_multiplier,
      fx_mentor_customer, fx_customer_inr, fx_mentor_inr,
      gross_customer, fee_pct, fee_amount, net_customer, net_mentor)
    values (v_booking, (s->>'pricing_version')::int, (s->>'ppp_version')::int, s->>'fx_provider',
      s->>'mentor_currency', s->>'customer_currency', (s->>'set_price')::numeric, (s->>'ppp_multiplier')::numeric,
      (s->>'fx_mentor_customer')::numeric, (s->>'fx_customer_inr')::numeric, (s->>'fx_mentor_inr')::numeric,
      v_gross, (s->>'fee_pct')::numeric, v_fee_amount, v_net_customer, (s->>'net_mentor')::numeric);

  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text'
    from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';

  update pricing_quotes set used = true, booking_id = v_booking where id = p_quote_id;

  return jsonb_build_object(
    'booking_id', v_booking,
    'amount', v_gross,
    'currency', upper(s->>'customer_currency'),
    'discount_pct', v_discount_pct,
    'hold_expires_at', now() + make_interval(mins => v_hold_min));
end; $$;
grant execute on function reserve_booking(uuid,bigint,bigint,timestamptz,text,text,text,jsonb,text,text,text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. confirm_booking_payment — the ONE shared confirmation function, called
--    by both razorpay-verify and razorpay-webhook. Resolving attribution here
--    (rather than in either edge function) guarantees it fires exactly once,
--    regardless of which path actually completed the payment, and only for
--    bookings that were genuinely paid.
-- ---------------------------------------------------------------------------

create or replace function confirm_booking_payment(p_booking_id bigint, p_provider_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare b bookings; v_ccy text; v_email text;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking % not found', p_booking_id; end if;
  if b.status = 'confirmed' then return 'already_confirmed'; end if;
  if b.status <> 'pending' or b.payment_hold_expires_at is null then
    raise exception 'HOLD_EXPIRED: booking % is no longer awaiting payment (status %)', p_booking_id, b.status using errcode='P0001';
  end if;
  update bookings set status = 'confirmed', payment_hold_expires_at = null where id = p_booking_id;
  update customer_payments
     set status = 'paid', state = 'captured', provider = 'razorpay',
         provider_payment_id = p_provider_ref, stripe_payment_id = coalesce(stripe_payment_id, p_provider_ref)
   where booking_id = p_booking_id and status = 'initiated'
   returning upper(currency) into v_ccy;
  update mentor_payouts
     set method = coalesce(method, case when upper(coalesce(mentor_currency, currency))='INR' then 'auto_inr' else 'manual' end),
         payout_state = coalesce(payout_state, 'pending')
   where booking_id = p_booking_id;

  if b.referral_session_token is not null or b.referral_code is not null then
    v_email := referral_email_for_booking(p_booking_id);
    if v_email is not null then
      perform resolve_referral_attribution(b.referral_session_token, v_email, b.referral_code);
    end if;
  end if;

  return 'confirmed';
end; $$;
revoke all on function confirm_booking_payment(bigint,text) from public, anon, authenticated;
grant execute on function confirm_booking_payment(bigint,text) to service_role;

-- ---------------------------------------------------------------------------
-- 3. book_session_guest — mock/no-payment path. Goes straight to 'confirmed',
--    so attribution resolves inline instead of waiting for a separate
--    confirmation step.
-- ---------------------------------------------------------------------------

drop function if exists book_session_guest(uuid,bigint,bigint,timestamptz,text,text,text,jsonb,text);
create or replace function book_session_guest(
  p_quote_id uuid, p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_email text, p_name text default null, p_timezone text default 'UTC',
  p_answers jsonb default '[]'::jsonb, p_target_country text default null,
  p_referral_session_token text default null, p_referral_code text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare
  q pricing_quotes%rowtype;
  s jsonb;
  v_user_id bigint; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
  v_discount_pct numeric := 0; v_gross numeric; v_fee_amount numeric; v_net_customer numeric;
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;

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

  s := q.snapshot;

  if p_referral_code is not null and trim(p_referral_code) <> '' then
    select discount_pct into v_discount_pct from referral_codes
      where code_string = upper(trim(p_referral_code)) and expires_at > now() and redemption_count < redemption_cap;
    v_discount_pct := coalesce(v_discount_pct, 0);
  end if;
  v_gross := round((s->>'gross_customer')::numeric * (1 - v_discount_pct / 100.0), 2);
  v_fee_amount := round(v_gross * (s->>'fee_pct')::numeric / 100.0, 2);
  v_net_customer := v_gross - v_fee_amount;

  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email,
      target_country, customer_country, customer_currency, fx_customer_inr, fx_mentor_inr,
      referral_session_token, referral_code, referral_discount_applied_pct)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', v_tz, v_email,
      nullif(trim(coalesce(p_target_country,'')),''), q.customer_country, s->>'customer_currency',
      nullif((s->>'fx_customer_inr')::numeric,0), nullif((s->>'fx_mentor_inr')::numeric,0),
      nullif(trim(coalesce(p_referral_session_token,'')),''), nullif(trim(coalesce(p_referral_code,'')),''), v_discount_pct)
    returning id into v_booking;

  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, v_gross, upper(s->>'customer_currency'), 'paid', 'mock_'||gen_random_uuid());

  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at,
      gross_amount, fee_pct, platform_fee_amount, net_amount_customer_currency, net_amount_mentor_currency,
      exchange_rate_used, customer_currency, mentor_currency, ppp_multiplier)
    values (p_mentor_id, v_booking,
      round((s->>'set_price')::numeric * (s->>'ppp_multiplier')::numeric, 2),
      s->>'mentor_currency', 'pending', now(),
      v_gross, (s->>'fee_pct')::numeric, v_fee_amount,
      v_net_customer, (s->>'net_mentor')::numeric, (s->>'fx_mentor_customer')::numeric,
      upper(s->>'customer_currency'), s->>'mentor_currency', (s->>'ppp_multiplier')::numeric);

  insert into booking_pricing(booking_id, pricing_version, ppp_version, fx_provider,
      mentor_currency, customer_currency, set_price, ppp_multiplier,
      fx_mentor_customer, fx_customer_inr, fx_mentor_inr,
      gross_customer, fee_pct, fee_amount, net_customer, net_mentor)
    values (v_booking, (s->>'pricing_version')::int, (s->>'ppp_version')::int, s->>'fx_provider',
      s->>'mentor_currency', s->>'customer_currency', (s->>'set_price')::numeric, (s->>'ppp_multiplier')::numeric,
      (s->>'fx_mentor_customer')::numeric, (s->>'fx_customer_inr')::numeric, (s->>'fx_mentor_inr')::numeric,
      v_gross, (s->>'fee_pct')::numeric, v_fee_amount, v_net_customer, (s->>'net_mentor')::numeric);

  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text'
    from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';

  update pricing_quotes set used = true, booking_id = v_booking where id = p_quote_id;

  if p_referral_session_token is not null or p_referral_code is not null then
    perform resolve_referral_attribution(p_referral_session_token, v_email, p_referral_code);
  end if;

  return v_booking;
end; $$;
grant execute on function book_session_guest(uuid,bigint,bigint,timestamptz,text,text,text,jsonb,text,text,text) to anon, authenticated;
