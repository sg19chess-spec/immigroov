import { createClient } from "@supabase/supabase-js";

// Re-embed the editable knowledge sources (country_docs + faq_docs + mentor
// profiles) into kb_documents. Triggered by the "Sync to Groovia AI" button in
// the mentor console. Server-side only — uses the service-role key + embeddings
// key, neither of which touches the browser.
//
// NOTE: this is an unauthenticated endpoint for the demo. Gate it (admin auth or
// a shared token) before production, since it costs embedding tokens per call.
export const runtime = "nodejs";
export const maxDuration = 60;

const EMBED_MODEL = process.env.EMBEDDINGS_MODEL || "text-embedding-3-small";
const EMBED_BASE_URL = process.env.EMBEDDINGS_BASE_URL || "https://api.openai.com/v1";
const EMBED_KEY = process.env.EMBEDDINGS_API_KEY || process.env.OPENAI_API_KEY || "";

function admin() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.SUPABASE_SERVICE_ROLE_KEY!,
    { auth: { persistSession: false } }
  );
}

async function embedBatch(texts: string[]): Promise<number[][]> {
  const out: number[][] = [];
  for (let i = 0; i < texts.length; i += 96) {
    const batch = texts.slice(i, i + 96).map((t) => t.slice(0, 8000));
    const res = await fetch(`${EMBED_BASE_URL}/embeddings`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${EMBED_KEY}` },
      body: JSON.stringify({ model: EMBED_MODEL, input: batch }),
    });
    if (!res.ok) throw new Error(`embeddings ${res.status}: ${(await res.text()).slice(0, 300)}`);
    const j = await res.json();
    for (const d of j.data) out.push(d.embedding);
  }
  return out;
}

export async function POST() {
  if (!process.env.SUPABASE_SERVICE_ROLE_KEY)
    return Response.json(
      { error: "Sync needs SUPABASE_SERVICE_ROLE_KEY set in the server environment." },
      { status: 503 }
    );
  if (!EMBED_KEY)
    return Response.json(
      { error: "Sync needs EMBEDDINGS_API_KEY (OpenAI) set in the server environment." },
      { status: 503 }
    );

  const sb = admin();
  try {
    const [countriesRes, faqsRes, mentorsRes] = await Promise.all([
      sb.from("country_docs").select("country_code,country_name,content").eq("is_published", true),
      sb.from("faq_docs").select("id,title,content").eq("is_published", true),
      sb.rpc("kb_mentor_source"),
    ]);
    if (countriesRes.error) throw new Error(`country_docs: ${countriesRes.error.message}`);
    if (faqsRes.error) throw new Error(`faq_docs: ${faqsRes.error.message}`);
    if (mentorsRes.error) throw new Error(`kb_mentor_source: ${mentorsRes.error.message}`);

    type Doc = { kind: string; source_key: string; ref_id: number | null; title: string; content: string; url: string | null };
    const docs: Doc[] = [];

    for (const c of countriesRes.data || [])
      docs.push({
        kind: "country",
        source_key: `country:${String(c.country_code).toLowerCase()}`,
        ref_id: null,
        title: `${c.country_name} — immigration overview`,
        content: c.content,
        url: null,
      });

    for (const f of faqsRes.data || [])
      docs.push({
        kind: "faq",
        source_key: `faq:${f.id}`,
        ref_id: null,
        title: f.title,
        content: f.content,
        url: null,
      });

    for (const m of (mentorsRes.data || []) as any[]) {
      if (!m.name) continue;
      const specs = (m.specializations || []).join(", ");
      const langs = (m.languages || []).join(", ");
      docs.push({
        kind: "mentor",
        source_key: `mentor:${m.mentor_id}`,
        ref_id: m.mentor_id,
        title: `${m.name} — ${m.title || "Mentor"}`,
        url: `/mentor/${m.mentor_id}`,
        content:
          `${m.name} — ${m.title || "immigration mentor"} on Immigroov. ` +
          (m.about_me ? `${m.about_me} ` : "") +
          (specs ? `Specializes in: ${specs}. ` : "") +
          (langs ? `Speaks: ${langs}. ` : "") +
          `Average rating ${Number(m.avg_rating).toFixed(1)} from ${m.review_count} reviews. ` +
          `Book a 1:1 session with this mentor at /mentor/${m.mentor_id}.`,
      });
    }

    if (docs.length === 0) return Response.json({ ok: true, embedded: 0, removed: 0 });

    const vectors = await embedBatch(docs.map((d) => `${d.title}\n\n${d.content}`));
    const rows = docs.map((d, i) => ({
      kind: d.kind,
      source_key: d.source_key,
      ref_id: d.ref_id,
      title: d.title,
      content: d.content,
      url: d.url,
      embedding: JSON.stringify(vectors[i]),
    }));

    const { error: upErr } = await sb.from("kb_documents").upsert(rows, { onConflict: "kind,source_key" });
    if (upErr) throw new Error(`upsert: ${upErr.message}`);

    // Drop entries whose source was deleted/unpublished (keep the store in sync).
    const keys = rows.map((r) => r.source_key);
    const { error: delErr } = await sb
      .from("kb_documents")
      .delete()
      .in("kind", ["country", "faq", "mentor", "guide"])
      .not("source_key", "in", `(${keys.map((k) => `"${k}"`).join(",")})`);
    if (delErr) throw new Error(`cleanup: ${delErr.message}`);

    return Response.json({ ok: true, embedded: rows.length });
  } catch (e: any) {
    console.error("[/api/kb/sync]", e?.message || e);
    return Response.json({ error: e?.message || "Sync failed." }, { status: 500 });
  }
}
