-- Simplify the review flow per founder decision: reviews are final once
-- submitted (no edit window) — simpler to reason about, matches how most
-- marketplaces treat reviews, and removes the ability to swap a 5* review
-- to 1* (or vice versa) months later. Admin moderation for 1-3* stays
-- unchanged; the customer just never sees pending/rejected/published
-- distinctions — only "you reviewed this session".

-- ---------------------------------------------------------------------------
-- 1. Drop the edit path entirely — submit_review already refuses a second
--    submission ("used_at is not null"), so removing edit_review makes that
--    refusal final rather than a workaround.
-- ---------------------------------------------------------------------------
drop function if exists edit_review(uuid,int,text,text);

-- ---------------------------------------------------------------------------
-- 2. Token lookup no longer exposes status/editable — just enough to render
--    the form, or the fact that a review already exists (with its star
--    count, so the confirmation screen can redisplay it) so the page can't
--    be resubmitted.
-- ---------------------------------------------------------------------------
create or replace function get_review_token_info(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t review_email_tokens; b bookings; v_mentor_name text; v_service_title text; v_rating int;
begin
  select * into t from review_email_tokens where token = p_token;
  if not found then raise exception 'Invalid review link'; end if;
  select * into b from bookings where id = t.booking_id;
  select coalesce(u.first_name, 'your mentor') into v_mentor_name from mentors m join users u on u.id = m.user_id where m.id = b.mentor_id;
  select title into v_service_title from services where id = b.service_id;
  select rating into v_rating from reviews where booking_id = t.booking_id;

  return jsonb_build_object(
    'booking_id', b.id, 'mentor_name', v_mentor_name, 'service_title', v_service_title,
    'expired', t.expires_at < now(),
    'already_submitted', t.used_at is not null,
    'rating', v_rating
  );
end; $$;
grant execute on function get_review_token_info(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. Admin-configurable review link expiry (was hardcoded default 90).
--    No edit-window setting — there's no edit to configure.
-- ---------------------------------------------------------------------------
drop function if exists admin_get_settings();
create or replace function admin_get_settings()
returns table(commission_pct numeric, ppp_floor numeric, default_currency text, test_redirect text, review_token_expiry_days int)
language sql security definer set search_path = public as $$
  select (select value::numeric from platform_settings where key='immigroov_commission_pct'),
         (select value::numeric from platform_settings where key='ppp_floor'),
         (select value from platform_settings where key='default_currency'),
         (select value from platform_settings where key='test_redirect_email'),
         coalesce((select value::int from platform_settings where key='review_token_expiry_days'), 90);
$$;
grant execute on function admin_get_settings() to anon, authenticated;

create or replace function admin_set_setting(p_key text, p_value text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if p_key not in ('immigroov_commission_pct','ppp_floor','default_currency','test_redirect_email','review_token_expiry_days') then
    raise exception 'Setting % is not editable here', p_key;
  end if;
  if p_key = 'review_token_expiry_days' and (p_value::int < 1 or p_value::int > 365) then
    raise exception 'Review link expiry must be between 1 and 365 days';
  end if;
  update platform_settings set value = p_value where key = p_key;
  if not found then insert into platform_settings(key, value) values (p_key, p_value); end if;
end; $$;
grant execute on function admin_set_setting(text,text) to anon, authenticated;
