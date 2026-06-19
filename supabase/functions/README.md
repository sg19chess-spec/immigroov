# Immigroov Edge Functions

TypeScript/Deno functions that replace the old AWS Lambda layer. The frontend
talks to Supabase directly for plain CRUD/RPC; these functions handle anything
that touches **secrets or the outside world** (Stripe, email).

## Functions

| Function | What it does | Auth | JWT verify |
|---|---|---|---|
| **book-and-pay** | Resolves regional price → applies discount → adds Immigroov fee → creates a pending booking (user or guest) → creates a Stripe PaymentIntent → returns `client_secret`. | session (anon ok) | yes |
| **stripe-webhook** | Stripe → us. Source of truth for payment status: marks `customer_payments` paid/failed/refunded, confirms the booking, emails the customer. | Stripe signature | **no** (`--no-verify-jwt`) |
| **cancel-and-refund** | Cancels via `cancel_booking()` (RLS-authorized), then refunds the Stripe payment if one was captured. | participant | yes |
| **send-reminders** | Cron-invoked. Emails confirmed bookings starting in ~24h / ~1h, idempotently. | service role / cron | no |
| **process-payout** | Admin. Stripe Connect transfer of the mentor's share for a completed booking; records `mentor_payouts`. | admin | yes |
| **review-verification** | Admin. Approve/reject a mentor verification doc; flips `users.is_verified` when all clear. | admin | yes |

## Money model (book-and-pay)

```
customer pays = (offer_price ?? base_price) * (1 - discount%)  +  immigroov_price
mentor gets   = (offer_price ?? base_price) * (1 - discount%)     [paid out later]
Immigroov keeps = immigroov_price
```
The mentor's share is stored in the PaymentIntent metadata (`mentor_price`) so
`process-payout` knows exactly what to transfer.

## Required secrets

Set once with the CLI (auto-injected ones are already present):

```bash
supabase secrets set STRIPE_SECRET_KEY=sk_test_xxx
supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxx
supabase secrets set RESEND_API_KEY=re_xxx
supabase secrets set FROM_EMAIL="Immigroov <noreply@yourdomain.com>"
```
(`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` are provided by the runtime.)

## Deploy

```bash
supabase functions deploy book-and-pay
supabase functions deploy cancel-and-refund
supabase functions deploy process-payout
supabase functions deploy review-verification
supabase functions deploy send-reminders
supabase functions deploy stripe-webhook --no-verify-jwt   # Stripe can't send a Supabase JWT
```

Then in the Stripe Dashboard add a webhook endpoint pointing at the deployed
`stripe-webhook` URL, subscribing to `payment_intent.succeeded`,
`payment_intent.payment_failed`, `charge.refunded`.

## Outstanding DB dependencies (not yet in migrations)

- **`mentors.stripe_account_id`** — needed by `process-payout` for Stripe Connect transfers.
- **`booking_reminders` table + `due_reminders()` RPC + pg_cron schedule** — needed by `send-reminders` (the Phase 5 reminder migration).

Ask and I'll add both as migration `0008`.
