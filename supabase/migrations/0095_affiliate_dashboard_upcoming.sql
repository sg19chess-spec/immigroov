-- Small UX fix: an affiliate whose code was just redeemed sees
-- redemption_count=1 but referrals=[] and pending_commission=0, because
-- referrals/commission only populate once the session completes and the
-- commission cron runs. That reads as "did my referral even work?" — it did,
-- it's just not payable yet. Expose the earlier pipeline stage (booked, not
-- yet completed) as a separate "upcoming" list so the affiliate can see the
-- referral is tracked while it's in flight, without touching payable numbers.

create or replace function affiliate_dashboard_summary(p_email text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_affiliate affiliates; v_link affiliate_links; v_code referral_codes; v_result jsonb;
begin
  select a.* into v_affiliate from affiliates a join users u on u.id = a.user_id where lower(u.email) = lower(trim(p_email));
  if not found then raise exception 'Not an affiliate account'; end if;
  select * into v_link from affiliate_links where affiliate_id = v_affiliate.id;
  select * into v_code from referral_codes where affiliate_id = v_affiliate.id;

  select jsonb_build_object(
    'affiliate', jsonb_build_object('id', v_affiliate.id, 'type', v_affiliate.type, 'status', v_affiliate.status),
    'link', jsonb_build_object('slug', v_link.slug, 'is_house_channel', v_link.is_house_channel),
    'code', jsonb_build_object('code', v_code.code_string, 'expires_at', v_code.expires_at,
                                'redemption_count', v_code.redemption_count, 'redemption_cap', v_code.redemption_cap,
                                'discount_pct', v_code.discount_pct),
    'tier', current_affiliate_tier(v_affiliate.id),
    'pending_commission_inr', (select coalesce(sum(commission_amount_inr), 0) from commission_ledger where affiliate_id = v_affiliate.id and status in ('pending_review', 'approved')),
    'paid_commission_inr', (select coalesce(sum(commission_amount_inr), 0) from commission_ledger where affiliate_id = v_affiliate.id and status = 'paid'),
    'upcoming', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'booking_id', b.id, 'slot_time', b.slot_time, 'status', b.status
      ) order by b.slot_time asc nulls last), '[]'::jsonb)
      from bookings b
      where b.status in ('confirmed', 'rescheduled')
        and not exists (select 1 from commission_ledger cl where cl.booking_id = b.id)
        and (
          (v_code.code_string is not null and b.referral_code = v_code.code_string)
          or exists (
            select 1 from referral_click_events rce
            where rce.affiliate_id = v_affiliate.id and rce.session_token = b.referral_session_token
          )
        )
    ),
    'referrals', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'booking_id', cl.booking_id, 'status', cl.status, 'amount_inr', cl.commission_amount_inr,
        'created_at', cl.created_at,
        'under_review', exists(select 1 from fraud_flags f where f.booking_id = cl.booking_id and f.status = 'escalated')
      ) order by cl.created_at desc), '[]'::jsonb)
      from commission_ledger cl where cl.affiliate_id = v_affiliate.id
    ),
    'payouts', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'batch_date', pb.batch_date, 'amount_inr', s.total, 'entry_count', s.n
      ) order by pb.batch_date desc), '[]'::jsonb)
      from payout_batches pb
      join lateral (
        select sum(commission_amount_inr) as total, count(*) as n
        from commission_ledger where payout_batch_id = pb.id and affiliate_id = v_affiliate.id
      ) s on true
      where exists (select 1 from commission_ledger where payout_batch_id = pb.id and affiliate_id = v_affiliate.id)
    )
  ) into v_result;
  return v_result;
end; $$;
