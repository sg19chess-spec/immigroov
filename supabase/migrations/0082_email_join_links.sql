-- Phase 4 of the attendance tracking plan: every email that currently links
-- to the raw Jitsi meeting_url instead links to the recipient's own secure
-- /join/:token page. Three places found (traced to their actual current
-- definitions, since these functions had been rewritten many times):
--   1. notify_booking_event() — confirmed/rescheduled emails' "Join video
--      call" button and inline video-link row (0047_email_no_show.sql).
--   2. booking_ics() — the .ics calendar attachment's LOCATION/DESCRIPTION
--      fields (0031_ics_calendar_invite.sql). Mentee and mentor now get
--      DIFFERENT calendar files, each carrying only their own token.
--   3. process_due_reminders()/due_reminders() — the 24h/1h reminder email
--      (0012_jitsi_meeting_link.sql).
--
-- Known pre-existing asymmetry, left as-is (out of scope for "stop leaking
-- the raw link" — would be adding a new notification, not fixing this one):
-- process_due_reminders only ever emailed the customer, never the mentor.

-- ---------------------------------------------------------------------------
-- 1. booking_ics gains an explicit join-link parameter and stops reading
--    meeting_url itself. Callers now decide which recipient's link (if any)
--    goes into that recipient's own calendar file.
-- ---------------------------------------------------------------------------

create or replace function booking_ics(p_booking_id bigint, p_cancelled boolean default false, p_join_url text default null)
returns text language plpgsql stable security definer set search_path = public as $$
declare b record; v_end timestamptz; crlf text := chr(13)||chr(10); ics text;
begin
  select bk.slot_time, s.title, coalesce(s.duration,30) as duration,
         coalesce(nullif(mu.first_name,''),'your mentor') as mentor_name
    into b
  from bookings bk
  join services s on s.id = bk.service_id
  join mentors mm on mm.id = bk.mentor_id
  join users mu on mu.id = mm.user_id
  where bk.id = p_booking_id;
  if not found or b.slot_time is null then return null; end if;
  v_end := b.slot_time + make_interval(mins => b.duration);

  ics := 'BEGIN:VCALENDAR'||crlf
    ||'VERSION:2.0'||crlf
    ||'PRODID:-//Immigroov//Booking//EN'||crlf
    ||'METHOD:PUBLISH'||crlf
    ||'BEGIN:VEVENT'||crlf
    ||'UID:booking-'||p_booking_id||'@immigroov'||crlf
    ||'SEQUENCE:'||floor(extract(epoch from now())/60)::bigint||crlf
    ||'DTSTAMP:'||to_char(now() at time zone 'UTC','YYYYMMDD"T"HH24MISS"Z"')||crlf
    ||'DTSTART:'||to_char(b.slot_time at time zone 'UTC','YYYYMMDD"T"HH24MISS"Z"')||crlf
    ||'DTEND:'||to_char(v_end at time zone 'UTC','YYYYMMDD"T"HH24MISS"Z"')||crlf
    ||'SUMMARY:'||ical_esc(b.title||' — Immigroov')||crlf
    ||'STATUS:'||(case when p_cancelled then 'CANCELLED' else 'CONFIRMED' end)||crlf
    ||coalesce('LOCATION:'||ical_esc(p_join_url)||crlf,'')
    ||'DESCRIPTION:'||ical_esc('Session with '||b.mentor_name||case when p_join_url is not null then E'\nJoin: '||p_join_url else '' end)||crlf
    ||'END:VEVENT'||crlf
    ||'END:VCALENDAR'||crlf;
  return ics;
end; $$;

-- ---------------------------------------------------------------------------
-- 2. notify_booking_event — same as 0047's version, with:
--    - customer_join_token/mentor_join_token fetched alongside the other
--      booking fields (meeting_url is no longer selected at all here).
--    - the shared "Video link" table row removed (it showed one raw URL to
--      both recipients) — the existing role-specific CTA button now carries
--      each recipient's own secure link instead.
--    - two separate .ics attachments built (one per recipient), each with
--      only that recipient's own join link.
-- ---------------------------------------------------------------------------

create or replace function notify_booking_event(p_booking_id bigint, p_event text)
returns void language plpgsql security definer set search_path = public as $$
declare
  d record; o record;
  s_title text; v_dur int; v_amount numeric; v_cur text; v_no_show_by text;
  v_customer_token uuid; v_mentor_token uuid; v_join_mentee text; v_join_mentor text;
  mentee_email text; mentee_name text; mentor_email text; mentor_name text;
  admin_email text; site text; redirect text;
  when_mentee text; when_mentor text; lbl text;
  heading text; ld_m text; ld_r text; ld_a text; det text; extra text := '';
  to_mentee text; to_mentor text; to_admin text; tag text;
  msgs jsonb := '[]'::jsonb; att_mentee jsonb := null; att_mentor jsonb := null;
  ics_mentee_b64 text; ics_mentor_b64 text;
  bookings_url text; sessions_url text; dash_url text; home_url text;
  ml1 text; mu1 text; ml2 text; mu2 text;
  rl1 text; ru1 text; rl2 text; ru2 text;
begin
  select coalesce(b.guest_email, cu.email), coalesce(nullif(cu.first_name,''),'there'),
         mu.email, coalesce(nullif(mu.first_name,''),'there'), s.title, s.duration, b.no_show_by,
         b.customer_join_token, b.mentor_join_token
    into mentee_email, mentee_name, mentor_email, mentor_name, s_title, v_dur, v_no_show_by,
         v_customer_token, v_mentor_token
  from bookings b
  join users cu on cu.id = b.user_id
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join services s on s.id = b.service_id
  where b.id = p_booking_id;
  if not found then return; end if;

  select amount, currency into v_amount, v_cur from customer_payments where booking_id = p_booking_id order by id desc limit 1;
  select value into admin_email from platform_settings where key = 'admin_email';
  select value into site from platform_settings where key = 'site_url';
  select value into redirect from platform_settings where key = 'test_redirect_email';
  site := coalesce(nullif(site,''), 'https://immigroov.vercel.app');
  redirect := nullif(redirect, '');
  if redirect = 'mentee' then redirect := mentee_email; end if;
  tag := case when redirect is not null then '[%role%] ' else '' end;
  bookings_url := site||'/bookings'; sessions_url := site||'/dashboard?tab=sessions';
  dash_url := site||'/dashboard'; home_url := site;
  v_join_mentee := case when v_customer_token is not null then site||'/join/'||v_customer_token else null end;
  v_join_mentor := case when v_mentor_token is not null then site||'/join/'||v_mentor_token else null end;

  select * into d from booking_times_display(p_booking_id);
  when_mentee := to_char(d.customer_local, 'FMDay, FMMon DD YYYY, HH12:MI AM') || ' (' || d.customer_tz || ')';
  when_mentor := to_char(d.mentor_local,   'FMDay, FMMon DD YYYY, HH12:MI AM') || ' (' || d.mentor_tz   || ')';
  lbl := case when p_event in ('proposed','selected','counter','cancel_requested','reschedule_requested','reschedule_approved','reschedule_rejected') then 'Current ' else '' end;

  det := '<div style="border:1px solid #e8ecf4;border-radius:14px;overflow:hidden;margin-top:16px;">'
       ||'<div style="background:linear-gradient(135deg,#0a2240,#15375f);color:#fff;padding:11px 14px;font-weight:700;font-size:14px;">'||s_title||' &middot; '||coalesce(v_dur::text,'')||' min</div>'
       ||'<table style="width:100%;border-collapse:collapse;font-size:13px;">'
       ||email_row('Mentor', mentor_name)||email_row('Mentee', mentee_name)
       ||email_row(lbl||'mentee time', when_mentee)||email_row(lbl||'mentor time', when_mentor)
       ||case when v_amount is not null then email_row('Amount paid', to_char(round(v_amount,2),'FM999990.00')||' '||coalesce(v_cur,'')) else '' end
       ||email_row('Booking reference','#'||p_booking_id)
       ||'</table></div>';

  ml1:='View your session'; mu1:=bookings_url; ml2:=null; mu2:=null;
  rl1:='Open Sessions';     ru1:=sessions_url; rl2:=null; ru2:=null;

  if p_event = 'confirmed' then
    heading:='Your session is confirmed'; ld_m:='Your session is confirmed — details below.'; ld_r:='A session with '||mentee_name||' is confirmed.'; ld_a:='A session was confirmed.';
  elsif p_event = 'cancelled' then
    heading:='Session cancelled'; ld_m:='Your session has been cancelled — any refund/credit is shown below.'; ld_r:='Your session with '||mentee_name||' was cancelled.'; ld_a:='A session was cancelled.'; ml1:='Find a mentor'; mu1:=home_url;
  elsif p_event = 'rescheduled' then
    heading:='Session rescheduled'; ld_m:='Your session has moved to a new time — updated details below.'; ld_r:='Your session with '||mentee_name||' moved to a new time.'; ld_a:='A session was rescheduled.';
  elsif p_event = 'completed' then
    heading:='Session complete'; ld_m:='Thanks for using Immigroov — we''d love your feedback.'; ld_r:='Your session with '||mentee_name||' is complete.'; ld_a:='A session completed.'; ml1:='Leave a review'; mu1:=bookings_url;
  elsif p_event = 'proposed' then
    heading:='A new time was proposed'; ld_m:='Your mentor proposed a new time window — your current time has not changed yet. Pick a slot that works for you.'; ld_r:='You proposed a new time window — '||mentee_name||' can now pick a slot inside it.'; ld_a:='The mentor proposed a new time.';
    ml1:='Pick a new time'; mu1:=bookings_url; rl1:='View in console'; ru1:=sessions_url;
    select * into o from reschedule_offers where booking_id=p_booking_id and status='pending' and proposed_by='mentor' order by id desc limit 1;
    if o.range_start is not null then extra:='<div style="background:#fff2e8;border:1px solid #fb7321;border-radius:14px;padding:14px;margin-top:12px;font-size:13px;color:#0c1b33;"><b>Proposed window — '||to_char(o.offer_date,'FMDay, FMMon DD YYYY')||':</b><br>'||to_char(o.range_start at time zone d.customer_tz,'HH12:MI AM')||' &ndash; '||to_char(o.range_end at time zone d.customer_tz,'HH12:MI AM')||' ('||d.customer_tz||')</div>'; end if;
  elsif p_event = 'counter' then
    heading:='A different day was requested'; ld_m:='You asked for a different day — your mentor will propose times for it.'; ld_r:=mentee_name||' can''t make the proposed day and asked for another date. Please propose a time range for it.'; ld_a:='The mentee requested a different day.'; rl1:='Propose times'; ru1:=sessions_url;
    select * into o from reschedule_offers where booking_id=p_booking_id and status='pending' and proposed_by='user' order by id desc limit 1;
    if o.requested_date is not null then extra:='<div style="background:#eef3fb;border:1px solid #15375f;border-radius:14px;padding:14px;margin-top:12px;font-size:13px;color:#0c1b33;"><b>Requested day:</b> '||to_char(o.requested_date,'FMDay, FMMon DD YYYY')||'</div>'; end if;
  elsif p_event = 'cancel_requested' then
    heading:='Cancellation request'; ld_m:='Your cancellation request was sent to your mentor. If they don''t reply in time it is auto-approved (full refund). If they decline, you pay 50%.'; ld_r:=mentee_name||' requested to cancel this session. Approve = full refund; reject = they pay 50%. No reply auto-approves.'; ld_a:='Customer requested a cancellation.'; rl1:='Respond in console'; ru1:=sessions_url;
  elsif p_event = 'reschedule_requested' then
    heading:='Reschedule request'; ld_m:='Your reschedule request was sent to your mentor (auto-approved if they don''t reply in time).'; ld_r:=mentee_name||' requested to reschedule. Approve so they can pick a new time. No reply auto-approves.'; ld_a:='Customer requested a reschedule.'; rl1:='Respond in console'; ru1:=sessions_url;
  elsif p_event = 'reschedule_approved' then
    heading:='Reschedule approved'; ld_m:='Your reschedule was approved — pick a new time that works for you.'; ld_r:='You approved '||mentee_name||'''s reschedule — they will pick a new time.'; ld_a:='Reschedule request approved.'; ml1:='Pick a new time'; mu1:=bookings_url;
  elsif p_event = 'reschedule_rejected' then
    heading:='Reschedule declined'; ld_m:='Your mentor declined the reschedule. You can keep your session, or cancel it.'; ld_r:='You declined '||mentee_name||'''s reschedule — their original session stands.'; ld_a:='Reschedule request rejected.';
  elsif p_event = 'no_show' then
    heading:='Session marked as a no-show';
    if v_no_show_by = 'mentor' then
      ld_m:='Your mentor didn''t join. Choose what''s next: rebook the same mentor, rebook a different one, or get a full refund.'; ld_r:='You were recorded as not attending '||mentee_name||'''s session.'; ld_a:='Mentor no-show reported.';
      ml1:='Choose what''s next'; mu1:=bookings_url; rl1:='Open Sessions'; ru1:=sessions_url;
    else
      ld_m:='You were marked as a no-show for this session.'; ld_r:=mentee_name||' didn''t join. Offer a rebook, or close the session (you''re paid in full).'; ld_a:='Customer no-show reported.';
      ml1:='View your session'; mu1:=bookings_url; rl1:='Choose what''s next'; ru1:=sessions_url;
    end if;
  else return;
  end if;

  if p_event in ('confirmed','rescheduled') then
    if v_join_mentee is not null then ml1:='🎥 Join video call'; mu1:=v_join_mentee; ml2:='Manage booking'; mu2:=bookings_url; end if;
    if v_join_mentor is not null then rl1:='🎥 Join video call'; ru1:=v_join_mentor; rl2:='Manage in console'; ru2:=sessions_url; end if;
  end if;

  if p_event in ('confirmed','rescheduled','cancelled') then
    ics_mentee_b64 := translate(encode(convert_to(coalesce(booking_ics(p_booking_id, p_event='cancelled', case when p_event<>'cancelled' then v_join_mentee else null end),''),'UTF8'),'base64'), E'\n\r', '');
    ics_mentor_b64 := translate(encode(convert_to(coalesce(booking_ics(p_booking_id, p_event='cancelled', case when p_event<>'cancelled' then v_join_mentor else null end),''),'UTF8'),'base64'), E'\n\r', '');
    if ics_mentee_b64 is not null and ics_mentee_b64 <> '' then att_mentee := jsonb_build_array(jsonb_build_object('filename','invite.ics','content',ics_mentee_b64)); end if;
    if ics_mentor_b64 is not null and ics_mentor_b64 <> '' then att_mentor := jsonb_build_array(jsonb_build_object('filename','invite.ics','content',ics_mentor_b64)); end if;
  end if;

  to_mentee := coalesce(redirect, mentee_email);
  to_mentor := coalesce(redirect, mentor_email);
  to_admin  := coalesce(redirect, nullif(admin_email,''));

  if to_mentee is not null then
    msgs := msgs || (jsonb_build_object('to', to_mentee, 'subject', replace(tag,'%role%','MENTEE')||'Immigroov: '||heading,
      'html', email_layout(heading, '<p style="font-size:14px;color:#0c1b33;margin:0 0 6px;">Hi '||mentee_name||',</p><p style="font-size:14px;color:#0c1b33;margin:0;">'||ld_m||'</p>'||det||extra, ml1, mu1, ml2, mu2))
      || (case when att_mentee is not null then jsonb_build_object('attachments', att_mentee) else '{}'::jsonb end));
  end if;
  if to_mentor is not null then
    msgs := msgs || (jsonb_build_object('to', to_mentor, 'subject', replace(tag,'%role%','MENTOR')||'Immigroov: '||heading,
      'html', email_layout(heading, '<p style="font-size:14px;color:#0c1b33;margin:0 0 6px;">Hi '||mentor_name||',</p><p style="font-size:14px;color:#0c1b33;margin:0;">'||ld_r||'</p>'||det||extra, rl1, ru1, rl2, ru2))
      || (case when att_mentor is not null then jsonb_build_object('attachments', att_mentor) else '{}'::jsonb end));
  end if;
  if to_admin is not null then
    msgs := msgs || jsonb_build_object('to', to_admin, 'subject', replace(tag,'%role%','ADMIN')||'Immigroov ['||p_event||']: '||s_title,
      'html', email_layout(heading, '<p style="font-size:14px;color:#0c1b33;margin:0;">Admin notification &middot; booking #'||p_booking_id||'</p><p style="font-size:14px;color:#0c1b33;margin:6px 0 0;">'||ld_a||'</p>'||det||extra, 'Open console', dash_url));
  end if;

  perform app_send_email_batch(msgs);
end; $$;

-- ---------------------------------------------------------------------------
-- 3. 24h/1h reminder emails (0012_jitsi_meeting_link.sql) — swap the raw
--    meeting_url for the customer's secure join link. Still customer-only,
--    matching existing behavior (see note at top of this file).
-- ---------------------------------------------------------------------------

drop function if exists process_due_reminders(text, interval, interval);
drop function if exists due_reminders(text, interval, interval);

create function due_reminders(p_kind text, p_lo interval, p_hi interval)
returns table (
  booking_id  bigint,
  email       text,
  first_name  text,
  slot_utc    timestamptz,
  customer_tz text,
  customer_join_token uuid
)
language sql stable as $$
  select b.id, u.email, u.first_name, b.slot_time,
         coalesce(b.customer_timezone, u.timezone, 'UTC'), b.customer_join_token
  from bookings b
  join users u on u.id = b.user_id
  where b.status in ('confirmed', 'rescheduled')
    and b.slot_time between now() + p_lo and now() + p_hi
    and not exists (
      select 1 from booking_reminders r
      where r.booking_id = b.id and r.kind = p_kind
    );
$$;

create function process_due_reminders(p_kind text, p_lo interval, p_hi interval)
returns int
language plpgsql security definer set search_path = public as $$
declare
  r     record;
  n     int := 0;
  site  text;
  label text := case p_kind when '1h' then 'in about an hour' else 'in 24 hours' end;
  link  text;
begin
  select value into site from platform_settings where key = 'site_url';
  site := coalesce(nullif(site,''), 'https://immigroov.vercel.app');
  for r in select * from due_reminders(p_kind, p_lo, p_hi) loop
    link := case when r.customer_join_token is not null
                 then '<p>Join: <a href="' || site || '/join/' || r.customer_join_token || '">' || site || '/join/' || r.customer_join_token || '</a></p>'
                 else '' end;
    perform app_send_email(
      r.email, 'Reminder: your Immigroov session is ' || label,
      '<p>Hi ' || coalesce(r.first_name,'') || ', your session is ' || label || ' — <b>' ||
      to_char(r.slot_utc at time zone r.customer_tz, 'FMDay, FMMonth DD at HH12:MI AM') ||
      ' (' || r.customer_tz || ')</b>.</p>' || link);
    insert into booking_reminders (booking_id, kind) values (r.booking_id, p_kind)
      on conflict (booking_id, kind) do nothing;
    n := n + 1;
  end loop;
  return n;
end;
$$;
