-- =============================================================================
-- Immigroov — Materialized View + Triggers
-- =============================================================================

-- -----------------------------------------------------------------------------
-- mentor_earnings_summary (materialized view)
--   total_earnings : total paid out to the mentor
--   payout_pending : value of completed sessions not yet paid out
--   yet_to_service : value of booked-but-not-yet-completed sessions
-- -----------------------------------------------------------------------------
create materialized view mentor_earnings_summary as
with paid_out as (
  select mentor_id, coalesce(sum(amount), 0) as total_earnings
  from mentor_payouts
  where status = 'paid'
  group by mentor_id
),
pending_payout as (
  select b.mentor_id, coalesce(sum(cp.amount), 0) as payout_pending
  from bookings b
  join customer_payments cp on cp.booking_id = b.id and cp.status = 'paid'
  left join mentor_payouts mp on mp.booking_id = b.id and mp.status = 'paid'
  where b.status = 'completed'
    and mp.id is null
  group by b.mentor_id
),
upcoming as (
  select b.mentor_id, coalesce(sum(cp.amount), 0) as yet_to_service
  from bookings b
  join customer_payments cp on cp.booking_id = b.id and cp.status = 'paid'
  where b.status in ('pending', 'confirmed', 'rescheduled')
  group by b.mentor_id
)
select
  m.id as mentor_id,
  coalesce(po.total_earnings, 0)  as total_earnings,
  coalesce(pp.payout_pending, 0)  as payout_pending,
  coalesce(u.yet_to_service, 0)   as yet_to_service
from mentors m
left join paid_out       po on po.mentor_id = m.id
left join pending_payout pp on pp.mentor_id = m.id
left join upcoming        u on u.mentor_id  = m.id;

-- Unique index required for REFRESH MATERIALIZED VIEW CONCURRENTLY
create unique index idx_mentor_earnings_summary_mentor on mentor_earnings_summary(mentor_id);

-- Helper to refresh (call from a cron / pg_cron job)
create or replace function refresh_mentor_earnings_summary()
returns void language sql as $$
  refresh materialized view concurrently mentor_earnings_summary;
$$;

-- Example pg_cron schedule (enable pg_cron extension in Supabase first):
--   select cron.schedule('refresh-earnings', '*/15 * * * *',
--     $$ select refresh_mentor_earnings_summary() $$);

-- -----------------------------------------------------------------------------
-- updated_at touch trigger for platform_settings
-- -----------------------------------------------------------------------------
create or replace function touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger trg_platform_settings_touch
  before update on platform_settings
  for each row execute function touch_updated_at();
