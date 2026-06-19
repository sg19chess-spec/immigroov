-- =============================================================================
-- Immigroov — LIVE email via pg_net + Vault (no Edge Function deploy needed)
-- =============================================================================
-- Prereq (run once in SQL Editor, with your ROTATED key):
--   select vault.create_secret('re_xxx', 'resend_api_key');
--   select vault.create_secret('Immigroov <onboarding@resend.dev>', 'resend_from');
--
-- Sends:
--   * booking confirmation  (trigger when a booking becomes 'confirmed')
--   * booking cancellation   (trigger when a booking becomes 'cancelled')
--   * 24h / 1h reminders     (pg_cron -> process_due_reminders)
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Generic sender: reads the Resend key from Vault, posts via pg_net (async).
-- Returns NULL (and skips) if the key isn't configured yet.
-- -----------------------------------------------------------------------------
create or replace function app_send_email(p_to text, p_subject text, p_html text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_key  text;
  v_from text;
  v_req  bigint;
begin
  select decrypted_secret into v_key  from vault.decrypted_secrets where name = 'resend_api_key';
  if v_key is null or p_to is null then
    raise notice 'app_send_email: no resend_api_key in Vault (or no recipient) — skipping';
    return null;
  end if;
  select decrypted_secret into v_from from vault.decrypted_secrets where name = 'resend_from';
  v_from := coalesce(v_from, 'Immigroov <onboarding@resend.dev>');

  select net.http_post(
    url     := 'https://api.resend.com/emails',
    headers := jsonb_build_object(
                 'Authorization', 'Bearer ' || v_key,
                 'Content-Type', 'application/json'),
    body    := jsonb_build_object('from', v_from, 'to', p_to, 'subject', p_subject, 'html', p_html)
  ) into v_req;
  return v_req;
end;
$$;

-- -----------------------------------------------------------------------------
-- Booking confirmation / cancellation emails (status-change trigger)
-- -----------------------------------------------------------------------------
create or replace function trg_booking_status_email()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_email text;
  v_first text;
  d       record;
  when_txt text;
begin
  select u.email, u.first_name into v_email, v_first from users u where u.id = new.user_id;
  if v_email is null then return new; end if;

  select * into d from booking_times_display(new.id);
  when_txt := to_char(d.customer_local, 'FMDay, FMMonth DD YYYY at HH12:MI AM')
              || ' (' || d.customer_tz || ')';

  if new.status = 'confirmed' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
    perform app_send_email(
      v_email, 'Your Immigroov session is confirmed',
      '<p>Hi ' || coalesce(v_first, '') || ',</p>' ||
      '<p>Your session is confirmed for <b>' || when_txt || '</b>.</p>');
  elsif new.status = 'cancelled' and tg_op = 'UPDATE' and old.status is distinct from new.status then
    perform app_send_email(
      v_email, 'Your Immigroov session was cancelled',
      '<p>Hi ' || coalesce(v_first, '') || ',</p>' ||
      '<p>Your session scheduled for ' || when_txt || ' has been cancelled.</p>');
  end if;
  return new;
end;
$$;

drop trigger if exists booking_status_email on bookings;
create trigger booking_status_email
  after insert or update of status on bookings
  for each row execute function trg_booking_status_email();

-- -----------------------------------------------------------------------------
-- Reminder runner (called by pg_cron) — sends + records, idempotently.
-- -----------------------------------------------------------------------------
create or replace function process_due_reminders(p_kind text, p_lo interval, p_hi interval)
returns int
language plpgsql security definer set search_path = public as $$
declare
  r     record;
  n     int := 0;
  label text := case p_kind when '1h' then 'in about an hour' else 'in 24 hours' end;
begin
  for r in select * from due_reminders(p_kind, p_lo, p_hi) loop
    perform app_send_email(
      r.email, 'Reminder: your Immigroov session is ' || label,
      '<p>Hi ' || coalesce(r.first_name, '') || ', your session is ' || label || ' — <b>' ||
      to_char(r.slot_utc at time zone r.customer_tz, 'FMDay, FMMonth DD at HH12:MI AM') ||
      ' (' || r.customer_tz || ')</b>.</p>');
    insert into booking_reminders (booking_id, kind) values (r.booking_id, p_kind)
      on conflict (booking_id, kind) do nothing;
    n := n + 1;
  end loop;
  return n;
end;
$$;

-- -----------------------------------------------------------------------------
-- Schedule reminders (pure DB — no Edge Function needed). Idempotent.
-- -----------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from cron.job where jobname = 'reminders-24h') then perform cron.unschedule('reminders-24h'); end if;
  if exists (select 1 from cron.job where jobname = 'reminders-1h')  then perform cron.unschedule('reminders-1h');  end if;
end $$;

select cron.schedule('reminders-24h', '*/15 * * * *',
  $$ select process_due_reminders('24h', '23 hours'::interval, '25 hours'::interval) $$);
select cron.schedule('reminders-1h', '*/5 * * * *',
  $$ select process_due_reminders('1h', '30 minutes'::interval, '90 minutes'::interval) $$);
