-- Prevent double webinar registration: idempotent register_webinar that detects an
-- existing registration, skips the duplicate confirmation email, and returns `already`.
create or replace function register_webinar(p_webinar_id bigint, p_email text, p_name text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare w webinars; v_email text := lower(nullif(trim(coalesce(p_email,'')),'')); v_count int; v_uid bigint; v_already boolean;
begin
  if v_email is null or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;
  select * into w from webinars where id = p_webinar_id;
  if not found then raise exception 'Webinar not found'; end if;
  if w.status <> 'scheduled' then raise exception 'This webinar is no longer open'; end if;
  if w.start_time <= now() then raise exception 'This webinar has already started'; end if;

  select exists (select 1 from webinar_registrations where webinar_id = p_webinar_id and lower(email) = v_email) into v_already;

  if not v_already and w.capacity is not null then
    select count(*) into v_count from webinar_registrations where webinar_id = p_webinar_id;
    if v_count >= w.capacity then raise exception 'This webinar is full'; end if;
  end if;

  select id into v_uid from users where email = v_email;
  insert into webinar_registrations(webinar_id, user_id, email, name)
    values (p_webinar_id, v_uid, v_email, nullif(trim(coalesce(p_name,'')),''))
    on conflict (webinar_id, lower(email)) do update set name = coalesce(excluded.name, webinar_registrations.name);

  if not v_already then
    perform app_send_email(v_email, 'You''re registered: '||w.title,
      '<p>Hi'||coalesce(' '||p_name,'')||',</p><p>You''re registered for <b>'||w.title||'</b>.</p>'||
      '<p>Starts: '||to_char(w.start_time,'FMDay, FMMon DD YYYY, HH24:MI')||' UTC ('||w.duration||' min)</p>'||
      '<p>Join link: <a href="'||w.room_url||'">'||w.room_url||'</a></p>'||
      '<p>We''ll remind you 1 day and 1 hour before it starts.</p>');
  end if;

  return jsonb_build_object('ok', true, 'already', v_already, 'room_url', w.room_url, 'title', w.title, 'start_time', w.start_time);
end; $$;
