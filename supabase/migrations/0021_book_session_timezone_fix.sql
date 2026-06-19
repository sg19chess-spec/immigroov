-- FIX: book_session stored the currency code in users.timezone (invalid IANA
-- value -> users_timezone_check violation -> 400 on confirm). Now it accepts
-- the mentee's real timezone (validated, defaults to UTC).
create or replace function book_session(
  p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_mentee_currency text, p_mentee_cost numeric, p_answers jsonb default '[]',
  p_timezone text default 'UTC'
)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid(); v_user_id bigint; v_utz text; v_set numeric; v_cur text; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
begin
  if v_uid is null then raise exception 'Sign in required to book'; end if;
  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then
    raise exception 'That time is not available — please choose another slot';
  end if;
  select id, timezone into v_user_id, v_utz from users where auth_id = v_uid;
  if v_user_id is null then
    insert into users(auth_id, email, role, timezone)
    values (v_uid, coalesce((select email from auth.users where id = v_uid), 'guest-'||v_uid||'@immigroov.local'), 'user', v_tz)
    returning id, timezone into v_user_id, v_utz;
  end if;
  select s.set_price, coalesce(s.set_currency,'USD') into v_set, v_cur from services s where s.id = p_service_id and s.is_active;
  if v_set is null then raise exception 'Service not available'; end if;
  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', coalesce(v_utz, v_tz)) returning id into v_booking;
  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), 'paid', 'mock_'||gen_random_uuid());
  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at)
    values (p_mentor_id, v_booking, v_set, v_cur, 'pending', now());
  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text'
    from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';
  return v_booking;
end; $$;
grant execute on function book_session(bigint,bigint,timestamptz,text,numeric,jsonb,text) to authenticated, anon;
