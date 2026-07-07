-- Two affiliate-facing emails, using the same app_send_email() (pg_net +
-- Resend via Vault) already used for booking confirmations/reminders:
--   1. "Referral tracked" — the moment a code is redeemed or a click resolves
--      to attribution (resolve_referral_attribution).
--   2. "Commission generated" — the moment a commission clears the automatic
--      fraud checks and flips pending_review -> approved
--      (run_referral_fraud_checks). Note: approval is AUTOMATIC by default —
--      a commission is only held for manual admin review if one of the three
--      fraud checks (volume spike, code-speed-high-value, cancel/rebook
--      cycling) fires. This email covers the automatic path only; a
--      manually-approved (post fraud-review) commission doesn't yet notify.

create or replace function resolve_referral_attribution(p_session_token text, p_email text, p_code text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_hash text; v_click_affiliate bigint; v_code_affiliate bigint; v_window_days int;
  v_existing attribution_records; v_aff_email text;
begin
  v_hash := encode(extensions.digest(lower(trim(p_email)), 'sha256'), 'hex');
  v_window_days := coalesce(referral_setting('referral_attribution_window_days')::int, 60);
  select * into v_existing from attribution_records where email_hash = v_hash;

  if p_code is not null and trim(p_code) <> '' then
    select affiliate_id into v_code_affiliate from referral_codes
      where code_string = upper(trim(p_code)) and expires_at > now() and redemption_count < redemption_cap;
  end if;

  select affiliate_id into v_click_affiliate from referral_click_events
    where session_token = p_session_token order by clicked_at desc limit 1;

  if v_existing.frozen then
    return; -- a no-show rebooking decision is pending for this customer — leave attribution untouched
  end if;

  if v_code_affiliate is not null then
    insert into attribution_records (email_hash, affiliate_id, source_type, created_at, expires_at)
      values (v_hash, v_code_affiliate, 'code', now(), now() + (v_window_days || ' days')::interval)
      on conflict (email_hash) do update set
        affiliate_id = excluded.affiliate_id, source_type = 'code',
        created_at = now(), expires_at = now() + (v_window_days || ' days')::interval, updated_at = now();
    update referral_codes set redemption_count = redemption_count + 1 where affiliate_id = v_code_affiliate;

    select u.email into v_aff_email from affiliates a join users u on u.id = a.user_id where a.id = v_code_affiliate;
    perform app_send_email(v_aff_email, 'Your referral code was just used',
      '<p>Someone just booked a session using your code — it''s tracked and will show up in your dashboard once the session completes.</p>');
  elsif v_click_affiliate is not null then
    insert into attribution_records (email_hash, affiliate_id, source_type, created_at, expires_at)
      values (v_hash, v_click_affiliate, 'link', now(), now() + (v_window_days || ' days')::interval)
      on conflict (email_hash) do update set
        affiliate_id = excluded.affiliate_id, source_type = 'link',
        created_at = now(), expires_at = now() + (v_window_days || ' days')::interval, updated_at = now();

    select u.email into v_aff_email from affiliates a join users u on u.id = a.user_id where a.id = v_click_affiliate;
    perform app_send_email(v_aff_email, 'Your referral link was just used',
      '<p>Someone who clicked your referral link just booked a session — it''s tracked and will show up in your dashboard once the session completes.</p>');
  end if;
end; $$;

create or replace function run_referral_fraud_checks(p_ledger_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  cl commission_ledger;
  v_avg30 numeric; v_today_count int; v_spike_escalate numeric;
  v_email text; v_hash text; v_att attribution_records; v_code referral_codes;
  v_speed_minutes numeric; v_speed_high_value numeric;
  v_flagged boolean := false; v_aff_email text;
begin
  select * into cl from commission_ledger where id = p_ledger_id;

  v_spike_escalate := referral_setting('referral_volume_spike_escalate_multiplier')::numeric;
  select count(*) into v_today_count from commission_ledger
    where affiliate_id = cl.affiliate_id and session_completed_at::date = cl.session_completed_at::date;
  select count(*)::numeric / 30.0 into v_avg30 from commission_ledger
    where affiliate_id = cl.affiliate_id
      and session_completed_at >= cl.session_completed_at - interval '30 days'
      and session_completed_at < cl.session_completed_at;
  if v_avg30 > 0 and v_today_count / v_avg30 > coalesce(v_spike_escalate, 5) then
    insert into fraud_flags (affiliate_id, booking_id, vector_type, status) values (cl.affiliate_id, cl.booking_id, 'volume_spike', 'escalated');
    v_flagged := true;
  end if;

  v_email := referral_email_for_booking(cl.booking_id);
  v_hash := encode(extensions.digest(lower(trim(v_email)), 'sha256'), 'hex');
  select * into v_att from attribution_records where email_hash = v_hash;
  if v_att.source_type = 'code' then
    select * into v_code from referral_codes where affiliate_id = cl.affiliate_id;
    v_speed_minutes := coalesce(referral_setting('referral_code_redemption_speed_minutes')::numeric, 30);
    v_speed_high_value := referral_setting('referral_code_speed_high_value_inr')::numeric;
    if v_speed_high_value is not null
       and extract(epoch from (v_att.created_at - v_code.created_at)) / 60.0 <= v_speed_minutes
       and cl.commission_amount_inr > v_speed_high_value then
      insert into fraud_flags (affiliate_id, booking_id, vector_type, status) values (cl.affiliate_id, cl.booking_id, 'code_speed', 'escalated');
      v_flagged := true;
    end if;
  end if;

  if (select reschedule_count from bookings where id = cl.booking_id) >= 3 then
    insert into fraud_flags (affiliate_id, booking_id, vector_type, status) values (cl.affiliate_id, cl.booking_id, 'cancel_rebook_cycling', 'escalated');
    v_flagged := true;
  end if;

  if not v_flagged then
    update commission_ledger set status = 'approved' where id = p_ledger_id;
    select u.email into v_aff_email from affiliates a join users u on u.id = a.user_id where a.id = cl.affiliate_id;
    perform app_send_email(v_aff_email, 'Commission approved — booking #' || cl.booking_id,
      '<p>Your referral commission of ₹' || to_char(cl.commission_amount_inr, 'FM999999990.00') ||
      ' for booking #' || cl.booking_id || ' has been approved and is queued for payout.</p>');
  end if;
end; $$;
