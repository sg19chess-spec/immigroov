"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, myTz, fmtTime, fmtDate } from "@/lib/format";
import { getEmail } from "@/lib/identity";

type B = {
  id: number; status: string; slot_time: string; meeting_url: string | null;
  service_title: string; mentor_name: string; mentor_tz: string; customer_tz: string;
  cost: number; cost_currency: string; mentor_earn: number; mentor_currency: string;
};

export default function Bookings() {
  const supabase = createClient();
  const tz = myTz();
  const [rows, setRows] = useState<B[]>([]);
  const [email, setEmail] = useState<string | null | undefined>(undefined);

  async function load(e: string) {
    const { data } = await supabase.rpc("bookings_by_email", { p_email: e });
    setRows((data || []) as B[]);
  }
  useEffect(() => { const e = getEmail(); setEmail(e); if (e) load(e); }, []);
  async function cancel(id: number) { await supabase.rpc("cancel_booking", { p_booking_id: id, p_cancelled_by: "user" }); if (email) load(email); }

  const now = Date.now();
  const upcoming = rows.filter((b) => new Date(b.slot_time).getTime() >= now && !["cancelled", "completed", "no_show"].includes(b.status));
  const past = rows.filter((b) => !upcoming.includes(b));

  return (
    <div className="container">
      <div className="section-head"><h2 className="sec">Your sessions</h2></div>

      {email === null && <div className="empty"><div className="ico">🔑</div>Sign in with your email to see your sessions.<br /><Link href="/login" className="btn btn-cta" style={{ marginTop: 14 }}>Sign in</Link></div>}
      {email && rows.length === 0 && <div className="empty"><div className="ico">📅</div>No bookings under {email} yet.<br /><Link href="/" className="btn btn-cta" style={{ marginTop: 14 }}>Find a mentor</Link></div>}

      {upcoming.length > 0 && <h3 style={{ fontSize: 15, color: "var(--muted)", margin: "8px 0 14px" }}>Upcoming</h3>}
      <div className="grid">{upcoming.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} onCancel={cancel} />)}</div>

      {past.length > 0 && <h3 style={{ fontSize: 15, color: "var(--muted)", margin: "30px 0 14px" }}>Past &amp; cancelled</h3>}
      <div className="grid">{past.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} onCancel={cancel} dim />)}</div>
    </div>
  );
}

function Card({ b, tz, i, onCancel, dim }: { b: B; tz: string; i: number; onCancel: (id: number) => void; dim?: boolean }) {
  const active = !["cancelled", "completed", "no_show"].includes(b.status);
  return (
    <div className="card reveal" style={{ padding: 0, overflow: "hidden", animationDelay: `${i * 50}ms`, opacity: dim ? 0.85 : 1 }}>
      <div style={{ padding: "18px 20px", display: "flex", justifyContent: "space-between", gap: 10 }}>
        <div>
          <div style={{ fontWeight: 700, fontSize: 16 }}>{b.service_title}</div>
          <div className="muted" style={{ fontSize: 13 }}>with {b.mentor_name}</div>
        </div>
        <span className={`pill st-${b.status}`}>{b.status}</span>
      </div>
      <div style={{ padding: "0 20px 14px" }}>
        <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: "-.02em" }}>{fmtTime(b.slot_time, tz)}</div>
        <div className="muted" style={{ fontSize: 13 }}>{fmtDate(b.slot_time, tz)} · your time ({tz})</div>
        <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>Mentor: {fmtTime(b.slot_time, b.mentor_tz)} ({b.mentor_tz}) · UTC {fmtTime(b.slot_time, "UTC")}</div>
      </div>
      <div style={{ display: "flex", justifyContent: "space-between", padding: "12px 20px", borderTop: "1px solid var(--line)", fontSize: 12, background: "var(--surface-2)" }}>
        <div><div className="faint">You paid</div><b>{b.cost != null ? money(b.cost, b.cost_currency) : "—"}</b></div>
        <div style={{ textAlign: "right" }}><div className="faint">Mentor earns</div><b style={{ color: "var(--orange-d)" }}>{b.mentor_earn != null ? money(b.mentor_earn, b.mentor_currency) : "—"}</b></div>
      </div>
      <div style={{ display: "flex", gap: 10, padding: 16, borderTop: "1px solid var(--line)" }}>
        {b.meeting_url && active && <a href={b.meeting_url} target="_blank" className="btn btn-cta" style={{ flex: 1 }}>🎥 Join video call</a>}
        {active && <button className="btn-ghost" onClick={() => onCancel(b.id)}>Cancel</button>}
        {!active && <span className="faint" style={{ fontSize: 13, padding: "6px 0" }}>No actions available</span>}
      </div>
    </div>
  );
}
