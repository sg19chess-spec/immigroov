// Embed knowledge sources and upsert them into kb_documents (pgvector).
//
// Sources:
//   - country_docs table  (editable country text)        -> kind "country"
//   - kb_mentor_source()  (mentor profiles incl. bios)    -> kind "mentor"
//   - kb-seed.mjs         (platform FAQs + guides)        -> kind "faq"/"guide"
//
// Run from the web/ directory (reads web/.env.local automatically):
//   npm run ingest
//
// Requires: SUPABASE_SERVICE_ROLE_KEY, NEXT_PUBLIC_SUPABASE_URL, and an
// OpenAI-compatible embeddings key (EMBEDDINGS_API_KEY or OPENAI_API_KEY).
// Re-run any time content or the mentor roster changes — upserts on (kind, source_key).

import { createClient } from "@supabase/supabase-js";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { SEED } from "./kb-seed.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));

// Minimal .env.local loader (no extra dependency).
try {
  const env = readFileSync(join(__dirname, "..", ".env.local"), "utf8");
  for (const line of env.split("\n")) {
    const m = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
  }
} catch {
  /* no .env.local — rely on the environment */
}

const SUPABASE_URL = process.env.NEXT_PUBLIC_SUPABASE_URL || process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const EMBED_MODEL = process.env.EMBEDDINGS_MODEL || "text-embedding-3-small";
const EMBED_BASE_URL = process.env.EMBEDDINGS_BASE_URL || "https://api.openai.com/v1";
const EMBED_KEY = process.env.EMBEDDINGS_API_KEY || process.env.OPENAI_API_KEY;

if (!SUPABASE_URL || !SERVICE_KEY) {
  console.error("Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY.");
  process.exit(1);
}
if (!EMBED_KEY) {
  console.error("Missing EMBEDDINGS_API_KEY / OPENAI_API_KEY (needed to compute embeddings).");
  process.exit(1);
}

const sb = createClient(SUPABASE_URL, SERVICE_KEY, { auth: { persistSession: false } });

// Embed an array of strings (batched). Returns vectors in the same order.
async function embedBatch(texts) {
  const out = [];
  for (let i = 0; i < texts.length; i += 96) {
    const batch = texts.slice(i, i + 96).map((t) => t.slice(0, 8000));
    const res = await fetch(`${EMBED_BASE_URL}/embeddings`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${EMBED_KEY}` },
      body: JSON.stringify({ model: EMBED_MODEL, input: batch }),
    });
    if (!res.ok) throw new Error(`embeddings ${res.status}: ${await res.text()}`);
    const j = await res.json();
    for (const d of j.data) out.push(d.embedding);
  }
  return out;
}

async function countryDocs() {
  const { data, error } = await sb
    .from("country_docs")
    .select("country_code,country_name,content")
    .eq("is_published", true);
  if (error) throw new Error(`country_docs: ${error.message}`);
  return (data || []).map((c) => ({
    kind: "country",
    source_key: `country:${c.country_code.toLowerCase()}`,
    title: `${c.country_name} — immigration overview`,
    content: c.content,
    metadata: { country_code: c.country_code },
  }));
}

async function mentorDocs() {
  const { data, error } = await sb.rpc("kb_mentor_source");
  if (error) throw new Error(`kb_mentor_source: ${error.message}`);
  return (data || [])
    .filter((m) => m.name)
    .map((m) => {
      const specs = (m.specializations || []).join(", ");
      const langs = (m.languages || []).join(", ");
      const content =
        `${m.name} — ${m.title || "immigration mentor"} on Immigroov. ` +
        (m.about_me ? `${m.about_me} ` : "") +
        (specs ? `Specializes in: ${specs}. ` : "") +
        (langs ? `Speaks: ${langs}. ` : "") +
        `Average rating ${Number(m.avg_rating).toFixed(1)} from ${m.review_count} reviews. ` +
        `Book a 1:1 session with this mentor at /mentor/${m.mentor_id}.`;
      return {
        kind: "mentor",
        source_key: `mentor:${m.mentor_id}`,
        ref_id: m.mentor_id,
        title: `${m.name} — ${m.title || "Mentor"}`,
        url: `/mentor/${m.mentor_id}`,
        content,
      };
    });
}

async function main() {
  const [countries, mentors] = await Promise.all([countryDocs(), mentorDocs()]);
  const docs = [...SEED, ...countries, ...mentors];
  console.log(
    `Embedding ${docs.length} documents (${SEED.length} seed + ${countries.length} countries + ${mentors.length} mentors)…`
  );

  const vectors = await embedBatch(docs.map((d) => `${d.title}\n\n${d.content}`));

  const rows = docs.map((d, i) => ({
    kind: d.kind,
    source_key: d.source_key,
    ref_id: d.ref_id ?? null,
    title: d.title,
    content: d.content,
    url: d.url ?? null,
    metadata: d.metadata ?? {},
    // pgvector accepts its text form "[a,b,c]" — JSON.stringify of a number[] matches exactly.
    embedding: JSON.stringify(vectors[i]),
  }));

  const { error } = await sb.from("kb_documents").upsert(rows, { onConflict: "kind,source_key" });
  if (error) throw new Error(`upsert: ${error.message}`);

  console.log(`✓ Upserted ${rows.length} documents into kb_documents.`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
