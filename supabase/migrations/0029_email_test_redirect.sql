-- Optional test redirect: when platform_settings.test_redirect_email is set,
-- all lifecycle emails go to that one inbox (tagged by role) instead of the real
-- mentor/mentee/admin. Leave empty for production.
-- (notify_booking_event is re-created again in 0030 to use Resend batch sending.)
insert into platform_settings(key, value, description) values
  ('test_redirect_email', '', 'If set, all booking emails route here (testing). Empty = live.')
on conflict (key) do nothing;

create or replace function notify_booking_event(p_booking_id bigint, p_event text)
returns void language plpgsql security definer set search_path = public as $$
declare
  d record; o record;
  s_title text;
  mentee_email text; mentee_name text; mentor_email text; mentor_name text;
  admin_email text; site text; redirect text;
  when_mentee text; when_mentor text;
  heading text; lead text; card text;
  to_mentee text; to_mentor text; to_admin text; tag text;
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
  select value into redirect from platform_settings where key = 'test_redirect_email';
  site := coalesce(nullif(site,''), 'https://immigroov.vercel.app');
  redirect := nullif(redirect, '');
  tag := case when redirect is not null then '[%role%] ' else '' end;

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

  if p_event = 'confirmed' then heading := 'Session confirmed'; lead := 'This session is now confirmed. Details below.';
  elsif p_event = 'cancelled' then heading := 'Session cancelled'; lead := 'This session has been cancelled.';
  elsif p_event = 'rescheduled' then heading := 'Session rescheduled'; lead := 'This session has been moved to a new time.';
  elsif p_event = 'completed' then heading := 'Session completed'; lead := 'Thanks! This session is complete. We would love a review.';
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
  else return;
  end if;

  to_mentee := coalesce(redirect, mentee_email);
  to_mentor := coalesce(redirect, mentor_email);
  to_admin  := coalesce(redirect, nullif(admin_email,''));

  if to_mentee is not null then
    perform app_send_email(to_mentee, replace(tag,'%role%','MENTEE')||'Immigroov: '||heading,
      email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Hi '||mentee_name||',</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card,
        'View your session', site||'/bookings'));
  end if;
  if to_mentor is not null then
    perform app_send_email(to_mentor, replace(tag,'%role%','MENTOR')||'Immigroov: '||heading,
      email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Hi '||mentor_name||',</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card,
        'Open mentor console', site||'/dashboard'));
  end if;
  if to_admin is not null then
    perform app_send_email(to_admin, replace(tag,'%role%','ADMIN')||'Immigroov ['||p_event||']: '||s_title,
      email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Admin notification.</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card,
        'Open console', site||'/dashboard'));
  end if;
end; $$;