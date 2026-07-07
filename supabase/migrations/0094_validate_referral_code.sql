-- Public, read-only referral code check for the checkout UI. referral_codes
-- itself is locked down to the owning affiliate only (referral_codes_self_read),
-- so guests/customers need a narrow security-definer RPC that reveals just
-- enough to show "code applied — X% off" before payment, without exposing
-- affiliate_id, redemption counts, or any other row data.
create or replace function validate_referral_code(p_code text)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when exists (
      select 1 from referral_codes
      where code_string = upper(trim(coalesce(p_code, '')))
        and expires_at > now()
        and redemption_count < redemption_cap
    )
    then jsonb_build_object('valid', true, 'discount_pct',
      (select discount_pct from referral_codes
        where code_string = upper(trim(p_code)) and expires_at > now() and redemption_count < redemption_cap))
    else jsonb_build_object('valid', false, 'discount_pct', 0)
  end;
$$;
grant execute on function validate_referral_code(text) to anon, authenticated;
