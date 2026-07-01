-- 0073 — tiny public read helpers for the payment client:
--   • public_setting(key): expose a small allowlist of non-sensitive settings
--     (payments_enabled) so the checkout can pick Razorpay vs the mock path.
--   • booking_status(id): let the checkout poll for webhook confirmation
--     (browser never confirms; it only reads status).
create or replace function public_setting(p_key text)
returns text language sql stable security definer set search_path = public as $$
  select value from platform_settings
   where key = p_key and p_key in ('payments_enabled');
$$;
grant execute on function public_setting(text) to anon, authenticated;

create or replace function booking_status(p_booking_id bigint)
returns text language sql stable security definer set search_path = public as $$
  select status::text from bookings where id = p_booking_id;
$$;
grant execute on function booking_status(bigint) to anon, authenticated;
