# Immigroov — AI Assistant + Vector DB Integration Plan

A practical plan to add an AI assistant that (a) answers immigration questions
grounded in **country knowledge**, and (b) recommends the right **mentor/service**
— using **RAG** (retrieval-augmented generation) over a vector store.

---

## 1. Recommended approach: pgvector inside Supabase (not a separate vector DB)

We already run PostgreSQL on Supabase. Use the **`pgvector`** extension rather
than standing up Pinecone/Weaviate/Qdrant:

| pgvector (Supabase) | External vector DB |
|---|---|
| No new infra, no extra bill | New service + cost + keys |
| Embeddings live **next to** mentor/booking data → can JOIN to live data | Data split across systems, sync needed |
| Same RLS / security model | Separate auth model |
| Great up to millions of vectors | Only needed at very large scale |

**Verdict:** start with pgvector. Revisit an external DB only if we exceed ~a few
million chunks or need multi-tenant isolation at scale.

---

## 2. Data model (ready-to-run SQL — apply once the embedding model is chosen)

> Dimension depends on the embedding model (see §5). `1536` = OpenAI
> `text-embedding-3-small`. Change `vector(1536)` if you pick another model.

```sql
create extension if not exists vector;

create table kb_documents (
  id          bigint generated always as identity primary key,
  source_type text not null,          -- 'country' | 'mentor' | 'service' | 'faq'
  ref_id      text,                   -- e.g. country code, mentor id
  title       text,
  content     text not null,          -- the chunk
  metadata    jsonb default '{}',
  embedding   vector(1536),
  created_at  timestamptz default now()
);
create index on kb_documents using hnsw (embedding vector_cosine_ops);
create index on kb_documents (source_type, ref_id);

-- cosine similarity search, optional source filter
create or replace function match_documents(
  query_embedding vector(1536), match_count int default 6, p_source text default null
)
returns table (id bigint, source_type text, ref_id text, title text, content text, metadata jsonb, similarity float)
language sql stable as $$
  select id, source_type, ref_id, title, content, metadata,
         1 - (embedding <=> query_embedding) as similarity
  from kb_documents
  where p_source is null or source_type = p_source
  order by embedding <=> query_embedding
  limit match_count;
$$;
```

---

## 3. How it works (pipeline)

**Ingestion (offline / nightly cron):**
1. Gather sources: per-country immigration info, each mentor's bio/specializations,
   each service description, FAQs.
2. Chunk (~500–800 tokens) → 3. Embed each chunk → 4. Upsert into `kb_documents`.

**Query (runtime, per user question):**
1. Embed the user's question.
2. `match_documents(embedding, k)` → top relevant chunks.
3. Build a prompt: system instructions + retrieved context + question.
4. Call the LLM (Claude) → answer.
5. For "who should I talk to?", also call `search_mentors(...)` (specialization /
   language / rating / country) and return mentor cards linking to `/mentor/[id]`.

**Best practice:** give the LLM **tools** (function calling) for
`search_mentors` and `get_available_slots`, so it can recommend a mentor *and*
pre-fill a booking, not just chat.

---

## 4. Where it runs

A single server-side endpoint — **Supabase Edge Function** `ai-ask` (or a Next.js
route handler) — does: embed query → `match_documents` (service role) → call Claude
→ stream the answer. **All keys stay server-side.** The frontend just sends the
question and renders the streamed reply.

---

## 5. Models & keys

- **Generation (LLM):** Anthropic **Claude** — `claude-sonnet-4-6` for the quality/
  cost balance on RAG answers, `claude-haiku-4-5-20251001` for cheap/fast. (We
  default to the latest Claude models.)
- **Embeddings:** Anthropic does **not** offer an embeddings endpoint, so pair Claude
  with an embeddings provider:
  - **OpenAI** `text-embedding-3-small` (1536 dims) — cheapest/easiest, or `-large` (3072).
  - or **Voyage AI** `voyage-3` — strong retrieval quality.
  Pick one and fix the `vector(N)` dimension to match.

---

## 6. What to hand the AI developer

**Access (all server-side — never in the frontend bundle):**
- **Supabase project URL**: `https://atkulcfyaqcivzxteela.supabase.co`
- **Supabase `service_role` key** — for ingestion + retrieval (bypasses RLS). Or a
  dedicated limited Postgres role if you want least-privilege.
- **Postgres connection string** (session pooler) — for bulk ingestion scripts.
- **The schema + RPCs**: `kb_documents`, `match_documents`, and the existing
  `search_mentors`, `get_available_slots` (this repo + `supabase/migrations/`).
- **Read access to** `mentors`, `services`, `specializations`, `languages` for
  recommendations.
- The **GitHub repo** (already private) and this doc.
- The **country-knowledge content** (who supplies it — a CMS, docs, or a feed).

**API keys to provision:**
- `ANTHROPIC_API_KEY` (Claude — generation)
- `OPENAI_API_KEY` **or** `VOYAGE_API_KEY` (embeddings)

**Environment variables (server-side):**
```
SUPABASE_URL=https://atkulcfyaqcivzxteela.supabase.co
SUPABASE_SERVICE_ROLE_KEY=...        # secret
SUPABASE_DB_URL=postgresql://...     # for bulk ingest (pooler)
ANTHROPIC_API_KEY=...                # Claude
OPENAI_API_KEY=...                   # embeddings (or VOYAGE_API_KEY)
EMBEDDING_MODEL=text-embedding-3-small
EMBEDDING_DIM=1536
LLM_MODEL=claude-sonnet-4-6
```

**APIs they'll integrate with:**
- Supabase RPC/REST + Postgres (`match_documents`, `search_mentors`).
- Embeddings provider API (OpenAI/Voyage).
- Anthropic **Messages API** (Claude), ideally with **tool use** to call our RPCs.

---

## 7. Security & PII (important)

- **Only embed public-safe content**: mentor bios, specializations, service
  descriptions, country info, FAQs. **Never** embed mentee PII, emails, payment
  data, or booking details.
- Keep `service_role` and all LLM/embedding keys **server-side** (Edge Function
  secrets / Vault). Never ship them to the browser.
- `kb_documents`: public read is fine if content is public; **writes service-role only**.
- **Rate-limit** the `ai-ask` endpoint and add per-day cost caps on LLM calls.
- Log prompts/answers for quality, but scrub any user-entered PII.

---

## 8. Phases

1. **Foundation** — enable `pgvector`, create `kb_documents` + `match_documents` (SQL in §2).
2. **Ingestion** — script to chunk + embed country & mentor data into `kb_documents` (nightly cron).
3. **`ai-ask` Edge Function** — retrieval + Claude, streamed.
4. **Chat widget** in the Next.js app.
5. **Tool use** — let the assistant call `search_mentors` / `get_available_slots`
   to recommend a mentor and pre-fill a booking.

---

## TL;DR for the team
> Use **pgvector in Supabase** (no new DB). Give the AI dev the **Supabase URL +
> service_role key + DB string**, an **Anthropic key** (Claude) and an **OpenAI/Voyage
> key** (embeddings), plus this schema. Embed only **public** country/mentor content.
> Run retrieval + generation in a **server-side Edge Function**; the browser only
> sends questions. Start with the §2 SQL whenever you lock the embedding model.
```
