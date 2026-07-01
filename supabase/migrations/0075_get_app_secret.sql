-- 0075 — service-role-only accessor for app secrets stored in Supabase Vault.
-- Lets the payment edge functions read Razorpay credentials from Vault (populated
-- out-of-band via vault.create_secret) when they aren't set as edge-function env
-- secrets. Allowlisted names only; never granted to anon/authenticated.
create or replace function get_app_secret(p_name text)
returns text language sql stable security definer set search_path = public as $$
  select decrypted_secret from vault.decrypted_secrets
   where name = p_name and p_name in ('razorpay_key_id','razorpay_key_secret','razorpay_webhook_secret');
$$;
revoke all on function get_app_secret(text) from public, anon, authenticated;
grant execute on function get_app_secret(text) to service_role;
