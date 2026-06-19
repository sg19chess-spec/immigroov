"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { money } from "@/lib/format";

type Svc = { id: number; title: string; description: string; duration: number; type: string; category: string; set_price: number; set_currency: string; platform_fee: number; is_active: boolean; is_ppp: boolean };
type Q = { id: number; question_text: string; is_required: boolean };

export default function ServicesManager({ mentorId }: { mentorId: number }) {
  const supabase = createClient();
  const [list, setList] = useState<Svc[]>([]);
  const [openQ, setOpenQ] = useState<number | null>(null);
  const [qs, setQs] = useState<Q[]>([]);
  const [form, setForm] = useState({ title: "", desc: "", cat: "", type: "video", dur: 30, price: "", ppp: false, active: true });
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("demo_list_services", { p_mentor_id: mentorId });
    setList((data || []) as Svc[]);
  }, [supabase, mentorId]);
  useEffect(() => { load(); }, [load]);

  async function create() {
    if (!form.title || !form.price) { setMsg("Title and price are required."); return; }
    const { error } = await supabase.rpc("demo_create_service", {
      p_mentor_id: mentorId, p_title: form.title, p_description: form.desc, p_type: form.type,
      p_duration: form.dur, p_category: form.cat, p_set_price: Number(form.price), p_active: form.active, p_ppp: form.ppp,
    });
    if (error) { setMsg(error.message); return; }
    setForm({ title: "", desc: "", cat: "", type: "video", dur: 30, price: "", ppp: false, active: true });
    setMsg("Service created."); load();
  }
  async function toggle(s: Svc) { await supabase.rpc("demo_set_service_active", { p_id: s.id, p_active: !s.is_active }); load(); }
  async function del(id: number) { const { error } = await supabase.rpc("demo_delete_service", { p_id: id }); if (error) setMsg(error.message); load(); }
  async function showQ(id: number) {
    if (openQ === id) { setOpenQ(null); return; }
    setOpenQ(id);
    const { data } = await supabase.rpc("demo_list_questions", { p_service_id: id });
    setQs((data || []) as Q[]);
  }
  async function addQ(id: number, text: string, req: boolean) {
    if (!text) return;
    await supabase.rpc("demo_add_question", { p_service_id: id, p_text: text, p_required: req, p_type: "text" });
    const { data } = await supabase.rpc("demo_list_questions", { p_service_id: id }); setQs((data || []) as Q[]);
  }
  async function rmQ(qid: number, sid: number) {
    await supabase.rpc("demo_remove_question", { p_id: qid });
    const { data } = await supabase.rpc("demo_list_questions", { p_service_id: sid }); setQs((data || []) as Q[]);
  }

  const inp = { padding: "8px 10px", width: "100%" } as const;
  return (
    <div className="card">
      <h2 style={{ marginTop: 0 }}>Services</h2>
      {msg && <div className="banner ok">{msg}</div>}
      {list.map((s) => (
        <div key={s.id} style={{ display: "flex", justifyContent: "space-between", gap: 10, padding: "10px 0", borderBottom: "1px solid var(--line)" }}>
          <div>
            <div style={{ fontWeight: 600 }}>{s.title} <span className="muted" style={{ fontWeight: 400 }}>· {s.duration}m · {s.type}</span> {s.is_active ? "" : <span className="tag">inactive</span>}</div>
            <div className="muted" style={{ fontSize: 12 }}>{s.category || "—"} · {money(s.set_price, s.set_currency)} {s.set_currency} (fee {money(s.platform_fee, s.set_currency)}){s.is_ppp ? " · PPP" : ""}</div>
            {openQ === s.id && (
              <div style={{ background: "var(--bg)", border: "1px solid var(--line)", borderRadius: 9, padding: 8, marginTop: 6 }}>
                <div style={{ fontSize: 12, fontWeight: 600 }}>Custom questions</div>
                {qs.length === 0 && <div className="muted" style={{ fontSize: 12 }}>None yet.</div>}
                {qs.map((q) => <div key={q.id} style={{ fontSize: 12, padding: "2px 0" }}>• {q.question_text}{q.is_required ? " (required)" : ""} <span style={{ color: "var(--bad)", cursor: "pointer" }} onClick={() => rmQ(q.id, s.id)}>×</span></div>)}
                <QAdd onAdd={(t, r) => addQ(s.id, t, r)} />
              </div>
            )}
          </div>
          <div style={{ display: "flex", gap: 6, height: "fit-content", whiteSpace: "nowrap" }}>
            <button className="btn-ghost" onClick={() => toggle(s)}>{s.is_active ? "Deactivate" : "Activate"}</button>
            <button className="btn-ghost" onClick={() => showQ(s.id)}>Questions</button>
            <button className="btn-ghost" style={{ color: "var(--bad)" }} onClick={() => del(s.id)}>Delete</button>
          </div>
        </div>
      ))}
      {list.length === 0 && <p className="muted">No services yet.</p>}

      <div style={{ borderTop: "1px solid var(--line)", marginTop: 14, paddingTop: 14 }}>
        <b style={{ fontSize: 13 }}>Add a service</b>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 8, marginTop: 8 }}>
          <input style={inp} placeholder="Title" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} />
          <input style={inp} placeholder="Category" value={form.cat} onChange={(e) => setForm({ ...form, cat: e.target.value })} />
          <input style={{ ...inp, gridColumn: "1/3" }} placeholder="Short description" value={form.desc} onChange={(e) => setForm({ ...form, desc: e.target.value })} />
          <select style={inp} value={form.type} onChange={(e) => setForm({ ...form, type: e.target.value })}><option value="video">Video consultation</option><option value="dm">DM / text</option></select>
          <select style={inp} value={form.dur} onChange={(e) => setForm({ ...form, dur: Number(e.target.value) })}><option value={15}>15 min</option><option value={30}>30 min</option><option value={45}>45 min</option><option value={60}>60 min</option></select>
          <input style={inp} type="number" placeholder="Price (in your currency)" value={form.price} onChange={(e) => setForm({ ...form, price: e.target.value })} />
          <div style={{ display: "flex", gap: 14, alignItems: "center", fontSize: 13 }}>
            <label style={{ display: "inline-flex", gap: 5, alignItems: "center" }}><input type="checkbox" checked={form.ppp} onChange={(e) => setForm({ ...form, ppp: e.target.checked })} /> PPP</label>
            <label style={{ display: "inline-flex", gap: 5, alignItems: "center" }}><input type="checkbox" checked={form.active} onChange={(e) => setForm({ ...form, active: e.target.checked })} /> Active</label>
          </div>
        </div>
        <button className="btn-cta" style={{ marginTop: 10 }} onClick={create}>Create service</button>
      </div>
    </div>
  );
}

function QAdd({ onAdd }: { onAdd: (t: string, r: boolean) => void }) {
  const [t, setT] = useState(""); const [r, setR] = useState(false);
  return (
    <div style={{ display: "flex", gap: 6, marginTop: 6 }}>
      <input style={{ flex: 1, padding: "5px 8px", fontSize: 12 }} placeholder="New question" value={t} onChange={(e) => setT(e.target.value)} />
      <label style={{ fontSize: 12, display: "inline-flex", gap: 4, alignItems: "center" }}><input type="checkbox" checked={r} onChange={(e) => setR(e.target.checked)} />req</label>
      <button className="btn-cta" onClick={() => { onAdd(t, r); setT(""); }}>Add</button>
    </div>
  );
}
