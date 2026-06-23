-- Beautiful, branded lifecycle emails to mentee + mentor + admin for:
-- confirmed / cancelled / rescheduled / completed / proposed / counter.
-- Sends only once a Resend key is in Vault (resend_api_key); otherwise no-ops.

insert into platform_settings(key, value, description) values
  ('site_url', 'https://immigroov.vercel.app', 'Base URL for links in emails'),
  ('admin_email', 'sg19chess@gmail.com', 'Admin recipient for booking notifications')
on conflict (key) do nothing;

create or replace function demo_set_setting(p_key text, p_value text)
returns void language sql security definer set search_path = public as $$
  insert into platform_settings(key, value) values (p_key, p_value)
  on conflict (key) do update set value = excluded.value, updated_at = now();
$$;
grant execute on function demo_set_setting(text, text) to anon, authenticated;

-- Branded HTML shell (inline styles for email clients)
create or replace function email_layout(p_heading text, p_body text, p_cta_label text default null, p_cta_url text default null)
returns text language sql immutable as $$
  select
   '<div style="margin:0;padding:0;background:#f4f6fb;">'
 ||'<div style="max-width:560px;margin:0 auto;padding:24px;font-family:Inter,Segoe UI,Arial,sans-serif;">'
 ||'<div style="background:linear-gradient(135deg,#0a2240,#15375f);border-radius:18px 18px 0 0;padding:20px 26px;">'
 ||'<span style="display:inline-block;background:linear-gradient(135deg,#fb7321,#fa5a2b);color:#fff;font-weight:800;font-size:13px;padding:7px 9px;border-radius:9px;">IM</span>'
 ||'<span style="color:#fff;font-weight:800;font-size:18px;margin-left:8px;">Immigroov</span>'
 ||'</div>'
 ||'<div style="background:#fff;border:1px solid #e8ecf4;border-top:none;border-radius:0 0 18px 18px;padding:26px;">'
 ||'<h1 style="font-size:20px;margin:0 0 12px;color:#0a2240;">'||p_heading||'</h1>'
 ||p_body
 ||case when p_cta_url is not null then
     '<div style="margin-top:22px;"><a href="'||p_cta_url||'" style="display:inline-block;background:linear-gradient(135deg,#fb7321,#fa5a2b);color:#fff;text-decoration:none;font-weight:700;font-size:14px;padding:12px 20px;border-radius:12px;">'||coalesce(p_cta_label,'View')||'</a></div>'
    else '' end
 ||'<p style="color:#97a1b3;font-size:12px;margin-top:24px;">Immigroov &middot; 1:1 immigration mentoring</p>'
 ||'</div></div></div>';
$$;

-- Send a branded event email to mentee, mentor, and admin
create or replace function notify_booking_event(p_booking_id bigint, p_event text)
returns void language plpgsql security definer set search_path = public as $$
declare
  d record; o record;
  s_title text;
  mentee_email text; mentee_name text; mentor_email text; mentor_name text;
  admin_email text; site text;
  when_mentee text; when_mentor text;
  heading text; lead text; card text;
begin
  select coalesce(b.guest_email, cu.email), coalesce(nullif(cu.first_name,''),'there'),
         mu.email, coalesce(nullif(mu.first_name,''),'there'), s.title
    into mentee_email, mentee_name, mentor_email, mentor_name, s_title
  from bookings b
  join users cu on cu.id = b.user_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join services s on s.id = b.service_id
  where b.id = p_booking_id;
  if not found then return; end if;

  select value into admin_email from platform_settings where key = 'admin_email';
  select value into site from platform_settings where key = 'site_url';
  site := coalesce(nullif(site,''), 'https://immigroov.vercel.app');

  select * into d from booking_times_display(p_booking_id);
  when_mentee := to_char(d.customer_local, 'FMDay, FMMon DD, YYYY at HH12:MI AM') || ' (' || d.customer_tz || ')';
  when_mentor := to_char(d.mentor_local,   'FMDay, FMMon DD, YYYY at HH12:MI AM') || ' (' || d.mentor_tz   || ')';

  card :=
     '<div style="background:#fafbfe;border:1px solid #e8ecf4;border-radius:14px;padding:16px;margin-top:8px;">'
   ||'<div style="font-weight:700;font-size:15px;color:#0c1b33;">'||s_title||'</div>'
   ||'<div style="color:#6b7689;font-size:13px;margin-top:6px;">Mentor: '||mentor_name||' &middot; Mentee: '||mentee_name||'</div>'
   ||'<div style="margin-top:10px;font-size:13px;color:#0c1b33;"><b>Mentee time:</b> '||when_mentee||'</div>'
   ||'<div style="font-size:13px;color:#0c1b33;"><b>Mentor time:</b> '||when_mentor||'</div>'
   ||'</div>';

  if p_event = 'confirmed' then
    heading := 'Session confirmed'; lead := 'This session is now confirmed. Details below.';
  elsif p_event = 'cancelled' then
    heading := 'Session cancelled'; lead := 'This session has been cancelled.';
  elsif p_event = 'rescheduled' then
    heading := 'Session rescheduled'; lead := 'This session has been moved to a new time.';
  elsif p_event = 'completed' then
    heading := 'Session completed'; lead := 'Thanks! This session is complete. We would love a review.';
  elsif p_event = 'proposed' then
    heading := 'A new time was proposed'; lead := 'The mentor proposed a new time window. The mentee can now pick a slot inside it.';
    select * into o from reschedule_offers where booking_id = p_booking_id and status='pending' and proposed_by='mentor' order by id desc limit 1;
    if o.range_start is not null then
      card := card || '<div style="background:#fff2e8;border:1px solid #fb7321;border-radius:14px;padding:14px;margin-top:10px;font-size:13px;color:#0c1b33;"><b>Proposed window ('||o.offer_date||'):</b> '
        ||to_char(o.range_start at time zone d.customer_tz,'HH12:MI AM')||' &ndash; '||to_char(o.range_end at time zone d.customer_tz,'HH12:MI AM')||' ('||d.customer_tz||')</div>';
    end if;
  elsif p_event = 'counter' then
    heading := 'A different day was requested'; lead := 'The mentee cannot make the proposed day and asked for another date. Please propose a time range for it.';
    select * into o from reschedule_offers where booking_id = p_booking_id and status='pending' and proposed_by='user' order by id desc limit 1;
    if o.requested_date is not null then
      card := card || '<div style="background:#eef3fb;border:1px solid #15375f;border-radius:14px;padding:14px;margin-top:10px;font-size:13px;color:#0c1b33;"><b>Requested day:</b> '||o.requested_date||'</div>';
    end if;
  else
    return;
  end if;

  if mentee_email is not null then
    perform app_send_email(mentee_email, 'Immigroov: '||heading,
      email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Hi '||mentee_name||',</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card,
        'View your session', site||'/bookings'));
  end if;
  if mentor_email is not null then
    perform app_send_email(mentor_email, 'Immigroov: '||heading,
      email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Hi '||mentor_name||',</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card,
        'Open mentor console', site||'/dashboard'));
  end if;
  if admin_email is not null and admin_email <> '' then
    perform app_send_email(admin_email, 'Immigroov ['||p_event||']: '||s_title,
      email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Admin notification.</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card,
        'Open console', site||'/dashboard'));
  end if;
end; $$;

-- Route booking status changes through the branded notifier (to all three)
create or replace function trg_booking_status_email()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform notify_booking_event(new.id, 'confirmed');
  elsif new.status = 'rescheduled' and tg_op = 'UPDATE' and (old.status is distinct from new.status or old.slot_time is distinct from new.slot_time) then
    perform notify_booking_event(new.id, 'rescheduled');
  elsif new.status = 'cancelled' and tg_op = 'UPDATE' and old.status is distinct from new.status then
    perform notify_booking_event(new.id, 'cancelled');
  elsif new.status = 'completed' and tg_op = 'UPDATE' and old.status is distinct from new.status then
    perform notify_booking_event(new.id, 'completed');
  end if;
  return new;
end; $$;

-- Negotiation emails: re-create the two RPCs with notifications added
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
  perform notify_booking_event(p_booking_id, 'proposed');
  return v_id;
end; $$;

create or replace function mentee_request_other_date(p_booking_id bigint, p_date date)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status = 'pending';
  insert into reschedule_offers(booking_id, proposed_by, requested_date, status)
    values (p_booking_id, 'user', p_date, 'pending') returning id into v_id;
  perform notify_booking_event(p_booking_id, 'counter');
  return v_id;
end; $$;
