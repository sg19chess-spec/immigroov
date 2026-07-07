-- Schema changes for wiring referral attribution + a first-session discount
-- into the real checkout flow (reserve_booking / book_session_guest /
-- confirm_booking_payment). Per the founder's decision: discount_pct lives on
-- each affiliate code (not a global setting), so mentor/influencer/future
-- code types can each have their own predictable, fixed rate. Marketing/
-- campaign codes (no affiliate, no commission) are explicitly out of scope —
-- they'll be a separate promotion_codes system later.

-- ---------------------------------------------------------------------------
-- 1. Per-code discount percentage.
-- ---------------------------------------------------------------------------

alter table referral_codes add column if not exists discount_pct numeric not null default 0;

drop function if exists admin_create_referral_code(bigint, text, integer, timestamptz);
create or replace function admin_create_referral_code(
  p_affiliate_id bigint, p_code text, p_redemption_cap integer, p_expires_at timestamptz, p_discount_pct numeric
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_clean text := upper(trim(p_code));
  v_denylist text[] := array['FUCK','SHIT','BITCH','ASS','CUNT','DAMN'];
begin
  if v_clean !~ '^[A-Z0-9_-]{3,20}$' then
    raise exception 'Code must be 3-20 characters, letters/numbers/hyphen/underscore only';
  end if;
  if exists (select 1 from unnest(v_denylist) w where v_clean like '%'||w||'%') then
    raise exception 'Code failed the profanity check — choose another';
  end if;
  if p_redemption_cap is null or p_redemption_cap < 1 then
    raise exception 'Redemption cap must be at least 1';
  end if;
  if p_expires_at is null or p_expires_at <= now() then
    raise exception 'Expiry date must be in the future';
  end if;
  if p_discount_pct is null or p_discount_pct < 0 or p_discount_pct > 100 then
    raise exception 'Discount percent must be between 0 and 100';
  end if;
  insert into referral_codes (affiliate_id, code_string, redemption_cap, expires_at, discount_pct)
    values (p_affiliate_id, v_clean, p_redemption_cap, p_expires_at, p_discount_pct)
    returning id into v_id;
  return v_id;
end; $$;

-- ---------------------------------------------------------------------------
-- 2. Attribution + discount data captured on the booking itself, so
--    confirm_booking_payment (and book_session_guest's mock path) can resolve
--    attribution later without needing these values re-threaded through
--    razorpay-verify / razorpay-webhook separately.
-- ---------------------------------------------------------------------------

alter table bookings
  add column if not exists referral_session_token text,
  add column if not exists referral_code text,
  add column if not exists referral_discount_applied_pct numeric;
