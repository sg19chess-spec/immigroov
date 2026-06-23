-- Mentee picks a specific time inside the mentor's window -> mentor must CONFIRM
-- it before the booking is moved. Adds a 'mentee_selected' state + selected_time,
-- and exposes offer_status / selected_time / mentee_tz to both consoles.

alter table reschedule_offers add column if not exists selected_time timestamptz;
alter table reschedule_offers drop constraint if exists reschedule_offers_status_check;
alter table reschedule_offers add constraint reschedule_offers_status_check
  check (status in ('pending','mentee_selected','accepted','declined','superseded'));

-- mentee selects a slot -> awaits mentor confirmation (no longer finalizes)
drop function if exists mentee_accept_reschedule(bigint, timestamptz);
create or replace function mentee_accept_reschedule(p_offer_id bigint, p_slot_time timestamptz)
returns void language plpgsql security definer set search_path = public as $$
declare o reschedule_offers;
begin
  select * into o from reschedule_offers where id = p_offer_id;
  if not found or o.status <> 'pending' or o.proposed_by <> 'mentor' then raise exception 'This proposal is no longer open'; end if;
  if p_slot_time < o.range_start or p_slot_time >= o.range_end then raise exception 'Please pick a time inside the proposed range'; end if;
  if p_slot_time <= now() then raise exception 'Please pick a future time'; end if;
  update reschedule_offers set selected_time = p_slot_time, status = 'mentee_selected' where id = p_offer_id;
  perform notify_booking_event(o.booking_id, 'selected');
end; $$;

-- mentor confirms the mentee's selected time -> finalize the move
create or replace function mentor_confirm_reschedule(p_offer_id bigint)
returns bookings language plpgsql security definer set search_path = public as $$
declare o reschedule_offers; b bookings;
begin
  select * into o from reschedule_offers where id = p_offer_id;
  if not found or o.status <> 'mentee_selected' or o.selected_time is null then raise exception 'No selected time to confirm'; end if;
  update reschedule_offers set status = 'accepted' where id = p_offer_id;
  update bookings set slot_time = o.selected_time, slot_end = null, status = 'rescheduled'
    where id = o.booking_id returning * into b;   -- status trigger sends the 'rescheduled' email
  delete from booking_reminders where booking_id = o.booking_id;
  return b;
end; $$;

-- supersede mentee_selected offers too when re-proposing / countering
create or replace function mentor_propose_reschedule(p_booking_id bigint, p_date date, p_start timestamptz, p_end timestamptz)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; b bookings;
begin
  select * into b from bookings where id = p_booking_id;
  if not found then raise exception 'Booking not found'; end if;
  if b.status in ('cancelled','completed','no_show') then raise exception 'Cannot reschedule (status %)', b.status; end if;
  if p_end <= p_start then raise exception 'Range end must be after start'; end if;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
  insert into reschedule_offers(booking_id, proposed_by, offer_date, range_start, range_end, status)
    values (p_booking_id, 'mentor', p_date, p_start, p_end, 'pending') returning id into v_id;
  perform notify_booking_event(p_booking_id, 'proposed');
  return v_id;
end; $$;

create or replace function mentee_request_other_date(p_booking_id bigint, p_date date)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
  insert into reschedule_offers(booking_id, proposed_by, requested_date, status)
    values (p_booking_id, 'user', p_date, 'pending') returning id into v_id;
  perform notify_booking_event(p_booking_id, 'counter');
  return v_id;
end; $$;

-- expose offer_status + selected_time + mentee_tz to the consoles
drop function if exists mentor_sessions(bigint);
create or replace function mentor_sessions(p_mentor_id bigint)
returns table (
  id bigint, status text, slot_time timestamptz, meeting_url text,
  service_title text, service_duration int, mentee_name text, mentee_email text,
  mentor_tz text, mentee_tz text, mentor_confirmed_at timestamptz,
  offer_id bigint, offer_by text, offer_status text, offer_date date,
  range_start timestamptz, range_end timestamptz, requested_date date, selected_time timestamptz
) language sql security definer set search_path = public as $$
  select b.id, b.status::text, b.slot_time, b.meeting_url,
         s.title, s.duration,
         coalesce(nullif(cu.first_name,''), b.guest_email, cu.email),
         coalesce(b.guest_email, cu.email),
         coalesce(mm.app_timezone,'UTC'), coalesce(b.customer_timezone, cu.timezone, 'UTC'),
         b.mentor_confirmed_at,
         ro.id, ro.proposed_by, ro.status, ro.offer_date, ro.range_start, ro.range_end, ro.requested_date, ro.selected_time
  from bookings b
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users cu on cu.id = b.user_id
  left join lateral (select * from reschedule_offers where booking_id = b.id and status in ('pending','mentee_selected') order by id desc limit 1) ro on true
  where b.mentor_id = p_mentor_id
  order by b.slot_time desc;
$$;
grant execute on function mentor_sessions(bigint) to anon, authenticated;

drop function if exists bookings_by_email(text);
create or replace function bookings_by_email(p_email text)
returns table (
  id bigint, status text, slot_time timestamptz, meeting_url text,
  service_title text, mentor_name text, mentor_tz text, customer_tz text,
  cost numeric, cost_currency text, mentor_earn numeric, mentor_currency text,
  service_duration int,
  offer_id bigint, offer_by text, offer_status text, offer_date date,
  range_start timestamptz, range_end timestamptz, requested_date date, selected_time timestamptz
) language sql security definer set search_path = public as $$
  select b.id, b.status::text, b.slot_time, b.meeting_url,
         s.title, mu.first_name, coalesce(mm.app_timezone,'UTC'),
         coalesce(b.customer_timezone, cu.timezone,'UTC'),
         cp.amount, cp.currency, mp.amount, coalesce(mm.currency,'USD'),
         s.duration,
         ro.id, ro.proposed_by, ro.status, ro.offer_date, ro.range_start, ro.range_end, ro.requested_date, ro.selected_time
  from bookings b
  join users cu on cu.id = b.user_id
  join services s on s.id = b.service_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  left join lateral (select amount,currency from customer_payments where booking_id=b.id order by id desc limit 1) cp on true
  left join lateral (select amount from mentor_payouts where booking_id=b.id order by id desc limit 1) mp on true
  left join lateral (select * from reschedule_offers where booking_id=b.id and status in ('pending','mentee_selected') order by id desc limit 1) ro on true
  where lower(coalesce(b.guest_email, cu.email)) = lower(p_email)
  order by b.slot_time desc;
$$;
grant execute on function bookings_by_email(text) to anon, authenticated;

grant execute on function mentee_accept_reschedule(bigint, timestamptz) to anon, authenticated;
grant execute on function mentor_confirm_reschedule(bigint) to anon, authenticated;
