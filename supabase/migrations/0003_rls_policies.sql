-- =============================================================================
-- Immigroov — Row Level Security
-- =============================================================================
-- Supabase exposes every table via PostgREST, so RLS must be enabled on all of
-- them. The `service_role` key (used by your AWS Lambda / backend) BYPASSES RLS,
-- so server-side logic is unaffected. These policies govern the anon/authed API.
-- =============================================================================

-- Map the JWT (auth.uid()) to our internal users.id
create or replace function current_user_id()
returns bigint
language sql stable
as $$
  select id from users where auth_id = auth.uid();
$$;

-- Is the current user the owner (by mentor row) ?
create or replace function current_mentor_id()
returns bigint
language sql stable
as $$
  select m.id from mentors m
  join users u on u.id = m.user_id
  where u.auth_id = auth.uid();
$$;

-- -----------------------------------------------------------------------------
-- Enable RLS everywhere
-- -----------------------------------------------------------------------------
alter table users                      enable row level security;
alter table mentors                    enable row level security;
alter table languages                  enable row level security;
alter table mentor_languages           enable row level security;
alter table specializations            enable row level security;
alter table mentor_specializations     enable row level security;
alter table mentor_verifications       enable row level security;
alter table social_links               enable row level security;
alter table address                    enable row level security;
alter table services                   enable row level security;
alter table service_pricing            enable row level security;
alter table platform_settings          enable row level security;
alter table weekly_availability        enable row level security;
alter table specific_availability      enable row level security;
alter table discounts                  enable row level security;
alter table bookings                   enable row level security;
alter table customer_payments          enable row level security;
alter table mentor_payouts             enable row level security;
alter table reviews                    enable row level security;
alter table service_questions          enable row level security;
alter table booking_question_answers   enable row level security;
alter table mentor_cancellation_policy enable row level security;
alter table referral_links             enable row level security;

-- -----------------------------------------------------------------------------
-- Public discovery (anyone can read active marketplace content)
-- -----------------------------------------------------------------------------
create policy "public read languages"        on languages              for select using (true);
create policy "public read specializations"  on specializations        for select using (true);
create policy "public read mentors"          on mentors                for select using (true);
create policy "public read mentor_languages" on mentor_languages       for select using (true);
create policy "public read mentor_specs"     on mentor_specializations for select using (true);
create policy "public read services"         on services               for select using (is_active);
create policy "public read pricing"          on service_pricing        for select using (is_active);
create policy "public read questions"        on service_questions      for select using (is_active);
create policy "public read reviews"          on reviews                for select using (true);
create policy "public read weekly_avail"     on weekly_availability    for select using (is_active);
create policy "public read specific_avail"   on specific_availability  for select using (true);
create policy "public read social_links"     on social_links           for select using (true);

-- -----------------------------------------------------------------------------
-- USERS — self access
-- -----------------------------------------------------------------------------
create policy "users read self"   on users for select using (auth_id = auth.uid());
create policy "users update self" on users for update using (auth_id = auth.uid());

-- -----------------------------------------------------------------------------
-- MENTORS — owner manages own profile (read is public above)
-- -----------------------------------------------------------------------------
create policy "mentor manages own profile" on mentors
  for all using (user_id = current_user_id())
  with check (user_id = current_user_id());

-- Mentor-owned child records (insert/update/delete by owning mentor)
create policy "mentor manages own services" on services
  for all using (mentor_id = current_mentor_id())
  with check (mentor_id = current_mentor_id());

create policy "mentor manages own pricing" on service_pricing
  for all using (service_id in (select id from services where mentor_id = current_mentor_id()))
  with check (service_id in (select id from services where mentor_id = current_mentor_id()));

create policy "mentor manages own questions" on service_questions
  for all using (service_id in (select id from services where mentor_id = current_mentor_id()))
  with check (service_id in (select id from services where mentor_id = current_mentor_id()));

create policy "mentor manages own weekly_avail" on weekly_availability
  for all using (mentor_id = current_mentor_id())
  with check (mentor_id = current_mentor_id());

create policy "mentor manages own specific_avail" on specific_availability
  for all using (mentor_id = current_mentor_id())
  with check (mentor_id = current_mentor_id());

create policy "mentor reads own verifications" on mentor_verifications
  for select using (mentor_id = current_mentor_id());
create policy "mentor submits verifications" on mentor_verifications
  for insert with check (mentor_id = current_mentor_id());

create policy "mentor reads own payouts" on mentor_payouts
  for select using (mentor_id = current_mentor_id());

create policy "mentor reads own cancel policy" on mentor_cancellation_policy
  for select using (mentor_id = current_mentor_id());

-- -----------------------------------------------------------------------------
-- ADDRESS & SOCIAL LINKS — owner manages
-- -----------------------------------------------------------------------------
create policy "user manages own address" on address
  for all using (user_id = current_user_id())
  with check (user_id = current_user_id());

create policy "user manages own social_links" on social_links
  for all using (user_id = current_user_id())
  with check (user_id = current_user_id());

-- -----------------------------------------------------------------------------
-- BOOKINGS — customer or the booked mentor can see; customer creates
-- -----------------------------------------------------------------------------
create policy "booking visible to participants" on bookings
  for select using (user_id = current_user_id() or mentor_id = current_mentor_id());
create policy "customer creates booking" on bookings
  for insert with check (user_id = current_user_id());
create policy "participants update booking" on bookings
  for update using (user_id = current_user_id() or mentor_id = current_mentor_id());

-- -----------------------------------------------------------------------------
-- PAYMENTS — customer who owns the booking can read
-- -----------------------------------------------------------------------------
create policy "customer reads own payments" on customer_payments
  for select using (booking_id in (select id from bookings where user_id = current_user_id()));

-- -----------------------------------------------------------------------------
-- BOOKING QUESTION ANSWERS — customer who owns the booking
-- -----------------------------------------------------------------------------
create policy "customer manages own answers" on booking_question_answers
  for all using (booking_id in (select id from bookings where user_id = current_user_id()))
  with check (booking_id in (select id from bookings where user_id = current_user_id()));

-- -----------------------------------------------------------------------------
-- REVIEWS — customer writes review for own booking
-- -----------------------------------------------------------------------------
create policy "customer writes review" on reviews
  for insert with check (user_id = current_user_id()
    and booking_id in (select id from bookings where user_id = current_user_id()));
create policy "customer edits own review" on reviews
  for update using (user_id = current_user_id());

-- -----------------------------------------------------------------------------
-- DISCOUNTS — anyone can read active codes (validation still server-side)
-- -----------------------------------------------------------------------------
create policy "public read active discounts" on discounts
  for select using (is_active);

-- -----------------------------------------------------------------------------
-- REFERRAL LINKS — referrer can see their own
-- -----------------------------------------------------------------------------
create policy "referrer reads own links" on referral_links
  for select using (referrer_mentor_id = current_user_id());

-- platform_settings & mentor_payouts writes: no anon/authed policies ->
-- only the backend (service_role) can write them. (RLS denies by default.)
