-- In-app chat MVP: masked mentor <-> customer messaging per booking.
-- No Supabase Auth in this app (identity = email + SECURITY DEFINER RPCs), so the messages
-- table is RLS-locked with NO policies — it is ONLY reachable through the participant-checked
-- RPCs below. Bodies are redacted (email/phone/URL stripped) so identities stay masked.
-- Offline recipients get a Resend "new message" email (link only, never the content) via cron.

create table if not exists messages (
  id bigserial primary key,
  booking_id bigint not null references bookings(id) on delete cascade,
  sender_role text not null check (sender_role in ('mentor','customer')),
  body text not null,
  created_at timestamptz not null default now(),
  read_at timestamptz,
  notified_at timestamptz
);
create index if not exists messages_booking_idx on messages(booking_id, id);
alter table messages enable row level security;   -- no policies: only SECURITY DEFINER RPCs may touch it

-- Strip contact info so neither party can leak email / phone / links.
create or replace function redact_contact(p text)
returns text language sql immutable as $$
  select regexp_replace(
           regexp_replace(
             regexp_replace(
               regexp_replace(coalesce(p,''),
                 '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}', '[contact hidden]', 'g'),
               'https?://\S+', '[link hidden]', 'g'),
             'www\.[^\s]+', '[link hidden]', 'g'),
           '\+?\d[\d\s().-]{6,}\d', '[number hidden]', 'g');
$$;

-- Resolve which side an email is on for a booking (or null if not a participant).
create or replace function chat_role(p_booking_id bigint, p_email text)
returns text language sql stable security definer set search_path = public as $$
  select case
    when lower(coalesce(b.guest_email, cu.email)) = lower(trim(p_email)) then 'customer'
    when lower(mu.email) = lower(trim(p_email)) then 'mentor'
    else null end
  from bookings b
  join users cu on cu.id = b.user_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  where b.id = p_booking_id;
$$;
grant execute on function chat_role(bigint, text) to anon, authenticated;

create or replace function send_message(p_booking_id bigint, p_email text, p_body text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_role text; v_id bigint; v_body text;
begin
  if coalesce(trim(p_body),'') = '' then raise exception 'Message is empty'; end if;
  v_role := chat_role(p_booking_id, p_email);
  if v_role is null then raise exception 'You are not a participant in this conversation'; end if;
  v_body := redact_contact(p_body);
  insert into messages(booking_id, sender_role, body) values (p_booking_id, v_role, v_body) returning id into v_id;
  return jsonb_build_object('id', v_id, 'sender_role', v_role, 'body', v_body, 'created_at', now());
end; $$;
grant execute on function send_message(bigint, text, text) to anon, authenticated;

-- Returns the thread for a participant and marks the other side's messages read.
create or replace function list_messages(p_booking_id bigint, p_email text)
returns table(id bigint, sender_role text, body text, created_at timestamptz, mine boolean)
language plpgsql security definer set search_path = public as $$
declare v_role text;
begin
  v_role := chat_role(p_booking_id, p_email);
  if v_role is null then raise exception 'You are not a participant in this conversation'; end if;
  update messages m set read_at = now() where m.booking_id = p_booking_id and m.read_at is null and m.sender_role <> v_role;
  return query
    select m.id, m.sender_role, m.body, m.created_at, (m.sender_role = v_role)
    from messages m where m.booking_id = p_booking_id order by m.id;
end; $$;
grant execute on function list_messages(bigint, text) to anon, authenticated;

-- Cron: email the recipient (link only) when a message stays unread > 5 min. One email per
-- booking per unread batch (dedupe via notified_at).
create or replace function notify_unread_messages()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_site text; v_to text; v_link text; v_subject text;
begin
  select value into v_site from platform_settings where key = 'site_url';
  v_site := coalesce(nullif(v_site,''), 'https://immigroov.vercel.app');
  for r in
    select distinct on (m.booking_id) m.booking_id, m.sender_role,
           coalesce(b.guest_email, cu.email) as mentee_email, mu.email as mentor_email
    from messages m
    join bookings b on b.id = m.booking_id
    join users cu on cu.id = b.user_id
    join mentors mm on mm.id = b.mentor_id
    join users mu on mu.id = mm.user_id
    where m.read_at is null and m.notified_at is null and m.created_at < now() - interval '5 minutes'
    order by m.booking_id, m.id
  loop
    if r.sender_role = 'customer' then
      v_to := r.mentor_email; v_link := v_site||'/dashboard?tab=sessions'; v_subject := 'New message from your mentee';
    else
      v_to := r.mentee_email;  v_link := v_site||'/bookings';             v_subject := 'New message from your mentor';
    end if;
    if v_to is not null then
      perform app_send_email(v_to, v_subject,
        '<p>You have a new message about your Immigroov session.</p>'||
        '<p>Open the app to read and reply: <a href="'||v_link||'">'||v_link||'</a></p>'||
        '<p style="color:#888;font-size:12px">For your privacy, messages stay inside Immigroov.</p>');
    end if;
    update messages set notified_at = now() where booking_id = r.booking_id and read_at is null;
    n := n + 1;
  end loop;
  return n;
end; $$;

select cron.schedule('chat-notify', '*/5 * * * *', 'select notify_unread_messages()');
