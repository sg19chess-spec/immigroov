# Immigroov — Booking Flowcharts (as-built)

> These charts mirror the **live** functions documented in
> [`BOOKING_SYSTEM.md`](BOOKING_SYSTEM.md) (verified against the database on
> 2026-06-25). Every branch corresponds to a real code path; nothing here is
> aspirational. Each diagram lists the functions it covers underneath it.
>
> Deadline states come from `booking_deadline_state(slot)`:
> **≥24h before = free · 2–24h before = late · under 2h = buffer (blocked)**.
> The response/approval window is `response_window(slot) = MIN(now+48h, slot−2h)`.
>
> **Rendered SVGs** live in [`flowcharts/`](flowcharts/) (regenerate from the `.mmd`
> sources with `mmdc -i <name>.mmd -o <name>.svg -c flowcharts/theme.json`). Each section
> below shows the image plus its source.

---

## 1. Booking confirmation

![Booking confirmation flow](flowcharts/1-confirmation.svg)

```mermaid
flowchart TD
  A(["Customer picks mentor + service + slot,<br/>enters name + email"]) --> B{"Valid email?"}
  B -- no --> Bx[/"Error: a valid email is required"/]
  B -- yes --> C{"is_slot_available?"}
  C -- no --> Cx[/"Error: that time is not available"/]
  C -- yes --> D["Find or create user by email"]
  D --> E["Read active service price<br/>Insert booking (status = confirmed)"]
  E --> F["Triggers fire automatically:<br/>• set slot_end (= slot + duration)<br/>• set meeting_url (Jitsi, if video service)<br/>• lock specific_availability slot<br/>• status email"]
  F --> G["Insert customer_payments (mock 'paid')<br/>Insert mentor_payouts (price x ppp, 'pending')<br/>Save intake question answers"]
  G --> H(["CONFIRMED<br/>Confirmation email + .ics to mentee / mentor / admin"])
```

**Covers:** `book_session_guest` → triggers `bookings_set_slot_end`, `set_meeting_url`,
`bookings_sync_slot_lock`, `trg_booking_status_email('confirmed')`. Booking is
**confirmed immediately on payment** — there is no separate mentor "accept" step.

---

## 2. Cancellation

![Cancellation flow](flowcharts/2-cancellation.svg)

```mermaid
flowchart TD
  A(["cancel_booking(id, by)"]) --> G{"Already cancelled /<br/>completed / no_show?"}
  G -- yes --> Gx[/"Error: already finalised"/]
  G -- no --> B{"Under 2h before start (buffer)?"}
  B -- yes --> Bx[/"Error: blocked — contact the other party"/]
  B -- no --> W{"Who cancels?"}

  %% Mentor cancels
  W -- Mentor --> M["Booking → cancelled (trigger sends email + .ics)<br/>Customer refund 100%"]
  M --> ML{"Late (2–24h)?"}
  ML -- "yes" --> MLy["+ Mentor penalty 25%<br/>+ bump monthly cancellation count"]
  ML -- "no (free, ≥24h)" --> MEnd([Done])
  MLy --> MEnd

  %% Customer cancels
  W -- Customer --> CF{"≥24h before (free)?"}
  CF -- yes --> CFy["Booking → cancelled (trigger email)<br/>Customer refund 100%"] --> CEnd([Done])
  CF -- "no (late, 2–24h)" --> CL["Booking STAYS confirmed<br/>Insert cancel request (respond_by = window)<br/>Email: cancel_requested → mentor"]
  CL --> R{{"Mentor responds<br/>respond_booking_request<br/>(or cron auto-approves at expiry)"}}
  R -- "Accept / no reply by window" --> Ra["Booking → cancelled (trigger email)<br/>Customer refund 100%"] --> CEnd
  R -- "Reject" --> Rr["Booking → cancelled (trigger email)<br/>Customer charged 50% + refunded 50%"] --> CEnd
```

**Covers:** `cancel_booking`, `respond_booking_request(kind='cancel')`,
`resolve_expired_requests` (auto-approve), `trg_booking_status_email('cancelled')`,
`bump_mentor_cancellation`. The cancelled email fires **once**, from the trigger
(fixed in migration `0048`).

---

## 3. Reschedule

![Reschedule flow](flowcharts/3-reschedule.svg)

```mermaid
flowchart TD
  S([Reschedule initiated]) --> WHO{"Initiated by?"}

  %% ---------- Customer ----------
  WHO -- Customer --> c0{"3rd attempt?<br/>(reschedule_count ≥ 2)"}
  c0 -- yes --> FAC["force_autocancel(customer)"]
  c0 -- no --> cb{"Under 2h (buffer)?"}
  cb -- yes --> cbx[/"Error: blocked"/]
  cb -- no --> cf{"≥24h before (free)?"}
  cf -- yes --> cAvail{"is_slot_available?"}
  cAvail -- no --> cax[/"Error: pick another slot"/]
  cAvail -- yes --> cMove["Booking → rescheduled (trigger email + .ics)<br/>count + 1, reminders cleared"]
  cf -- "no (late)" --> creq["request_reschedule:<br/>insert reschedule request (respond_by = window)<br/>Email: reschedule_requested → mentor"]
  creq --> mresp{{"Mentor responds<br/>(or cron auto-approves)"}}
  mresp -- "Accept / no reply" --> capp["Email: reschedule_approved → customer"]
  capp --> cpick["Customer picks new slot<br/>(customer_reschedule, now permitted)"]
  cpick --> cAvail
  mresp -- "Reject" --> crej["Email: reschedule_rejected<br/>Customer keeps original OR cancels via cancel flow"]

  %% ---------- Mentor ----------
  WHO -- Mentor --> m0{"3rd attempt?<br/>(reschedule_count ≥ 2)"}
  m0 -- yes --> FAC2["force_autocancel(mentor)"]
  m0 -- no --> mprop["mentor_propose_reschedule:<br/>insert offer (date + time range,<br/>respond_by = window, was_late = late?)<br/>Email: proposed → customer"]
  mprop --> mopt{"Customer choice"}

  mopt -- "Accept a slot in range" --> macc{"In range + future +<br/>is_slot_available?"}
  macc -- no --> maccx[/"Error: pick another slot in the range"/]
  macc -- yes --> mmove["Booking → rescheduled (trigger email + .ics)<br/>count + 1"]
  mmove --> mlate{"Offer was late?"}
  mlate -- "yes (past-deadline)" --> mlatey["+ Mentor penalty 25%"] --> mdone([Done])
  mlate -- "no" --> mdone

  mopt -- "Ask for a different date" --> mother["mentee_request_other_date:<br/>insert counter-offer<br/>Email: counter → mentor"]
  mother --> mprop

  mopt -- "Reject proposal" --> mrej["mentee_reject_reschedule:<br/>Booking → cancelled (trigger email)"]
  mrej --> mrejl{"Offer was late?"}
  mrejl -- "yes (past-deadline)" --> mrejy["Customer refund 100%<br/>+ Mentor penalty 25%"]
  mrejl -- "no (within deadline)" --> mrejn["Customer credit 100% (no cash)"]

  mopt -- "No response by window" --> mexp["Cron: offer expired<br/>Booking unchanged at original time (no email)"]

  %% ---------- 3rd-attempt outcome ----------
  FAC --> FACout
  FAC2 --> FACout["Booking → cancelled (trigger email)<br/>Customer refund 100%<br/>+ 100% penalty on the initiator"]
```

**Covers:** `customer_reschedule`, `request_reschedule`,
`respond_booking_request(kind='reschedule')`, `mentor_propose_reschedule`,
`mentee_accept_reschedule`, `mentee_request_other_date`, `mentee_reject_reschedule`,
`force_autocancel`, `resolve_expired_requests` (auto-approve + offer expiry).

**Two real edge behaviours to note (from the code):**
- After a **late customer request is approved**, the customer must still call
  `customer_reschedule` to pick a slot. If they never do, the booking simply **runs at
  its original time** — approval only unlocks the pick.
- A **mentor offer that gets no response** is set to `expired` by the cron; the booking is
  **unchanged** and **no email** is sent on expiry.

---

## 4. Refund / credit / penalty outcomes

The money is mock — every outcome below is written as rows in `booking_ledger`
(`kind ∈ refund | credit | charge | penalty`, with a `pct`). Nothing is actually moved.

![Refund and penalty outcomes](flowcharts/4-refund.svg)

### What the customer gets

```mermaid
flowchart TD
  q0([Booking ended via...]) --> e{Which path?}
  e -- "Customer cancel ≥24h" --> r1["Refund 100%"]
  e -- "Customer late cancel — approved / no mentor reply" --> r1
  e -- "Customer late cancel — mentor rejects" --> r2["Refund 50% + charge 50%"]
  e -- "Mentor cancels (free or late)" --> r1
  e -- "Mentor reschedule rejected — within deadline" --> r3["Credit 100% (no cash)"]
  e -- "Mentor reschedule rejected — past deadline" --> r1
  e -- "3rd reschedule attempt (auto-cancel)" --> r1
  e -- "Mentor no-show → request refund" --> r1
  e -- "Mentor no-show → rebook a different mentor" --> r3
  e -- "Mentor no-show → rebook same mentor" --> r0["No refund — session reinstated"]
  e -- "Customer no-show → mentor closes" --> r0
```

### What the mentor is charged (payout penalties)

```mermaid
flowchart TD
  p0([Mentor penalty applied when...]) --> p{Path}
  p -- "Mentor cancels late (2–24h)" --> p25["Penalty 25% of payout"]
  p -- "Mentor late reschedule accepted by customer" --> p25
  p -- "Customer rejects a past-deadline mentor reschedule" --> p25
  p -- "Mentor no-show, strike 3+ (90-day window)" --> p25
  p -- "Mentor initiates the 3rd reschedule (auto-cancel)" --> p100["Penalty 100% of payout"]
  p -- "Mentor no-show, strike 1–2" --> p0w["Warning only (0% — strike 2 = ops check-in)"]
```

### Full matrix (every terminal outcome)

| Path | Customer ledger | Mentor ledger | Booking status |
|---|---|---|---|
| Customer cancel ≥24h (free) | refund 100% | — | cancelled |
| Customer late cancel — approved / auto (no reply) | refund 100% | — | cancelled |
| Customer late cancel — rejected | charge 50% + refund 50% | — | cancelled |
| Mentor cancel ≥24h (free) | refund 100% | — | cancelled |
| Mentor cancel late (2–24h) | refund 100% | penalty 25% | cancelled |
| Mentor reschedule accepted (within deadline) | — | — | rescheduled |
| Mentor reschedule accepted (past deadline) | — | penalty 25% | rescheduled |
| Mentor reschedule rejected (within deadline) | credit 100% | — | cancelled |
| Mentor reschedule rejected (past deadline) | refund 100% | penalty 25% | cancelled |
| 3rd reschedule attempt — customer initiated | refund 100% + penalty 100% | — | cancelled |
| 3rd reschedule attempt — mentor initiated | refund 100% | penalty 100% | cancelled |
| Mentor no-show → rebook same | — | — | confirmed (reinstated) |
| Mentor no-show → rebook different | credit 100% | strike (3+ → penalty 25%) | no_show |
| Mentor no-show → refund | refund 100% | strike (3+ → penalty 25%) | no_show |
| Customer no-show → accept rebook | — | — | confirmed (reinstated) |
| Customer no-show → reject (close) | — | credit 100% (paid in full) | completed |

**Covers the ledger writes in:** `cancel_booking`, `respond_booking_request`,
`mentee_accept_reschedule`, `mentee_reject_reschedule`, `force_autocancel`,
`resolve_mentor_no_show`, `resolve_customer_no_show`, `apply_mentor_strike`
(all via `add_ledger`).

> No-show paths reach these outcomes only after a party manually reports via
> `flag_no_show(id, party)` (allowed only after **T+10 min**) — there is no automatic
> no-show detection in the current system.
