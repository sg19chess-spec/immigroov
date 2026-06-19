-- Capture guest email at booking time so confirmations/reminders can be sent,
-- and allow guest booking without anonymous auth.
alter table bookings add column if not exists guest_email text;

-- session-less guest booking (creates/reuses a users row by email)
create or replace function book_session_guest(
  p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_mentee_currency text, p_mentee_cost numeric, p_email text, p_name text default null,
  p_timezone text default 'UTC', p_answers jsonb default '[]'
)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_user_id bigint; v_set numeric; v_cur text; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;
  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then raise exception 'That time is not available — please choose another slot'; end if;
  select id into v_user_id from users where email = v_email;
  if v_user_id is null then insert into users(email, first_name, role, timezone) values (v_email, p_name, 'user', v_tz) returning id into v_user_id; end if;
  select s.set_price, coalesce(s.set_currency,'USD') into v_set, v_cur from services s where s.id = p_service_id and s.is_active;
  if v_set is null then raise exception 'Service not available'; end if;
  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', v_tz, v_email) returning id into v_booking;
  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), 'paid', 'mock_'||gen_random_uuid());
  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at)
    values (p_mentor_id, v_booking, v_set, v_cur, 'pending', now());
  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text' from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';
  return v_booking;
end; $$;
grant execute on function book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb) to anon, authenticated;

-- email engine sends to coalesce(booking.guest_email, account email): see
-- trg_booking_status_email and due_reminders (updated in this migration set).
