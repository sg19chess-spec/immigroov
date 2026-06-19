-- =============================================================================
-- Immigroov — Reviews integrity + rating rollup + mentor discovery
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Rating rollup columns on mentors (denormalized for fast cards/search)
-- -----------------------------------------------------------------------------
alter table mentors add column if not exists avg_rating   numeric(3,2) not null default 0;
alter table mentors add column if not exists review_count int          not null default 0;

create or replace function recompute_mentor_rating(p_mentor_id bigint)
returns void language sql as $$
  update mentors m set
    avg_rating   = coalesce((select round(avg(rating)::numeric, 2) from reviews where mentor_id = p_mentor_id), 0),
    review_count = (select count(*) from reviews where mentor_id = p_mentor_id)
  where m.id = p_mentor_id;
$$;

create or replace function trg_reviews_rollup()
returns trigger language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    perform recompute_mentor_rating(old.mentor_id);
    return old;
  end if;
  perform recompute_mentor_rating(new.mentor_id);
  if tg_op = 'UPDATE' and old.mentor_id is distinct from new.mentor_id then
    perform recompute_mentor_rating(old.mentor_id);
  end if;
  return new;
end;
$$;

drop trigger if exists reviews_rollup on reviews;
create trigger reviews_rollup
  after insert or update or delete on reviews
  for each row execute function trg_reviews_rollup();

-- -----------------------------------------------------------------------------
-- 2) Review integrity: only your OWN, COMPLETED booking; mentor/service must match
-- -----------------------------------------------------------------------------
create or replace function trg_review_guard()
returns trigger language plpgsql as $$
declare b bookings;
begin
  select * into b from bookings where id = new.booking_id;
  if not found then
    raise exception 'Booking % not found', new.booking_id;
  end if;
  if b.status <> 'completed' then
    raise exception 'You can only review a completed session (booking status is %)', b.status;
  end if;
  if b.user_id <> new.user_id then
    raise exception 'You can only review your own booking';
  end if;
  if b.mentor_id <> new.mentor_id then
    raise exception 'mentor_id does not match the booking';
  end if;
  if new.service_id is null then
    new.service_id := b.service_id;  -- default from the booking
  end if;
  return new;
end;
$$;

drop trigger if exists review_guard on reviews;
create trigger review_guard
  before insert on reviews
  for each row execute function trg_review_guard();

-- -----------------------------------------------------------------------------
-- 3) Mentor discovery / search
--    Filters: free-text, specialization, language, rating, price range (by
--    country). Sort: rating | reviews | price_asc | price_desc. Paginated.
-- -----------------------------------------------------------------------------
create or replace function search_mentors(
  p_search         text    default null,
  p_specialization text    default null,
  p_language       text    default null,
  p_min_rating     numeric default null,
  p_min_price      numeric default null,
  p_max_price      numeric default null,
  p_country_code   text    default null,
  p_sort           text    default 'rating',
  p_limit          int     default 20,
  p_offset         int     default 0
)
returns table (
  mentor_id       bigint,
  name            text,
  title           text,
  profile_pic_url text,
  avg_rating      numeric,
  review_count    int,
  min_price       numeric,
  currency        text,
  specializations text[],
  languages       text[]
)
language sql stable as $$
  with prices as (
    select s.mentor_id,
           min(coalesce(sp.offer_price, sp.base_price)) as min_price,
           (array_agg(sp.currency order by coalesce(sp.offer_price, sp.base_price)))[1] as currency
    from services s
    join service_pricing sp on sp.service_id = s.id and sp.is_active
    where s.is_active
      and (p_country_code is null or sp.country_code = p_country_code)
    group by s.mentor_id
  )
  select
    m.id,
    nullif(trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')), ''),
    m.title,
    m.profile_pic_url,
    m.avg_rating,
    m.review_count,
    pr.min_price,
    pr.currency,
    coalesce((select array_agg(distinct s2.name)
                from mentor_specializations ms
                join specializations s2 on s2.id = ms.specialization_id
               where ms.mentor_id = m.id), '{}'),
    coalesce((select array_agg(distinct l2.name)
                from mentor_languages ml
                join languages l2 on l2.id = ml.language_id
               where ml.mentor_id = m.id), '{}')
  from mentors m
  join users u on u.id = m.user_id
  left join prices pr on pr.mentor_id = m.id
  where m.is_available
    and (p_min_rating is null or m.avg_rating >= p_min_rating)
    and (p_min_price  is null or pr.min_price >= p_min_price)
    and (p_max_price  is null or pr.min_price <= p_max_price)
    and (p_search is null
         or m.title    ilike '%' || p_search || '%'
         or m.about_me ilike '%' || p_search || '%'
         or u.first_name ilike '%' || p_search || '%'
         or u.last_name  ilike '%' || p_search || '%')
    and (p_specialization is null or exists (
          select 1 from mentor_specializations ms
          join specializations s2 on s2.id = ms.specialization_id
          where ms.mentor_id = m.id and s2.name ilike p_specialization))
    and (p_language is null or exists (
          select 1 from mentor_languages ml
          join languages l2 on l2.id = ml.language_id
          where ml.mentor_id = m.id and l2.name ilike p_language))
  order by
    case when p_sort = 'price_asc'  then pr.min_price end asc  nulls last,
    case when p_sort = 'price_desc' then pr.min_price end desc nulls last,
    case when p_sort = 'reviews'    then m.review_count end desc,
    m.avg_rating desc, m.review_count desc
  limit greatest(p_limit, 1) offset greatest(p_offset, 0);
$$;

grant execute on function
  search_mentors(text, text, text, numeric, numeric, numeric, text, text, int, int)
  to anon, authenticated;
