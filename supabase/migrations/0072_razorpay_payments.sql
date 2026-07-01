-- =============================================================================
-- 0072 — Razorpay payments: provider-agnostic schema, payment state machine,
-- refunds/events/reconciliation tables, payout modeling. (Sandbox-first.)
--
-- Adds the real payment rail's DATA layer on top of the reserve-then-confirm
-- flow (0069) and hardened lifecycle (0070/0071). Edge functions (create-order,
-- webhook, process-refunds, reconcile) and client wiring are separate.
--
-- Design notes:
--  • Provider-agnostic columns (provider/provider_order_id/provider_payment_id/
--    provider_payload) — NO mirroring into legacy stripe_payment_id.
--  • Canonical payment `state` (text + CHECK) instead of extending the
--    payment_status enum (ALTER TYPE ADD VALUE is unsafe inside a txn). Legacy
--    enum `status` kept loosely synced for old readers.
--  • Payout lifecycle uses a canonical text `payout_state` (pending/paid/void/
--    blocked) for the same reason; a trigger voids payouts when a booking ends
--    cancelled/no_show, so the 5 lifecycle money-functions don't need re-editing.
-- =============================================================================

-- 1) customer_payments: provider-agnostic + state machine + error capture ------
alter table customer_payments
  add column if not exists provider text default 'razorpay',
  add column if not exists provider_order_id text,
  add column if not exists provider_payment_id text,
  add column if not exists provider_payload jsonb,
  add column if not exists state text default 'created',
  add column if not exists provider_error_code text,
  add column if not exists provider_error_description text;

do $$ begin
  alter table customer_payments add constraint customer_payments_state_chk
    check (state is null or state in ('created','authorized','captured','partially_refunded','refunded','failed'));
exception when duplicate_object then null; end $$;

-- Backfill canonical state from the legacy enum for existing rows.
update customer_payments set state = case status::text
  when 'paid' then 'captured' when 'refunded' then 'refunded'
  when 'failed' then 'failed' else 'created' end
where state is null or state = 'created';

-- 2) booking_pricing: freeze the INR estimate for reconciliation ---------------
alter table booking_pricing add column if not exists platform_inr_estimate numeric;
update booking_pricing set platform_inr_estimate = round(gross_customer * coalesce(fx_customer_inr,1), 2)
  where platform_inr_estimate is null and gross_customer is not null;

-- 3) mentor_payouts: method + payout_state + reference -------------------------
alter table mentor_payouts
  add column if not exists method text,
  add column if not exists payout_reference text,
  add column if not exists payout_state text;

do $$ begin
  alter table mentor_payouts add constraint mentor_payouts_payout_state_chk
    check (payout_state is null or payout_state in ('pending','paid','void','blocked'));
exception when duplicate_object then null; end $$;

update mentor_payouts set
  method = coalesce(method, case when upper(coalesce(mentor_currency, currency)) = 'INR' then 'auto_inr' else 'manual' end),
  payout_state = coalesce(payout_state, case when status::text = 'paid' then 'paid' else 'pending' end)
where method is null or payout_state is null;

-- 4) payment_refunds — many refunds per payment --------------------------------
create table if not exists payment_refunds (
  id bigserial primary key,
  payment_id bigint references customer_payments(id) on delete set null,
  booking_id bigint references bookings(id) on delete cascade,
  provider_refund_id text unique,
  amount_minor int not null,
  currency text not null,
  status text not null default 'created' check (status in ('created','processed','failed')),
  provider_payload jsonb,
  provider_error_code text,
  provider_error_description text,
  ledger_version int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists payment_refunds_booking_idx on payment_refunds(booking_id);

-- 5) payment_events — webhook audit + dedup + retry metadata -------------------
create table if not exists payment_events (
  event_id text primary key,
  type text,
  payload jsonb,
  signature text,
  attempt_count int not null default 0,
  last_attempt_at timestamptz,
  next_retry_at timestamptz,
  processed_at timestamptz,
  error text,
  received_at timestamptz not null default now()
);

-- 6) payment_reconciliation_log — nightly mismatch report ----------------------
create table if not exists payment_reconciliation_log (
  id bigserial primary key,
  ran_at timestamptz not null default now(),
  kind text,                        -- 'missing_local' | 'amount_mismatch' | 'status_mismatch' | ...
  provider_payment_id text,
  booking_id bigint,
  detail jsonb
);

-- 7) payments_enabled flag (mock fallback when false / no keys) ----------------
insert into platform_settings(key, value, description)
values ('payments_enabled','false','When true, bookings go through the Razorpay reserve→pay→confirm flow; when false, the mock instant-confirm path is used.')
on conflict (key) do nothing;

-- 8) Payment-state transition guard --------------------------------------------
create or replace function set_payment_state(p_payment_id bigint, p_new text)
returns void language plpgsql security definer set search_path = public as $$
declare v_cur text;
begin
  select state into v_cur from customer_payments where id = p_payment_id for update;
  if v_cur is null then v_cur := 'created'; end if;
  if p_new = 'failed'
     or (v_cur='created' and p_new in ('authorized','captured'))
     or (v_cur='authorized' and p_new='captured')
     or (v_cur='captured' and p_new in ('partially_refunded','refunded'))
     or (v_cur='partially_refunded' and p_new in ('partially_refunded','refunded'))
     or (v_cur=p_new) then
    update customer_payments set state = p_new where id = p_payment_id;
  else
    raise exception 'Illegal payment state transition % -> %', v_cur, p_new using errcode='P0001';
  end if;
end; $$;
revoke all on function set_payment_state(bigint,text) from public, anon, authenticated;
grant execute on function set_payment_state(bigint,text) to service_role;

-- 9) set_provider_order — store the Razorpay order id on the reserved payment --
create or replace function set_provider_order(p_booking_id bigint, p_order_id text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update customer_payments set provider = 'razorpay', provider_order_id = p_order_id
   where booking_id = p_booking_id and status = 'initiated';
end; $$;
revoke all on function set_provider_order(bigint,text) from public, anon, authenticated;
grant execute on function set_provider_order(bigint,text) to service_role;

-- 10) confirm_booking_payment — extend 0069 with provider id + state + method --
create or replace function confirm_booking_payment(p_booking_id bigint, p_provider_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare b bookings; v_ccy text;
begin
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking % not found', p_booking_id; end if;
  if b.status = 'confirmed' then return 'already_confirmed'; end if;
  if b.status <> 'pending' or b.payment_hold_expires_at is null then
    raise exception 'HOLD_EXPIRED: booking % is no longer awaiting payment (status %)', p_booking_id, b.status using errcode='P0001';
  end if;
  update bookings set status = 'confirmed', payment_hold_expires_at = null where id = p_booking_id;
  update customer_payments
     set status = 'paid', state = 'captured', provider = 'razorpay',
         provider_payment_id = p_provider_ref, stripe_payment_id = coalesce(stripe_payment_id, p_provider_ref)
   where booking_id = p_booking_id and status = 'initiated'
   returning upper(currency) into v_ccy;
  update mentor_payouts
     set method = coalesce(method, case when upper(coalesce(mentor_currency, currency))='INR' then 'auto_inr' else 'manual' end),
         payout_state = coalesce(payout_state, 'pending')
   where booking_id = p_booking_id;
  return 'confirmed';
end; $$;
revoke all on function confirm_booking_payment(bigint,text) from public, anon, authenticated;
grant execute on function confirm_booking_payment(bigint,text) to service_role;

-- 11) refund_owed_minor — how much (mentee-currency minor units) still owed -----
-- Refund intent = customer 'refund' ledger rows; minus what payment_refunds
-- already covers. Assumes 2-decimal currencies (INR/USD/EUR/etc.); zero-decimal
-- (JPY/KRW) would need an exponent map — noted for later.
create or replace function refund_owed_minor(p_booking_id bigint)
returns int language sql stable security definer set search_path = public as $$
  select greatest(0, (
    round(coalesce((select sum(amount) from booking_ledger
                    where booking_id = p_booking_id and party='customer' and kind='refund'), 0) * 100)
    - coalesce((select sum(amount_minor) from payment_refunds
                where booking_id = p_booking_id and status in ('created','processed')), 0)
  ))::int;
$$;
grant execute on function refund_owed_minor(bigint) to service_role;

-- 12) Payout admin actions -----------------------------------------------------
create or replace function mark_payout_paid(p_booking_id bigint, p_reference text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_status text; v_pstate text;
begin
  select b.status::text, mp.payout_state into v_status, v_pstate
    from bookings b join mentor_payouts mp on mp.booking_id = b.id
   where b.id = p_booking_id order by mp.id desc limit 1;
  if v_status is distinct from 'completed' then raise exception 'Payout only after the session is completed (status %)', v_status using errcode='P0001'; end if;
  if v_pstate in ('void','blocked') then raise exception 'Payout is % — cannot mark paid', v_pstate using errcode='P0001'; end if;
  update mentor_payouts set payout_state='paid', status='paid', paid_date=now(), payout_reference=p_reference
   where booking_id = p_booking_id;
end; $$;
revoke all on function mark_payout_paid(bigint,text) from public, anon;
grant execute on function mark_payout_paid(bigint,text) to authenticated, service_role;

create or replace function set_payout_blocked(p_booking_id bigint, p_reason text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  update mentor_payouts set payout_state='blocked', comments = coalesce(p_reason, comments)
   where booking_id = p_booking_id and coalesce(payout_state,'pending') <> 'paid';
end; $$;
revoke all on function set_payout_blocked(bigint,text) from public, anon;
grant execute on function set_payout_blocked(bigint,text) to authenticated, service_role;

-- 13) Trigger: void the payout when a booking ends cancelled/no_show -----------
-- (covers cancel/reschedule-reject/no-show refund branches without editing them;
--  customer-no-show 'reject' sets status='completed' so the payout stays payable.)
create or replace function trg_void_payout_fn()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('cancelled','no_show') and new.status is distinct from old.status then
    update mentor_payouts set payout_state = 'void'
     where booking_id = new.id and coalesce(payout_state,'pending') not in ('paid','blocked');
  end if;
  return new;
end; $$;
drop trigger if exists trg_void_payout on bookings;
create trigger trg_void_payout after update of status on bookings
  for each row execute function trg_void_payout_fn();

-- 14) Mentor can change their receiving currency (per service) -----------------
-- extend create + add update; validate against the FX-supported set.
create or replace function is_supported_currency(p_ccy text)
returns boolean language sql immutable set search_path = public as $$
  select upper(coalesce(p_ccy,'')) in
    ('USD','GBP','INR','EUR','CAD','AUD','NZD','SGD','HKD','JPY','KRW','CNY','MXN','BRL','ZAR',
     'CHF','SEK','NOK','DKK','PLN','RON','CZK','HUF','BGN','ILS','IDR','PHP','MYR','THB','TRY');
$$;
grant execute on function is_supported_currency(text) to anon, authenticated;

create or replace function demo_set_service_currency(p_id bigint, p_currency text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_supported_currency(p_currency) then raise exception 'Unsupported currency %', p_currency using errcode='P0001'; end if;
  update services set set_currency = upper(p_currency) where id = p_id;
end; $$;
grant execute on function demo_set_service_currency(bigint,text) to anon, authenticated;
