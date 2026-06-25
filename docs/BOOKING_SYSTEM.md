# Immigroov — Booking System (as-built)

> This document describes what the booking system **actually does today**, derived
> directly from the live database (function/trigger/constraint/cron definitions via
> `pg_get_functiondef`, `pg_trigger`, `pg_constraint`, `cron.job`) and the Next.js
> frontend (`.rpc(...)` call sites). It is not the design spec — for the intended
> design see `docs/spec/booking-flow-overview.md`. Where the implementation differs
> from the spec, this file reflects the implementation.
>
> Generated 2026-06-25 against project `atkulcfyaqcivzxteela`.

---

## 1. Stack & layering

- **DB:** Supabase Postgres. All business logic lives in `SECURITY DEFINER` SQL/PLpgSQL
  functions called from the client via PostgREST `rpc(...)`. Background work runs on
  `pg_cron`; outbound email uses `pg_net` → Resend (see §10).
- **Frontend:** Next.js App Router. The pages call RPCs directly with the Supabase JS
  client; there is no Node API layer for booking actions (only `/api/chat` and
  `/api/kb/*` exist server-side).
- **Money is mock.** No real charges. `customer_payments` rows are written with
  `status='paid'` and `stripe_payment_id='mock_<uuid>'`; `mentor_payouts` are
  `status='pending'`. All penalties/refunds/credits are **recorded as rows in
  `booking_ledger`**, never charged.

---

## 2. Data model (booking-relevant)

### `bookings`
`id, user_id, mentor_id, service_id, discount_id, slot_time timestamptz, status,
created_at, specific_availability_id uuid, slot_end timestamptz, slot_range tstzrange,
customer_timezone text, meeting_url text, guest_email text, mentor_confirmed_at timestamptz,
reschedule_count int, no_show_by text`

- **`status`** is enum `booking_status`: `pending, confirmed, rescheduled, cancelled, completed, no_show`.
  (`pending` is defined but the live creation path inserts `confirmed` directly — see §4.)
- **`no_show_by`** ∈ `{mentor, customer}` — who failed to attend (set by `flag_no_show`).
- **`reschedule_count`** — incremented on every successful reschedule; gate at `>= 2` (§7).

### Triggers on `bookings` (all fire automatically)
| Trigger | Function | Effect |
|---|---|---|
| `trg_bookings_set_slot_end` | `bookings_set_slot_end` | On insert/update, if `slot_end` is null derives it from `slot_time + services.duration`; backfills `customer_timezone` from the user. |
| `trg_set_meeting_url` | `set_meeting_url` | If `meeting_url` null and the service `type='video'`, generates a Jitsi URL `https://meet.jit.si/Immigroov-<uuid>`. |
| `trg_bookings_sync_slot_lock` | `bookings_sync_slot_lock` | Keeps `specific_availability.is_booked` in sync (true unless status is `cancelled`/`no_show`); frees the slot on delete or slot change. |
| `booking_status_email` | `trg_booking_status_email` | Sends lifecycle email on status transitions — see §10. |

### Overlap constraint
```
bookings_no_overlap = EXCLUDE USING gist (mentor_id WITH =, slot_range WITH &&)
  WHERE (status <> ALL (ARRAY['cancelled','no_show']) AND slot_range IS NOT NULL)
```
A mentor cannot have two non-cancelled bookings whose time ranges overlap. This is the
final guard; any RPC that lands an overlapping slot raises here.

### Supporting tables
- **`customer_payments`** (`booking_id, amount, currency, status, stripe_payment_id`) — what the mentee paid.
- **`mentor_payouts`** (`mentor_id, booking_id, amount, currency, status`) — mentor earning, `set_price × ppp_factor`.
- **`booking_ledger`** (`booking_id, party, kind, amount, pct, currency, reason`) — penalty/refund/credit/charge audit, written by `add_ledger` (§9).
- **`booking_requests`** (`booking_id, kind, initiated_by, status, respond_by, note, resolved_at`) — late cancel / late reschedule approval requests. `kind ∈ {cancel, reschedule}`, `status ∈ {pending, approved, rejected, auto_approved, withdrawn, completed}`.
- **`reschedule_offers`** (`booking_id, proposed_by, offer_date, range_start, range_end, requested_date, selected_time, status, was_late, respond_by`) — the mentor↔mentee reschedule negotiation. `proposed_by ∈ {mentor, user}`, `status ∈ {pending, mentee_selected, accepted, rejected, superseded, expired}`.
- **`mentors`** booking-relevant fields: `app_timezone, app_buffertime, app_minimum_notice, app_booking_window, cancel_notice_hours, no_show_strikes int, last_no_show_at timestamptz`.
- **`booking_reminders`** (`booking_id, kind`) — dedupe ledger for reminder/attend-check emails.
- **`mentor_cancellation_policy`** (`mentor_id, month_year, cancel_count`) — bumped on late mentor cancels.

---

## 3. Time & deadline helpers

```sql
booking_deadline_state(slot) =
   slot IS NULL                  -> 'free'
   slot - now() < 2 hours        -> 'buffer'
   slot - now() < 24 hours       -> 'late'
   else                          -> 'free'
```
```sql
response_window(slot) = least(now() + 48 hours, slot - 2 hours)
```
So: **≥24h before the session = `free`; 2–24h = `late` (needs approval / incurs penalty);
<2h = `buffer`.** The approval deadline for a request is `MIN(now+48h, slot−2h)`.

> The `buffer` state is enforced as a hard block **only** in `cancel_booking`,
> `customer_reschedule`, and `request_reschedule`. `mentor_propose_reschedule`,
> `mentee_accept_reschedule`, and `mentee_request_other_date` do **not** check it (though an
> offer created under 2h has its `respond_by` in the past and is expired by the cron almost
> immediately). The state itself is just a label; "blocked" is whatever each function does
> with it.

---

## 4. Creating a booking

The mentor profile page (`app/mentor/[id]/page.tsx`) calls **`book_session_guest`**
(the 10-arg PPP overload). Behaviour:

1. Validates a non-empty email containing `@`.
2. **`is_slot_available(mentor, service, slot)`** must be true (else raises) — see §5.
3. Finds-or-creates a `users` row by lowercased email (`role='user'`, stores timezone).
4. Reads `services.set_price` / `set_currency` (must be active).
5. Inserts `bookings` with **`status='confirmed'`** directly (no pending/approval step),
   `customer_timezone`, `guest_email`. The triggers then set `slot_end`, `slot_range`,
   `meeting_url`, lock the slot, and fire the **confirmed** email.
6. Inserts `customer_payments` (mock paid) and `mentor_payouts` (`set_price × ppp_factor`, pending).
7. Inserts any `booking_question_answers`.

> Other creation functions exist in the DB (`book_session`, `book_and_pay_mock`,
> `demo_book_and_pay`, `create_guest_booking`) but the production booking UI uses
> `book_session_guest`.
>
> **UI preconditions (client-side, not enforced in the RPC):** the Book button requires the
> customer to have opened the Groovia AI chat at least once (`isEngaged()`) and checks the
> email contains `@` before calling the RPC. These are front-end gates only — the RPC itself
> can be called without them.

---

## 5. Availability

**`get_available_slots(mentor, service, from_date, to_date)`** (used by the profile page,
reschedule pickers, and `is_slot_available`):

- Loads the mentor's `app_timezone`, `app_buffertime`, `app_minimum_notice`,
  `app_booking_window` and the service duration.
- For each day: skips blackout dates; if the day has any `specific_availability`
  override it uses those windows, otherwise the matching `weekly_availability` window.
- Steps through each window in **service-duration increments** (slots are back-to-back,
  no gap), emitting a slot only if:
  - `start ≥ now + minimum_notice`, and
  - `start ≤ now + booking_window`, and
  - it does not collide with any existing non-cancelled/non-no_show booking, **padded by
    `app_buffertime` on both sides**.

**`is_slot_available(mentor, service, slot)`** = the slot exactly matches a `slot_start`
returned by `get_available_slots` for `[slot_date−1, slot_date+1]`.

---

## 6. Cancellation

Both the mentee page and the mentor console call **`cancel_booking(booking_id, cancelled_by)`**
(`cancelled_by` defaults to `'user'`; the mentor console passes `'mentor'`).

Guards: not already `cancelled/completed/no_show`; `buffer` state (<2h) **always raises**
("contact the other party").

| Who | State | Result |
|---|---|---|
| **Mentor** | `free` (≥24h) | Booking → `cancelled`; customer **refund 100%**. |
| **Mentor** | `late` (<24h) | Booking → `cancelled`; customer **refund 100%** + **mentor penalty 25%** + `bump_mentor_cancellation`. |
| **Customer** | `free` (≥24h) | Booking → `cancelled`; customer **refund 100%**. |
| **Customer** | `late` (<24h) | Booking **stays confirmed**; inserts a `booking_requests(kind='cancel')` with `respond_by = response_window`, fires **`cancel_requested`** email. Resolution below. |

**`respond_booking_request(request_id, accept)`** — mentor (or the cron) resolves a pending request:
- **cancel + accept** → booking `cancelled`, customer **refund 100%** ("Late cancel approved").
- **cancel + reject** → booking `cancelled`, ledger records **charge 50%** + **refund 50%**
  (i.e. customer keeps half back, mentor side keeps half), request `rejected`. Fires `cancelled` email.
- **reschedule + accept** → request `approved`, fires **`reschedule_approved`** (customer may now pick a new time).
- **reschedule + reject** → request `rejected`, fires **`reschedule_rejected`** (customer keeps original or cancels).

---

## 7. Rescheduling

Reschedule cap is **2 successful reschedules**; the gate is `reschedule_count >= 2`, so the
**3rd attempt auto-cancels** via `force_autocancel` (full refund to customer; **100% penalty
on whoever initiated** the 3rd attempt).

### Customer-initiated
- **`customer_reschedule(booking_id, slot_time)`** — direct move. Guards: not terminal;
  if `reschedule_count >= 2` it **auto-cancels instead** (see intro); raises on `buffer`.
  If state is **not `free`**, a prior **approved/auto_approved**
  reschedule request must exist, otherwise it raises ("late reschedule needs mentor approval").
  Requires `is_slot_available`. On success: `slot_time` updated, `slot_end` recomputed,
  status → `rescheduled`, `reschedule_count+1`, reminders cleared, the approval request
  marked `completed`. (The `rescheduled` email fires from the trigger.)
- **`request_reschedule(booking_id)`** — used when late: withdraws prior pending requests,
  inserts `booking_requests(kind='reschedule', respond_by=response_window)`, fires
  **`reschedule_requested`**. Returns `-1` if the cap is already hit (and auto-cancels).

So the customer flow is: **≥24h → reschedule directly; <24h → request → mentor approves →
then reschedule directly.**

### Mentor-initiated (propose a window, mentee picks inside it)
- **`mentor_propose_reschedule(booking_id, date, start, end)`** — supersedes prior offers,
  inserts a `reschedule_offers(proposed_by='mentor', range, respond_by=response_window,
  was_late = (state='late'))`, fires **`proposed`**. Returns `-1` + auto-cancels if cap hit.
- **`mentee_accept_reschedule(offer_id, slot_time)`** — `slot_time` must be inside
  `[range_start, range_end)` and in the future. Sets offer `accepted`, moves the booking
  (`rescheduled`, `count+1`, reminders cleared). **There is no mentor re-confirmation step.**
  If the offer `was_late`, records **mentor penalty 25%**.
- **`mentee_request_other_date(booking_id, date)`** — mentee can only ask for a **different
  date** (not propose a time). Supersedes prior offers, inserts
  `reschedule_offers(proposed_by='user', requested_date)`, fires **`counter`**; the mentor
  then proposes times for that date.
- **`mentee_reject_reschedule(offer_id)`** — rejects the mentor's proposal. Booking →
  `cancelled`. If the offer `was_late`: customer **refund 100%** + **mentor penalty 25%**.
  Otherwise: customer **credit 100%** (for a future booking). Fires `cancelled` email.

> `mentee_accept_reschedule` validates the range, future time, **and `is_slot_available`**
> (added in `0048`); a colliding pick now raises a clear error instead of only tripping the
> `bookings_no_overlap` constraint.

### `force_autocancel(booking, initiator)`
Booking → `cancelled`; customer **refund 100%**; **100% penalty** on `initiator`
(`mentor` or `customer`); supersedes offers; fires `cancelled`.

---

## 8. No-show + mentor strikes

Report-based (there is no video-join presence signal).

- **`flag_no_show(booking_id, party)`** — the present party reports the other
  (`party ∈ {mentor, customer}`). Guards: status `confirmed/rescheduled`; **only allowed
  after `slot_time + 10 minutes`**. Sets status `no_show`, `no_show_by=party`, supersedes
  open offers/requests, fires **`no_show`** email (role-specific by who missed it).
  - Mentee page reports `'mentor'`; mentor console reports `'customer'`.

- **Mentor no-show → `resolve_mentor_no_show(booking_id, choice)`** (mentee chooses):
  | choice | effect |
  |---|---|
  | `rebook_same` | status → `confirmed` (penalty **waived**); mentee reschedules. |
  | `rebook_different` | `apply_mentor_strike` + customer **credit 100%**. |
  | `refund` | `apply_mentor_strike` + customer **refund 100%**. |

- **Customer no-show → `resolve_customer_no_show(booking_id, choice)`** (mentor chooses):
  | choice | effect |
  |---|---|
  | `accept_rebook` | status → `confirmed` (reschedule cycle). |
  | `reject` | status → `completed`; ledger records mentor **credit 100%** ("paid in full"). |

- **`apply_mentor_strike(mentor_id, booking_id)`** — strike ladder:
  - If `last_no_show_at` is null or older than **90 days**, strike count resets to 0 first.
  - Increment `mentors.no_show_strikes`, set `last_no_show_at = now()`.
  - **Strikes 1–2:** ledger penalty `0%` (warning; strike 2 notes an ops check-in).
  - **Strikes ≥3:** ledger **penalty 25%** of the mentor payout.

---

## 9. Ledger

**`add_ledger(booking, party, kind, amount, pct, reason)`** inserts a `booking_ledger`
row (`amount` rounded to 2dp, currency inherited from the latest `customer_payment`).
`party ∈ {customer, mentor}`, `kind ∈ {refund, credit, charge, penalty}`. Nothing is
actually moved — these rows are the record of what *would* be charged/refunded once real
payments are wired. The console reads them back as a `ledger_summary` string.

---

## 10. Emails

**`notify_booking_event(booking_id, event)`** builds role-specific HTML (separate
mentee / mentor / admin copy) and sends one batched Resend request via
`app_send_email_batch`. Handled events:
`confirmed, cancelled, rescheduled, completed, proposed, counter, cancel_requested,
reschedule_requested, reschedule_approved, reschedule_rejected, no_show`.
Confirmed/rescheduled include a Jitsi join button; confirmed/rescheduled/cancelled attach
an `.ics` invite.

Two send paths exist:
1. **Status-change trigger** `trg_booking_status_email` fires `confirmed` (on insert or
   status change), `rescheduled` (status or slot_time change), `cancelled`, `completed`.
2. **Explicit calls** inside RPCs for events that aren't status transitions
   (`cancel_requested`, `reschedule_requested/approved/rejected`, `proposed`, `counter`,
   `no_show`).

> **Cancelled email is single-sourced (fixed in `0048`).** The status trigger
> `trg_booking_status_email` is the only sender of the `cancelled` email. RPCs that cancel
> (`cancel_booking`, `respond_booking_request`, `mentee_reject_reschedule`,
> `force_autocancel`) just set `status='cancelled'` and let the trigger fire once.

> **Test redirect.** `platform_settings.test_redirect_email = 'mentee'` is currently ON, so
> all three copies (mentee/mentor/admin) are delivered to the booking's mentee address.
> Set it to `''` to send to real recipients.

---

## 11. Scheduled jobs (`pg_cron`)

| Job | Schedule | Function | What it does |
|---|---|---|---|
| `resolve-requests` | every 10 min | `resolve_expired_requests` | For pending `booking_requests` past `respond_by`: calls `respond_booking_request(id, true)` (**auto-approve**) and marks `auto_approved`. Expires mentor `reschedule_offers` past `respond_by` (`status='expired'`). |
| `attend-checks` | every 10 min | `send_attendance_checks` | For `confirmed/rescheduled`, not yet `mentor_confirmed_at`, starting within 60 min: emails the mentor "are you available?" (dedupe via `booking_reminders.kind='attend_check'`). |
| `auto-complete` | every 15 min | `mark_past_bookings_completed` | `confirmed/rescheduled` with `slot_end < now()` → `completed` (fires the completed email via trigger). |
| `reminders-24h` | every 15 min | `process_due_reminders('24h', 23h, 25h)` | Emails the mentee a ~24h-out reminder. |
| `reminders-1h` | every 5 min | `process_due_reminders('1h', 30m, 90m)` | Emails the mentee a ~1h-out reminder. |

> Note: `mentor_confirm_attendance(booking_id)` just stamps `mentor_confirmed_at=now()`.
> Nothing auto-cancels a session the mentor never confirms; the attend-check is an email
> nudge only. A confirmed session whose `slot_end` passes is simply auto-completed unless a
> no-show is reported first.

---

## 12. Frontend → RPC map

**Mentee — `app/bookings/page.tsx`** (loads `bookings_by_email`):
`cancel_booking`, `mentee_accept_reschedule`, `mentee_reject_reschedule`,
`mentee_request_other_date`, `customer_reschedule`, `request_reschedule`,
`flag_no_show('mentor')`, `resolve_mentor_no_show`, `get_available_slots`.

**Mentor — `components/SessionsManager.tsx`** (loads `mentor_sessions`):
`respond_booking_request`, `cancel_booking('mentor')`, `mentor_propose_reschedule`,
`mentor_confirm_attendance`, `flag_no_show('customer')`, `resolve_customer_no_show`,
`demo_set_cancel_notice`.

**Booking creation — `app/mentor/[id]/page.tsx`:** `get_available_slots`,
`demo_list_questions`, `book_session_guest`.

The read RPCs `bookings_by_email` / `mentor_sessions` join in the latest open
`reschedule_offer`, the latest `booking_request`, `reschedule_count`, `no_show_by`, and a
`ledger_summary` so the UI can render the current negotiation/penalty state.

---

## 13. Known caveats & not-yet-built

- **Auth.** The lifecycle RPCs are `SECURITY DEFINER` and are granted to `anon`/`authenticated`;
  they trust the caller and do **not** verify that the caller owns the booking or is the
  mentor. The `demo_*` and `kb_admin_*` RPCs likewise bypass auth. These must be gated
  before production.
- **No real payments** — ledger only (§1, §9).
- **Not implemented** (deferred): packages, a credit *wallet* (credits are recorded in the
  ledger but not spendable), before/after-first-session refund nuance, and automatic
  `buffer → no_show` conversion (no-show is report-based instead).
