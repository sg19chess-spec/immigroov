"use client";
import { useEffect, useState, useCallback } from "react";
import { useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";
import { getEmail } from "@/lib/identity";

type W = {
  id: number; title: string; description: string | null; start_time: string; duration: number;
  capacity: number | null; status: string; mentor_name: string; registrations: number;
};
const fmt = (s: string) => new Date(s).toLocaleString([], { dateStyle: "full", timeStyle: "short" });

export default function WebinarShare() {
  const supabase = createClient();
  const params = useParams();
  const id = Number(params?.id);
  const [w, setW] = useState<W | null>(null);
  const [loading, setLoading] = useState(true);
  const [name, setName] = useState("");
  const [email, setEmail] = useState("");
  const [busy, setBusy] = useState(false);
  const [joined, setJoined] = useState<string | null>(null);
  const [err, setErr] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data } = await supabase.rpc("webinar_public", { p_id: id });
    setW(((data as W[]) || [])[0] || null);
    setLoading(false);
  }, [supabase, id]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => { setEmail(getEmail() || ""); }, []);

  async function register() {
    if (!email.includes("@")) { setErr("Enter a valid email."); return; }
    setBusy(true); setErr(null);
    const { data, error } = await supabase.rpc("register_webinar", { p_webinar_id: id, p_email: email.trim(), p_name: name || null });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setJoined((data as any)?.room_url || null);
    load();
  }

  if (loading) return <div className="container"><div className="empty">Loading…</div></div>;
  if (!w) return <div className="container"><div className="empty">This webinar link is invalid.</div></div>;

  const full = w.capacity != null && w.registrations >= w.capacity;
  const closed = w.status !== "scheduled" || new Date(w.start_time).getTime() < Date.now();

  return (
    <div className="container" style={{ maxWidth: 620 }}>
      <div className="card" style={{ padding: 24 }}>
        <h2 className="sec" style={{ marginBottom: 6 }}>{w.title}</h2>
        <div className="faint" style={{ fontSize: 14 }}>with {w.mentor_name} · {w.duration} min</div>
        <div style={{ fontWeight: 700, margin: "8px 0", fontSize: 15 }}>{fmt(w.start_time)}</div>
        {w.description && <p style={{ fontSize: 14.5, color: "var(--muted)", marginBottom: 10 }}>{w.description}</p>}
        <div className="faint" style={{ fontSize: 12.5, marginBottom: 14 }}>{w.registrations}{w.capacity != null ? ` / ${w.capacity}` : ""} registered</div>

        {joined ? (
          <div className="banner ok">
            <b>You're registered!</b> <a href={joined} target="_blank" rel="noreferrer" style={{ fontWeight: 700 }}>Join link</a>.<br />
            We've emailed your confirmation, and we'll remind you <b>1 day before</b> and <b>1 hour before</b> it starts.
          </div>
        ) : closed ? (
          <div className="banner bad">Registration for this webinar is closed.</div>
        ) : full ? (
          <div className="banner bad">This webinar is full.</div>
        ) : (
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <input placeholder="Your name (optional)" value={name} onChange={(e) => setName(e.target.value)} />
            <input placeholder="you@example.com" value={email} onChange={(e) => setEmail(e.target.value)} />
            {err && <div style={{ color: "var(--bad)", fontSize: 12.5 }}>{err}</div>}
            <button className="btn btn-cta" disabled={busy} onClick={register}>{busy ? "Registering…" : "Register"}</button>
            <div className="faint" style={{ fontSize: 12 }}>You'll get a confirmation email plus reminders 1 day and 1 hour before.</div>
          </div>
        )}
      </div>
    </div>
  );
}
