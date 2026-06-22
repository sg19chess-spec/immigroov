-- Editable FAQ source content + admin RPCs so the mentor console can manage the
-- AI knowledge base (countries + FAQs) without the service-role key in the browser.
-- These RPCs are SECURITY DEFINER (bypass RLS) like the other demo_* editors and
-- should be gated to an admin/owner before production.

create table if not exists faq_docs (
  id           bigint generated always as identity primary key,
  title        text not null,
  content      text not null,
  is_published boolean not null default true,
  updated_at   timestamptz not null default now()
);

alter table faq_docs enable row level security;
drop policy if exists faq_docs_read on faq_docs;
create policy faq_docs_read on faq_docs for select using (is_published);

drop trigger if exists trg_faq_docs_updated_at on faq_docs;
create trigger trg_faq_docs_updated_at before update on faq_docs
  for each row execute function set_country_docs_updated_at();

-- seed with the existing platform FAQs/guides
insert into faq_docs (title, content) values
('How Immigroov works',
 'Immigroov is a marketplace for booking 1:1 video sessions with vetted immigration mentors. You browse mentors by specialization, country, and language, pick a service (e.g. a 30 or 60 minute consultation), choose an open time slot, and book. Sessions happen over a video link. Mentors share guidance from lived and professional experience; they are not a substitute for a licensed attorney for case-specific legal advice.'),
('Booking and time zones',
 'On a mentor''s page you pick a service, then a date on the calendar. Only dates the mentor is available are selectable; choosing a date opens the available time slots. All times are shown in your own time zone, automatically converted from the mentor''s availability. You get a confirmation by email with the video link.'),
('Pricing, currency, and fair pricing',
 'Each mentor sets their price, shown in your local currency. Immigroov applies purchasing-power-parity (PPP) fair pricing, so visitors from lower-cost countries may see a reduced price while higher-income markets pay the standard rate. The exact amount is shown at checkout before you confirm. Immigroov adds a small platform fee on top of the mentor''s rate.'),
('Mentor vs. immigration lawyer',
 'Immigroov mentors offer guidance, planning, document-preparation tips, and first-hand experience with specific visa routes and countries. For a binding legal opinion, formal eligibility assessment, or representation before authorities, consult a licensed immigration attorney. A mentor can help you decide whether you need one.'),
('Getting the most from a session',
 'Before your session, note your goal (study, work, PR, family), your current status and nationality, your target country, and your timeline. Bring specific questions and take notes. Avoid sharing sensitive identifiers like passport or government ID numbers unless truly necessary.'),
('Choosing the right visa route',
 'Routes usually fall into families: study visas, work visas (employer sponsorship or skilled-worker points systems), permanent residency / skilled migration, family or partner visas, and investor/entrepreneur routes. The best route depends on your goal, qualifications, work experience, language ability, and how long you want to stay. A mentor who specializes in your destination can help you compare.')
on conflict do nothing;

-- ── admin RPCs ────────────────────────────────────────────────────────────
create or replace function kb_admin_list_countries()
returns setof country_docs language sql security definer set search_path = public as $$
  select * from country_docs order by country_name;
$$;

create or replace function kb_admin_upsert_country(p_code text, p_name text, p_content text, p_published boolean default true)
returns void language sql security definer set search_path = public as $$
  insert into country_docs (country_code, country_name, content, is_published)
  values (upper(p_code), p_name, p_content, p_published)
  on conflict (country_code) do update
    set country_name = excluded.country_name,
        content      = excluded.content,
        is_published = excluded.is_published;
$$;

create or replace function kb_admin_delete_country(p_code text)
returns void language sql security definer set search_path = public as $$
  delete from country_docs where country_code = upper(p_code);
$$;

create or replace function kb_admin_list_faqs()
returns setof faq_docs language sql security definer set search_path = public as $$
  select * from faq_docs order by id;
$$;

create or replace function kb_admin_upsert_faq(p_id bigint, p_title text, p_content text, p_published boolean default true)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  if p_id is null then
    insert into faq_docs (title, content, is_published) values (p_title, p_content, p_published) returning id into v_id;
  else
    update faq_docs set title = p_title, content = p_content, is_published = p_published, updated_at = now()
      where id = p_id returning id into v_id;
  end if;
  return v_id;
end; $$;

create or replace function kb_admin_delete_faq(p_id bigint)
returns void language sql security definer set search_path = public as $$
  delete from faq_docs where id = p_id;
$$;

grant execute on function
  kb_admin_list_countries(),
  kb_admin_upsert_country(text, text, text, boolean),
  kb_admin_delete_country(text),
  kb_admin_list_faqs(),
  kb_admin_upsert_faq(bigint, text, text, boolean),
  kb_admin_delete_faq(bigint)
  to anon, authenticated;
