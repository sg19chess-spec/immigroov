# Booking lifecycle v2 — Phase 1 plan (cancel + reschedule)

Source spec: [booking-flow-overview.md](./booking-flow-overview.md) + [booking-flow.html](./booking-flow.html).
Confirmed decisions: **≥24h before session = FREE**; <24h = LATE; <2h = BUFFER (blocked).
Payments are mock → penalties/refunds/credits are **recorded as amounts** in `booking_ledger`, not charged.

## Deadline states (migration 0040 — DONE)
`booking_deadline_state(slot)` → `free` (≥24h) · `late` (<24h) · `buffer` (<2h).
`response_window(slot)` → `MIN(now+48h, slot−2h)`.

## Cancel flow
**Customer cancels**
- `free` → cancel now, no penalty, **refund full** (records refund).
- `late` → create a `cancel` request to the mentor (respond_by = response window). Booking stays confirmed until resolved.
  - mentor **approves** / no reply (auto) → cancelled, refund full, no penalty.
  - mentor **rejects** → customer **charged 50%**, booking cancelled (refund = remaining 50%).
- `buffer` → blocked ("too close — would be a no-show").

**Mentor cancels**
- `free` → cancel now, no penalty, refund customer full.
- `late` → cancel now, **25% penalty** on mentor payout, refund customer full (mentor sees warning).
- `buffer` → blocked.

## Reschedule flow (cap = 2 per booking; 3rd attempt → auto-cancel + full refund + 100% penalty on initiator)
**Customer reschedules**
- `free` → pick a new slot directly → auto-confirmed (`reschedule_count++`).
- `late` → request to mentor (response window). approve/no-reply → customer picks slot, auto-confirmed. reject → customer pays 50% to cancel, or keeps original.
- `buffer` → blocked.

**Mentor reschedules** (replaces the current "mentor re-confirm" step — drops step ③)
- Mentor proposes slots (existing range model). System flags `free` (no penalty) vs `late` (25% penalty warning before confirm).
- Customer **accepts** → auto-confirmed (emails + .ics). 
- Customer **no response** within window → original reinstated, no penalty.
- Customer **rejects**: within-deadline proposal → **credit only**; past-deadline proposal → **full cash refund** + penalty on mentor.

## Schema (0040 done; more per sub-phase)
- `bookings.reschedule_count` ✓
- `booking_ledger` (party, kind=penalty|refund|credit|charge, amount, pct, reason) ✓
- `booking_requests` (kind=cancel|reschedule, initiated_by, status, respond_by) ✓ — customer-initiated late requests + response-window resolution.

## RPCs to build
- `cancel_booking` (upgrade): deadline branching + ledger + late-customer → request.
- `respond_booking_request(req_id, accept)`: mentor approve/reject of customer cancel/reschedule.
- `customer_reschedule(booking, slot)` (free) / `request_reschedule` (late).
- Mentor reschedule: reuse `mentor_propose_reschedule` + `mentee_accept_reschedule` (drop mentor re-confirm), add credit/refund-on-reject + penalty flags.
- `resolve_expired_requests()` (cron, ~10 min): pending past `respond_by` → auto-approve (cancel/customer-reschedule) or reinstate-original (mentor proposal no customer reply).

## Frontend touchpoints
- Mentee **Your sessions** + mentor **Sessions**: show request/penalty state; "reschedule" → direct (free) vs request (late) with the 24h/penalty notice; show ledger outcome (refund/credit/penalty).

## Build order
1. ✅ Foundation (0040).
2. Cancel flow (RPCs + cron resolver + frontend).
3. Reschedule rework (RPCs + frontend).
4. Wire emails for the new request/penalty events.
Deferred to later phases: no-show (T+10) + choices + mentor strikes; packages + credit wallet + before/after-first-session refund nuance; 2h-buffer→no-show conversion.
