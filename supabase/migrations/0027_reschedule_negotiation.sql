-- Cancellation notice window (both sides) + reschedule negotiation
--   mentor declines attendance -> proposes a date + time range
--   -> mentee accepts a slot inside it, OR counters with a different date
--   -> mentor proposes a range for that date -> ...

-- 1) mentor-set cancellation notice window (hours), enforced for mentor AND mentee
alter table mentors  add column if not exists cancel_notice_hours int not null default 24;
-- 2) "are you available?" attendance confirmation
alter table bookings add column if not exists mentor_confirmed_at timestamptz;

-- 3) the back-and-forth offers
create table if not exists reschedule_offers (
  id             bigint generated always as identity primary key,
  booking_id     bigint not null references bookings(id) on delete cascade,
  proposed_by    text not null check (proposed_by in ('mentor','user')),
  offer_date     date,            -- mentor: the day being offered
  range_start    timestamptz,     -- mentor: window the mentor is free
  range_end      timestamptz,
  requested_date date,            -- mentee: a different day they'd prefer
  status         text not null default 'pending' check (status in ('pending','accepted','declined','superseded')),
  created_at     timestamptz not null default now()
);
create index if not exists idx_reschedule_offers_booking on reschedule_offers(booking_id);
alter table reschedule_offers enable row level security;
drop policy if exists reschedule_offers_read on reschedule_offers;
create policy reschedule_offers_read on reschedule_offers for select using (true);

-- 4) cancel with notice window (applies to both mentor and mentee)
create or replace function cancel_booking(p_booking_id bigint, p_cancelled_by text default 'user')
returns bookings language plpgsql security definer set search_path = public as $$
declare b bookings; v_notice int;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'Booking % not found', p_booking_id; end if;
  if auth.uid() is not null
     and b.user_id is distinct from current_user_id()
     and b.mentor_id is distinct from current_mentor_id() then
    raise exception 'Not authorized to cancel booking %', p_booking_id;
  end if;
  if b.status in ('cancelled','completed') then
    raise exception 'Booking % is already %', p_booking_id, b.status;
  end if;
  select cancel_notice_hours into v_notice from mentors where id = b.mentor_id;
  if b.slot_time is not null and now() > b.slot_time - make_interval(hours => coalesce(v_notice,24)) then
    raise exception 'Cancellations must be at least % hours before the session — please reschedule instead.', coalesce(v_notice,24);
  end if;
  update bookings set status = 'cancelled' where id = p_booking_id returning * into b;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status = 'pending';
  if p_cancelled_by = 'mentor' then perform bump_mentor_cancellation(b.mentor_id); end if;
  return b;
end; $$;
grant execute on function cancel_booking(bigint, text) to anon, authenticated;

-- 5) mentor confirms they can attend ("Yes, available")
create or replace function mentor_confirm_attendance(p_booking_id bigint)
returns void language sql security definer set search_path = public as $$
  update bookings set mentor_confirmed_at = now() where id = p_booking_id;
$$;

-- 6) mentor proposes a date + free time range (the "No -> reschedule" path)
create or replace function mentor_propose_reschedule(p_booking_id bigint, p_date date, p_start timestamptz, p_end timestamptz)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; b bookings;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'Booking not found'; end if;
  if b.status in ('cancelled','completed','no_show') then raise exception 'Cannot reschedule (status %)', b.status; end if;
  if p_end <= p_start then raise exception 'Range end must be after start'; end if;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status = 'pending';
  insert into reschedule_offers(booking_id, proposed_by, offer_date, range_start, range_end, status)
    values (p_booking_id, 'mentor', p_date, p_start, p_end, 'pending') returning id into v_id;
  return v_id;
end; $$;

-- 7) mentee can't do that day -> requests a different date (mentor must re-propose)
create or replace function mentee_request_other_date(p_booking_id bigint, p_date date)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status = 'pending';
  insert into reschedule_offers(booking_id, proposed_by, requested_date, status)
    values (p_booking_id, 'user', p_date, 'pending') returning id into v_id;
  return v_id;
end; $$;

-- 8) mentee accepts a specific time inside the mentor's proposed range
create or replace function mentee_accept_reschedule(p_offer_id bigint, p_slot_time timestamptz)
returns bookings language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; b bookings;
begin
  select * into o from reschedule_offers where id = p_offer_id;
  if not found or o.status <> 'pending' or o.proposed_by <> 'mentor' then raise exception 'This proposal is no longer open'; end if;
  if p_slot_time < o.range_start or p_slot_time >= o.range_end then raise exception 'Please pick a time inside the proposed range'; end if;
  if p_slot_time <= now() then raise exception 'Please pick a future time'; end if;
  update reschedule_offers set status = 'accepted' where id = p_offer_id;
  update bookings set slot_time = p_slot_time, slot_end = null, status = 'rescheduled' where id = o.booking_id returning * into b;
  delete from booking_reminders where booking_id = o.booking_id;
  return b;
end; $$;

-- 9) mentor sets their cancellation-notice window (demo editor)
create or replace function demo_set_cancel_notice(p_mentor_id bigint, p_hours int)
returns void language sql security definer set search_path = public as $$
  update mentors set cancel_notice_hours = greatest(coalesce(p_hours,0),0) where id = p_mentor_id;
$$;

-- 10) mentor's upcoming sessions (with mentee + any pending offer)
create or replace function mentor_sessions(p_mentor_id bigint)
returns table (
  id bigint, status text, slot_time timestamptz, meeting_url text,
  service_title text, service_duration int, mentee_name text, mentee_email text,
  mentor_tz text, mentor_confirmed_at timestamptz,
  offer_id bigint, offer_by text, offer_date date, range_start timestamptz, range_end timestamptz, requested_date date
) language sql security definer set search_path = public as $$
  select b.id, b.status::text, b.slot_time, b.meeting_url,
         s.title, s.duration,
         coalesce(nullif(cu.first_name,''), b.guest_email, cu.email),
         coalesce(b.guest_email, cu.email),
         coalesce(mm.app_timezone,'UTC'), b.mentor_confirmed_at,
         ro.id, ro.proposed_by, ro.offer_date, ro.range_start, ro.range_end, ro.requested_date
  from bookings b
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users cu on cu.id = b.user_id
  left join lateral (select * from reschedule_offers where booking_id = b.id and status = 'pending' order by id desc limit 1) ro on true
  where b.mentor_id = p_mentor_id and b.status not in ('cancelled','completed','no_show')
  order by b.slot_time;
$$;

-- 11) extend bookings_by_email with service duration + any pending offer
drop function if exists bookings_by_email(text);
create or replace function bookings_by_email(p_email text)
returns table (
  id bigint, status text, slot_time timestamptz, meeting_url text,
  service_title text, mentor_name text, mentor_tz text, customer_tz text,
  cost numeric, cost_currency text, mentor_earn numeric, mentor_currency text,
  service_duration int,
  offer_id bigint, offer_by text, offer_date date, range_start timestamptz, range_end timestamptz, requested_date date
) language sql security definer set search_path = public as $$
  select b.id, b.status::text, b.slot_time, b.meeting_url,
         s.title, mu.first_name, coalesce(mm.app_timezone,'UTC'),
         coalesce(b.customer_timezone, cu.timezone,'UTC'),
         cp.amount, cp.currency, mp.amount, coalesce(mm.currency,'USD'),
         s.duration,
         ro.id, ro.proposed_by, ro.offer_date, ro.range_start, ro.range_end, ro.requested_date
  from bookings b
  join users cu on cu.id = b.user_id
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select amount from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  left join lateral (select * from reschedule_offers where booking_id=b.id and status='pending' order by id desc limit 1) ro on true
  where lower(coalesce(b.guest_email, cu.email)) = lower(p_email)
  order by b.slot_time desc;
$$;

-- 12) scheduled "are you available?" email ~1hr before (the automatic half)
create or replace function send_attendance_checks()
returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; m_email text; m_first text;
begin
  for r in
    select b.id, b.mentor_id from bookings b
    where b.status in ('confirmed','rescheduled')
      and b.mentor_confirmed_at is null
      and b.slot_time between now() and now() + interval '60 minutes'
      and not exists (select 1 from booking_reminders br where br.booking_id=b.id and br.kind='attend_check')
  loop
    select u.email, u.first_name into m_email, m_first
      from mentors mm join users u on u.id = mm.user_id where mm.id = r.mentor_id;
    if m_email is not null then
      perform app_send_email(m_email, 'Are you available for your upcoming Immigroov session?',
        '<p>Hi ' || coalesce(m_first,'') || ',</p><p>You have a session in about an hour. Open your mentor console to confirm you can attend, or propose a new time.</p>');
    end if;
    insert into booking_reminders(booking_id, kind) values (r.id, 'attend_check') on conflict (booking_id, kind) do nothing;
    n := n + 1;
  end loop;
  return n;
end; $$;

do $$ begin
  if exists (select 1 from cron.job where jobname = 'attend-checks') then perform cron.unschedule('attend-checks'); end if;
end $$;
select cron.schedule('attend-checks', '*/10 * * * *', $$ select send_attendance_checks() $$);

grant execute on function
  mentor_confirm_attendance(bigint),
  mentor_propose_reschedule(bigint, date, timestamptz, timestamptz),
  mentee_request_other_date(bigint, date),
  mentee_accept_reschedule(bigint, timestamptz),
  demo_set_cancel_notice(bigint, int),
  mentor_sessions(bigint),
  bookings_by_email(text)
  to anon, authenticated;
