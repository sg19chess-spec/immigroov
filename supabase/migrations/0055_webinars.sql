-- Webinar MVP: one-to-many sessions, separate from 1:1 bookings (no overlap/payout/reschedule
-- machinery). Reuses Jitsi for video and the Resend email infra. Demo-ungated like demo_* RPCs.

create table if not exists webinars (
  id bigserial primary key,
  mentor_id bigint not null references mentors(id) on delete cascade,
  title text not null,
  description text,
  start_time timestamptz not null,
  duration int not null default 60,
  capacity int,                              -- null = unlimited
  visibility text not null default 'public' check (visibility in ('public','invite')),
  room_url text,
  status text not null default 'scheduled' check (status in ('scheduled','cancelled','ended')),
  reminder_sent boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists webinar_registrations (
  id bigserial primary key,
  webinar_id bigint not null references webinars(id) on delete cascade,
  user_id bigint references users(id),
  email text not null,
  name text,
  registered_at timestamptz not null default now()
);
create unique index if not exists webinar_reg_unique on webinar_registrations(webinar_id, lower(email));

-- Mentor creates a webinar; a Jitsi room is generated.
create or replace function create_webinar(p_mentor_id bigint, p_title text, p_description text,
  p_start timestamptz, p_duration int default 60, p_capacity int default null, p_visibility text default 'public')
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if coalesce(trim(p_title),'') = '' then raise exception 'Title is required'; end if;
  if p_start is null or p_start <= now() then raise exception 'Start time must be in the future'; end if;
  insert into webinars(mentor_id, title, description, start_time, duration, capacity, visibility, room_url)
    values (p_mentor_id, trim(p_title), nullif(trim(coalesce(p_description,'')),''), p_start,
            coalesce(p_duration,60), p_capacity, coalesce(nullif(p_visibility,''),'public'),
            'https://meet.jit.si/ImmigroovWebinar-'||replace(gen_random_uuid()::text,'-',''))
    returning id into v_id;
  return v_id;
end; $$;
grant execute on function create_webinar(bigint,text,text,timestamptz,int,int,text) to anon, authenticated;

create or replace function cancel_webinar(p_webinar_id bigint)
returns void language sql security definer set search_path = public as $$
  update webinars set status = 'cancelled' where id = p_webinar_id;
$$;
grant execute on function cancel_webinar(bigint) to anon, authenticated;

-- A customer registers; capacity enforced; confirmation email with the join link.
create or replace function register_webinar(p_webinar_id bigint, p_email text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare w webinars; v_email text := lower(nullif(trim(coalesce(p_email,'')),'')); v_count int; v_uid bigint;
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;
  select * into w from webinars where id = p_webinar_id;
  if not found then raise exception 'Webinar not found'; end if;
  if w.status <> 'scheduled' then raise exception 'This webinar is no longer open'; end if;
  if w.start_time <= now() then raise exception 'This webinar has already started'; end if;
  if w.capacity is not null then
    select count(*) into v_count from webinar_registrations where webinar_id = p_webinar_id;
    if v_count >= w.capacity and not exists (select 1 from webinar_registrations where webinar_id=p_webinar_id and lower(email)=v_email)
      then raise exception 'This webinar is full'; end if;
  end if;
  select id into v_uid from users where email = v_email;
  insert into webinar_registrations(webinar_id, user_id, email, name)
    values (p_webinar_id, v_uid, v_email, nullif(trim(coalesce(p_name,'')),''))
    on conflict (webinar_id, lower(email)) do update set name = coalesce(excluded.name, webinar_registrations.name);

  perform app_send_email(v_email, 'You''re registered: '||w.title,
    '<p>Hi'||coalesce(' '||p_name,'')||',</p><p>You''re registered for <b>'||w.title||'</b>.</p>'||
    '<p>Starts: '||to_char(w.start_time,'FMDay, FMMon DD YYYY, HH24:MI')||' UTC ('||w.duration||' min)</p>'||
    '<p>Join link: <a href="'||w.room_url||'">'||w.room_url||'</a></p>');
  return jsonb_build_object('ok', true, 'room_url', w.room_url, 'title', w.title, 'start_time', w.start_time);
end; $$;
grant execute on function register_webinar(bigint,text,text) to anon, authenticated;

-- Public upcoming webinars (public visibility only), with registration counts.
create or replace function list_webinars()
returns table(id bigint, title text, description text, start_time timestamptz, duration int,
  capacity int, mentor_name text, registrations int) language sql stable security definer set search_path = public as $$
  select w.id, w.title, w.description, w.start_time, w.duration, w.capacity, mu.first_name,
         (select count(*)::int from webinar_registrations r where r.webinar_id = w.id)
  from webinars w join mentors mm on mm.id = w.mentor_id join users mu on mu.id = mm.user_id
  where w.visibility = 'public' and w.status = 'scheduled' and w.start_time > now()
  order by w.start_time;
$$;
grant execute on function list_webinars() to anon, authenticated;

-- A mentor's own webinars (any status), with counts + room link.
create or replace function mentor_webinars(p_mentor_id bigint)
returns table(id bigint, title text, description text, start_time timestamptz, duration int,
  capacity int, visibility text, status text, room_url text, registrations int)
language sql stable security definer set search_path = public as $$
  select w.id, w.title, w.description, w.start_time, w.duration, w.capacity, w.visibility, w.status, w.room_url,
         (select count(*)::int from webinar_registrations r where r.webinar_id = w.id)
  from webinars w where w.mentor_id = p_mentor_id order by w.start_time desc;
$$;
grant execute on function mentor_webinars(bigint) to anon, authenticated;

-- Cron: ~1h-before reminder to all registrants (one batch per webinar, then flag it).
create or replace function send_webinar_reminders()
returns integer language plpgsql security definer set search_path = public as $$
declare w record; msgs jsonb; n int := 0;
begin
  for w in select * from webinars
    where status = 'scheduled' and not reminder_sent
      and start_time between now() and now() + interval '60 minutes' loop
    select jsonb_agg(jsonb_build_object('to', r.email,
        'subject', 'Starting soon: '||w.title,
        'html', '<p>Your webinar <b>'||w.title||'</b> starts at '||to_char(w.start_time,'HH24:MI')||' UTC.</p>'||
                '<p>Join: <a href="'||w.room_url||'">'||w.room_url||'</a></p>'))
      into msgs from webinar_registrations r where r.webinar_id = w.id;
    if msgs is not null then perform app_send_email_batch(msgs); end if;
    update webinars set reminder_sent = true where id = w.id;
    n := n + 1;
  end loop;
  return n;
end; $$;

select cron.schedule('webinar-reminders', '*/10 * * * *', 'select send_webinar_reminders()');
