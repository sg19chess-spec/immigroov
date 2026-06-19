-- =============================================================================
-- Immigroov — MOCK payment flow (use until real Stripe is wired up)
-- =============================================================================
-- book_and_pay_mock() does everything book-and-pay does EXCEPT call Stripe:
--   * resolves regional price (offer_price ?? base_price) + Immigroov fee
--   * validates + applies a discount code
--   * creates the booking (overlap guard still enforced)
--   * records a customer_payments row as instantly 'paid' (stripe_payment_id
--     prefixed 'mock_') and confirms the booking
-- Works for logged-in users and anonymous guests (needs an auth session).
--
-- To go live later: stop calling this RPC and call the `book-and-pay` Edge
-- Function instead — the data model is identical, only the payment source changes.
-- =============================================================================
create or replace function book_and_pay_mock(
  p_mentor_id                bigint,
  p_service_id               bigint,
  p_slot_time                timestamptz,
  p_country_code             text,
  p_discount_code            text default null,
  p_specific_availability_id uuid default null,
  p_guest_email              text default null,
  p_guest_first_name         text default null,
  p_timezone                 text default 'UTC'
)
returns table (
  booking_id    bigint,
  payment_id    bigint,
  amount        numeric,
  currency      text,
  mentor_price  numeric,
  immigroov_fee numeric,
  status        text
)
language plpgsql security definer set search_path = public as $$
declare
  v_uid          uuid := auth.uid();
  v_user_id      bigint;
  v_currency     text;
  v_base         numeric;
  v_offer        numeric;
  v_fee          numeric;
  v_mentor_price numeric;
  v_pct          int := 0;
  v_discount_id  bigint;
  v_total        numeric;
  v_booking      bigint;
  v_payment      bigint;
begin
  if v_uid is null then
    raise exception 'No session: sign in (or signInAnonymously) before booking';
  end if;

  -- Profile: reuse existing, else create one (guest path).
  select id into v_user_id from users where auth_id = v_uid;
  if v_user_id is null then
    if p_guest_email is null then
      raise exception 'guest email required for a new (guest) booking';
    end if;
    insert into users (auth_id, first_name, email, role, timezone)
    values (v_uid, p_guest_first_name, p_guest_email, 'user', p_timezone)
    returning id into v_user_id;
  end if;

  -- Price for this country, else any active pricing row.
  select sp.currency, sp.base_price, sp.offer_price, sp.immigroov_price
    into v_currency, v_base, v_offer, v_fee
  from service_pricing sp
  where sp.service_id = p_service_id and sp.country_code = p_country_code and sp.is_active
  limit 1;
  if not found then
    select sp.currency, sp.base_price, sp.offer_price, sp.immigroov_price
      into v_currency, v_base, v_offer, v_fee
    from service_pricing sp where sp.service_id = p_service_id and sp.is_active limit 1;
  end if;
  if not found then
    raise exception 'No active pricing for service %', p_service_id;
  end if;

  v_mentor_price := coalesce(v_offer, v_base);
  v_fee          := coalesce(v_fee, 0);

  -- Validate discount.
  if p_discount_code is not null then
    select d.id, coalesce(d.percentage, 0) into v_discount_id, v_pct
    from discounts d
    where d.code = p_discount_code and d.is_active
      and (d.expires_at is null or d.expires_at > now());
    if not found then v_discount_id := null; v_pct := 0; end if;
  end if;

  v_mentor_price := round(v_mentor_price * (1 - v_pct / 100.0), 2);
  v_total        := round(v_mentor_price + v_fee, 2);

  -- Create the booking (bookings_no_overlap still guards against clashes).
  insert into bookings (user_id, mentor_id, service_id, slot_time, status,
                        discount_id, customer_timezone, specific_availability_id)
  values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed',
          v_discount_id, p_timezone, p_specific_availability_id)
  returning id into v_booking;

  -- Mock payment: instantly 'paid'.
  insert into customer_payments (booking_id, amount, currency, status, stripe_payment_id)
  values (v_booking, v_total, upper(v_currency), 'paid', 'mock_' || gen_random_uuid())
  returning id into v_payment;

  return query
    select v_booking, v_payment, v_total, upper(v_currency),
           v_mentor_price, v_fee, 'confirmed'::text;
end;
$$;

grant execute on function
  book_and_pay_mock(bigint, bigint, timestamptz, text, text, uuid, text, text, text)
  to anon, authenticated;

-- Mock refund: cancel + mark the mock payment refunded in one call.
create or replace function cancel_and_refund_mock(
  p_booking_id   bigint,
  p_cancelled_by text default 'user'
)
returns void
language plpgsql security definer set search_path = public as $$
begin
  perform cancel_booking(p_booking_id, p_cancelled_by);  -- authorizes the caller
  update customer_payments set status = 'refunded'
  where booking_id = p_booking_id and status = 'paid';
end;
$$;

grant execute on function cancel_and_refund_mock(bigint, text) to anon, authenticated;
