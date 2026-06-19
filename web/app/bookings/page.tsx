"use client";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { money, myTz, fmtTime, fmtDate } from "@/lib/format";

type B = {
  id: number; status: string; slot_time: string; meeting_url: string | null;
  service_title: string; mentor_name: string; mentor_tz: string; customer_tz: string;
  cost: number; cost_currency: string; mentor_earn: number; mentor_currency: string;
};

const STATUS: Record<string, string> = { confirmed: "var(--ok)", completed: "var(--navy2)", rescheduled: "#d97706", cancelled: "var(--bad)", no_show: "var(--bad)", pending: "var(--muted)" };

export default function Bookings() {
  const supabase = createClient();
  const tz = myTz();
  const [rows, setRows] = useState<B[]>([]);
  const [signedIn, setSignedIn] = useState<boolean | null>(null);

  async function load() {
    const { data: u } = await supabase.auth.getUser();
    setSignedIn(!!u.user);
    if (!u.user) return;
    const { data } = await supabase.rpc("my_bookings");
    setRows((data || []) as B[]);
  }
  useEffect(() => { load(); }, []);

  async function cancel(id: number) {
    await supabase.rpc("cancel_booking", { p_booking_id: id, p_cancelled_by: "user" });
    load();
  }

  return (
    <div className="container">
      <h2 className="sec">Your sessions</h2>
      {signedIn === false && <p className="muted">Sign in (or book a session) to see your bookings.</p>}
      {signedIn && rows.length === 0 && <p className="muted">No bookings yet.</p>}
      <div className="grid">
        {rows.map((b) => (
          <div className="card" key={b.id} style={{ padding: 0, overflow: "hidden" }}>
            <div style={{ padding: 18, display: "flex", justifyContent: "space-between", gap: 10 }}>
              <div>
                <div style={{ fontWeight: 600 }}>{b.service_title}</div>
                <div className="muted" style={{ fontSize: 13 }}>with {b.mentor_name}</div>
              </div>
              <span style={{ fontSize: 11, fontWeight: 600, textTransform: "uppercase", color: STATUS[b.status], border: `1px solid ${STATUS[b.status]}`, padding: "3px 9px", borderRadius: 999, height: "fit-content" }}>{b.status}</span>
            </div>
            <Clock label="You" tz={b.customer_tz} iso={b.slot_time} dot="var(--orange)" />
            <Clock label="Mentor" tz={b.mentor_tz} iso={b.slot_time} dot="var(--navy)" />
            <Clock label="UTC" tz="UTC" iso={b.slot_time} dot="#94a3b8" />
            <div style={{ display: "flex", justifyContent: "space-between", padding: "11px 18px", borderTop: "1px solid var(--line)", fontSize: 12 }}>
              <div><div className="muted">You paid</div><b>{b.cost != null ? money(b.cost, b.cost_currency) : "—"}</b></div>
              <div style={{ textAlign: "right" }}><div className="muted">Mentor earns</div><b style={{ color: "var(--orange-d)" }}>{b.mentor_earn != null ? money(b.mentor_earn, b.mentor_currency) : "—"}</b></div>
            </div>
            <div style={{ display: "flex", gap: 10, padding: 14, borderTop: "1px solid var(--line)" }}>
              {b.meeting_url && <a href={b.meeting_url} target="_blank" className="btn btn-cta" style={{ padding: "9px 14px" }}>Join video call</a>}
              {!["cancelled", "completed", "no_show"].includes(b.status) && <button className="btn-ghost" onClick={() => cancel(b.id)}>Cancel</button>}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

function Clock({ label, tz, iso, dot }: { label: string; tz: string; iso: string; dot: string }) {
  return (
    <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", padding: "11px 18px", borderTop: "1px solid var(--line)" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <span style={{ width: 9, height: 9, borderRadius: "50%", background: dot, display: "inline-block" }} />
        <div><div style={{ fontSize: 13, fontWeight: 600 }}>{label}</div><div className="muted" style={{ fontSize: 11 }}>{tz}</div></div>
      </div>
      <div style={{ textAlign: "right" }}>
        <div style={{ fontFamily: "monospace", fontSize: 16, fontWeight: 600 }}>{fmtTime(iso, tz)}</div>
        <div className="muted" style={{ fontSize: 11 }}>{fmtDate(iso, tz)}</div>
      </div>
    </div>
  );
}
