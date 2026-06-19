-- =============================================================================
-- Immigroov — sample seed data (optional, for local/dev)
-- =============================================================================

insert into users (first_name, last_name, email, role, is_verified) values
  ('Asha',  'Mehta',  'asha.mentor@example.com',  'mentor', true),
  ('Liam',  'Nguyen', 'liam.user@example.com',    'user',   true),
  ('Admin', 'Root',   'admin@immigroov.com',       'admin',  true);

insert into mentors (user_id, title, about_me, currency, app_timezone, is_available, expertise_tag)
values ((select id from users where email='asha.mentor@example.com'),
        'Immigration Consultant', 'Helping with visas & PR.', 'USD', 'Asia/Kolkata', true, 'immigration');

insert into languages (name, lang_code) values ('English','en'), ('Hindi','hi'), ('Dutch','nl');

insert into mentor_languages (mentor_id, language_id)
select (select id from mentors limit 1), id from languages where name in ('English','Hindi');

insert into specializations (name) values ('Work Visa'), ('Student Visa'), ('Permanent Residency');

insert into services (mentor_id, title, description, type, duration, is_ppp, is_active)
values ((select id from mentors limit 1), '30-min Visa Consultation',
        'One-on-one video call.', 'video', 30, true, true);

-- Pricing incl. Immigroov platform fee
insert into service_pricing (service_id, country_code, currency, base_price, offer_price, immigroov_price)
values
  ((select id from services limit 1), 'US', 'USD', 80.00, 70.00, 12.00),
  ((select id from services limit 1), 'IN', 'INR', 3000.00, 2500.00, 400.00),
  ((select id from services limit 1), 'NL', 'EUR', 75.00, 65.00, 10.00);

insert into weekly_availability (mentor_id, weekday, start_time, end_time, timezone)
values ((select id from mentors limit 1), 'Monday', '09:00', '17:00', 'Asia/Kolkata');

insert into discounts (code, description, percentage, max_uses, is_active)
values ('WELCOME10', '10% off first session', 10, 1000, true);
