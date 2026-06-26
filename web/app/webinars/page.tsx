"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { getEmail } from "@/lib/identity";

type Webinar = {
  id: number; title: string; description: string | null; start_time: string; duration: number;
  capacity: number | null; mentor_name: string; registrations: number;
};

const fmt = (s: string) => new Date(s).toLocaleString([], { dateStyle: "medium", timeStyle: "short" });

export default function WebinarsPage() {
  const supabase = createClient();
  const [rows, setRows] = useState<Webinar[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    const { data } = await supabase.rpc("list_webinars");
    setRows((data as Webinar[]) || []);
    setLoading(false);
  }, [supabase]);
  useEffect(() => { load(); }, [load]);

  return (
    <div className="container">
      <div className="section-head">
        <div>
          <h2 className="sec">Upcoming webinars</h2>
          <div className="lead">Group sessions with our mentors — register to get the join link.</div>
        </div>
      </div>
      {loading ? <div className="empty">Loading…</div> :
        rows.length === 0 ? <div className="empty">No upcoming webinars right now. Check back soon.</div> :
        <div style={{ display: "grid", gap: 16, gridTemplateColumns: "repeat(auto-fill, minmax(300px,1fr))" }}>
          {rows.map((w) => <Card key={w.id} w={w} onChange={load} />)}
        </div>}
    </div>
  );
}

function Card({ w, onChange }: { w: Webinar; onChange: () => void }) {
  const supabase = createClient();
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [joined, setJoined] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);
  useEffect(() => { setEmail(getEmail() || ""); }, []);
  const full = w.capacity != null && w.registrations >= w.capacity;

  async function register() {
    if (!email.includes("@")) { setErr("Enter a valid email."); return; }
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("register_webinar", { p_webinar_id: w.id, p_email: email.trim(), p_name: name || null });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setJoined((data as any)?.room_url || null);
    onChange();
  }

  return (
    <div className="card" style={{ padding: 18, display: "flex", flexDirection: "column", gap: 8 }}>
      <div style={{ fontWeight: 800, fontSize: 16 }}>{w.title}</div>
      <div className="faint" style={{ fontSize: 13 }}>with {w.mentor_name} · {fmt(w.start_time)} · {w.duration} min</div>
      {w.description && <div style={{ fontSize: 13.5, color: "var(--muted)" }}>{w.description}</div>}
      <div className="faint" style={{ fontSize: 12 }}>{w.registrations}{w.capacity != null ? ` / ${w.capacity}` : ""} registered</div>

      {joined ? (
        <div className="banner ok" style={{ marginTop: 6 }}>
          You're registered! <a href={joined} target="_blank" rel="noreferrer" style={{ fontWeight: 700 }}>Join link</a> — also emailed to you.
        </div>
      ) : full ? (
        <div className="banner bad" style={{ marginTop: 6 }}>This webinar is full.</div>
      ) : (
        <div style={{ display: "flex", flexDirection: "column", gap: 8, marginTop: 6 }}>
          <input placeholder="Your name (optional)" value={name} onChange={(e) => setName(e.target.value)} />
          <input placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
          {err && <div style={{ color: "var(--bad)", fontSize: 12.5 }}>{err}</div>}
          <button className="btn btn-cta" disabled={busy} onClick={register}>{busy ? "Registering…" : "Register"}</button>
        </div>
      )}
    </div>
  );
}
