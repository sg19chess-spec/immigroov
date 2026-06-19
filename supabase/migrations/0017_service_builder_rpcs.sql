-- =============================================================================
-- Immigroov — service builder RPCs (demo). Price in mentor's currency;
-- platform fee auto = commission % from platform_settings.
-- =============================================================================
create or replace function demo_create_service(
  p_mentor_id bigint, p_title text, p_description text, p_type text,
  p_duration int, p_category text, p_set_price numeric,
  p_active boolean default true, p_ppp boolean default false
)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_cur text; v_pct numeric; v_id bigint;
begin
  select coalesce(currency,'USD') into v_cur from mentors where id = p_mentor_id;
  select coalesce(value::numeric,15) into v_pct from platform_settings where key='immigroov_commission_pct';
  insert into services(mentor_id,title,description,type,duration,category,is_ppp,is_active,set_price,set_currency,platform_fee)
  values (p_mentor_id,p_title,p_description,p_type::service_type,p_duration,p_category,p_ppp,p_active,
          p_set_price, v_cur, round(p_set_price*v_pct/100,2))
  returning id into v_id;
  return v_id;
end; $$;

create or replace function demo_list_services(p_mentor_id bigint)
returns table(id bigint, title text, description text, type text, duration int, category text,
              set_price numeric, set_currency text, platform_fee numeric, is_active boolean, is_ppp boolean)
language sql security definer set search_path = public as $$
  select id,title,description,type::text,duration,category,set_price,set_currency,platform_fee,is_active,is_ppp
  from services where mentor_id=p_mentor_id order by id;
$$;

create or replace function demo_set_service_active(p_id bigint, p_active boolean)
returns void language sql security definer set search_path = public as $$
  update services set is_active=p_active where id=p_id;
$$;

create or replace function demo_delete_service(p_id bigint)
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from services where id=p_id;          -- fails if bookings reference it (FK restrict)
exception when foreign_key_violation then
  update services set is_active=false where id=p_id;  -- archive instead
end; $$;

create or replace function demo_add_question(p_service_id bigint, p_text text, p_required boolean default false, p_type text default 'text')
returns bigint language sql security definer set search_path = public as $$
  insert into service_questions(service_id,question_text,is_required,question_type,is_active)
  values(p_service_id,p_text,p_required,p_type::question_type,true) returning id;
$$;

create or replace function demo_list_questions(p_service_id bigint)
returns table(id bigint, question_text text, is_required boolean, question_type text)
language sql security definer set search_path = public as $$
  select id,question_text,is_required,question_type::text from service_questions
  where service_id=p_service_id and is_active order by id;
$$;

create or replace function demo_remove_question(p_id bigint)
returns void language sql security definer set search_path = public as $$
  delete from service_questions where id=p_id;
$$;

grant execute on function demo_create_service(bigint,text,text,text,int,text,numeric,boolean,boolean) to anon, authenticated;
grant execute on function demo_list_services(bigint) to anon, authenticated;
grant execute on function demo_set_service_active(bigint,boolean) to anon, authenticated;
grant execute on function demo_delete_service(bigint) to anon, authenticated;
grant execute on function demo_add_question(bigint,text,boolean,text) to anon, authenticated;
grant execute on function demo_list_questions(bigint) to anon, authenticated;
grant execute on function demo_remove_question(bigint) to anon, authenticated;
