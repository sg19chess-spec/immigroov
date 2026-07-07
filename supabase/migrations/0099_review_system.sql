-- Review system: token-gated submission email, star-based moderation gating
-- (4-5* auto-publish, 1-3* held for admin review), admin moderation queue,
-- and mentor-profile-facing published reviews + rating breakdown.
--
-- Builds on the EXISTING reviews table/rollup/guard (0001, 0013) rather than
-- replacing them — those already enforce "own completed booking only" and
-- "one review per booking" (unique(booking_id)). This migration adds the
-- moderation/token/email layer on top.

-- ---------------------------------------------------------------------------
-- 1. Schema additions
-- ---------------------------------------------------------------------------
alter table reviews add column if not exists title text;
alter table reviews add column if not exists status text not null default 'pending' check (status in ('pending', 'published', 'rejected'));
alter table reviews add column if not exists published_at timestamptz;
alter table reviews add column if not exists edited_at timestamptz;
alter table reviews add column if not exists reviewed_by bigint references users(id);
alter table reviews add column if not exists review_token uuid;

-- The existing "public read reviews" policy (0003_rls_policies.sql) allows
-- reading every row unconditionally — fine when every review was published
-- instantly, but now that pending/rejected states exist, that would leak
-- unmoderated content (including rejected reviews) via a direct table read.
-- Admin/customer flows above already read through SECURITY DEFINER RPCs, so
-- direct table access only needs to expose published rows.
drop policy if exists "public read reviews" on reviews;
create policy "public read reviews" on reviews for select using (status = 'published');

create table if not exists review_email_tokens (
  id         bigint generated always as identity primary key,
  booking_id bigint not null references bookings(id) on delete cascade unique,
  token      uuid not null default gen_random_uuid() unique,
  expires_at timestamptz not null,
  used_at    timestamptz
);
alter table review_email_tokens enable row level security; -- no direct policies — token RPCs only, never queried by client filters

-- ---------------------------------------------------------------------------
-- 2. Rating rollup must only count PUBLISHED reviews — a pending/rejected
--    review must never move the public average (business rule).
-- ---------------------------------------------------------------------------
create or replace function recompute_mentor_rating(p_mentor_id bigint)
returns void language sql as $$
  update mentors m set
    avg_rating   = coalesce((select round(avg(rating)::numeric, 2) from reviews where mentor_id = p_mentor_id and status = 'published'), 0),
    review_count = (select count(*) from reviews where mentor_id = p_mentor_id and status = 'published')
  where m.id = p_mentor_id;
$$;

-- ---------------------------------------------------------------------------
-- 3. Booking completion -> review-request email. Hooks into the existing
--    single choke point where bookings become 'completed'
--    (mark_past_bookings_completed, 0080), generating a one-per-booking
--    token and sending the request email in the same pass.
-- ---------------------------------------------------------------------------
create or replace function mark_past_bookings_completed()
returns int
language plpgsql security definer set search_path = public as $$
declare
  n int; v_enabled boolean; r record; v_mentor_name text; v_customer_email text;
  v_site text; v_token_days int; v_token uuid;
begin
  v_enabled := coalesce(referral_setting('attendance_engine_enabled')::boolean, false);
  v_token_days := coalesce(referral_setting('review_token_expiry_days')::int, 90);
  select nullif(value,'') into v_site from platform_settings where key = 'site_url';
  v_site := coalesce(v_site, 'https://immigroov.vercel.app');

  n := 0;
  for r in
    update bookings
      set status = 'completed'
      where status in ('confirmed', 'rescheduled')
        and slot_end is not null
        and slot_end < now()
        and (not v_enabled or (mentor_joined and customer_joined))
      returning *
  loop
    n := n + 1;
    select coalesce(u.first_name, 'your mentor') into v_mentor_name
      from mentors m join users u on u.id = m.user_id where m.id = r.mentor_id;
    v_customer_email := coalesce(r.guest_email, (select email from users where id = r.user_id));

    insert into review_email_tokens (booking_id, expires_at)
      values (r.id, now() + (v_token_days || ' days')::interval)
      on conflict (booking_id) do nothing
      returning token into v_token;

    if v_token is not null and v_customer_email is not null then
      perform app_send_email(v_customer_email, 'How was your session with ' || v_mentor_name || '?',
        '<p>Thanks for booking with ' || v_mentor_name || '. We''d love to hear how it went.</p>' ||
        '<p><a href="' || v_site || '/review/' || v_token || '">Leave a review</a></p>');
    end if;
    v_token := null;
  end loop;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- 4. Public token lookup — feeds the /review/:token page. Reveals only what's
--    needed to render the form (mentor/service names, expiry/used state,
--    and the existing review if this token is being reused to edit).
-- ---------------------------------------------------------------------------
create or replace function get_review_token_info(p_token uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t review_email_tokens; b bookings; v_mentor_name text; v_service_title text; v_review reviews;
begin
  select * into t from review_email_tokens where token = p_token;
  if not found then raise exception 'Invalid review link'; end if;
  select * into b from bookings where id = t.booking_id;
  select coalesce(u.first_name, 'your mentor') into v_mentor_name from mentors m join users u on u.id = m.user_id where m.id = b.mentor_id;
  select title into v_service_title from services where id = b.service_id;
  select * into v_review from reviews where booking_id = t.booking_id;

  return jsonb_build_object(
    'booking_id', b.id, 'mentor_name', v_mentor_name, 'service_title', v_service_title,
    'expired', t.expires_at < now(),
    'existing_review', case when v_review.id is not null then
      jsonb_build_object('rating', v_review.rating, 'title', v_review.title, 'review', v_review.comment,
        'status', v_review.status, 'created_at', v_review.created_at,
        'editable', v_review.created_at > now() - (coalesce(referral_setting('review_edit_window_days')::int, 30) || ' days')::interval)
      else null end
  );
end; $$;
grant execute on function get_review_token_info(uuid) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. Submit a review via token. Rating gates publication immediately:
--    4-5* -> published (visible right away, mentor emailed on 5*);
--    1-3* -> pending, held for admin moderation, never counted in avg_rating
--    until approved (recompute_mentor_rating already filters on status).
-- ---------------------------------------------------------------------------
create or replace function submit_review(p_token uuid, p_rating int, p_title text, p_review text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t review_email_tokens; b bookings; v_status text; v_review_id bigint; v_mentor_name text;
  v_mentor_email text;
begin
  if p_rating not between 1 and 5 then raise exception 'Rating must be between 1 and 5'; end if;
  select * into t from review_email_tokens where token = p_token for update;
  if not found then raise exception 'Invalid review link'; end if;
  if t.expires_at < now() then raise exception 'This review link has expired'; end if;
  if t.used_at is not null then raise exception 'A review was already submitted for this session — use the same link to edit it'; end if;

  select * into b from bookings where id = t.booking_id;
  if b.status <> 'completed' then raise exception 'You can only review a completed session'; end if;

  v_status := case when p_rating >= 4 then 'published' else 'pending' end;

  insert into reviews (user_id, mentor_id, service_id, booking_id, rating, title, comment, status, published_at, review_token)
    values (b.user_id, b.mentor_id, b.service_id, b.id, p_rating, nullif(trim(coalesce(p_title,'')),''), p_review,
            v_status, case when v_status = 'published' then now() else null end, p_token)
    returning id into v_review_id;

  update review_email_tokens set used_at = now() where id = t.id;

  if p_rating = 5 then
    select coalesce(u.first_name, ''), u.email into v_mentor_name, v_mentor_email
      from mentors m join users u on u.id = m.user_id where m.id = b.mentor_id;
    perform app_send_email(v_mentor_email, 'You received a new 5★ review',
      '<p>Congrats' || case when v_mentor_name <> '' then ', ' || v_mentor_name else '' end ||
      '! You just received a new 5-star review' || case when p_title is not null and trim(p_title) <> '' then ': "' || p_title || '"' else '.' end || '</p>');
  end if;

  return jsonb_build_object('review_id', v_review_id, 'status', v_status);
end; $$;
grant execute on function submit_review(uuid,int,text,text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Edit a review via the same token, within the edit window. Re-applies
--    the same star gating — dropping the rating below 4 sends a previously
--    published review back to pending (and drops it out of the public
--    average until re-approved), matching the same rule that governs
--    first-time submission.
-- ---------------------------------------------------------------------------
create or replace function edit_review(p_token uuid, p_rating int, p_title text, p_review text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare t review_email_tokens; rv reviews; v_status text; v_edit_days int;
begin
  if p_rating not between 1 and 5 then raise exception 'Rating must be between 1 and 5'; end if;
  select * into t from review_email_tokens where token = p_token;
  if not found or t.used_at is null then raise exception 'No review to edit for this link'; end if;

  select * into rv from reviews where booking_id = t.booking_id for update;
  if not found then raise exception 'No review to edit for this link'; end if;

  v_edit_days := coalesce(referral_setting('review_edit_window_days')::int, 30);
  if rv.created_at <= now() - (v_edit_days || ' days')::interval then
    raise exception 'The edit window for this review has closed';
  end if;

  v_status := case when p_rating >= 4 then 'published' else 'pending' end;
  update reviews set
    rating = p_rating, title = nullif(trim(coalesce(p_title,'')),''), comment = p_review,
    status = v_status, edited_at = now(),
    published_at = case when v_status = 'published' and rv.status <> 'published' then now() when v_status = 'published' then published_at else null end,
    reviewed_by = null
  where id = rv.id;

  return jsonb_build_object('review_id', rv.id, 'status', v_status);
end; $$;
grant execute on function edit_review(uuid,int,text,text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 7. Mentor-profile-facing published reviews + rating breakdown histogram.
-- ---------------------------------------------------------------------------
create or replace function mentor_reviews_public(p_mentor_id bigint, p_limit int default 10, p_offset int default 0)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'breakdown', (
      select jsonb_build_object(
        '5', count(*) filter (where rating = 5), '4', count(*) filter (where rating = 4),
        '3', count(*) filter (where rating = 3), '2', count(*) filter (where rating = 2),
        '1', count(*) filter (where rating = 1))
      from reviews where mentor_id = p_mentor_id and status = 'published'
    ),
    'reviews', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'rating', r.rating, 'title', r.title, 'review', r.comment,
        'created_at', r.created_at, 'booking_slot_time', b.slot_time, 'verified_session', true
      ) order by r.created_at desc), '[]'::jsonb)
      from (
        select * from reviews where mentor_id = p_mentor_id and status = 'published'
        order by created_at desc limit p_limit offset p_offset
      ) r
      join bookings b on b.id = r.booking_id
    )
  );
$$;
grant execute on function mentor_reviews_public(bigint,int,int) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 8. Admin moderation queue (1-3* holds) + approve/reject.
-- ---------------------------------------------------------------------------
create or replace function admin_reviews_queue()
returns table (
  review_id bigint, booking_id bigint, rating int, title text, review text,
  customer_email text, mentor_name text, created_at timestamptz
)
language sql stable security definer set search_path = public as $$
  select r.id, r.booking_id, r.rating, r.title, r.comment,
    coalesce(b.guest_email, cu.email), coalesce(mu.first_name, 'Mentor'), r.created_at
  from reviews r
  join bookings b on b.id = r.booking_id
  left join users cu on cu.id = b.user_id
  join mentors m on m.id = r.mentor_id
  join users mu on mu.id = m.user_id
  where r.status = 'pending'
  order by r.created_at asc;
$$;
grant execute on function admin_reviews_queue() to authenticated;

create or replace function admin_moderate_review(p_review_id bigint, p_decision text, p_admin_user_id bigint default null)
returns void language plpgsql security definer set search_path = public as $$
declare rv reviews;
begin
  if p_decision not in ('approve', 'reject') then raise exception 'decision must be approve or reject'; end if;
  select * into rv from reviews where id = p_review_id for update;
  if not found then raise exception 'Review not found'; end if;
  if rv.status <> 'pending' then raise exception 'Review is not awaiting moderation (status %)', rv.status; end if;

  update reviews set
    status = case when p_decision = 'approve' then 'published' else 'rejected' end,
    published_at = case when p_decision = 'approve' then now() else null end,
    reviewed_by = p_admin_user_id
  where id = p_review_id;
end; $$;
grant execute on function admin_moderate_review(bigint,text,bigint) to authenticated;
