"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

type W = {
  id: number; title: string; description: string | null; start_time: string; duration: number;
  capacity: number | null; visibility: string; status: string; room_url: string | null; registrations: number;
};
const fmt = (s: string) => new Date(s).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });

export default function WebinarsManager({ mentorId }: { mentorId: number }) {
  const supabase = createClient();
  const [rows, setRows] = useState<W[]>([]);
  const [form, setForm] = useState({ title: "", description: "", start: "", duration: 60, capacity: "", visibility: "public" });
  const [busy, setBusy] = useState(false);
  const [msg, setMsg] = useState<{ t: string; ok: boolean } | null>(null);
  const [regsFor, setRegsFor] = useState<number | null>(null);
  const [regs, setRegs] = useState<{ name: string; email: string; registered_at: string }[]>([]);

  async function toggleRegs(id: number) {
    if (regsFor === id) { setRegsFor(null); return; }
    setRegsFor(id); setRegs([]);
    const { data } = await supabase.rpc("webinar_registrants", { p_webinar_id: id });
    setRegs((data as any[]) || []);
  }

  const load = useCallback(async () => {
    const { data } = await supabase.rpc("mentor_webinars", { p_mentor_id: mentorId });
    setRows((data as W[]) || []);
  }, [supabase, mentorId]);
  useEffect(() => { load(); }, [load]);

  async function create() {
    if (!form.title.trim() || !form.start) { setMsg({ t: "Title and start time are required.", ok: false }); return; }
    setBusy(true); setMsg(null);
    const { error } = await supabase.rpc("create_webinar", {
      p_mentor_id: mentorId, p_title: form.title, p_description: form.description || null,
      p_start: new Date(form.start).toISOString(), p_duration: Number(form.duration) || 60,
      p_capacity: form.capacity ? Number(form.capacity) : null, p_visibility: form.visibility,
    });
    setBusy(false);
    if (error) { setMsg({ t: error.message, ok: false }); return; }
    setForm({ title: "", description: "", start: "", duration: 60, capacity: "", visibility: "public" });
    setMsg({ t: "Webinar created.", ok: true });
    load();
  }
  async function cancel(id: number) {
    await supabase.rpc("cancel_webinar", { p_webinar_id: id });
    load();
  }

  return (
    <div>
      <div className="card" style={{ padding: 18, marginBottom: 20 }}>
        <div style={{ fontWeight: 800, marginBottom: 12 }}>New webinar</div>
        <div style={{ display: "grid", gap: 10, gridTemplateColumns: "1fr 1fr" }}>
          <input placeholder="Title" value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} style={{ gridColumn: "1 / -1" }} />
          <textarea placeholder="Description (optional)" value={form.description} onChange={(e) => setForm({ ...form, description: e.target.value })} style={{ gridColumn: "1 / -1", minHeight: 60 }} />
          <label className="fld">Start<input type="datetime-local" value={form.start} onChange={(e) => setForm({ ...form, start: e.target.value })} /></label>
          <label className="fld">Duration (min)<input type="number" value={form.duration} onChange={(e) => setForm({ ...form, duration: Number(e.target.value) })} /></label>
          <label className="fld">Capacity (blank = unlimited)<input type="number" value={form.capacity} onChange={(e) => setForm({ ...form, capacity: e.target.value })} /></label>
          <label className="fld">Visibility
            <select value={form.visibility} onChange={(e) => setForm({ ...form, visibility: e.target.value })}>
              <option value="public">Public (listed)</option>
              <option value="invite">Invite-only (link only)</option>
            </select>
          </label>
        </div>
        {msg && <div className={`banner ${msg.ok ? "ok" : "bad"}`} style={{ marginTop: 12 }}>{msg.t}</div>}
        <button className="btn btn-cta" disabled={busy} onClick={create} style={{ marginTop: 12 }}>{busy ? "Creating…" : "Create webinar"}</button>
      </div>

      {rows.length === 0 ? <div className="empty">No webinars yet.</div> :
        <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
          {rows.map((w) => (
            <div key={w.id} className="card" style={{ padding: 16, display: "flex", justifyContent: "space-between", gap: 12, flexWrap: "wrap" }}>
              <div>
                <div style={{ fontWeight: 800 }}>{w.title} <span className={`pill st-${w.status === "scheduled" ? "confirmed" : "cancelled"}`}>{w.status}</span></div>
                <div className="faint" style={{ fontSize: 13 }}>{fmt(w.start_time)} · {w.duration} min · {w.visibility}</div>
                <div className="faint" style={{ fontSize: 12.5, marginTop: 2 }}>
                  <button className="btn-ghost btn-sm" style={{ padding: "2px 8px" }} onClick={() => toggleRegs(w.id)}>
                    {regsFor === w.id ? "Hide" : "View"} registrants ({w.registrations}{w.capacity != null ? ` / ${w.capacity}` : ""})
                  </button>
                </div>
                {w.room_url && <a href={w.room_url} target="_blank" rel="noreferrer" style={{ fontSize: 12.5, fontWeight: 700 }}>Join link</a>}
                {regsFor === w.id && (
                  <div style={{ marginTop: 8, border: "1px solid var(--line)", borderRadius: 8, padding: 10, fontSize: 12.5 }}>
                    {regs.length === 0 ? <span className="faint">No registrants yet.</span> :
                      regs.map((r, i) => <div key={i} style={{ padding: "3px 0", borderBottom: i < regs.length - 1 ? "1px solid var(--line)" : "none" }}>{r.name} · {r.email} <span className="faint">· {new Date(r.registered_at).toLocaleDateString()}</span></div>)}
                  </div>
                )}
              </div>
              {w.status === "scheduled" && <button className="btn-ghost btn-sm" style={{ color: "var(--bad)", alignSelf: "start" }} onClick={() => cancel(w.id)}>Cancel</button>}
            </div>
          ))}
        </div>}
    </div>
  );
}
