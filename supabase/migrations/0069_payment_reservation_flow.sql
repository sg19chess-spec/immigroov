-- =============================================================================
-- 0069 — Reserve-then-confirm booking flow (payment-ready foundation).
--
-- Resolves the two "paid but no booking" failure modes before real payments:
--   1) Quote TTL vs async payment latency — the 10-min pricing_quotes window can
--      expire mid-payment. Fixed by freezing the price onto a real booking row
--      (booking_pricing) at checkout, so the ephemeral quote no longer matters
--      once reserved.
--   2) Slot held during payment — reserve creates the booking as status='pending',
--      which the existing bookings_no_overlap GiST constraint + get_available_slots
--      already treat as occupying the slot. No two customers can pay for the same
--      slot; the second reserve fails cleanly.
--
-- Uses the EXISTING 'pending'/'cancelled' enum values (no ALTER TYPE, no
-- constraint change): reserve => 'pending' (slot held), confirm => 'confirmed',
-- expire => 'cancelled' (slot freed — already excluded by the overlap rules).
--
-- This is ADDITIVE and provider-agnostic (Stripe or Razorpay). The current mock
-- path (book_session_guest instant-confirm) is untouched; when a real provider is
-- wired, the client calls reserve_booking -> creates a provider order for the
-- returned amount -> the provider webhook (service_role) calls
-- confirm_booking_payment. A per-minute cron expires unpaid 10-min holds.
-- =============================================================================

alter table bookings add column if not exists payment_hold_expires_at timestamptz;

-- 1) reserve_booking — hold the slot + freeze the price, awaiting payment. -------
-- Same quote validation + snapshot commit as book_session_guest, but writes the
-- booking as 'pending' with a 10-minute hold and the payment as 'initiated'.
-- Returns the amount/currency the caller must charge (from the frozen snapshot).
create or replace function reserve_booking(
  p_quote_id uuid, p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_email text, p_name text default null, p_timezone text default 'UTC',
  p_answers jsonb default '[]'::jsonb, p_target_country text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  q pricing_quotes%rowtype; s jsonb; v_user_id bigint; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
  v_hold_min int := 10;
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

  -- 'pending' holds the slot; the bookings_no_overlap exclusion constraint is the
  -- race backstop if two reservations pass is_slot_available concurrently.
  begin
    insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email,
        target_country, customer_country, customer_currency, fx_customer_inr, fx_mentor_inr, payment_hold_expires_at)
      values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'pending', v_tz, v_email,
        nullif(trim(coalesce(p_target_country,'')),''), q.customer_country, s->>'customer_currency',
        nullif((s->>'fx_customer_inr')::numeric,0), nullif((s->>'fx_mentor_inr')::numeric,0),
        now() + make_interval(mins => v_hold_min))
      returning id into v_booking;
  exception when exclusion_violation or unique_violation then
    raise exception 'That time was just taken — please choose another slot' using errcode='P0001';
  end;

  insert into customer_payments(booking_id, amount, currency, status)
    values (v_booking, (s->>'gross_customer')::numeric, upper(s->>'customer_currency'), 'initiated');

  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at,
      gross_amount, fee_pct, platform_fee_amount, net_amount_customer_currency, net_amount_mentor_currency,
      exchange_rate_used, customer_currency, mentor_currency, ppp_multiplier)
    values (p_mentor_id, v_booking,
      round((s->>'set_price')::numeric * (s->>'ppp_multiplier')::numeric, 2), s->>'mentor_currency', 'pending', now(),
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

  update pricing_quotes set used = true, booking_id = v_booking where id = p_quote_id;

  return jsonb_build_object(
    'booking_id', v_booking,
    'amount', (s->>'gross_customer')::numeric,
    'currency', upper(s->>'customer_currency'),
    'hold_expires_at', now() + make_interval(mins => v_hold_min));
end; $$;
grant execute on function reserve_booking(uuid,bigint,bigint,timestamptz,text,text,text,jsonb,text) to anon, authenticated;

-- 2) confirm_booking_payment — the payment webhook's callback. SERVICE-ROLE ONLY.
-- Idempotent (safe against webhook retries). Never grant to anon — that would let
-- a caller confirm a booking without paying.
create or replace function confirm_booking_payment(p_booking_id bigint, p_provider_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking % not found', p_booking_id; end if;
  if b.status = 'confirmed' then return 'already_confirmed'; end if;             -- webhook retry: no-op
  if b.status <> 'pending' or b.payment_hold_expires_at is null then
    -- e.g. the hold was already expired->cancelled by the janitor: payment landed
    -- for a dead hold; caller must refund. Surface it distinctly.
    raise exception 'HOLD_EXPIRED: booking % is no longer awaiting payment (status %)', p_booking_id, b.status using errcode='P0001';
  end if;

  -- The 'pending' row still occupies the slot (janitor hasn't cancelled it), so
  -- confirming is safe even a few seconds past the nominal hold.
  update bookings set status = 'confirmed', payment_hold_expires_at = null where id = p_booking_id;
  update customer_payments set status = 'paid', stripe_payment_id = p_provider_ref
    where booking_id = p_booking_id and status = 'initiated';
  return 'confirmed';
end; $$;
revoke all on function confirm_booking_payment(bigint,text) from public, anon, authenticated;
grant execute on function confirm_booking_payment(bigint,text) to service_role;

-- 3) expire_stale_holds — free slots whose 10-min payment hold lapsed. -----------
-- Only touches reservation rows (payment_hold_expires_at set); leaves other
-- 'pending' bookings alone.
create or replace function expire_stale_holds()
returns int language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  with expired as (
    update bookings set status = 'cancelled', payment_hold_expires_at = null
     where status = 'pending' and payment_hold_expires_at is not null and payment_hold_expires_at < now()
     returning id
  )
  update customer_payments cp set status = 'failed'
   from expired e where cp.booking_id = e.id and cp.status = 'initiated';
  get diagnostics v_count = row_count;
  return v_count;
end; $$;
revoke all on function expire_stale_holds() from public, anon, authenticated;

-- 4) Janitor cron — every minute (10-min hold, so minute granularity is plenty).
select cron.unschedule('expire-payment-holds') where exists (select 1 from cron.job where jobname='expire-payment-holds');
select cron.schedule('expire-payment-holds', '* * * * *', $$ select expire_stale_holds() $$);
