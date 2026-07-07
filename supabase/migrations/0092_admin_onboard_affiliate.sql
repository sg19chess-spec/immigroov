-- Consolidates the affiliate onboarding flow from 03_Product_Features.md
-- Section 1 into one call: find-or-create the user by email, then create the
-- affiliate + their one link + their one code, all in one step (matching "the
-- admin creates the affiliate account directly" — a single admin action, not
-- three separate ones). Reuses the existing, already-validated building
-- blocks (admin_create_affiliate/admin_create_referral_link/
-- admin_create_referral_code) rather than duplicating their checks.

create or replace function admin_onboard_affiliate(
  p_email text, p_type text, p_slug text, p_code text,
  p_redemption_cap integer, p_expires_at timestamptz, p_discount_pct numeric,
  p_first_name text default null, p_mentor_id bigint default null,
  p_payout_details jsonb default null, p_audience_corridor text default null,
  p_is_house_channel boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_email text := lower(trim(coalesce(p_email, '')));
  v_user_id bigint; v_affiliate_id bigint; v_link_id bigint; v_code_id bigint;
begin
  if v_email = '' or position('@' in v_email) = 0 then raise exception 'A valid email is required'; end if;

  select id into v_user_id from users where email = v_email;
  if v_user_id is null then
    insert into users (email, first_name, role) values (v_email, p_first_name, 'user') returning id into v_user_id;
  end if;

  v_affiliate_id := admin_create_affiliate(v_user_id, p_type, p_mentor_id, p_payout_details, p_audience_corridor);
  v_link_id := admin_create_referral_link(v_affiliate_id, p_slug, p_is_house_channel);
  v_code_id := admin_create_referral_code(v_affiliate_id, p_code, p_redemption_cap, p_expires_at, p_discount_pct);

  return jsonb_build_object('affiliate_id', v_affiliate_id, 'user_id', v_user_id, 'link_id', v_link_id, 'code_id', v_code_id);
end; $$;
