-- Phase 3 of the attendance tracking plan: the dashboard should link to each
-- participant's own secure join page instead of the raw Jitsi URL. Mentor
-- sessions only expose mentor_join_token; customer bookings only expose
-- customer_join_token — never both, never the raw meeting_url to the client.
-- (meeting_url itself is untouched and still exists on bookings — it's just
-- no longer read directly by these two dashboards; /join/:token resolves it
-- server-side at the moment of actual entry.)

drop function if exists bookings_by_email(text);
create or replace function bookings_by_email(p_email text)
returns table (
  id bigint, status text, slot_time timestamptz, meeting_url text,
  service_title text, mentor_name text, mentor_tz text, customer_tz text,
  cost numeric, cost_currency text, mentor_earn numeric, mentor_currency text,
  service_duration int, mentor_id bigint, service_id bigint, reschedule_count int, no_show_by text,
  offer_id bigint, offer_by text, offer_status text, offer_date date,
  range_start timestamptz, range_end timestamptz, requested_date date, selected_time timestamptz, offer_was_late boolean,
  req_id bigint, req_kind text, req_initiated_by text, req_status text,
  ledger_summary text, customer_join_token uuid
) language sql security definer set search_path = public as $$
  select b.id, b.status::text, b.slot_time, b.meeting_url,
         s.title, mu.first_name, coalesce(mm.app_timezone,'UTC'),
         coalesce(b.customer_timezone, cu.timezone,'UTC'),
         cp.amount, cp.currency, mp.amount, coalesce(mm.currency,'USD'),
         s.duration, b.mentor_id, b.service_id, b.reschedule_count, b.no_show_by,
         ro.id, ro.proposed_by, ro.status, ro.offer_date, ro.range_start, ro.range_end, ro.requested_date, ro.selected_time, ro.was_late,
         rq.id, rq.kind, rq.initiated_by, rq.status, lg.txt,
         b.customer_join_token
  from bookings b
  join users cu on cu.id = b.user_id
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select amount from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  left join lateral (select * from reschedule_offers where booking_id=b.id and status in ('pending','mentee_selected') order by id desc limit 1) ro on true
  left join lateral (select * from booking_requests where booking_id=b.id and status in ('pending','approved','rejected','auto_approved') order by id desc limit 1) rq on true
  left join lateral (select string_agg(initcap(kind)||coalesce(' '||pct||'%','')||case when amount is not null then ' ('||to_char(amount,'FM999990.00')||' '||currency||')' else '' end, ' · ' order by id) as txt from booking_ledger where booking_id=b.id) lg on true
  where lower(coalesce(b.guest_email, cu.email)) = lower(p_email)
  order by b.slot_time desc;
$$;
grant execute on function bookings_by_email(text) to anon, authenticated;

drop function if exists mentor_sessions(bigint);
create or replace function mentor_sessions(p_mentor_id bigint)
returns table (
  id bigint, status text, slot_time timestamptz, meeting_url text,
  service_title text, service_duration int, mentee_name text, mentee_email text,
  mentor_tz text, mentee_tz text, mentor_confirmed_at timestamptz, reschedule_count int, no_show_by text,
  offer_id bigint, offer_by text, offer_status text, offer_date date,
  range_start timestamptz, range_end timestamptz, requested_date date, selected_time timestamptz, offer_was_late boolean,
  req_id bigint, req_kind text, req_initiated_by text, req_status text,
  ledger_summary text, mentor_join_token uuid
) language sql security definer set search_path = public as $$
  select b.id, b.status::text, b.slot_time, b.meeting_url,
         s.title, s.duration,
         coalesce(nullif(cu.first_name,''), b.guest_email, cu.email),
         coalesce(b.guest_email, cu.email),
         coalesce(mm.app_timezone,'UTC'), coalesce(b.customer_timezone, cu.timezone, 'UTC'),
         b.mentor_confirmed_at, b.reschedule_count, b.no_show_by,
         ro.id, ro.proposed_by, ro.status, ro.offer_date, ro.range_start, ro.range_end, ro.requested_date, ro.selected_time, ro.was_late,
         rq.id, rq.kind, rq.initiated_by, rq.status, lg.txt,
         b.mentor_join_token
  from bookings b
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users cu on cu.id = b.user_id
  left join lateral (select * from reschedule_offers where booking_id = b.id and status in ('pending','mentee_selected') order by id desc limit 1) ro on true
  left join lateral (select * from booking_requests where booking_id = b.id and status in ('pending','approved','rejected','auto_approved') order by id desc limit 1) rq on true
  left join lateral (select string_agg(initcap(kind)||coalesce(' '||pct||'%','')||case when amount is not null then ' ('||to_char(amount,'FM999990.00')||' '||currency||')' else '' end, ' · ' order by id) as txt from booking_ledger where booking_id=b.id) lg on true
  where b.mentor_id = p_mentor_id
  order by b.slot_time desc;
$$;
grant execute on function mentor_sessions(bigint) to anon, authenticated;
