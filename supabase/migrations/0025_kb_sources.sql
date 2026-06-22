-- Editable source content for the AI knowledge base.
-- Country details live here as plain text and are embedded into kb_documents by
-- the ingest script (web/scripts/ingest.mjs). Mentor details (incl. bios) are
-- pulled via kb_mentor_source(). This keeps the assistant grounded in real,
-- editable data so it can't hallucinate country/visa or mentor facts.

create table if not exists country_docs (
  country_code text primary key,
  country_name text not null,
  content      text not null,
  is_published boolean not null default true,
  updated_at   timestamptz not null default now()
);

alter table country_docs enable row level security;
drop policy if exists country_docs_read on country_docs;
create policy country_docs_read on country_docs for select using (is_published);

create or replace function set_country_docs_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists trg_country_docs_updated_at on country_docs;
create trigger trg_country_docs_updated_at before update on country_docs
  for each row execute function set_country_docs_updated_at();

insert into country_docs (country_code, country_name, content) values
('US','United States',
 'Common routes to the United States include study visas (F-1), temporary work visas such as the H-1B (specialty occupation, usually employer-sponsored and subject to an annual cap and lottery), the L-1 (intra-company transfer), the O-1 (extraordinary ability), and employment- or family-based green cards for permanent residency. The H-1B typically requires a sponsoring employer and a relevant degree. Processing times and eligibility vary widely; a mentor who knows US work or study routes can help you plan timing and sponsorship.'),
('CA','Canada',
 'Canada is popular for skilled migration. Express Entry manages applications for several federal programs and ranks candidates on a points-based Comprehensive Ranking System (age, education, language, work experience). Provincial Nominee Programs let provinces select candidates for local needs. Study permits and post-graduation work permits are a common pathway from studying to permanent residency. Strong English/French scores and credential assessments help. A mentor can help you estimate your CRS score and pick a program.'),
('GB','United Kingdom',
 'The UK uses a points-based system. The Skilled Worker visa requires a job offer from a licensed sponsor at or above salary and skill thresholds. The Student visa covers study at licensed institutions, often with limited work rights and a Graduate route afterwards. Other routes include Global Talent and family visas. Sponsorship and meeting the English-language requirement are common hurdles. A mentor familiar with UK routes can help you check sponsor eligibility and prepare your application.'),
('AU','Australia',
 'Australia runs a points-tested skilled-migration system (such as the subclass 189 independent and 190 state-nominated visas) using a SkillSelect Expression of Interest. Points come from age, English ability, qualifications, and work experience, often after a skills assessment in your occupation. Student visas and temporary skilled work visas are also common. State nomination can boost your points. A mentor can help you check the skilled occupation lists and estimate your points.'),
('DE','Germany',
 'Germany attracts skilled workers and students. The EU Blue Card targets university-educated professionals with a qualifying job offer and salary threshold. There is also a Job Seeker visa to look for work on the ground, and an Opportunity Card (points-based) for skilled workers. Students can study at low or no tuition and work part-time. Recognition of foreign qualifications and some German-language ability help for many routes. A mentor can help you compare the Blue Card and skilled-worker options.')
on conflict (country_code) do nothing;

-- Mentor rows for embedding (includes the bio so retrieval is grounded in real profiles)
create or replace function kb_mentor_source()
returns table (
  mentor_id bigint, name text, title text, about_me text,
  specializations text[], languages text[], avg_rating numeric, review_count int
) language sql stable security definer set search_path = public, extensions as $$
  select m.id,
    nullif(trim(coalesce(u.first_name,'') || ' ' || coalesce(u.last_name,'')), ''),
    m.title, m.about_me,
    coalesce((select array_agg(distinct s2.name)
                from mentor_specializations ms
                join specializations s2 on s2.id = ms.specialization_id
               where ms.mentor_id = m.id), '{}'),
    coalesce((select array_agg(distinct l2.name)
                from mentor_languages ml
                join languages l2 on l2.id = ml.language_id
               where ml.mentor_id = m.id), '{}'),
    m.avg_rating, m.review_count
  from mentors m
  join users u on u.id = m.user_id
  where m.is_available;
$$;

grant execute on function kb_mentor_source() to authenticated, service_role;
