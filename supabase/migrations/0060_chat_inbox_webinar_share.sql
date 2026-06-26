-- Chat inbox (all of a person's threads in one place) + webinar share-link page data
-- + full reminder sequence (confirmation on register already exists; add 1-day & 1-hour).

-- All conversations for an email (works for mentor OR mentee — role resolved per booking).
create or replace function my_conversations(p_email text)
returns table(booking_id bigint, role text, other_name text, service_title text, status text,
  last_body text, last_at timestamptz, unread int)
language sql stable security definer set search_path = public as $$
  with me as (
    select b.id, chat_role(b.id, p_email) as role, s.title as title, b.status::text as st, b.created_at,
           mu.first_name as mentor_name,
           coalesce(nullif(cu.first_name,''), b.guest_email, cu.email) as mentee_name
    from bookings b
    join services s on s.id = b.service_id
    join mentors mm on mm.id = b.mentor_id
    join users mu on mu.id = mm.user_id
    join users cu on cu.id = b.user_id
  )
  select me.id, me.role,
         case when me.role = 'customer' then me.mentor_name else me.mentee_name end,
         me.title, me.st, lm.body, lm.created_at,
         coalesce((select count(*)::int from messages m
                   where m.booking_id = me.id and m.read_at is null and m.sender_role <> me.role), 0)
  from me
  left join lateral (select body, created_at from messages where booking_id = me.id order by id desc limit 1) lm on true
  where me.role is not null
    and (lm.created_at is not null or me.st in ('confirmed','rescheduled','completed'))
  order by coalesce(lm.created_at, me.created_at) desc;
$$;
grant execute on function my_conversations(text) to anon, authenticated;

-- Single webinar for a public share link (any visibility — having the link is the gate).
create or replace function webinar_public(p_id bigint)
returns table(id bigint, title text, description text, start_time timestamptz, duration int,
  capacity int, status text, mentor_name text, registrations int)
language sql stable security definer set search_path = public as $$
  select w.id, w.title, w.description, w.start_time, w.duration, w.capacity, w.status, mu.first_name,
         (select count(*)::int from webinar_registrations r where r.webinar_id = w.id)
  from webinars w join mentors mm on mm.id = w.mentor_id join users mu on mu.id = mm.user_id
  where w.id = p_id;
$$;
grant execute on function webinar_public(bigint) to anon, authenticated;

-- Two-stage reminders: ~1 day before and ~1 hour before. Each fires once (own flag).
alter table webinars add column if not exists reminded_1d boolean not null default false;
alter table webinars add column if not exists reminded_1h boolean not null default false;

create or replace function send_webinar_reminders()
returns integer language plpgsql security definer set search_path = public as $$
declare w record; msgs jsonb; n int := 0; v_when text; v_flag text;
begin
  for w in
    select *, case when not reminded_1d and start_time between now()+interval '23 hours' and now()+interval '25 hours' then '1d'
                   when not reminded_1h and start_time between now() and now()+interval '70 minutes' then '1h'
                   else null end as due
    from webinars where status = 'scheduled'
  loop
    if w.due is null then continue; end if;
    v_when := case when w.due='1d' then 'tomorrow' else 'in about an hour' end;
    select jsonb_agg(jsonb_build_object('to', r.email,
        'subject', (case when w.due='1d' then 'Tomorrow: ' else 'Starting soon: ' end)||w.title,
        'html', '<p>Your webinar <b>'||w.title||'</b> is '||v_when||' — '||
                to_char(w.start_time,'FMDay, FMMon DD YYYY, HH24:MI')||' UTC.</p>'||
                '<p>Join: <a href="'||w.room_url||'">'||w.room_url||'</a></p>'))
      into msgs from webinar_registrations r where r.webinar_id = w.id;
    if msgs is not null then perform app_send_email_batch(msgs); end if;
    if w.due='1d' then update webinars set reminded_1d = true where id = w.id;
    else update webinars set reminded_1h = true where id = w.id; end if;
    n := n + 1;
  end loop;
  return n;
end; $$;
