-- Admin booking detail: add mentor country, mentee country, and the platform's cut
-- (commission take + net to mentor). Mentee country is captured from the PPP country
-- already detected during pricing — no extra customer prompt.
alter table bookings add column if not exists customer_country text;

-- book_session_guest gains p_customer_country (sent from the booking page's detected country).
drop function if exists book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb,numeric,text);
create or replace function book_session_guest(
  p_mentor_id bigint, p_service_id bigint, p_slot_time timestamptz, p_mentee_currency text, p_mentee_cost numeric,
  p_email text, p_name text default null, p_timezone text default 'UTC', p_answers jsonb default '[]'::jsonb,
  p_ppp_factor numeric default 1.0, p_target_country text default null, p_customer_country text default null)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_user_id bigint; v_set numeric; v_cur text; v_booking bigint;
  v_tz text := case when is_valid_timezone(p_timezone) then p_timezone else 'UTC' end;
  v_email text := lower(nullif(trim(coalesce(p_email,'')), ''));
  v_f numeric := coalesce(p_ppp_factor, 1.0);
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;
  if not is_slot_available(p_mentor_id, p_service_id, p_slot_time) then raise exception 'That time is not available — please choose another slot'; end if;
  select id into v_user_id from users where email = v_email;
  if v_user_id is null then insert into users(email, first_name, role, timezone) values (v_email, p_name, 'user', v_tz) returning id into v_user_id; end if;
  select s.set_price, coalesce(s.set_currency,'USD') into v_set, v_cur from services s where s.id = p_service_id and s.is_active;
  if v_set is null then raise exception 'Service not available'; end if;
  insert into bookings(user_id, mentor_id, service_id, slot_time, status, customer_timezone, guest_email, target_country, customer_country)
    values (v_user_id, p_mentor_id, p_service_id, p_slot_time, 'confirmed', v_tz, v_email,
            nullif(trim(coalesce(p_target_country,'')),''), nullif(trim(coalesce(p_customer_country,'')),''))
    returning id into v_booking;
  insert into customer_payments(booking_id, amount, currency, status, stripe_payment_id)
    values (v_booking, round(p_mentee_cost,2), upper(p_mentee_currency), 'paid', 'mock_'||gen_random_uuid());
  insert into mentor_payouts(mentor_id, booking_id, amount, currency, status, created_at)
    values (p_mentor_id, v_booking, round(v_set * v_f, 2), v_cur, 'pending', now());
  insert into booking_question_answers(booking_id, question_id, answer_text)
    select v_booking, (a->>'question_id')::bigint, a->>'answer_text' from jsonb_array_elements(coalesce(p_answers,'[]'::jsonb)) a where a ? 'question_id';
  return v_booking;
end; $$;
grant execute on function book_session_guest(bigint,bigint,timestamptz,text,numeric,text,text,text,jsonb,numeric,text,text) to anon, authenticated;

create or replace function admin_booking_detail(p_booking_id bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_tz text; v_has boolean; v_res jsonb; v_fee numeric; v_gross numeric;
begin
  select coalesce(b.customer_timezone, cu.timezone, 'UTC') into v_tz
  from bookings b join users cu on cu.id = b.user_id where b.id = p_booking_id;
  if not found then return null; end if;
  v_has := exists (select 1 from booking_events where booking_id = p_booking_id);
  select coalesce(nullif(s.platform_fee,0), (select value::numeric from platform_settings where key='immigroov_commission_pct'), 15)
    into v_fee from bookings b join services s on s.id=b.service_id where b.id=p_booking_id;
  select amount into v_gross from customer_payments where booking_id=p_booking_id order by id desc limit 1;

  with b as (select * from bookings where id = p_booking_id),
  cp as (select amount, currency, status from customer_payments where booking_id = p_booking_id order by id desc limit 1),
  mp as (select amount, currency, status from mentor_payouts where booking_id = p_booking_id order by id desc limit 1),
  ev as (
    select b.created_at as at, 'customer'::text as actor, 'Booking created & paid'::text as title,
           (select 'Paid '||to_char(amount,'FM999990.00')||' '||currency from cp)::text as detail from b
    union all
    select b.mentor_confirmed_at, 'mentor', 'Mentor confirmed availability', null::text from b where b.mentor_confirmed_at is not null
    union all
    select e.at, e.actor, e.event, e.detail from booking_events e where e.booking_id = p_booking_id
    union all
    select r.created_at, case when r.initiated_by='user' then 'customer' else r.initiated_by end,
           initcap(r.kind)||' requested', r.note
      from booking_requests r where r.booking_id = p_booking_id and not v_has
    union all
    select r.resolved_at, case when r.initiated_by='user' then 'customer' else r.initiated_by end,
           initcap(r.kind)||' request '||r.status, null
      from booking_requests r where r.booking_id = p_booking_id and r.resolved_at is not null and not v_has
    union all
    select o.created_at, case when o.proposed_by='mentor' then 'mentor' else 'customer' end,
           case when o.proposed_by='mentor' then 'Mentor proposed a new time window'
                when o.requested_date is not null then 'Customer asked for a different date'
                else 'Reschedule offer' end,
           (case when o.proposed_by='mentor'
                 then to_char(o.offer_date,'FMDay, FMMon DD')||': '
                      ||to_char(o.range_start at time zone v_tz,'HH12:MI AM')||' – '||to_char(o.range_end at time zone v_tz,'HH12:MI AM')
                      ||' · status: '||o.status
                 when o.requested_date is not null then to_char(o.requested_date,'FMDay, FMMon DD')||' · status: '||o.status
                 else 'status: '||o.status end)::text
      from reschedule_offers o where o.booking_id = p_booking_id and not v_has
    union all
    select l.created_at, l.party, initcap(l.kind)||' '||coalesce(l.pct::text||'%','')
           ||case when l.amount is not null then ' — '||to_char(l.amount,'FM999990.00')||' '||l.currency else '' end,
           l.reason
      from booking_ledger l where l.booking_id = p_booking_id
  )
  select jsonb_build_object(
    'booking', (select jsonb_build_object(
        'id', b.id, 'status', b.status, 'created_at', b.created_at, 'slot_time', b.slot_time, 'slot_end', b.slot_end,
        'reschedule_count', b.reschedule_count, 'no_show_by', b.no_show_by, 'mentor_confirmed_at', b.mentor_confirmed_at,
        'meeting_url', b.meeting_url,
        'service', (select title from services where id = b.service_id),
        'duration', (select duration from services where id = b.service_id),
        'mentor', (select mu.first_name from mentors mm join users mu on mu.id = mm.user_id where mm.id = b.mentor_id),
        'mentee', coalesce(b.guest_email, (select email from users where id = b.user_id)),
        'mentee_tz', v_tz,
        'mentor_tz', (select coalesce(app_timezone,'UTC') from mentors where id = b.mentor_id),
        'mentor_country', (select country from mentors where id = b.mentor_id),
        'mentee_country', b.customer_country) from b),
    'payment', (select jsonb_build_object('amount', amount, 'currency', currency, 'status', status) from cp),
    'payout',  (select jsonb_build_object('amount', amount, 'currency', currency, 'status', status) from mp),
    'totals', jsonb_build_object(
        'paid', v_gross, 'currency', (select currency from cp),
        'fee_pct', v_fee,
        'platform_take', round(coalesce(v_gross,0) * v_fee / 100.0, 2),
        'net_to_mentor', round(coalesce(v_gross,0) * (1 - v_fee / 100.0), 2),
        'customer_refund',  (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='refund'),
        'customer_credit',  (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='credit'),
        'customer_charge',  (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='charge'),
        'customer_penalty', (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='customer' and kind='penalty'),
        'mentor_penalty',   (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='mentor' and kind='penalty'),
        'mentor_credit',    (select coalesce(sum(amount),0) from booking_ledger where booking_id=p_booking_id and party='mentor' and kind='credit')),
    'timeline', (select coalesce(jsonb_agg(jsonb_build_object('at',at,'actor',actor,'title',title,'detail',detail) order by at), '[]'::jsonb)
                 from ev where at is not null)
  ) into v_res;
  return v_res;
end $$;
