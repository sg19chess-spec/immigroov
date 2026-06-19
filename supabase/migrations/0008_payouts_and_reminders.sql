-- =============================================================================
-- Immigroov — Phase 5/7 DB deps: mentor Stripe account, reminders engine
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Stripe Connect account for mentor payouts (used by process-payout fn)
-- -----------------------------------------------------------------------------
alter table mentors add column if not exists stripe_account_id varchar(255);

-- -----------------------------------------------------------------------------
-- 2) Reminders bookkeeping (idempotency: never send the same reminder twice)
-- -----------------------------------------------------------------------------
create table if not exists booking_reminders (
  id         bigint generated always as identity primary key,
  booking_id bigint not null references bookings(id) on delete cascade,
  kind       varchar(10) not null,         -- '24h' | '1h'
  sent_at    timestamptz not null default now(),
  unique (booking_id, kind)
);
create index if not exists idx_booking_reminders_booking on booking_reminders(booking_id);

alter table booking_reminders enable row level security;  -- backend-only (no policies)

-- -----------------------------------------------------------------------------
-- 3) due_reminders(): confirmed bookings starting inside a window that haven't
--    been reminded yet, already localized to the customer's timezone.
-- -----------------------------------------------------------------------------
create or replace function due_reminders(p_kind text, p_lo interval, p_hi interval)
returns table (
  booking_id  bigint,
  email       text,
  first_name  text,
  slot_utc    timestamptz,
  customer_tz text
)
language sql stable as $$
  select b.id, u.email, u.first_name, b.slot_time,
         coalesce(b.customer_timezone, u.timezone, 'UTC')
  from bookings b
  join users u on u.id = b.user_id
  where b.status = 'confirmed'
    and b.slot_time between now() + p_lo and now() + p_hi
    and not exists (
      select 1 from booking_reminders r
      where r.booking_id = b.id and r.kind = p_kind
    );
$$;

-- -----------------------------------------------------------------------------
-- 4) Scheduling (run AFTER the send-reminders function is deployed)
--    pg_cron fires the Edge Function via pg_net. The service-role key is read
--    from Vault so it never lives in plaintext SQL.
-- -----------------------------------------------------------------------------
create extension if not exists pg_cron;
create extension if not exists pg_net;

-- One-time setup (run these in the SQL editor once the function is live):
--
--   -- store secrets in Vault
--   select vault.create_secret('https://atkulcfyaqcivzxteela.supabase.co', 'project_url');
--   select vault.create_secret('<SERVICE_ROLE_KEY>', 'service_role_key');
--
--   -- 24h reminders: every 15 min
--   select cron.schedule('reminders-24h', '*/15 * * * *', $$
--     select net.http_post(
--       url     := (select decrypted_secret from vault.decrypted_secrets where name='project_url')
--                  || '/functions/v1/send-reminders',
--       headers := jsonb_build_object(
--         'Content-Type','application/json',
--         'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='service_role_key')),
--       body    := jsonb_build_object('kind','24h')
--     );
--   $$);
--
--   -- 1h reminders: every 5 min
--   select cron.schedule('reminders-1h', '*/5 * * * *', $$
--     select net.http_post(
--       url     := (select decrypted_secret from vault.decrypted_secrets where name='project_url')
--                  || '/functions/v1/send-reminders',
--       headers := jsonb_build_object(
--         'Content-Type','application/json',
--         'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='service_role_key')),
--       body    := jsonb_build_object('kind','1h')
--     );
--   $$);
