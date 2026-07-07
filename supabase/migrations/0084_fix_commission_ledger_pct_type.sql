-- Real bug found during Phase 7 end-to-end testing: add_ledger()'s p_pct
-- parameter is `integer`, but v_promoter_pct was declared `numeric`, so
-- Postgres couldn't resolve the overload and the whole commission calculation
-- (including the commission_ledger insert) rolled back on every single
-- referred booking. Fix: cast to int at the call site, matching every other
-- existing add_ledger() call in the codebase (they all pass integer literals).

create or replace function process_referral_commissions()
returns void language plpgsql security definer set search_path = public as $$
declare
  r record;
  v_email text; v_hash text; v_att attribution_records; v_aff affiliates;
  v_gross numeric; v_mentor_pct numeric; v_immigroov_pct numeric; v_promoter_pct numeric;
  v_tier text; v_ledger_id bigint; v_already_had_session boolean;
begin
  for r in
    select b.* from bookings b
    where b.status = 'completed'
      and not exists (select 1 from commission_ledger cl where cl.booking_id = b.id)
  loop
    v_email := coalesce(r.guest_email, (select email from users where id = r.user_id));
    if v_email is null then continue; end if;
    v_hash := encode(extensions.digest(lower(trim(v_email)), 'sha256'), 'hex');

    select * into v_att from attribution_records where email_hash = v_hash;
    if not found or v_att.affiliate_id is null or v_att.frozen
       or v_att.expires_at < coalesce(r.slot_end, r.slot_time, now()) then
      continue;
    end if;

    select exists(
      select 1 from bookings b2
      where b2.id <> r.id and b2.status = 'completed'
        and coalesce(b2.guest_email, (select email from users where id = b2.user_id)) = v_email
        and b2.slot_time < r.slot_time
    ) into v_already_had_session;
    if v_already_had_session then continue; end if;

    select * into v_aff from affiliates where id = v_att.affiliate_id;
    if v_aff.status <> 'active' then continue; end if;

    if v_att.source_type = 'link' and exists (
      select 1 from affiliate_links rl where rl.affiliate_id = v_aff.id and rl.is_house_channel
    ) then
      continue;
    end if;

    select amount into v_gross from customer_payments where booking_id = r.id order by id desc limit 1;
    if v_gross is null then continue; end if;

    if v_aff.mentor_id = r.mentor_id then
      v_mentor_pct := 90; v_immigroov_pct := 10; v_promoter_pct := 0;
    elsif v_aff.type = 'mentor' then
      v_mentor_pct := 70; v_immigroov_pct := 20; v_promoter_pct := 10;
    else
      v_tier := current_affiliate_tier(v_aff.id);
      v_mentor_pct := 70;
      case v_tier
        when 'growth'  then v_immigroov_pct := 19; v_promoter_pct := 11;
        when 'partner' then v_immigroov_pct := 15; v_promoter_pct := 15;
        else                v_immigroov_pct := 22; v_promoter_pct := 8;
      end case;
    end if;

    insert into commission_ledger (booking_id, session_completed_at, mentor_id, affiliate_id, split_snapshot, commission_amount_inr, status)
      values (r.id, coalesce(r.slot_end, now()), r.mentor_id, v_aff.id,
              jsonb_build_object('mentor_pct', v_mentor_pct, 'immigroov_pct', v_immigroov_pct, 'promoter_pct', v_promoter_pct),
              round(v_gross * v_promoter_pct / 100.0, 2), 'pending_review')
      returning id into v_ledger_id;

    if v_promoter_pct > 0 then
      perform add_ledger(r.id, 'promoter', 'commission', round(v_gross * v_promoter_pct / 100.0, 2), v_promoter_pct::int,
                          'Referral commission — affiliate #'||v_aff.id);
    end if;
    perform log_event(r.id, 'system', 'Referral commission calculated', 'Affiliate #'||v_aff.id||', tier '||coalesce(v_tier, 'n/a'));

    perform run_referral_fraud_checks(v_ledger_id);
  end loop;
end; $$;
