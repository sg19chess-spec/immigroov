-- notify_booking_event gains the 'selected' event: when the mentee picks a time,
-- the mentor gets a "Please confirm the new time" email (with a Confirm CTA).
create or replace function notify_booking_event(p_booking_id bigint, p_event text)
returns void language plpgsql security definer set search_path = public as $$
declare
  d record; o record;
  s_title text; v_meeting text;
  mentee_email text; mentee_name text; mentor_email text; mentor_name text;
  admin_email text; site text; redirect text;
  when_mentee text; when_mentor text;
  heading text; lead text; card text;
  to_mentee text; to_mentor text; to_admin text; tag text;
  msgs jsonb := '[]'::jsonb; att jsonb := null; ics_b64 text;
  bookings_url text; sessions_url text; dash_url text; home_url text;
  ml1 text; mu1 text; ml2 text; mu2 text;
  rl1 text; ru1 text; rl2 text; ru2 text;
begin
  select coalesce(b.guest_email, cu.email), coalesce(nullif(cu.first_name,''),'there'),
         mu.email, coalesce(nullif(mu.first_name,''),'there'), s.title, b.meeting_url
    into mentee_email, mentee_name, mentor_email, mentor_name, s_title, v_meeting
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
  if redirect = 'mentee' then redirect := mentee_email; end if;
  tag := case when redirect is not null then '[%role%] ' else '' end;
  bookings_url := site||'/bookings'; sessions_url := site||'/dashboard?tab=sessions';
  dash_url := site||'/dashboard'; home_url := site;

  select * into d from booking_times_display(p_booking_id);
  when_mentee := to_char(d.customer_local, 'FMDay, FMMon DD, YYYY at HH12:MI AM') || ' (' || d.customer_tz || ')';
  when_mentor := to_char(d.mentor_local,   'FMDay, FMMon DD, YYYY at HH12:MI AM') || ' (' || d.mentor_tz   || ')';

  card :=
     '<div style="background:#fafbfe;border:1px solid #e8ecf4;border-radius:14px;padding:16px;margin-top:8px;">'
   ||'<div style="font-weight:700;font-size:15px;color:#0c1b33;">'||s_title||'</div>'
   ||'<div style="color:#6b7689;font-size:13px;margin-top:6px;">Mentor: '||mentor_name||' &middot; Mentee: '||mentee_name||'</div>'
   ||'<div style="margin-top:10px;font-size:13px;color:#0c1b33;"><b>Mentee time:</b> '||when_mentee||'</div>'
   ||'<div style="font-size:13px;color:#0c1b33;"><b>Mentor time:</b> '||when_mentor||'</div></div>';

  ml1 := 'View your session'; mu1 := bookings_url; ml2 := null; mu2 := null;
  rl1 := 'Open Sessions';     ru1 := sessions_url; rl2 := null; ru2 := null;

  if p_event = 'confirmed' then heading := 'Session confirmed'; lead := 'This session is now confirmed. Details below.';
  elsif p_event = 'cancelled' then heading := 'Session cancelled'; lead := 'This session has been cancelled.';
  elsif p_event = 'rescheduled' then heading := 'Session rescheduled'; lead := 'This session has been moved to a new time.';
  elsif p_event = 'completed' then heading := 'Session completed'; lead := 'Thanks! This session is complete. We would love a review.';
  elsif p_event = 'proposed' then
    heading := 'A new time was proposed'; lead := 'The mentor proposed a new time window. Pick a slot that works for you.';
    select * into o from reschedule_offers where booking_id = p_booking_id and status='pending' and proposed_by='mentor' order by id desc limit 1;
    if o.range_start is not null then
      card := card || '<div style="background:#fff2e8;border:1px solid #fb7321;border-radius:14px;padding:14px;margin-top:10px;font-size:13px;color:#0c1b33;"><b>Proposed window ('||o.offer_date||'):</b> '
        ||to_char(o.range_start at time zone d.customer_tz,'HH12:MI AM')||' &ndash; '||to_char(o.range_end at time zone d.customer_tz,'HH12:MI AM')||' ('||d.customer_tz||')</div>';
    end if;
  elsif p_event = 'selected' then
    heading := 'Please confirm the new time'; lead := 'The mentee picked a time inside your proposed window. Confirm it to lock in the reschedule.';
    select * into o from reschedule_offers where booking_id = p_booking_id and status='mentee_selected' order by id desc limit 1;
    if o.selected_time is not null then
      card := card || '<div style="background:#fff2e8;border:1px solid #fb7321;border-radius:14px;padding:14px;margin-top:10px;font-size:13px;color:#0c1b33;"><b>Mentee selected:</b> '
        ||to_char(o.selected_time at time zone d.mentor_tz,'FMDay, FMMon DD, HH12:MI AM')||' ('||d.mentor_tz||') &middot; '
        ||to_char(o.selected_time at time zone d.customer_tz,'HH12:MI AM')||' ('||d.customer_tz||')</div>';
    end if;
  elsif p_event = 'counter' then
    heading := 'A different day was requested'; lead := 'The mentee cannot make the proposed day and asked for another date. Please propose a time range for it.';
    select * into o from reschedule_offers where booking_id = p_booking_id and status='pending' and proposed_by='user' order by id desc limit 1;
    if o.requested_date is not null then
      card := card || '<div style="background:#eef3fb;border:1px solid #15375f;border-radius:14px;padding:14px;margin-top:10px;font-size:13px;color:#0c1b33;"><b>Requested day:</b> '||o.requested_date||'</div>';
    end if;
  else return;
  end if;

  if p_event in ('confirmed','rescheduled') then
    if v_meeting is not null then
      ml1 := '🎥 Join video call'; mu1 := v_meeting; ml2 := 'Manage booking'; mu2 := bookings_url;
      rl1 := '🎥 Join video call'; ru1 := v_meeting; rl2 := 'Manage in console'; ru2 := sessions_url;
    else
      ml1 := 'View your session'; mu1 := bookings_url; rl1 := 'Open Sessions'; ru1 := sessions_url;
    end if;
  elsif p_event = 'proposed' then
    ml1 := 'Pick a new time'; mu1 := bookings_url; rl1 := 'View in console'; ru1 := sessions_url;
  elsif p_event = 'selected' then
    ml1 := 'View your session'; mu1 := bookings_url; rl1 := 'Confirm time'; ru1 := sessions_url;
  elsif p_event = 'counter' then
    ml1 := 'View your session'; mu1 := bookings_url; rl1 := 'Propose times'; ru1 := sessions_url;
  elsif p_event = 'cancelled' then
    ml1 := 'Find a mentor'; mu1 := home_url; rl1 := 'Open Sessions'; ru1 := sessions_url;
  elsif p_event = 'completed' then
    ml1 := 'Leave a review'; mu1 := bookings_url; rl1 := 'Open Sessions'; ru1 := sessions_url;
  end if;

  if p_event in ('confirmed','rescheduled','cancelled') then
    ics_b64 := translate(encode(convert_to(coalesce(booking_ics(p_booking_id, p_event='cancelled'),''),'UTF8'),'base64'), E'\n\r', '');
    if ics_b64 is not null and ics_b64 <> '' then
      att := jsonb_build_array(jsonb_build_object('filename','invite.ics','content',ics_b64));
    end if;
  end if;

  to_mentee := coalesce(redirect, mentee_email);
  to_mentor := coalesce(redirect, mentor_email);
  to_admin  := coalesce(redirect, nullif(admin_email,''));

  if to_mentee is not null then
    msgs := msgs || (jsonb_build_object('to', to_mentee, 'subject', replace(tag,'%role%','MENTEE')||'Immigroov: '||heading,
      'html', email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Hi '||mentee_name||',</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card, ml1, mu1, ml2, mu2))
      || (case when att is not null then jsonb_build_object('attachments', att) else '{}'::jsonb end));
  end if;
  if to_mentor is not null then
    msgs := msgs || (jsonb_build_object('to', to_mentor, 'subject', replace(tag,'%role%','MENTOR')||'Immigroov: '||heading,
      'html', email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Hi '||mentor_name||',</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card, rl1, ru1, rl2, ru2))
      || (case when att is not null then jsonb_build_object('attachments', att) else '{}'::jsonb end));
  end if;
  if to_admin is not null then
    msgs := msgs || jsonb_build_object('to', to_admin, 'subject', replace(tag,'%role%','ADMIN')||'Immigroov ['||p_event||']: '||s_title,
      'html', email_layout(heading, '<p style="font-size:14px;color:#0c1b33;">Admin notification.</p><p style="font-size:14px;color:#0c1b33;">'||lead||'</p>'||card, 'Open console', dash_url));
  end if;

  perform app_send_email_batch(msgs);
end; $$;
