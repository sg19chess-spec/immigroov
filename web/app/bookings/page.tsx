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
  service_duration: number;
  offer_id: number | null; offer_by: string | null; offer_date: string | null;
  range_start: string | null; range_end: string | null; requested_date: string | null;
};

// Split a mentor's proposed window into bookable slot start-times of the service length.
function slotsIn(rangeStart: string, rangeEnd: string, durMin: number) {
  const out: string[] = [];
  const end = new Date(rangeEnd).getTime();
  const step = (durMin || 30) * 60000;
  const now = Date.now();
  for (let t = new Date(rangeStart).getTime(); t + step <= end; t += step) {
    if (t > now) out.push(new Date(t).toISOString());
  }
  return out;
}

export default function Bookings() {
  const supabase = createClient();
  const tz = myTz();
  const [rows, setRows] = useState<B[]>([]);
  const [email, setEmail] = useState<string | null | undefined>(undefined);
  const [msg, setMsg] = useState<string | null>(null);

  async function load(e: string) {
    const { data } = await supabase.rpc("bookings_by_email", { p_email: e });
    setRows((data || []) as B[]);
  }
  useEffect(() => { const e = getEmail(); setEmail(e); if (e) load(e); }, []);

  async function refresh() { if (email) load(email); }
  async function cancel(id: number) {
    const { error } = await supabase.rpc("cancel_booking", { p_booking_id: id, p_cancelled_by: "user" });
    setMsg(error ? error.message : "Booking cancelled."); refresh();
  }
  async function accept(offerId: number, slotISO: string) {
    const { error } = await supabase.rpc("mentee_accept_reschedule", { p_offer_id: offerId, p_slot_time: slotISO });
    setMsg(error ? error.message : "New time confirmed!"); refresh();
  }
  async function requestDate(bookingId: number, date: string) {
    if (!date) return;
    const { error } = await supabase.rpc("mentee_request_other_date", { p_booking_id: bookingId, p_date: date });
    setMsg(error ? error.message : "Asked your mentor to propose times for that day."); refresh();
  }

  const now = Date.now();
  const upcoming = rows.filter((b) => new Date(b.slot_time).getTime() >= now && !["cancelled", "completed", "no_show"].includes(b.status));
  const past = rows.filter((b) => !upcoming.includes(b));

  return (
    <div className="container">
      <div className="section-head"><h2 className="sec">Your sessions</h2></div>
      {msg && <div className="banner ok" style={{ marginBottom: 14 }}>{msg}</div>}

      {email === null && <div className="empty"><div className="ico">🔑</div>Sign in with your email to see your sessions.<br /><Link href="/login" className="btn btn-cta" style={{ marginTop: 14 }}>Sign in</Link></div>}
      {email && rows.length === 0 && <div className="empty"><div className="ico">📅</div>No bookings under {email} yet.<br /><Link href="/" className="btn btn-cta" style={{ marginTop: 14 }}>Find a mentor</Link></div>}

      {upcoming.length > 0 && <h3 style={{ fontSize: 15, color: "var(--muted)", margin: "8px 0 14px" }}>Upcoming</h3>}
      <div className="grid">{upcoming.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} onCancel={cancel} onAccept={accept} onRequestDate={requestDate} />)}</div>

      {past.length > 0 && <h3 style={{ fontSize: 15, color: "var(--muted)", margin: "30px 0 14px" }}>Past &amp; cancelled</h3>}
      <div className="grid">{past.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} onCancel={cancel} onAccept={accept} onRequestDate={requestDate} dim />)}</div>
    </div>
  );
}

function Card({ b, tz, i, onCancel, onAccept, onRequestDate, dim }: {
  b: B; tz: string; i: number;
  onCancel: (id: number) => void; onAccept: (offerId: number, slotISO: string) => void; onRequestDate: (bookingId: number, date: string) => void; dim?: boolean;
}) {
  const [otherDate, setOtherDate] = useState("");
  const active = !["cancelled", "completed", "no_show"].includes(b.status);
  const mentorOffer = active && b.offer_id && b.offer_by === "mentor" && b.range_start && b.range_end;
  const waitingMentor = active && b.offer_id && b.offer_by === "user";
  const slots = mentorOffer ? slotsIn(b.range_start!, b.range_end!, b.service_duration) : [];

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

      {mentorOffer && (
        <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--orange-soft)" }}>
          <div style={{ fontWeight: 700, fontSize: 13.5 }}>📅 Your mentor proposed a new time</div>
          <div className="muted" style={{ fontSize: 12.5, margin: "2px 0 8px" }}>{fmtDate(b.range_start!, tz)} · pick a slot that works for you ({tz}):</div>
          <div className="slotgrid">
            {slots.map((s) => <button key={s} className="slot" onClick={() => onAccept(b.offer_id!, s)}>{fmtTime(s, tz)}</button>)}
            {slots.length === 0 && <div className="faint" style={{ fontSize: 12.5 }}>No future slots in that window.</div>}
          </div>
          <div style={{ display: "flex", gap: 8, marginTop: 10, flexWrap: "wrap", alignItems: "center" }}>
            <span className="faint" style={{ fontSize: 12 }}>Can’t do that day?</span>
            <input type="date" value={otherDate} onChange={(e) => setOtherDate(e.target.value)} style={{ padding: "6px 8px", fontSize: 13 }} />
            <button className="btn-ghost btn-sm" disabled={!otherDate} onClick={() => onRequestDate(b.id, otherDate)}>Ask for this day</button>
          </div>
        </div>
      )}

      {waitingMentor && (
        <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--navy-soft)", fontSize: 12.5 }}>
          ⏳ Waiting for {b.mentor_name} to propose times for <b>{b.requested_date}</b>.
        </div>
      )}

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
