-- Booking lifecycle v2 — Phase 1 foundation (shared by cancel + reschedule).
-- Rule direction (per overview): >=24h before session = FREE; <24h = LATE
-- (approval/penalty); <2h = BUFFER (blocked, treated as no-show later).

alter table bookings add column if not exists reschedule_count int not null default 0;

create table if not exists booking_ledger (
  id          bigint generated always as identity primary key,
  booking_id  bigint not null references bookings(id) on delete cascade,
  party       text not null check (party in ('customer','mentor','platform')),
  kind        text not null check (kind in ('penalty','refund','credit','charge')),
  amount      numeric(10,2),
  pct         int,
  currency    text,
  reason      text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_booking_ledger_booking on booking_ledger(booking_id);
alter table booking_ledger enable row level security;
drop policy if exists booking_ledger_read on booking_ledger;
create policy booking_ledger_read on booking_ledger for select using (true);

create table if not exists booking_requests (
  id           bigint generated always as identity primary key,
  booking_id   bigint not null references bookings(id) on delete cascade,
  kind         text not null check (kind in ('cancel','reschedule')),
  initiated_by text not null check (initiated_by in ('customer','mentor')),
  status       text not null default 'pending'
               check (status in ('pending','approved','rejected','auto_approved','expired','withdrawn','completed')),
  respond_by   timestamptz,
  note         text,
  created_at   timestamptz not null default now(),
  resolved_at  timestamptz
);
create index if not exists idx_booking_requests_booking on booking_requests(booking_id);
create index if not exists idx_booking_requests_open on booking_requests(status) where status = 'pending';
alter table booking_requests enable row level security;
drop policy if exists booking_requests_read on booking_requests;
create policy booking_requests_read on booking_requests for select using (true);

create or replace function booking_deadline_state(p_slot timestamptz)
returns text language sql stable as $$
  select case
    when p_slot is null then 'free'
    when p_slot - now() < interval '2 hours'  then 'buffer'
    when p_slot - now() < interval '24 hours' then 'late'
    else 'free'
  end;
$$;

create or replace function response_window(p_slot timestamptz)
returns timestamptz language sql stable as $$
  select least(now() + interval '48 hours', p_slot - interval '2 hours');
$$;

grant execute on function booking_deadline_state(timestamptz) to anon, authenticated;
grant execute on function response_window(timestamptz) to anon, authenticated;
