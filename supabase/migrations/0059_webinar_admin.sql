-- Admin visibility into webinars + a registrant list for both admin and mentor views.
create or replace function admin_webinars()
returns table(id bigint, title text, mentor_name text, start_time timestamptz, duration int,
  capacity int, visibility text, status text, registrations int, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select w.id, w.title, mu.first_name, w.start_time, w.duration, w.capacity, w.visibility, w.status,
         (select count(*)::int from webinar_registrations r where r.webinar_id = w.id), w.created_at
  from webinars w join mentors mm on mm.id = w.mentor_id join users mu on mu.id = mm.user_id
  order by w.start_time desc;
$$;
grant execute on function admin_webinars() to anon, authenticated;

create or replace function webinar_registrants(p_webinar_id bigint)
returns table(name text, email text, registered_at timestamptz)
language sql stable security definer set search_path = public as $$
  select coalesce(name,'—'), email, registered_at
  from webinar_registrations where webinar_id = p_webinar_id order by registered_at;
$$;
grant execute on function webinar_registrants(bigint) to anon, authenticated;
