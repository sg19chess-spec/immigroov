# Immigroov — Feature Roadmap

Source: `new features implementation.md` (product owner, 2026-06-26). Build bare-minimum
working versions, no over-engineering. Status legend: ☐ todo · ◐ in progress · ☑ done.

## 1. Admin dashboard enhancements
The admin view (`/admin`, `web/components/AdminManager.tsx`, `admin_*` RPCs) gains:

**Filters** (on the Activity list) — ☑ DONE (`0052` + AdminManager filter bar):
- ☑ Mentor name · ☑ Customer email · ☑ Mentor email · ☑ Date range · ☑ Session status
- ☑ Country name → **destination country, derived from the mentor** (per owner: booking a mentor implies their country, so the customer isn't asked). `mentors.country` set in the mentor console; `admin_bookings` returns `coalesce(bookings.target_country, mentors.country)`.

**New views:**
- ☑ **Mentor Payout View** — `admin_payouts()` + Payouts tab. Per booking: gross, fee % (service `platform_fee` else `immigroov_commission_pct`=15), deduction, net payout, payout status. Verified.
- ☐ **Referral Tracking View** — uses existing `referral_links` (referrer_mentor_id → referred_user_id, type). Bare-minimum: who referred whom + date + type. **Note for owner:** customer→customer referrals and referral *credits/rewards* are NOT modeled yet — needs schema additions; decide scope before building.

## 2. Scheduling + payment integration tests
- ☐ Booked → payment captured
- ☐ Customer cancel → refund
- ☐ Mentor cancel → penalty (25%) — **TODO: penalty logic under review; make the % a configurable constant, do not finalize**
- ☐ Reschedule → payment hold/adjust
Note: payments are currently MOCK (ledger only), so tests assert ledger/state, not real charges.

## 3. Webinar feature (feasibility + basic)
**Feasibility: YES, as a separate model — do NOT reuse `bookings`** (its GiST no-overlap
constraint, payouts, reschedule/no-show machinery are all 1:1-specific and would fight a
1:many event). Clean shape:
- `webinars` (mentor_id, title, description, start_time, duration, capacity, visibility
  public|invite, room_url, status) + `webinar_registrations` (webinar_id, email/user, registered_at).
- RPCs: `create_webinar`, `register_webinar`, `list_webinars`, join = open room_url at start.
- **Video option:** reuse **Jitsi** (already integrated, free, room URL per webinar) for the MVP —
  fine for small/marketing webinars. Move to **Daily.co** (simplest API, recording, scale,
  registration) only if recording/large audiences/streaming are needed. Zoom Webinar SDK = most
  feature-complete but heaviest + paid; not recommended for MVP.
- Scheduling: a webinar is a single scheduled event (not the slot grid); reuse the Resend +
  pg_cron reminder infra for "starts soon" emails. Payment-free for MVP.
- Effort: **small–medium.** Scaffold model + 3 RPCs + a public webinars page + mentor create form.

## 4. In-app chat (assessment first)
**Feasibility: YES with the current stack; no chat SaaS needed.**
- **Realtime:** use **Supabase Realtime** (already available) + a `messages` table
  (booking_id/thread, sender, body, read_at) with RLS limiting rows to the two parties. Live chat,
  no third party.
- **Masking:** never expose email/phone — reference user ids only. **Main work = a redaction
  filter** that strips phone numbers / emails / URLs from message bodies (regex) so users can't
  swap contact info. This is the key risk to get right.
- **Offline → email:** reuse **Resend + pg_cron** — if the recipient hasn't read within N min,
  send a "you have a new message" email with a link to the thread (not the message content, to stay masked).
- **WhatsApp bridge:** needs **WhatsApp Business API (Meta) or Twilio Conversations** — paid,
  number provisioning, template approval, and a proxy to keep numbers masked. **Recommend deferring**
  to a later phase; ship in-app + email first.
- **Risks:** PII leakage (redaction + ToS), moderation/abuse, message retention/privacy, notification spam.
- Effort: **medium** for in-app + email; WhatsApp is a separate larger phase.

---
**Execution order (per owner):** start with Admin filters + payout view, then referral view, then features 2 → 3 → 4.
