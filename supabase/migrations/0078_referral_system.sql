-- Referral / affiliate commission system.
-- Source of truth for behavior: 01_Business_Rules.md. Implementation choices below
-- follow 02_Technical_Architecture.md. UI (03_Product_Features.md) is NOT built here —
-- this migration is data model + core logic only, per founder instruction.
--
-- Two things this migration deliberately does NOT do, because the underlying business
-- decision is still open (02_Technical_Architecture.md Section 6a):
--   - No margin-floor guard on heavily discounted bookings.
--   - No perverse-incentive audit (mentor-as-influencer self-price check).
-- Both can be added later without touching anything built here.

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- 1. Core tables
-- ---------------------------------------------------------------------------

create table affiliates (
  id               bigint generated always as identity primary key,
  user_id          bigint not null references users(id) on delete restrict,
  mentor_id        bigint references mentors(id) on delete restrict,
  type             text not null check (type in ('mentor', 'non_mentor')),
  payout_details   jsonb,
  audience_corridor text,
  status           text not null default 'active' check (status in ('active', 'frozen')),
  agreed_terms_at  timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  unique (user_id),
  constraint affiliates_mentor_type_requires_mentor_id
    check (type <> 'mentor' or mentor_id is not null)
);

-- One unique link and one code per affiliate (V1 locked scope) — enforced by the
-- unique constraint on affiliate_id below, not just application logic.
create table affiliate_links (
  id               bigint generated always as identity primary key,
  affiliate_id     bigint not null references affiliates(id) on delete cascade unique,
  slug             text not null unique,
  is_house_channel boolean not null default false,
  created_at       timestamptz not null default now()
);

create table referral_codes (
  id               bigint generated always as identity primary key,
  affiliate_id     bigint not null references affiliates(id) on delete cascade unique,
  code_string      text not null unique,
  redemption_cap   integer not null,
  expires_at       timestamptz not null,
  redemption_count integer not null default 0,
  created_at       timestamptz not null default now()
);

-- Ephemeral click log (stage 1 of attribution — session-token keyed, per
-- 02_Technical_Architecture.md Section 2 step 1). Resolved into a durable,
-- email-keyed attribution_records row at checkout.
create table referral_click_events (
  id           bigint generated always as identity primary key,
  affiliate_id bigint not null references affiliates(id) on delete cascade,
  session_token text not null,
  clicked_at   timestamptz not null default now()
);
create index idx_referral_click_events_session on referral_click_events(session_token, clicked_at desc);

-- Durable attribution (stage 2). One active row per customer email — "overwritten"
-- per the business rules, not versioned/history-tracked.
create table attribution_records (
  id           bigint generated always as identity primary key,
  email_hash   text not null unique,
  affiliate_id bigint references affiliates(id) on delete set null,
  source_type  text not null check (source_type in ('link', 'code')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  frozen       boolean not null default false,
  frozen_at    timestamptz,
  updated_at   timestamptz not null default now()
);

create table payout_batches (
  id         bigint generated always as identity primary key,
  batch_date date not null unique,
  status     text not null default 'preview' check (status in ('preview', 'finalized')),
  created_at timestamptz not null default now()
);

create table commission_ledger (
  id                    bigint generated always as identity primary key,
  booking_id            bigint not null references bookings(id) on delete restrict unique,
  session_completed_at  timestamptz not null,
  mentor_id             bigint not null references mentors(id) on delete restrict,
  affiliate_id          bigint not null references affiliates(id) on delete restrict,
  split_snapshot        jsonb not null,
  commission_amount_inr numeric(12, 2) not null,
  status                text not null default 'pending_review'
    check (status in ('pending_review', 'approved', 'paid')),
  payout_batch_id       bigint references payout_batches(id),
  created_at            timestamptz not null default now()
);

create table fraud_flags (
  id                      bigint generated always as identity primary key,
  affiliate_id            bigint not null references affiliates(id) on delete cascade,
  booking_id              bigint references bookings(id) on delete set null,
  vector_type             text not null check (vector_type in (
    'duplicate_person', 'volume_spike', 'geography_mismatch',
    'code_speed', 'cancel_rebook_cycling', 'mentor_steering', 'chargeback'
  )),
  status                  text not null default 'escalated'
    check (status in ('auto_cleared', 'escalated', 'resolved')),
  reviewer                bigint references users(id),
  decision                text check (decision in ('approve', 'approve_with_note', 'reject_and_hold')),
  note                    text,
  created_at              timestamptz not null default now(),
  resolved_at             timestamptz,
  escalated_to_cofounder_at timestamptz
);

-- Audit trail for admin overrides that aren't tied to one specific booking
-- (freezing an affiliate, voiding a ledger entry) — booking_events isn't a fit
-- since it requires a booking_id.
create table referral_admin_actions (
  id          bigint generated always as identity primary key,
  action      text not null,
  target_type text not null,
  target_id   bigint not null,
  note        text not null,
  created_at  timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 2. Reuse the existing money ledger for commission payouts.
--    booking_ledger's check constraints only knew about customer/mentor/platform
--    and penalty/refund/credit/charge — widen them additively (nothing removed)
--    so add_ledger() can also record a 'promoter' commission line.
-- ---------------------------------------------------------------------------

alter table booking_ledger drop constraint if exists booking_ledger_party_check;
alter table booking_ledger add constraint booking_ledger_party_check
  check (party in ('customer', 'mentor', 'platform', 'promoter'));

alter table booking_ledger drop constraint if exists booking_ledger_kind_check;
alter table booking_ledger add constraint booking_ledger_kind_check
  check (kind in ('penalty', 'refund', 'credit', 'charge', 'commission'));

-- ---------------------------------------------------------------------------
-- 3. Settings — every tunable number lives in platform_settings, none hardcoded.
--    Two are intentionally left unset (null): mentor-steering threshold and the
--    code-speed high-value threshold. Both checks are built and wired in, but stay
--    inactive (no auto-escalation) until a real number is entered here — per the
--    founder's decision to not guess these two numbers.
-- ---------------------------------------------------------------------------

insert into platform_settings (key, value, description) values
  ('referral_tier_starter_max', '4', 'Non-mentor affiliate tier: max completed referrals/month to stay Starter'),
  ('referral_tier_growth_max', '14', 'Non-mentor affiliate tier: max completed referrals/month to stay Growth (above this = Partner)'),
  ('referral_volume_spike_autoapprove_multiplier', '3', 'Auto-approve up to this multiple of the affiliate''s trailing 30-day daily average'),
  ('referral_volume_spike_escalate_multiplier', '5', 'Escalate for manual review above this multiple of the trailing 30-day average'),
  ('referral_code_redemption_speed_minutes', '30', 'A code used faster than this many minutes after it was created is a speed-fraud signal'),
  ('referral_code_speed_high_value_inr', null, 'INR amount above which a fast code redemption escalates. Unset = this specific escalation stays inactive.'),
  ('referral_mentor_steering_threshold_pct', null, 'Referral concentration % (to one mentor) above which mentor-steering escalates. Unset = tracked as a report only, no auto-escalation.'),
  ('referral_manual_review_escalation_days', '5', 'Days a flagged case can sit before auto-escalating to the co-founder'),
  ('referral_attribution_window_days', '60', 'Days an attribution record stays valid from its most recent qualifying touch (link click or code entry)'),
  ('referral_payout_min_working_days', '5', 'Minimum working days (Mon-Fri) after session completion before a commission is batch-eligible')
on conflict (key) do nothing;

create or replace function referral_setting(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from platform_settings where key = p_key;
$$;

-- ---------------------------------------------------------------------------
-- 4. Row-level security. All writes happen through the SECURITY DEFINER RPCs
--    below (which bypass RLS as their own owner), so these policies only
--    govern what a logged-in affiliate can read directly.
-- ---------------------------------------------------------------------------

alter table affiliates enable row level security;
create policy affiliates_self_read on affiliates for select using (user_id = current_user_id());

alter table affiliate_links enable row level security;
create policy referral_links_self_read on affiliate_links for select using (
  affiliate_id in (select id from affiliates where user_id = current_user_id())
);

alter table referral_codes enable row level security;
create policy referral_codes_self_read on referral_codes for select using (
  affiliate_id in (select id from affiliates where user_id = current_user_id())
);

-- attribution_records: no policies — internal bookkeeping only, never read directly
-- by an affiliate or customer, only through the RPCs below.
alter table attribution_records enable row level security;

alter table commission_ledger enable row level security;
create policy commission_ledger_self_read on commission_ledger for select using (
  affiliate_id in (select id from affiliates where user_id = current_user_id())
);

-- fraud_flags: intentionally no select policy for anyone but admin RPCs — the
-- product spec requires affiliates never see the internal fraud reasoning,
-- only a plain "under review" status (surfaced via affiliate_dashboard_summary).
alter table fraud_flags enable row level security;

alter table payout_batches enable row level security;
alter table referral_click_events enable row level security;
alter table referral_admin_actions enable row level security;

-- ---------------------------------------------------------------------------
-- 5. Affiliate onboarding (admin-created, invite-only — Section 1 of the
--    product doc). Matches the existing admin panel's current security model:
--    the admin_* RPCs are ungated for now, same as the rest of the admin panel
--    (see web/app/admin/page.tsx) — this is a known, pre-existing gap, not
--    something newly introduced here.
-- ---------------------------------------------------------------------------

create or replace function admin_create_affiliate(
  p_user_id bigint,
  p_type text,
  p_mentor_id bigint default null,
  p_payout_details jsonb default null,
  p_audience_corridor text default null
) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if p_type not in ('mentor', 'non_mentor') then
    raise exception 'Affiliate type must be mentor or non_mentor';
  end if;
  if p_type = 'mentor' and p_mentor_id is null then
    raise exception 'A mentor affiliate must reference an existing mentor_id';
  end if;
  insert into affiliates (user_id, type, mentor_id, payout_details, audience_corridor, agreed_terms_at)
    values (p_user_id, p_type, p_mentor_id, p_payout_details, p_audience_corridor, now())
    returning id into v_id;
  return v_id;
end; $$;

create or replace function admin_create_referral_link(p_affiliate_id bigint, p_slug text, p_is_house_channel boolean default false)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_clean text := lower(trim(p_slug));
begin
  if v_clean !~ '^[a-z0-9-]{3,40}$' then
    raise exception 'Slug must be 3-40 characters, lowercase letters/numbers/hyphens only';
  end if;
  insert into affiliate_links (affiliate_id, slug, is_house_channel)
    values (p_affiliate_id, v_clean, p_is_house_channel)
    returning id into v_id;
  return v_id;
end; $$;

create or replace function admin_create_referral_code(p_affiliate_id bigint, p_code text, p_redemption_cap integer, p_expires_at timestamptz)
returns bigint language plpgsql security definer set search_path = public as $$
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
  insert into referral_codes (affiliate_id, code_string, redemption_cap, expires_at)
    values (p_affiliate_id, v_clean, p_redemption_cap, p_expires_at)
    returning id into v_id;
  return v_id;
end; $$;

-- ---------------------------------------------------------------------------
-- 6. Attribution service (02_Technical_Architecture.md Section 2).
-- ---------------------------------------------------------------------------

create or replace function log_referral_click(p_slug text, p_session_token text)
returns void language plpgsql security definer set search_path = public as $$
declare v_affiliate_id bigint;
begin
  select affiliate_id into v_affiliate_id from affiliate_links where slug = lower(trim(p_slug));
  if not found then return; end if; -- unknown slug: fail silently, don't break the visitor's page load
  insert into referral_click_events (affiliate_id, session_token) values (v_affiliate_id, p_session_token);
end; $$;

-- Called at checkout. Precedence, per business rules Section 3: a code entered
-- this checkout always wins; otherwise a unique-link click logged against THIS
-- session (i.e. the last touch before checkout, not just the last click of the
-- whole browsing session, per 02_Technical_Architecture.md Section 2's multi-tab
-- precision note) overwrites any prior attribution; if neither happened this
-- checkout, whatever attribution already existed for this email is left as-is
-- (this is what makes "return via a later generic link" a no-op).
create or replace function resolve_referral_attribution(p_session_token text, p_email text, p_code text default null)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_hash text; v_click_affiliate bigint; v_code_affiliate bigint; v_window_days int;
  v_existing attribution_records;
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
  elsif v_click_affiliate is not null then
    insert into attribution_records (email_hash, affiliate_id, source_type, created_at, expires_at)
      values (v_hash, v_click_affiliate, 'link', now(), now() + (v_window_days || ' days')::interval)
      on conflict (email_hash) do update set
        affiliate_id = excluded.affiliate_id, source_type = 'link',
        created_at = now(), expires_at = now() + (v_window_days || ' days')::interval, updated_at = now();
  end if;
end; $$;

create or replace function referral_email_for_booking(p_booking_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(b.guest_email, u.email) from bookings b left join users u on u.id = b.user_id where b.id = p_booking_id;
$$;

-- Freezes the 60-day clock the moment a mentor no-show is logged against a
-- referred booking (business rules Section 7). Called from flag_no_show below.
create or replace function freeze_referral_attribution(p_booking_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text; v_hash text;
begin
  v_email := referral_email_for_booking(p_booking_id);
  if v_email is null then return; end if;
  v_hash := encode(extensions.digest(lower(trim(v_email)), 'sha256'), 'hex');
  update attribution_records set frozen = true, frozen_at = now() where email_hash = v_hash and not frozen;
end; $$;

-- Unfreezes once a rebooking decision is made, extending expires_at by however
-- long it sat frozen so the customer doesn't lose attribution time to the wait.
create or replace function unfreeze_referral_attribution(p_booking_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare v_email text; v_hash text;
begin
  v_email := referral_email_for_booking(p_booking_id);
  if v_email is null then return; end if;
  v_hash := encode(extensions.digest(lower(trim(v_email)), 'sha256'), 'hex');
  update attribution_records
    set frozen = false, expires_at = expires_at + (now() - frozen_at), frozen_at = null
    where email_hash = v_hash and frozen;
end; $$;

-- Wrap the existing no-show functions to also freeze/unfreeze referral
-- attribution. Bodies below are byte-for-byte the existing logic from
-- 0071_lifecycle_consolidation.sql with one addition each (marked) —
-- no existing behavior changes.
create or replace function flag_no_show(p_booking_id bigint, p_no_show_party text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  if p_no_show_party not in ('mentor','customer') then raise exception 'no_show_party must be mentor or customer'; end if;
  select * into b from bookings where id = p_booking_id for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status not in ('confirmed','rescheduled') then raise exception 'Only an active session can be reported as a no-show'; end if;
  if b.slot_time is null or now() < b.slot_time + interval '10 minutes' then
    raise exception 'No-shows can only be reported 10 minutes after the start time';
  end if;
  update bookings set status = 'no_show', no_show_by = p_no_show_party where id = p_booking_id;
  update reschedule_offers set status = 'superseded' where booking_id = p_booking_id and status in ('pending','mentee_selected');
  update booking_requests set status = 'withdrawn', resolved_at = now() where booking_id = p_booking_id and status = 'pending';
  perform notify_booking_event(p_booking_id, 'no_show');
  perform log_event(p_booking_id, case when p_no_show_party='mentor' then 'customer' else 'mentor' end,
                    'Reported a no-show', 'Marked the '||p_no_show_party||' as not attending');
  if p_no_show_party = 'mentor' then
    perform freeze_referral_attribution(p_booking_id); -- ADDED: referral system hook
  end if;
end; $$;

create or replace function resolve_mentor_no_show(p_booking_id bigint, p_choice text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings; v_cost numeric;
begin
  select * into b from bookings where id = p_booking_id for update;
  if b.no_show_by is distinct from 'mentor' or b.status <> 'no_show' then raise exception 'Not a mentor no-show awaiting resolution'; end if;
  select amount into v_cost from customer_payments where booking_id = p_booking_id order by id desc limit 1;
  if p_choice = 'rebook_same' then
    update bookings set status = 'confirmed', no_show_by = null where id = p_booking_id;
  elsif p_choice = 'rebook_different' then
    update bookings set status = 'cancelled', no_show_by = null where id = p_booking_id;   -- close the window (0067 fix)
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'credit', v_cost, 100, 'Mentor no-show — credit to rebook another mentor');
  elsif p_choice = 'refund' then
    update bookings set status = 'cancelled', no_show_by = null where id = p_booking_id;   -- close the window (0067 fix)
    perform apply_mentor_strike(b.mentor_id, p_booking_id);
    perform add_ledger(p_booking_id, 'customer', 'refund', v_cost, 100, 'Mentor no-show — full refund');
  else raise exception 'Unknown choice %', p_choice; end if;
  perform log_event(p_booking_id, 'customer', 'Mentor no-show resolved: '||p_choice);
  perform unfreeze_referral_attribution(p_booking_id); -- ADDED: referral system hook
end; $$;

-- ---------------------------------------------------------------------------
-- 7. Commission calculator + fraud engine
--    (02_Technical_Architecture.md Sections 3 and 4).
-- ---------------------------------------------------------------------------

-- "Cannot advance a tier while flagged" (business rules Section 5) means the
-- affiliate is held at whatever tier they'd already reached THIS month before
-- their first active flag appeared — not reset to Starter. A flag never blocks
-- tier progress that was already earned; it only stops further advancement.
create or replace function current_affiliate_tier(p_affiliate_id bigint)
returns text language plpgsql stable security definer set search_path = public as $$
declare
  v_type text; v_starter_max int; v_growth_max int;
  v_count_now int; v_count_at_flag int; v_first_flag_at timestamptz;
  v_rank_now int; v_rank_at_flag int; v_rank int;
begin
  select type into v_type from affiliates where id = p_affiliate_id;
  if v_type = 'mentor' then return 'flat_peer_rate'; end if; -- mentor-to-mentor referrals never tier

  v_starter_max := coalesce(referral_setting('referral_tier_starter_max')::int, 4);
  v_growth_max := coalesce(referral_setting('referral_tier_growth_max')::int, 14);

  select count(*) into v_count_now from commission_ledger
    where affiliate_id = p_affiliate_id and status in ('approved', 'paid')
      and date_trunc('month', session_completed_at) = date_trunc('month', now());
  v_rank_now := case when v_count_now <= v_starter_max then 1 when v_count_now <= v_growth_max then 2 else 3 end;

  select min(created_at) into v_first_flag_at from fraud_flags
    where affiliate_id = p_affiliate_id and status = 'escalated'
      and date_trunc('month', created_at) = date_trunc('month', now());

  if v_first_flag_at is null then
    v_rank := v_rank_now; -- no active flag this month: free to advance normally
  else
    select count(*) into v_count_at_flag from commission_ledger
      where affiliate_id = p_affiliate_id and status in ('approved', 'paid')
        and date_trunc('month', session_completed_at) = date_trunc('month', now())
        and created_at < v_first_flag_at;
    v_rank_at_flag := case when v_count_at_flag <= v_starter_max then 1 when v_count_at_flag <= v_growth_max then 2 else 3 end;
    v_rank := least(v_rank_now, v_rank_at_flag); -- capped at the tier already reached before the flag
  end if;

  return case v_rank when 1 then 'starter' when 2 then 'growth' else 'partner' end;
end; $$;

-- Deterministic fraud checks. Two vectors from the business rules doc can't be
-- built yet with the data currently captured anywhere in the schema, and are
-- left as explicit no-ops rather than guessed at:
--   - Self-referral via device/IP/payment fingerprint (no such data is stored
--     per booking today).
--   - Geography mismatch (no customer-geography column exists on bookings yet;
--     the edge middleware's ig_geo cookie is client-side only and never
--     reaches the database).
-- Mentor-steering concentration is deliberately informational-only per the
-- founder's decision — see admin_mentor_steering_report() below.
create or replace function run_referral_fraud_checks(p_ledger_id bigint)
returns void language plpgsql security definer set search_path = public as $$
declare
  cl commission_ledger;
  v_avg30 numeric; v_today_count int; v_spike_escalate numeric;
  v_email text; v_hash text; v_att attribution_records; v_code referral_codes;
  v_speed_minutes numeric; v_speed_high_value numeric;
  v_flagged boolean := false;
begin
  select * into cl from commission_ledger where id = p_ledger_id;

  -- Volume spike
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

  -- Code redemption speed (only relevant if this referral came from a code)
  v_email := referral_email_for_booking(cl.booking_id);
  v_hash := encode(extensions.digest(lower(trim(v_email)), 'sha256'), 'hex');
  select * into v_att from attribution_records where email_hash = v_hash;
  if v_att.source_type = 'code' then
    select * into v_code from referral_codes where affiliate_id = cl.affiliate_id;
    v_speed_minutes := coalesce(referral_setting('referral_code_redemption_speed_minutes')::numeric, 30);
    v_speed_high_value := referral_setting('referral_code_speed_high_value_inr')::numeric; -- null = check inactive
    if v_speed_high_value is not null
       and extract(epoch from (v_att.created_at - v_code.created_at)) / 60.0 <= v_speed_minutes
       and cl.commission_amount_inr > v_speed_high_value then
      insert into fraud_flags (affiliate_id, booking_id, vector_type, status) values (cl.affiliate_id, cl.booking_id, 'code_speed', 'escalated');
      v_flagged := true;
    end if;
  end if;

  -- Cancel/rebook cycling — reuses the existing bookings.reschedule_count column
  if (select reschedule_count from bookings where id = cl.booking_id) >= 3 then
    insert into fraud_flags (affiliate_id, booking_id, vector_type, status) values (cl.affiliate_id, cl.booking_id, 'cancel_rebook_cycling', 'escalated');
    v_flagged := true;
  end if;

  if not v_flagged then
    update commission_ledger set status = 'approved' where id = p_ledger_id;
  end if;
end; $$;

-- Runs on a schedule (see cron.schedule below), not on booking creation — the
-- business rule is completion-only. Idempotent: only processes bookings that
-- don't already have a commission_ledger row.
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
      continue; -- organic, lapsed, or still awaiting a no-show decision — no ledger entry, per the rules
    end if;

    -- Referral credit applies to the customer's lifetime first paid session only
    select exists(
      select 1 from bookings b2
      where b2.id <> r.id and b2.status = 'completed'
        and coalesce(b2.guest_email, (select email from users where id = b2.user_id)) = v_email
        and b2.slot_time < r.slot_time
    ) into v_already_had_session;
    if v_already_had_session then continue; end if;

    select * into v_aff from affiliates where id = v_att.affiliate_id;
    if v_aff.status <> 'active' then continue; end if;

    -- The founder's own house channel always pays 0% promoter fee — it's owned
    -- marketing, not a paid acquisition channel, so no payable commission is
    -- created (equivalent to organic for payout purposes; the click/attribution
    -- data is still captured above for analytics).
    if v_att.source_type = 'link' and exists (
      select 1 from affiliate_links rl where rl.affiliate_id = v_aff.id and rl.is_house_channel
    ) then
      continue;
    end if;

    select amount into v_gross from customer_payments where booking_id = r.id order by id desc limit 1;
    if v_gross is null then continue; end if;

    if v_aff.mentor_id = r.mentor_id then
      -- Scenarios 1/2/5: the promoter is the mentor who delivered the session
      v_mentor_pct := 90; v_immigroov_pct := 10; v_promoter_pct := 0;
    elsif v_aff.type = 'mentor' then
      -- Scenarios 3/6: mentor-to-mentor peer referral — flat, never tiered
      v_mentor_pct := 70; v_immigroov_pct := 20; v_promoter_pct := 10;
    else
      -- Scenarios 4/6: non-mentor influencer — tiered by this-month completed-referral count
      v_tier := current_affiliate_tier(v_aff.id);
      v_mentor_pct := 70;
      case v_tier
        when 'growth'  then v_immigroov_pct := 19; v_promoter_pct := 11;
        when 'partner' then v_immigroov_pct := 15; v_promoter_pct := 15;
        else                v_immigroov_pct := 22; v_promoter_pct := 8; -- starter, and the blocked-pending-review fallback (fraud gate withholds payment regardless)
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

create or replace function escalate_stale_fraud_flags()
returns void language plpgsql security definer set search_path = public as $$
declare v_days int;
begin
  v_days := coalesce(referral_setting('referral_manual_review_escalation_days')::int, 5);
  update fraud_flags
    set escalated_to_cofounder_at = now()
    where status = 'escalated' and escalated_to_cofounder_at is null
      and created_at < now() - (v_days || ' days')::interval;
end; $$;

-- Dashboard-only metric, per the founder's decision to not auto-escalate this
-- vector without a defined threshold. Shows, per affiliate this month, what
-- share of their referrals went to their single most-referred mentor.
create or replace function admin_mentor_steering_report()
returns table(affiliate_id bigint, top_mentor_id bigint, concentration_pct numeric)
language sql stable security definer set search_path = public as $$
  select cl.affiliate_id, cl.mentor_id,
         round(100.0 * count(*) / sum(count(*)) over (partition by cl.affiliate_id), 1)
  from commission_ledger cl
  where cl.session_completed_at >= date_trunc('month', now())
  group by cl.affiliate_id, cl.mentor_id
  order by cl.affiliate_id, 3 desc;
$$;

-- ---------------------------------------------------------------------------
-- 8. Manual review queue (Sections 5 and 8).
-- ---------------------------------------------------------------------------

create or replace function admin_referral_review_queue()
returns table (
  flag_id bigint, affiliate_id bigint, booking_id bigint, vector_type text,
  created_at timestamptz, escalated_to_cofounder_at timestamptz,
  commission_amount_inr numeric, split_snapshot jsonb
) language sql stable security definer set search_path = public as $$
  select ff.id, ff.affiliate_id, ff.booking_id, ff.vector_type, ff.created_at, ff.escalated_to_cofounder_at,
         cl.commission_amount_inr, cl.split_snapshot
  from fraud_flags ff
  left join commission_ledger cl on cl.booking_id = ff.booking_id
  where ff.status = 'escalated'
  order by ff.created_at asc;
$$;

create or replace function admin_resolve_fraud_flag(p_flag_id bigint, p_decision text, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare f fraud_flags;
begin
  if p_decision not in ('approve', 'approve_with_note', 'reject_and_hold') then
    raise exception 'Decision must be approve, approve_with_note, or reject_and_hold';
  end if;
  select * into f from fraud_flags where id = p_flag_id for update;
  if not found then raise exception 'Flag not found'; end if;

  update fraud_flags set status = 'resolved', decision = p_decision, note = p_note, resolved_at = now() where id = p_flag_id;

  if p_decision in ('approve', 'approve_with_note') then
    update commission_ledger set status = 'approved' where booking_id = f.booking_id and status = 'pending_review';
  end if;
  -- reject_and_hold: ledger entry simply stays pending_review forever — there is
  -- no separate "rejected" state in the ledger's 3-state design, so it just
  -- never becomes eligible for a payout batch. This matches "no clawback is
  -- ever needed" since nothing was paid in the first place.
end; $$;

-- ---------------------------------------------------------------------------
-- 9. Payout batching (Section 5 / business rules Section 9). Twice-monthly OR
--    5 working days after completion, whichever is later — implemented with a
--    real Mon-Fri working-day calendar, not naive calendar days, per the
--    worked examples in the technical architecture doc.
--    IMPORTANT SCOPE NOTE: per the founder's decision, this only tracks
--    eligibility and marks entries "paid" (i.e. swept into a finalized batch).
--    It does NOT move any money — the actual bank/PayPal/Razorpay transfer is
--    a manual step the admin does outside this system for V1.
-- ---------------------------------------------------------------------------

create or replace function add_working_days(p_start timestamptz, p_days int)
returns timestamptz language plpgsql immutable as $$
declare v_date date := p_start::date; v_added int := 0;
begin
  while v_added < p_days loop
    v_date := v_date + 1;
    if extract(isodow from v_date) < 6 then v_added := v_added + 1; end if; -- Mon-Fri only, no holiday calendar (locked V1 convention)
  end loop;
  return v_date::timestamptz;
end; $$;

create or replace function admin_payout_batch_preview(p_batch_date date)
returns table (commission_ledger_id bigint, affiliate_id bigint, amount_inr numeric, booking_id bigint)
language plpgsql stable security definer set search_path = public as $$
declare v_min_days int;
begin
  v_min_days := coalesce(referral_setting('referral_payout_min_working_days')::int, 5);
  return query
    select cl.id, cl.affiliate_id, cl.commission_amount_inr, cl.booking_id
    from commission_ledger cl
    where cl.status = 'approved'
      and cl.payout_batch_id is null
      and add_working_days(cl.session_completed_at, v_min_days) <= p_batch_date::timestamptz;
end; $$;

create or replace function admin_finalize_payout_batch(p_batch_date date)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_batch_id bigint;
begin
  insert into payout_batches (batch_date, status) values (p_batch_date, 'finalized')
    on conflict (batch_date) do update set status = 'finalized'
    returning id into v_batch_id;
  update commission_ledger cl
    set payout_batch_id = v_batch_id, status = 'paid'
    from admin_payout_batch_preview(p_batch_date) prev
    where cl.id = prev.commission_ledger_id;
  return v_batch_id;
end; $$;

-- ---------------------------------------------------------------------------
-- 10. Manual override tools (Section 5) — each requires a note for the audit trail.
-- ---------------------------------------------------------------------------

create or replace function admin_freeze_affiliate(p_affiliate_id bigint, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_note is null or trim(p_note) = '' then raise exception 'A note is required to freeze an affiliate'; end if;
  update affiliates set status = 'frozen' where id = p_affiliate_id;
  insert into referral_admin_actions (action, target_type, target_id, note) values ('freeze', 'affiliate', p_affiliate_id, p_note);
end; $$;

create or replace function admin_unfreeze_affiliate(p_affiliate_id bigint, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_note is null or trim(p_note) = '' then raise exception 'A note is required to unfreeze an affiliate'; end if;
  update affiliates set status = 'active' where id = p_affiliate_id;
  insert into referral_admin_actions (action, target_type, target_id, note) values ('unfreeze', 'affiliate', p_affiliate_id, p_note);
end; $$;

create or replace function admin_void_commission_ledger_entry(p_ledger_id bigint, p_note text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_note is null or trim(p_note) = '' then raise exception 'A note is required to void a ledger entry'; end if;
  update commission_ledger set status = 'pending_review', payout_batch_id = null where id = p_ledger_id;
  insert into referral_admin_actions (action, target_type, target_id, note) values ('void_ledger_entry', 'commission_ledger', p_ledger_id, p_note);
end; $$;

-- ---------------------------------------------------------------------------
-- 11. Affiliate-facing read (Section 4). Deliberately hides fraud-flag
--     reasoning — only ever exposes a plain boolean "under_review".
-- ---------------------------------------------------------------------------

create or replace function affiliate_dashboard_summary()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_affiliate affiliates; v_link affiliate_links; v_code referral_codes; v_result jsonb;
begin
  select * into v_affiliate from affiliates where user_id = current_user_id();
  if not found then raise exception 'Not an affiliate account'; end if;
  select * into v_link from affiliate_links where affiliate_id = v_affiliate.id;
  select * into v_code from referral_codes where affiliate_id = v_affiliate.id;

  select jsonb_build_object(
    'affiliate', jsonb_build_object('id', v_affiliate.id, 'type', v_affiliate.type, 'status', v_affiliate.status),
    'link', jsonb_build_object('slug', v_link.slug, 'is_house_channel', v_link.is_house_channel),
    'code', jsonb_build_object('code', v_code.code_string, 'expires_at', v_code.expires_at,
                                'redemption_count', v_code.redemption_count, 'redemption_cap', v_code.redemption_cap),
    'tier', current_affiliate_tier(v_affiliate.id),
    'pending_commission_inr', (select coalesce(sum(commission_amount_inr), 0) from commission_ledger where affiliate_id = v_affiliate.id and status in ('pending_review', 'approved')),
    'paid_commission_inr', (select coalesce(sum(commission_amount_inr), 0) from commission_ledger where affiliate_id = v_affiliate.id and status = 'paid'),
    'referrals', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'booking_id', cl.booking_id, 'status', cl.status, 'amount_inr', cl.commission_amount_inr,
        'under_review', exists(select 1 from fraud_flags f where f.booking_id = cl.booking_id and f.status = 'escalated')
      )), '[]'::jsonb)
      from commission_ledger cl where cl.affiliate_id = v_affiliate.id
    )
  ) into v_result;
  return v_result;
end; $$;

-- ---------------------------------------------------------------------------
-- 12. Scheduled jobs — same 15-minute cadence as the existing auto-complete
--     job (0011_reschedule_complete_flow.sql) so commissions are calculated
--     shortly after a session is marked completed.
-- ---------------------------------------------------------------------------

select cron.schedule('referral-commissions', '*/15 * * * *', $$ select process_referral_commissions() $$);
select cron.schedule('referral-escalations', '0 3 * * *', $$ select escalate_stale_fraud_flags() $$);
