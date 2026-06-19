-- =============================================================================
-- Immigroov — server-side slot validation, booking answers, availability RPCs
-- =============================================================================

-- Authoritative check: is this exact instant a real, bookable slot?
-- Reuses get_available_slots, so it honors weekly/override/blackout, buffer,
-- minimum notice, booking window, and existing bookings — all in one place.
create or replace function is_slot_available(p_mentor_id bigint, p_service_id bigint, p_slot timestamptz)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from get_available_slots(
      p_mentor_id, p_service_id,
      (p_slot at time zone 'UTC')::date - 1,
      (p_slot at time zone 'UTC')::date + 1)
    where slot_start = p_slot);
$$;
grant execute on function is_slot_available(bigint,bigint,timestamptz) to anon, authenticated;

-- Booking now VALIDATES the slot server-side and captures custom answers.
drop function if exists demo_book_and_pay(bigint,bigint,timestamptz,text,text,text,text,numeric);
create function demo_book_and_pay(
  p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz,
  p_email text, p_name text default null, p_timezone text default 'UTC',
  p_mentee_currency text default 'USD', p_mentee_cost numeric default 0,
  p_answers jsonb default '[]'
)
returns table(booking_id bigint, mentee_cost numeric, mentee_currency text,
              mentor_earn numeric, mentor_currency text, platform_fee numeric, status text)
language plpgsql security definer set search_path = public as $$
declare v_user_id bigint; v_set numeric; v_cur text; v_pct numeric; v_fee numeric; v_booking bigint;
begin
  if p_email is null then raise exception 'email required'; end if;
  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then
    raise exception 'That time is not available — please choose another slot';
  end if;
  select id into v_user_id from users where email = p_email;
  if v_user_id is null then
    insert into users(first_name,email,role,timezone) values(p_name,p_email,'user',p_timezone) returning id into v_user_id;
  end if;
  select s.set_price, coalesce(s.set_currency,'USD') into v_set, v_cur from services s where s.id = p_service_id;
  if v_set is null then raise exception 'service has no set price'; end if;
  select coalesce(value::numeric,15) into v_pct from platform_settings where key='immigroov_commission_pct';
  v_fee := round(v_set * v_pct/100, 2);

  insert into bookings(user_id,mentor_id,service_id,slot_time,status,customer_timezone)
    values(v_user_id,p_mentor_id,p_service_id,p_slot_time,'confirmed',p_timezone) returning id into v_booking;
  insert into customer_payments(booking_id,amount,currency,status,stripe_payment_id)
    values(v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), 'paid', 'mock_'||gen_random_uuid());
  insert into mentor_payouts(mentor_id,booking_id,amount,currency,status,created_at)
    values(p_mentor_id,v_booking,v_set,v_cur,'pending',now());
  -- custom client answers
  insert into booking_question_answers(booking_id, question_id, answer_text)
  select v_booking, (a->>'question_id')::bigint, a->>'answer_text'
  from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a
  where a ? 'question_id';

  return query select v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), v_set, v_cur, v_fee, 'confirmed'::text;
end; $$;
grant execute on function demo_book_and_pay(bigint,bigint,timestamptz,text,text,text,text,numeric,jsonb) to anon, authenticated;

-- Reschedule also validates the new time against availability.
create or replace function reschedule_booking(p_booking_id bigint, p_new_slot_time timestamptz)
returns bookings
language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'Booking % not found', p_booking_id; end if;
  if auth.uid() is not null
     and b.user_id is distinct from current_user_id()
     and b.mentor_id is distinct from current_mentor_id() then
    raise exception 'Not authorized to reschedule booking %', p_booking_id;
  end if;
  if b.status in ('cancelled','completed','no_show') then
    raise exception 'Booking % cannot be rescheduled (status %)', p_booking_id, b.status;
  end if;
  if not is_slot_available(b.mentor_id, b.service_id, p_new_slot_time) then
    raise exception 'That time is not available — please choose another slot';
  end if;
  update bookings set slot_time = p_new_slot_time, slot_end = null, status = 'rescheduled'
    where id = p_booking_id returning * into b;
  delete from booking_reminders where booking_id = p_booking_id;
  return b;
end; $$;

-- ---- Availability manager RPCs (demo) -------------------------------------
create or replace function demo_get_rules(p_mentor_id bigint)
returns table(days_ahead int, min_notice_hours numeric, timezone text)
language sql security definer set search_path = public as $$
  select coalesce(extract(day from app_booking_window)::int, 30),
         round((coalesce(extract(epoch from app_minimum_notice),0)/3600.0)::numeric, 1),
         coalesce(app_timezone,'UTC')
  from mentors where id = p_mentor_id;
$$;

create or replace function demo_set_rules(p_mentor_id bigint, p_days_ahead int, p_min_notice_hours numeric)
returns void language sql security definer set search_path = public as $$
  update mentors set
    app_booking_window = make_interval(days => greatest(p_days_ahead,1)),
    app_minimum_notice = make_interval(mins => round(greatest(p_min_notice_hours,0)*60)::int)
  where id = p_mentor_id;
$$;

create or replace function demo_block_date(p_mentor_id bigint, p_date date)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from specific_availability where mentor_id=p_mentor_id and slot_date=p_date;
  insert into specific_availability(mentor_id,slot_date,start_time,end_time,timezone,is_blackout)
  values(p_mentor_id,p_date,null,null,(select coalesce(app_timezone,'UTC') from mentors where id=p_mentor_id),true);
end; $$;

create or replace function demo_override_date(p_mentor_id bigint, p_date date, p_start time, p_end time)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from specific_availability where mentor_id=p_mentor_id and slot_date=p_date and is_blackout;
  insert into specific_availability(mentor_id,slot_date,start_time,end_time,timezone,is_blackout)
  values(p_mentor_id,p_date,p_start,p_end,(select coalesce(app_timezone,'UTC') from mentors where id=p_mentor_id),false);
end; $$;

-- list one-off entries (overrides + blackouts) — now includes is_blackout
drop function if exists demo_list_slots(bigint);
create function demo_list_slots(p_mentor_id bigint)
returns table(id uuid, slot_date date, start_time time, end_time time, timezone text, is_booked boolean, is_blackout boolean)
language sql security definer set search_path = public as $$
  select id, slot_date, start_time, end_time, timezone, is_booked, is_blackout
  from specific_availability where mentor_id = p_mentor_id and slot_date >= current_date
  order by slot_date, start_time nulls first;
$$;

grant execute on function demo_get_rules(bigint) to anon, authenticated;
grant execute on function demo_set_rules(bigint,int,numeric) to anon, authenticated;
grant execute on function demo_block_date(bigint,date) to anon, authenticated;
grant execute on function demo_override_date(bigint,date,time,time) to anon, authenticated;
grant execute on function demo_list_slots(bigint) to anon, authenticated;

-- sample custom questions on Emma's 30-min service (so answer capture is testable)
insert into service_questions(service_id, question_text, is_required, question_type, is_active)
select s.id, q.txt, q.req, 'text', true
from services s
join mentors mm on mm.id = s.mentor_id
join users u on u.id = mm.user_id
cross join (values ('What is your current visa status?', true), ('Which country are you applying to?', false)) q(txt,req)
where u.email='emma@demo.immigroov.test' and s.duration=30
  and not exists (select 1 from service_questions sq where sq.service_id=s.id);
