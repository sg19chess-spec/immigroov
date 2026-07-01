-- =============================================================================
-- 0076 — RazorpayX INR payout (real mentor payouts, sandbox-testable).
-- Admin-initiated: an admin triggers razorpayx-payout for a completed, pending,
-- auto_inr (INR-mentor) payout. RazorpayX pays the mentor's fund account from the
-- business's RazorpayX account (source). Payout status is finalized by the
-- payout.* webhook. Non-INR mentors remain 'manual'.
-- =============================================================================

-- Cache the mentor's RazorpayX contact + fund account (created once).
alter table mentors
  add column if not exists razorpay_contact_id text,
  add column if not exists razorpay_fund_account_id text;

-- Track the actual RazorpayX payout on the payout row.
alter table mentor_payouts
  add column if not exists razorpay_payout_id text,
  add column if not exists payout_provider_status text;

-- Allow the RazorpayX source account number to be read from Vault by the fns.
create or replace function get_app_secret(p_name text)
returns text language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets
   where name = p_name and p_name in
     ('razorpay_key_id','razorpay_key_secret','razorpay_webhook_secret','razorpayx_account_number');
$$;
revoke all on function get_app_secret(text) from public, anon, authenticated;
grant execute on function get_app_secret(text) to service_role;

-- Apply a RazorpayX payout status update (called by the webhook / payout fn).
create or replace function apply_payout_status(p_payout_id text, p_status text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update mentor_payouts set
    payout_provider_status = p_status,
    payout_state = case
      when p_status = 'processed' then 'paid'
      when p_status in ('reversed','failed','rejected','cancelled') then 'pending'
      else coalesce(payout_state,'pending') end,
    status = case when p_status = 'processed' then 'paid'::payout_status else status end,
    paid_date = case when p_status = 'processed' then now() else paid_date end
  where razorpay_payout_id = p_payout_id;
end; $$;
revoke all on function apply_payout_status(text,text) from public, anon, authenticated;
grant execute on function apply_payout_status(text,text) to service_role;

-- Eligibility + snapshot read for the payout edge function (service-role only).
create or replace function payout_candidate(p_booking_id bigint)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  select jsonb_build_object(
    'booking_id', b.id, 'booking_status', b.status::text,
    'mentor_id', mm.id, 'mentor_name', mu.first_name,
    'net_minor', round(mp.net_amount_mentor_currency * 100)::int,
    'mentor_currency', mp.mentor_currency, 'method', mp.method, 'payout_state', mp.payout_state,
    'contact_id', mm.razorpay_contact_id, 'fund_account_id', mm.razorpay_fund_account_id,
    'existing_payout_id', mp.razorpay_payout_id)
  into v
  from bookings b
  join mentors mm on mm.id = b.mentor_id
  join users mu on mu.id = mm.user_id
  join lateral (select * from mentor_payouts where booking_id = b.id order by id desc limit 1) mp on true
  where b.id = p_booking_id;
  return v;
end; $$;
revoke all on function payout_candidate(bigint) from public, anon, authenticated;
grant execute on function payout_candidate(bigint) to service_role;
