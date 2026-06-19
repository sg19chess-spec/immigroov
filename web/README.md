# Immigroov — Web (Next.js)

Production frontend for the Immigroov mentor marketplace. Next.js (App Router) +
TypeScript + Supabase **real auth** (anonymous + magic link), talking to the
auth-secured RPCs on project `atkulcfyaqcivzxteela`.

## Run

```bash
cd web
npm install
npm run dev        # http://localhost:3000
```

Env vars are in `.env.local` (already filled with the public Supabase URL + anon
key). Copy `.env.local.example` for your own project.

## What's wired

| Route | Purpose | Backend |
|---|---|---|
| `/` | Browse mentors (auto-converted prices) | `search_mentors` |
| `/mentor/[id]` | Pick a **service** → slot → book (with custom questions) | `get_available_slots`, `book_session`, `demo_list_questions` |
| `/bookings` | Your sessions (3-clock timezone view, cancel) | `my_bookings`, `cancel_booking` |
| `/login` | Magic link or "continue as guest" | Supabase Auth |
| `/dashboard` | Mentor services (starter) | `demo_list_services` |

- **Real auth**: anonymous sign-in is created automatically at booking time if
  the visitor has no session; magic-link covers registered users. No more
  "email as identity" — bookings are tied to `auth.uid()`.
- **Server-side slot validation** (`book_session` → `is_slot_available`) so a
  crafted request can't book outside availability.
- **Auto FX**: mentor price (their currency) → mentee currency via Frankfurter.

## Prerequisites in Supabase
- **Anonymous sign-ins** enabled (Auth → Providers) — for guest booking.
- (Optional) Email provider for magic-link, and the Resend Vault key for emails.

## Still to port (next)
- Mentor dashboard editing (services + availability) behind mentor auth — the
  logic exists as RPCs (`demo_*` today); production versions should gate to the
  owning mentor via `current_mentor_id()`.
- Real Stripe checkout (replace the mock payment recorded by `book_session`).
