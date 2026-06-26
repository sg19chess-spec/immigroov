-- Chat "new message" email: honour test_redirect_email (when 'mentee', every copy goes to the
-- booking's mentee inbox for testing) and name the mentor + tag the intended recipient role.
create or replace function notify_unread_messages()
returns integer language plpgsql security definer set search_path = public as $$
declare r record; n int := 0; v_site text; v_redirect text;
        v_role text; v_to text; v_link text; v_subject text; v_body text;
begin
  select value into v_site from platform_settings where key = 'site_url';
  v_site := coalesce(nullif(v_site,''), 'https://immigroov.vercel.app');
  select value into v_redirect from platform_settings where key = 'test_redirect_email';
  v_redirect := nullif(v_redirect,'');

  for r in
    select distinct on (m.booking_id) m.booking_id, m.sender_role,
           coalesce(b.guest_email, cu.email) as mentee_email, mu.email as mentor_email,
           coalesce(nullif(mu.first_name,''),'your mentor') as mentor_name,
           coalesce(nullif(cu.first_name,''), b.guest_email, cu.email) as mentee_name
    from messages m
    join bookings b on b.id = m.booking_id
    join users cu on cu.id = b.user_id
    join mentors mm on mm.id = b.mentor_id
    join users mu on mu.id = mm.user_id
    where m.read_at is null and m.notified_at is null and m.created_at < now() - interval '5 minutes'
    order by m.booking_id, m.id
  loop
    if r.sender_role = 'customer' then
      -- recipient is the MENTOR
      v_role := 'MENTOR'; v_to := r.mentor_email; v_link := v_site||'/dashboard?tab=sessions';
      v_subject := 'New message from your mentee';
      v_body := '<p>Hi '||r.mentor_name||',</p><p>You have a new message from '||r.mentee_name||
                ' about your Immigroov session (mentor: '||r.mentor_name||').</p>';
    else
      -- recipient is the MENTEE
      v_role := 'MENTEE'; v_to := r.mentee_email; v_link := v_site||'/bookings';
      v_subject := 'New message from your mentor';
      v_body := '<p>Hi '||r.mentee_name||',</p><p>You have a new message from your mentor '||r.mentor_name||
                ' about your Immigroov session.</p>';
    end if;

    -- testing: redirect every copy to the mentee inbox and tag who it was meant for
    if v_redirect = 'mentee' then
      v_subject := '['||v_role||'] '||v_subject;
      v_to := r.mentee_email;
    elsif v_redirect is not null then
      v_subject := '['||v_role||'] '||v_subject;
      v_to := v_redirect;
    end if;

    if v_to is not null then
      perform app_send_email(v_to, v_subject,
        v_body||'<p>Open the app to read and reply: <a href="'||v_link||'">'||v_link||'</a></p>'||
        '<p style="color:#888;font-size:12px">For your privacy, messages stay inside Immigroov — contact details are hidden.</p>');
    end if;
    update messages set notified_at = now() where booking_id = r.booking_id and read_at is null;
    n := n + 1;
  end loop;
  return n;
end; $$;
