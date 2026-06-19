-- =============================================================================
-- Immigroov Mentor Marketplace — Initial Schema
-- Target: Supabase (PostgreSQL 15+)
-- =============================================================================
-- Notes:
--  * Serial PKs -> `bigint generated always as identity`
--  * timestamp  -> `timestamptz`
--  * Documented status varchars -> Postgres ENUM types
--  * Supabase ships gen_random_uuid() (pgcrypto) by default
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ENUM TYPES
-- -----------------------------------------------------------------------------
create type user_role            as enum ('mentor', 'user', 'admin', 'super_admin');
create type verification_status  as enum ('pending', 'approved', 'rejected');
create type service_type         as enum ('video', 'dm');
create type question_type        as enum ('text', 'multiple_choice', 'yes_no');
create type booking_status       as enum ('pending', 'confirmed', 'rescheduled', 'cancelled', 'completed', 'no_show');
create type payment_status       as enum ('initiated', 'paid', 'failed', 'refunded');
create type payout_status        as enum ('pending', 'requested', 'processing', 'paid', 'failed');
create type referral_type        as enum ('mentor', 'user');

-- -----------------------------------------------------------------------------
-- USERS
-- -----------------------------------------------------------------------------
-- `auth_id` bridges this profile row to Supabase Auth (auth.users). Keep
-- password_hash only if you are NOT using Supabase Auth for credentials.
create table users (
  id            bigint generated always as identity primary key,
  auth_id       uuid unique references auth.users(id) on delete set null,
  first_name    varchar(100),
  last_name     varchar(100),
  email         varchar(255) unique not null,
  password_hash text,
  role          user_role not null default 'user',
  is_verified   boolean not null default false,
  created_at    timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- MENTORS
-- -----------------------------------------------------------------------------
create table mentors (
  id                     bigint generated always as identity primary key,
  user_id                bigint not null references users(id) on delete cascade,
  title                  text,
  about_me               text,
  languages              text,
  disclaimer             text,
  currency               varchar(3),
  app_timezone           varchar(64),
  app_buffertime         varchar(50),
  app_minimum_notice     varchar(50),
  app_booking_window     varchar(50),
  app_cancellation_policy varchar(255),
  app_reschedule_policy  varchar(255),
  response_time          varchar(50),
  is_available           boolean not null default true,
  expertise_tag          text,
  profile_pic_url        text,
  created_at             timestamptz not null default now(),
  unique (user_id)
);

-- -----------------------------------------------------------------------------
-- LANGUAGES & SPECIALIZATIONS (lookup + junctions)
-- -----------------------------------------------------------------------------
create table languages (
  id        bigint generated always as identity primary key,
  name      varchar(100) unique not null,
  lang_code varchar(10)
);

create table mentor_languages (
  mentor_id   bigint not null references mentors(id) on delete cascade,
  language_id bigint not null references languages(id) on delete cascade,
  primary key (mentor_id, language_id)
);

create table specializations (
  id   bigint generated always as identity primary key,
  name varchar(150) unique not null
);

create table mentor_specializations (
  mentor_id        bigint not null references mentors(id) on delete cascade,
  specialization_id bigint not null references specializations(id) on delete cascade,
  primary key (mentor_id, specialization_id)
);

-- -----------------------------------------------------------------------------
-- MENTOR VERIFICATIONS
-- -----------------------------------------------------------------------------
create table mentor_verifications (
  id           bigint generated always as identity primary key,
  mentor_id    bigint not null references mentors(id) on delete cascade,
  type         varchar(50),                 -- id_proof, degree, experience, license, etc.
  document_url text,
  status       verification_status not null default 'pending',
  submitted_at timestamptz not null default now(),
  reviewed_at  timestamptz,
  comments     text
);

-- -----------------------------------------------------------------------------
-- SOCIAL LINKS & ADDRESS
-- -----------------------------------------------------------------------------
create table social_links (
  id         bigint generated always as identity primary key,
  user_id    bigint not null references users(id) on delete cascade,
  platform   varchar(50),                   -- LinkedIn, Twitter, Instagram, etc.
  url        text,
  created_at timestamptz not null default now()
);

create table address (
  id          bigint generated always as identity primary key,
  user_id     bigint not null unique references users(id) on delete cascade,
  street      text,
  city        varchar(100),
  state       varchar(100),
  postal_code varchar(20),
  country     varchar(100),
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- SERVICES
-- -----------------------------------------------------------------------------
create table services (
  id               bigint generated always as identity primary key,
  mentor_id        bigint not null references mentors(id) on delete cascade,
  title            varchar(200),
  description      text,
  type             service_type,
  duration         int,                     -- minutes
  is_ppp           boolean not null default false,  -- purchasing-power parity pricing
  is_active        boolean not null default true,
  base_template_id bigint references services(id) on delete set null  -- null if original
);

-- -----------------------------------------------------------------------------
-- SERVICE PRICING (per-country) — includes Immigroov platform price
-- -----------------------------------------------------------------------------
create table service_pricing (
  id              bigint generated always as identity primary key,
  service_id      bigint not null references services(id) on delete cascade,
  country_code    varchar(2),               -- e.g. NL, IN, US
  currency        varchar(3),
  base_price      numeric(10,2),            -- mentor list price
  offer_price     numeric(10,2),            -- discounted/promotional price
  immigroov_price numeric(10,2),            -- platform fee charged on top of mentor price
  is_active       boolean not null default true,
  unique (service_id, country_code)
);

comment on column service_pricing.immigroov_price is
  'Immigroov platform fee/commission applied for this service in this country. '
  'Customer pays (offer_price or base_price) + immigroov_price; mentor payout '
  'excludes immigroov_price.';

-- -----------------------------------------------------------------------------
-- PLATFORM SETTINGS (global default Immigroov commission, etc.)
-- -----------------------------------------------------------------------------
create table platform_settings (
  id                       bigint generated always as identity primary key,
  key                      varchar(100) unique not null,
  value                    text,
  description              text,
  updated_at               timestamptz not null default now()
);

insert into platform_settings (key, value, description) values
  ('immigroov_commission_pct', '15', 'Default Immigroov commission percentage applied when service_pricing.immigroov_price is not set'),
  ('default_currency', 'USD', 'Fallback currency for the platform');

-- -----------------------------------------------------------------------------
-- AVAILABILITY
-- -----------------------------------------------------------------------------
create table weekly_availability (
  id         uuid primary key default gen_random_uuid(),
  mentor_id  bigint not null references mentors(id) on delete cascade,
  weekday    varchar(10),                   -- Monday..Sunday
  start_time time,
  end_time   time,
  timezone   varchar(64),                   -- e.g. UTC, America/New_York, Asia/Kolkata
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

create table specific_availability (
  id         uuid primary key default gen_random_uuid(),
  mentor_id  bigint not null references mentors(id) on delete cascade,
  slot_date  date,
  start_time time,
  end_time   time,
  timezone   varchar(64),
  is_booked  boolean not null default false,
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- DISCOUNTS
-- -----------------------------------------------------------------------------
create table discounts (
  id          bigint generated always as identity primary key,
  code        varchar(50) unique not null,
  description text,
  percentage  int check (percentage between 0 and 100),
  max_uses    int,
  expires_at  timestamptz,
  is_active   boolean not null default true
);

-- -----------------------------------------------------------------------------
-- BOOKINGS
-- -----------------------------------------------------------------------------
create table bookings (
  id          bigint generated always as identity primary key,
  user_id     bigint not null references users(id) on delete restrict,
  mentor_id   bigint not null references mentors(id) on delete restrict,
  service_id  bigint not null references services(id) on delete restrict,
  discount_id bigint references discounts(id) on delete set null,
  slot_time   timestamptz,
  status      booking_status not null default 'pending',
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- PAYMENTS (customer -> platform)
-- -----------------------------------------------------------------------------
create table customer_payments (
  id                bigint generated always as identity primary key,
  booking_id        bigint not null references bookings(id) on delete cascade,
  amount            numeric(10,2),
  currency          varchar(3),
  status            payment_status not null default 'initiated',
  stripe_payment_id varchar(255),
  created_at        timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- PAYOUTS (platform -> mentor)
-- -----------------------------------------------------------------------------
create table mentor_payouts (
  id                bigint generated always as identity primary key,
  mentor_id         bigint not null references mentors(id) on delete restrict,
  booking_id        bigint not null references bookings(id) on delete restrict,
  amount            numeric(10,2),
  currency          varchar(3),
  status            payout_status not null default 'pending',
  stripe_payment_id varchar(255),
  created_at        timestamptz not null default now(),
  request_date      timestamptz,
  paid_date         timestamptz,
  comments          text
);

-- -----------------------------------------------------------------------------
-- REVIEWS
-- -----------------------------------------------------------------------------
create table reviews (
  id         bigint generated always as identity primary key,
  user_id    bigint not null references users(id) on delete cascade,
  mentor_id  bigint not null references mentors(id) on delete cascade,
  service_id bigint references services(id) on delete set null,
  booking_id bigint not null references bookings(id) on delete cascade,
  rating     int check (rating between 1 and 5),
  comment    text,
  created_at timestamptz not null default now(),
  unique (booking_id)
);

-- -----------------------------------------------------------------------------
-- SERVICE QUESTIONS & BOOKING ANSWERS
-- -----------------------------------------------------------------------------
create table service_questions (
  id            bigint generated always as identity primary key,
  service_id    bigint not null references services(id) on delete cascade,
  question_text text,
  is_required   boolean not null default false,
  is_active     boolean not null default true,
  question_type question_type not null default 'text',
  created_at    timestamptz not null default now()
);

create table booking_question_answers (
  id          bigint generated always as identity primary key,
  booking_id  bigint not null references bookings(id) on delete cascade,
  question_id bigint not null references service_questions(id) on delete cascade,
  answer_text text,
  created_at  timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- MENTOR CANCELLATION POLICY (monthly counter)
-- -----------------------------------------------------------------------------
create table mentor_cancellation_policy (
  id           bigint generated always as identity primary key,
  mentor_id    bigint not null references mentors(id) on delete cascade,
  month_year   varchar(7),                  -- e.g. 2025-06
  cancel_count int not null default 0,
  last_updated timestamptz not null default now(),
  unique (mentor_id, month_year)
);

-- -----------------------------------------------------------------------------
-- REFERRAL LINKS
-- -----------------------------------------------------------------------------
create table referral_links (
  id                 bigint generated always as identity primary key,
  referrer_mentor_id bigint not null references users(id) on delete cascade,
  referred_user_id   bigint references users(id) on delete set null,
  type               referral_type,
  created_at         timestamptz not null default now()
);

-- =============================================================================
-- INDEXES ON FOREIGN KEYS (performance)
-- =============================================================================
create index idx_mentors_user_id                  on mentors(user_id);
create index idx_mentor_languages_language_id      on mentor_languages(language_id);
create index idx_mentor_specializations_spec_id    on mentor_specializations(specialization_id);
create index idx_mentor_verifications_mentor_id    on mentor_verifications(mentor_id);
create index idx_social_links_user_id              on social_links(user_id);
create index idx_services_mentor_id                on services(mentor_id);
create index idx_services_base_template_id         on services(base_template_id);
create index idx_service_pricing_service_id        on service_pricing(service_id);
create index idx_weekly_availability_mentor_id     on weekly_availability(mentor_id);
create index idx_specific_availability_mentor_id   on specific_availability(mentor_id);
create index idx_bookings_user_id                  on bookings(user_id);
create index idx_bookings_mentor_id                on bookings(mentor_id);
create index idx_bookings_service_id               on bookings(service_id);
create index idx_bookings_discount_id              on bookings(discount_id);
create index idx_customer_payments_booking_id      on customer_payments(booking_id);
create index idx_mentor_payouts_mentor_id          on mentor_payouts(mentor_id);
create index idx_mentor_payouts_booking_id         on mentor_payouts(booking_id);
create index idx_reviews_mentor_id                 on reviews(mentor_id);
create index idx_reviews_user_id                   on reviews(user_id);
create index idx_service_questions_service_id      on service_questions(service_id);
create index idx_bqa_booking_id                    on booking_question_answers(booking_id);
create index idx_bqa_question_id                   on booking_question_answers(question_id);
create index idx_mcp_mentor_id                     on mentor_cancellation_policy(mentor_id);
create index idx_referral_links_referrer           on referral_links(referrer_mentor_id);
create index idx_referral_links_referred           on referral_links(referred_user_id);
