-- =============================================================================
-- Immigroov — auth-secured RPCs for the production frontend
-- These use auth.uid() (real Supabase Auth) instead of a passed-in email.
-- =============================================================================

-- Book a session as the signed-in (or anonymous) user.
create or replace function book_session(
  p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_mentee_currency text, p_mentee_cost numeric, p_answers jsonb default '[]'
)
returns bigint
language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_user_id bigint; v_set numeric; v_cur text; v_tz text; v_booking bigint;
begin
  if v_uid is null then raise exception 'Sign in required to book'; end if;
  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then
    raise exception 'That time is not available — please choose another slot';
  end if;

  select id, timezone into v_user_id, v_tz from users where auth_id = v_uid;
  if v_user_id is null then
    insert into users(auth_id, email, role, timezone)
    values (v_uid,
            coalesce((select email from auth.users where id = v_uid), 'guest-'||v_uid||'@immigroov.local'),
            'user', coalesce(p_mentee_currency, 'UTC'))  -- tz overwritten below if known
    returning id, timezone into v_user_id, v_tz;
  end if;

  select s.set_price, coalesce(s.set_currency,'USD') into v_set, v_cur
  from services s where s.id = p_service_id and s.is_active;
  if v_set is null then raise exception 'Service not available'; end if;

  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', coalesce(v_tz,'UTC'))
    returning id into v_booking;
  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), 'paid', 'mock_'||gen_random_uuid());
  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at)
    values (p_mentor_id, v_booking, v_set, v_cur, 'pending', now());
  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text'
    from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';

  return v_booking;
end; $$;
grant execute on function book_session(bigint,bigint,timestamptz,text,numeric,jsonb) to authenticated;

-- The signed-in user's own bookings (RLS-safe; uses current_user_id()).
create or replace function my_bookings()
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
  where cu.id = current_user_id()
  order by b.slot_time desc;
$$;
grant execute on function my_bookings() to authenticated;
