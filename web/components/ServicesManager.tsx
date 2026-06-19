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
  const [adding, setAdding] = useState(false);
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
    setAdding(false); setMsg("Service created."); load();
  }
  async function toggle(s: Svc) { await supabase.rpc("demo_set_service_active", { p_id: s.id, p_active: !s.is_active }); load(); }
  async function del(id: number) { const { error } = await supabase.rpc("demo_delete_service", { p_id: id }); if (error) setMsg(error.message); load(); }
  async function showQ(id: number) {
    if (openQ === id) { setOpenQ(null); return; }
    setOpenQ(id);
    const { data } = await supabase.rpc("demo_list_questions", { p_service_id: id }); setQs((data || []) as Q[]);
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

  return (
    <div className="card">
      <div className="row-between" style={{ marginBottom: 8 }}>
        <h2 className="sec" style={{ fontSize: 18 }}>Services</h2>
        {!adding && <button className="btn-cta btn-sm" onClick={() => setAdding(true)}>+ New service</button>}
      </div>
      {msg && <div className="banner ok">{msg}</div>}

      {adding && (
        <div className="card reveal" style={{ background: "var(--surface-2)", marginBottom: 16 }}>
          <div className="row-between" style={{ marginBottom: 10 }}><b>New service</b><button className="btn-ghost btn-sm" onClick={() => setAdding(false)}>Cancel</button></div>
          <div className="form-grid">
            <div className="span2"><label className="fld">Title *</label><input className="full-sm" style={{ width: "100%" }} placeholder="e.g. Visa strategy call" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} /></div>
            <div className="span2"><label className="fld">Description</label><input style={{ width: "100%" }} placeholder="What's included" value={form.desc} onChange={(e) => setForm({ ...form, desc: e.target.value })} /></div>
            <div><label className="fld">Category</label><input style={{ width: "100%" }} placeholder="e.g. Work visa" value={form.cat} onChange={(e) => setForm({ ...form, cat: e.target.value })} /></div>
            <div><label className="fld">Type</label><select style={{ width: "100%" }} value={form.type} onChange={(e) => setForm({ ...form, type: e.target.value })}><option value="video">Video consultation</option><option value="dm">DM / text</option></select></div>
            <div><label className="fld">Duration</label><select style={{ width: "100%" }} value={form.dur} onChange={(e) => setForm({ ...form, dur: Number(e.target.value) })}><option value={15}>15 min</option><option value={30}>30 min</option><option value={45}>45 min</option><option value={60}>60 min</option></select></div>
            <div><label className="fld">Price (your currency)</label><input style={{ width: "100%" }} type="number" inputMode="decimal" placeholder="0.00" value={form.price} onChange={(e) => setForm({ ...form, price: e.target.value })} /></div>
          </div>
          <div className="actions" style={{ margin: "14px 0", gap: 18 }}>
            <label className="row-between" style={{ gap: 8 }}><span className={`toggle ${form.ppp ? "on" : ""}`} onClick={() => setForm({ ...form, ppp: !form.ppp })}><span className="knob" /></span> <span style={{ fontSize: 13 }}>PPP pricing</span></label>
            <label className="row-between" style={{ gap: 8 }}><span className={`toggle ${form.active ? "on" : ""}`} onClick={() => setForm({ ...form, active: !form.active })}><span className="knob" /></span> <span style={{ fontSize: 13 }}>Active</span></label>
          </div>
          <button className="btn-cta full-sm" onClick={create}>Create service</button>
        </div>
      )}

      {list.map((s) => (
        <div className="list-row" key={s.id}>
          <div style={{ minWidth: 0, flex: 1 }}>
            <div style={{ fontWeight: 700 }}>{s.title} {!s.is_active && <span className="pill st-pending" style={{ marginLeft: 4 }}>inactive</span>}</div>
            <div className="muted" style={{ fontSize: 12.5, marginTop: 2 }}>{s.duration} min · {s.type === "video" ? "Video" : "DM"} · {money(s.set_price, s.set_currency)} {s.set_currency}{s.is_ppp ? " · PPP" : ""}</div>
            {openQ === s.id && (
              <div style={{ background: "var(--surface-2)", border: "1px solid var(--line)", borderRadius: 12, padding: 12, marginTop: 10 }}>
                <div style={{ fontSize: 12.5, fontWeight: 700, marginBottom: 6 }}>Custom questions</div>
                {qs.length === 0 && <div className="muted" style={{ fontSize: 12.5 }}>None yet.</div>}
                {qs.map((q) => <div key={q.id} style={{ fontSize: 13, padding: "3px 0", display: "flex", justifyContent: "space-between" }}><span>{q.question_text}{q.is_required ? " *" : ""}</span><span style={{ color: "var(--bad)", cursor: "pointer" }} onClick={() => rmQ(q.id, s.id)}>Remove</span></div>)}
                <QAdd onAdd={(t, r) => addQ(s.id, t, r)} />
              </div>
            )}
          </div>
          <div className="actions">
            <span className={`toggle ${s.is_active ? "on" : ""}`} title="Active" onClick={() => toggle(s)}><span className="knob" /></span>
            <button className="btn-ghost btn-sm" onClick={() => showQ(s.id)}>Questions</button>
            <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => del(s.id)}>Delete</button>
          </div>
        </div>
      ))}
      {list.length === 0 && !adding && <div className="empty" style={{ padding: "32px 10px" }}><div className="ico">🧰</div>No services yet — add your first one.</div>}
    </div>
  );
}

function QAdd({ onAdd }: { onAdd: (t: string, r: boolean) => void }) {
  const [t, setT] = useState(""); const [r, setR] = useState(false);
  return (
    <div style={{ display: "flex", gap: 8, marginTop: 8, flexWrap: "wrap" }}>
      <input style={{ flex: 1, minWidth: 160 }} placeholder="New question" value={t} onChange={(e) => setT(e.target.value)} />
      <label className="row-between" style={{ gap: 6, fontSize: 12.5 }}><span className={`toggle ${r ? "on" : ""}`} onClick={() => setR(!r)}><span className="knob" /></span> required</label>
      <button className="btn-cta btn-sm" onClick={() => { onAdd(t, r); setT(""); }}>Add</button>
    </div>
  );
}
