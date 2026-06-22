-- pgvector knowledge base for the AI assistant (RAG over public content).
-- The chat assistant ("Immi") retrieves relevant snippets from here via match_kb
-- and grounds its answers on them. Content is PUBLIC only (country/visa guides,
-- mentor bios, service descriptions, FAQs) — never mentee PII or payment data.

create extension if not exists vector with schema extensions;

create table if not exists kb_documents (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('country','mentor','service','faq','guide')),
  ref_id      bigint,                       -- optional link to a mentor/service row
  source_key  text not null,                -- stable id for upsert (e.g. 'country:us')
  title       text not null,
  content     text not null,
  url         text,
  metadata    jsonb not null default '{}',
  embedding   extensions.vector(1536),      -- OpenAI text-embedding-3-small
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create unique index if not exists kb_documents_kind_source_key
  on kb_documents (kind, source_key);

-- approximate-nearest-neighbour index (cosine distance)
create index if not exists kb_documents_embedding_idx
  on kb_documents using hnsw (embedding extensions.vector_cosine_ops);

-- knowledge base is public content: anyone may read; writes are service_role only
alter table kb_documents enable row level security;
drop policy if exists kb_public_read on kb_documents;
create policy kb_public_read on kb_documents for select using (true);

create or replace function set_kb_updated_at() returns trigger
language plpgsql
set search_path = ''
as $$
begin new.updated_at = now(); return new; end; $$;
drop trigger if exists trg_kb_updated_at on kb_documents;
create trigger trg_kb_updated_at before update on kb_documents
  for each row execute function set_kb_updated_at();

-- semantic similarity search used by the chat assistant
create or replace function match_kb(
  query_embedding extensions.vector(1536),
  match_count     int  default 5,
  filter_kind     text default null
) returns table (
  id bigint, kind text, title text, content text, url text, similarity float
) language sql stable
set search_path = public, extensions
as $$
  select d.id, d.kind, d.title, d.content, d.url,
         1 - (d.embedding <=> query_embedding) as similarity
  from kb_documents d
  where d.embedding is not null
    and (filter_kind is null or d.kind = filter_kind)
  order by d.embedding <=> query_embedding
  limit greatest(match_count, 1);
$$;

grant execute on function match_kb(extensions.vector, int, text) to anon, authenticated;
