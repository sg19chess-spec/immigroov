# Immigroov — Feature Roadmap

Source: `new features implementation.md` (product owner, 2026-06-26). Build bare-minimum
working versions, no over-engineering. Status legend: ☐ todo · ◐ in progress · ☑ done.

## 1. Admin dashboard enhancements
The admin view (`/admin`, `web/components/AdminManager.tsx`, `admin_*` RPCs) gains:

**Filters** (on the Activity list) — ☑ DONE (`0052` + AdminManager filter bar):
- ☑ Mentor name · ☑ Customer email · ☑ Mentor email · ☑ Date range · ☑ Session status
- ☑ Country name → **target immigration country** (per owner). New `bookings.target_country`, captured by an optional selector in the booking form; admin filters on it.

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
- ☐ Feasibility assessment against current stack (one-to-many sessions vs current 1:1 bookings).
- ☐ If feasible: scaffold webinar model (create / register / join).
- ☐ Recommend the simplest video option (Daily.co / Whereby / Zoom SDK) — current 1:1 uses Jitsi links.

## 4. In-app chat (assessment first)
- ☐ Mentor ↔ customer chat, fully masked (no personal phone/email exposed).
- ☐ Offline mentor → email notification OR WhatsApp bridge.
- ☐ Post-session follow-up without sharing personal details.
- ☐ Assessment: build effort, services/libraries, risks (masking, WhatsApp Business API, moderation, storage).

---
**Execution order (per owner):** start with Admin filters + payout view, then referral view, then features 2 → 3 → 4.
