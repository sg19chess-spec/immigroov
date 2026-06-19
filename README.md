# Immigroov — Mentor Marketplace (Supabase Schema)

PostgreSQL schema for the Immigroov mentor marketplace, packaged as Supabase
migrations.

## Structure

```
supabase/
  migrations/
    0001_initial_schema.sql   -- enums, tables, FKs, indexes
    0002_views_and_triggers.sql -- mentor_earnings_summary + helpers
    0003_rls_policies.sql     -- Row Level Security
  seed.sql                    -- optional sample data
```

## Apply

**Option A — Supabase CLI (recommended)**
```bash
supabase init          # if not already a project
supabase link --project-ref <your-ref>
supabase db push       # applies migrations in order
```

**Option B — SQL editor / psql**
Run `0001`, `0002`, `0003` in order against your database.

## What changed vs. the source DBML

| Change | Why |
|---|---|
| **Added `service_pricing.immigroov_price`** | The requested "Immigroov price" — the platform fee charged on top of the mentor's price, per service + country. Mentor payout excludes it. |
| **Added `platform_settings`** | Global defaults (e.g. `immigroov_commission_pct`) used when a per-row `immigroov_price` isn't set. |
| Dropped `Ref: social_links.id < address.created_at` | Designer-tool artifact — not a valid relationship (links a PK to a timestamp). |
| Status `varchar` → **enums** | `booking_status`, `payment_status`, `payout_status`, etc. — values are fully specified in the doc, so enums enforce them. |
| `serial` → `bigint generated always as identity`; `timestamp` → `timestamptz` | Supabase / Postgres conventions. |
| Added `users.auth_id uuid → auth.users` | Bridges profiles to Supabase Auth. Keep `password_hash` only if NOT using Supabase Auth. |
| Added FK indexes, unique constraints (`reviews.booking_id`, `service_pricing(service_id, country_code)`), `ON DELETE` rules | Performance + integrity. |
| Enabled **RLS** on all tables | Required for Supabase's public API. Your Lambda backend uses the `service_role` key, which bypasses RLS. |

## Immigroov pricing model

For a booking, the customer pays:

```
customer_total = coalesce(offer_price, base_price) + immigroov_price   (minus any discount)
mentor_payout  = coalesce(offer_price, base_price)                     (immigroov keeps immigroov_price)
```

If `service_pricing.immigroov_price` is NULL, compute the fee from
`platform_settings.immigroov_commission_pct` in your backend.

## Earnings view

`mentor_earnings_summary` (materialized) exposes `total_earnings`,
`payout_pending`, `yet_to_service` per mentor. Refresh via:

```sql
select refresh_mentor_earnings_summary();
```

Schedule it with `pg_cron` (enable the extension in Supabase) — example schedule
is commented at the bottom of `0002`.

## Notes
- The backend (AWS Lambda) should connect with the `service_role` key for trusted
  writes (payments, payouts, verification approvals) — these have no anon policies.
- Enable `pg_cron` and `pgcrypto` extensions in the Supabase dashboard
  (`gen_random_uuid()` is available by default).
```
