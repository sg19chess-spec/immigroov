-- mentor_sessions now returns ALL sessions (incl. completed/cancelled) so the
-- mentor console can show Upcoming + Past, like the mentee's "Your sessions".
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
  where b.mentor_id = p_mentor_id
  order by b.slot_time desc;
$$;
grant execute on function mentor_sessions(bigint) to anon, authenticated;
