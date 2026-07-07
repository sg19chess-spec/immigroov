-- The "all-affiliates table" from 03_Product_Features.md Section 5 (current
-- tier, this month's completed referrals, lifetime payouts, flag history)
-- never got its own RPC — only the per-affiliate dashboard did. Adding it now
-- for the admin UI.

create or replace function admin_affiliates_overview()
returns table (
  affiliate_id bigint, email text, first_name text, type text, status text, tier text,
  this_month_referrals bigint, lifetime_paid_inr numeric, active_flag_count bigint, total_flag_count bigint,
  link_slug text, code_string text
)
language plpgsql stable security definer set search_path = public as $$
begin
  return query
    select a.id, u.email, u.first_name, a.type, a.status, current_affiliate_tier(a.id),
      (select count(*) from commission_ledger cl where cl.affiliate_id = a.id and cl.status in ('approved','paid')
         and date_trunc('month', cl.session_completed_at) = date_trunc('month', now())),
      (select coalesce(sum(commission_amount_inr), 0) from commission_ledger where affiliate_id = a.id and status = 'paid'),
      (select count(*) from fraud_flags where affiliate_id = a.id and status = 'escalated'),
      (select count(*) from fraud_flags where affiliate_id = a.id),
      al.slug, rc.code_string
    from affiliates a
    join users u on u.id = a.user_id
    left join affiliate_links al on al.affiliate_id = a.id
    left join referral_codes rc on rc.affiliate_id = a.id
    order by a.created_at desc;
end; $$;
