"use client";
import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

type Country = { country_code: string; country_name: string; content: string; is_published: boolean };
type Faq = { id: number; title: string; content: string; is_published: boolean };

// Knowledge base editor: the text here is what Groovia AI is allowed to use.
// Saving stores the text; "Sync to Groovia AI" embeds it into the vector store.
export default function ResourcesManager() {
  const supabase = createClient();
  const [sub, setSub] = useState<"faqs" | "countries">("faqs");
  const [faqs, setFaqs] = useState<Faq[]>([]);
  const [countries, setCountries] = useState<Country[]>([]);
  const [faqEdit, setFaqEdit] = useState<number | "new" | null>(null);
  const [ctyEdit, setCtyEdit] = useState<string | "new" | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [syncing, setSyncing] = useState(false);

  const load = useCallback(async () => {
    const [{ data: f }, { data: c }] = await Promise.all([
      supabase.rpc("kb_admin_list_faqs"),
      supabase.rpc("kb_admin_list_countries"),
    ]);
    setFaqs((f || []) as Faq[]);
    setCountries((c || []) as Country[]);
  }, [supabase]);
  useEffect(() => { load(); }, [load]);

  async function sync() {
    setSyncing(true); setMsg(null);
    try {
      const res = await fetch("/api/kb/sync", { method: "POST" });
      const d = await res.json();
      setMsg(res.ok ? `✓ Synced ${d.embedded} documents into Groovia AI's memory.` : (d.error || "Sync failed."));
    } catch { setMsg("Sync failed — network error."); }
    setSyncing(false);
  }

  async function saveFaq(id: number | null, title: string, content: string, pub: boolean) {
    if (!title.trim() || !content.trim()) { setMsg("Title and content are required."); return false; }
    const { error } = await supabase.rpc("kb_admin_upsert_faq", { p_id: id, p_title: title, p_content: content, p_published: pub });
    if (error) { setMsg(error.message); return false; }
    await load(); setMsg('Saved. Click "Sync to Groovia AI" to update its answers.'); return true;
  }
  async function delFaq(id: number) { await supabase.rpc("kb_admin_delete_faq", { p_id: id }); load(); }

  async function saveCountry(code: string, name: string, content: string, pub: boolean) {
    if (!code.trim() || !name.trim() || !content.trim()) { setMsg("Code, name and content are required."); return false; }
    const { error } = await supabase.rpc("kb_admin_upsert_country", { p_code: code, p_name: name, p_content: content, p_published: pub });
    if (error) { setMsg(error.message); return false; }
    await load(); setMsg('Saved. Click "Sync to Groovia AI" to update its answers.'); return true;
  }
  async function delCountry(code: string) { await supabase.rpc("kb_admin_delete_country", { p_code: code }); load(); }

  return (
    <div className="card">
      <div className="row-between" style={{ marginBottom: 6, flexWrap: "wrap", gap: 10 }}>
        <div>
          <h2 className="sec" style={{ fontSize: 18 }}>Groovia AI knowledge</h2>
          <div className="muted" style={{ fontSize: 12.5 }}>Add the text the assistant is allowed to answer from. It won't invent facts outside this.</div>
        </div>
        <button className="btn-cta btn-sm" onClick={sync} disabled={syncing}>{syncing ? "Syncing…" : "⚡ Sync to Groovia AI"}</button>
      </div>
      {msg && <div className="banner ok">{msg}</div>}

      <div className="seg" style={{ margin: "12px 0 16px" }}>
        {(["faqs", "countries"] as const).map((t) => (
          <button key={t} className={sub === t ? "on" : ""} onClick={() => setSub(t)} style={{ textTransform: "capitalize" }}>{t}</button>
        ))}
      </div>

      {sub === "faqs" && (
        <>
          <div className="row-between" style={{ marginBottom: 8 }}>
            <b style={{ fontSize: 14 }}>FAQs &amp; guides</b>
            {faqEdit !== "new" && <button className="btn-ghost btn-sm" onClick={() => setFaqEdit("new")}>+ New FAQ</button>}
          </div>
          {faqEdit === "new" && (
            <FaqEditor onSave={async (t, c, p) => { if (await saveFaq(null, t, c, p)) setFaqEdit(null); }} onCancel={() => setFaqEdit(null)} />
          )}
          {faqs.map((f) =>
            faqEdit === f.id ? (
              <FaqEditor key={f.id} initial={f} onSave={async (t, c, p) => { if (await saveFaq(f.id, t, c, p)) setFaqEdit(null); }} onCancel={() => setFaqEdit(null)} />
            ) : (
              <div className="list-row" key={f.id}>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div style={{ fontWeight: 700 }}>{f.title}{!f.is_published && <span className="pill st-pending" style={{ marginLeft: 6 }}>hidden</span>}</div>
                  <div className="muted clamp2" style={{ fontSize: 12.5, marginTop: 2 }}>{f.content}</div>
                </div>
                <div className="actions">
                  <button className="btn-ghost btn-sm" onClick={() => setFaqEdit(f.id)}>Edit</button>
                  <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => delFaq(f.id)}>Delete</button>
                </div>
              </div>
            )
          )}
          {faqs.length === 0 && faqEdit !== "new" && <div className="empty" style={{ padding: "28px 10px" }}><div className="ico">❓</div>No FAQs yet — add your first one.</div>}
        </>
      )}

      {sub === "countries" && (
        <>
          <div className="row-between" style={{ marginBottom: 8 }}>
            <b style={{ fontSize: 14 }}>Country guides</b>
            {ctyEdit !== "new" && <button className="btn-ghost btn-sm" onClick={() => setCtyEdit("new")}>+ New country</button>}
          </div>
          {ctyEdit === "new" && (
            <CountryEditor onSave={async (code, n, c, p) => { if (await saveCountry(code, n, c, p)) setCtyEdit(null); }} onCancel={() => setCtyEdit(null)} />
          )}
          {countries.map((c) =>
            ctyEdit === c.country_code ? (
              <CountryEditor key={c.country_code} initial={c} onSave={async (code, n, ct, p) => { if (await saveCountry(code, n, ct, p)) setCtyEdit(null); }} onCancel={() => setCtyEdit(null)} />
            ) : (
              <div className="list-row" key={c.country_code}>
                <div style={{ minWidth: 0, flex: 1 }}>
                  <div style={{ fontWeight: 700 }}>{c.country_name} <span className="faint" style={{ fontWeight: 500 }}>({c.country_code})</span>{!c.is_published && <span className="pill st-pending" style={{ marginLeft: 6 }}>hidden</span>}</div>
                  <div className="muted clamp2" style={{ fontSize: 12.5, marginTop: 2 }}>{c.content}</div>
                </div>
                <div className="actions">
                  <button className="btn-ghost btn-sm" onClick={() => setCtyEdit(c.country_code)}>Edit</button>
                  <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => delCountry(c.country_code)}>Delete</button>
                </div>
              </div>
            )
          )}
          {countries.length === 0 && ctyEdit !== "new" && <div className="empty" style={{ padding: "28px 10px" }}><div className="ico">🌍</div>No countries yet — add your first one.</div>}
        </>
      )}

      <div className="faint" style={{ fontSize: 11.5, marginTop: 14 }}>
        Saving stores the text. Press <b>Sync to Groovia AI</b> to re-embed everything (countries, FAQs, and mentor profiles) into the assistant's searchable memory. Sync needs the embeddings key configured on the server.
      </div>
    </div>
  );
}

function FaqEditor({ initial, onSave, onCancel }: { initial?: Faq; onSave: (t: string, c: string, p: boolean) => void; onCancel: () => void }) {
  const [t, setT] = useState(initial?.title || "");
  const [c, setC] = useState(initial?.content || "");
  const [p, setP] = useState(initial?.is_published ?? true);
  return (
    <div className="card reveal" style={{ background: "var(--surface-2)", marginBottom: 12 }}>
      <div className="row-between" style={{ marginBottom: 10 }}><b>{initial ? "Edit FAQ" : "New FAQ"}</b><button className="btn-ghost btn-sm" onClick={onCancel}>Cancel</button></div>
      <label className="fld">Question / title</label>
      <input style={{ width: "100%", marginBottom: 10 }} value={t} onChange={(e) => setT(e.target.value)} placeholder="e.g. How does booking work?" />
      <label className="fld">Answer (plain text)</label>
      <textarea style={{ width: "100%", minHeight: 120 }} value={c} onChange={(e) => setC(e.target.value)} placeholder="Write the answer Groovia AI should use…" />
      <div className="actions" style={{ marginTop: 12, gap: 16 }}>
        <label className="row-between" style={{ gap: 8 }}><span className={`toggle ${p ? "on" : ""}`} onClick={() => setP(!p)}><span className="knob" /></span><span style={{ fontSize: 13 }}>Published</span></label>
        <button className="btn-cta btn-sm" onClick={() => onSave(t, c, p)}>Save</button>
      </div>
    </div>
  );
}

function CountryEditor({ initial, onSave, onCancel }: { initial?: Country; onSave: (code: string, name: string, content: string, p: boolean) => void; onCancel: () => void }) {
  const [code, setCode] = useState(initial?.country_code || "");
  const [name, setName] = useState(initial?.country_name || "");
  const [c, setC] = useState(initial?.content || "");
  const [p, setP] = useState(initial?.is_published ?? true);
  return (
    <div className="card reveal" style={{ background: "var(--surface-2)", marginBottom: 12 }}>
      <div className="row-between" style={{ marginBottom: 10 }}><b>{initial ? "Edit country" : "New country"}</b><button className="btn-ghost btn-sm" onClick={onCancel}>Cancel</button></div>
      <div className="form-grid">
        <div><label className="fld">Country code</label><input style={{ width: "100%" }} maxLength={2} value={code} disabled={!!initial} onChange={(e) => setCode(e.target.value.toUpperCase())} placeholder="US" /></div>
        <div><label className="fld">Country name</label><input style={{ width: "100%" }} value={name} onChange={(e) => setName(e.target.value)} placeholder="United States" /></div>
      </div>
      <label className="fld" style={{ marginTop: 10 }}>Details (plain text)</label>
      <textarea style={{ width: "100%", minHeight: 140 }} value={c} onChange={(e) => setC(e.target.value)} placeholder="Visa routes, eligibility basics, timelines, common pitfalls…" />
      <div className="actions" style={{ marginTop: 12, gap: 16 }}>
        <label className="row-between" style={{ gap: 8 }}><span className={`toggle ${p ? "on" : ""}`} onClick={() => setP(!p)}><span className="knob" /></span><span style={{ fontSize: 13 }}>Published</span></label>
        <button className="btn-cta btn-sm" onClick={() => onSave(code, name, c, p)}>Save</button>
      </div>
    </div>
  );
}
