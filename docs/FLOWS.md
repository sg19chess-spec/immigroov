# Booking lifecycle flows

Visual: [`booking-flows.svg`](./booking-flows.svg) — confirm, cancel, and reschedule in one diagram.
Colour key: blue = mentee, amber = mentor, grey = system/email, red = blocked, green = done.

## Confirmation (booking)
1. Mentee picks service + date/time and clicks **Confirm booking** (the only confirmation step).
2. Booking → `confirmed`, mock payment recorded.
3. Branded emails + `.ics` go to **mentee, mentor, admin**.
4. ~1 hour before, an attendance check asks the mentor **"Are you available?"** (in-app prompt + scheduled email). Yes → session goes ahead; No → reschedule.

## Cancellation
- Either the mentee or mentor clicks **Cancel**.
- Guard: if `now > slot − mentor.cancel_notice_hours`, it is **blocked** ("reschedule instead").
- Otherwise → `cancelled` → emails + cancel `.ics` to all three.

## Reschedule (negotiation)
1. **① Mentor proposes** a date + time **range** (after declining attendance, or via Reschedule).
2. Mentee either:
   - **② picks a time inside the range**, then **③ the mentor confirms** it → `rescheduled` (emails + updated `.ics`); or
   - **asks for a different day** → loops back to ① for that date.

Only the mentor proposes times; the mentee can only pick within the offered range or ask for another day.

### Open decision — step ③
Step ③ (mentor re-confirms the mentee's pick) is the one **removable** confirmation. Dropping it makes the mentee's pick inside the mentor's own range finalise immediately (reschedule = 2 steps), matching the original spec. Kept for now; revisit if the back-and-forth feels heavy.
