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
  service_duration: number; mentor_id: number; service_id: number; reschedule_count: number; no_show_by: string | null;
  offer_id: number | null; offer_by: string | null; offer_status: string | null; offer_date: string | null;
  range_start: string | null; range_end: string | null; requested_date: string | null; selected_time: string | null; offer_was_late: boolean | null;
  req_id: number | null; req_kind: string | null; req_initiated_by: string | null; req_status: string | null;
  ledger_summary: string | null;
};

const isLate = (slot: string) => new Date(slot).getTime() - Date.now() < 24 * 3600 * 1000;
function slotsIn(rangeStart: string, rangeEnd: string, durMin: number) {
  const out: string[] = [];
  const end = new Date(rangeEnd).getTime();
  const step = (durMin || 30) * 60000;
  for (let t = new Date(rangeStart).getTime(); t + step <= end; t += step) if (t > Date.now()) out.push(new Date(t).toISOString());
  return out;
}

export default function Bookings() {
  const supabase = createClient();
  const tz = myTz();
  const [rows, setRows] = useState<B[]>([]);
  const [email, setEmail] = useState<string | null | undefined>(undefined);
  const [msg, setMsg] = useState<string | null>(null);

  async function load(e: string) { const { data } = await supabase.rpc("bookings_by_email", { p_email: e }); setRows((data || []) as B[]); }
  useEffect(() => { const e = getEmail(); setEmail(e); if (e) load(e); }, []);
  async function refresh() { if (email) load(email); }

  async function cancel(b: B) {
    const late = isLate(b.slot_time);
    if (!confirm(late
      ? "Within 24h: a cancellation request goes to your mentor (auto-approved if no reply). If they decline, you pay 50%. Continue?"
      : "Cancel this session? You'll be fully refunded.")) return;
    const { error } = await supabase.rpc("cancel_booking", { p_booking_id: b.id, p_cancelled_by: "user" });
    setMsg(error ? error.message : late ? "Cancellation request sent to your mentor." : "Cancelled — full refund recorded."); refresh();
  }
  async function accept(offerId: number, slotISO: string) {
    const { error } = await supabase.rpc("mentee_accept_reschedule", { p_offer_id: offerId, p_slot_time: slotISO });
    setMsg(error ? error.message : "Rescheduled — your new time is confirmed."); refresh();
  }
  async function reject(offerId: number) {
    if (!confirm("Reject this proposed time? The session will be cancelled and you'll get a credit (or a refund if the mentor proposed late).")) return;
    const { error } = await supabase.rpc("mentee_reject_reschedule", { p_offer_id: offerId });
    setMsg(error ? error.message : "Proposal rejected — credit/refund recorded."); refresh();
  }
  async function requestDate(bookingId: number, date: string) {
    if (!date) return;
    const { error } = await supabase.rpc("mentee_request_other_date", { p_booking_id: bookingId, p_date: date });
    setMsg(error ? error.message : "Asked your mentor to propose times for that day."); refresh();
  }
  async function customerReschedule(bookingId: number, slot: string) {
    const { data, error } = await supabase.rpc("customer_reschedule", { p_booking_id: bookingId, p_slot_time: slot });
    setMsg(error ? error.message : data === "autocancelled" ? "Reschedule limit reached — booking auto-cancelled with a full refund." : "Rescheduled — your new time is confirmed."); refresh();
  }
  async function requestReschedule(bookingId: number) {
    const { data, error } = await supabase.rpc("request_reschedule", { p_booking_id: bookingId });
    setMsg(error ? error.message : data === -1 ? "Reschedule limit reached — booking auto-cancelled with a full refund." : "Reschedule request sent to your mentor."); refresh();
  }
  async function flagNoShow(id: number) {
    if (!confirm("Report that your mentor didn't show up? You can only do this after the start time.")) return;
    const { error } = await supabase.rpc("flag_no_show", { p_booking_id: id, p_no_show_party: "mentor" });
    setMsg(error ? error.message : "Reported — choose how you'd like to proceed."); refresh();
  }
  async function resolveMentorNoShow(id: number, choice: string) {
    const { error } = await supabase.rpc("resolve_mentor_no_show", { p_booking_id: id, p_choice: choice });
    setMsg(error ? error.message : choice === "rebook_same" ? "Rebooked — use Reschedule to pick a new time." : choice === "refund" ? "Full refund recorded." : "Credit recorded — find another mentor."); refresh();
  }

  const now = Date.now();
  const upcoming = rows.filter((b) => new Date(b.slot_time).getTime() >= now && !["cancelled", "completed", "no_show"].includes(b.status));
  const past = rows.filter((b) => !upcoming.includes(b));
  const h = { cancel, accept, reject, requestDate, customerReschedule, requestReschedule, flagNoShow, resolveMentorNoShow };

  return (
    <div className="container">
      <div className="section-head"><h2 className="sec">Your sessions</h2></div>
      {msg && <div className="banner ok" style={{ marginBottom: 14 }}>{msg}</div>}

      {email === null && <div className="empty"><div className="ico">🔑</div>Sign in with your email to see your sessions.<br /><Link href="/login" className="btn btn-cta" style={{ marginTop: 14 }}>Sign in</Link></div>}
      {email && rows.length === 0 && <div className="empty"><div className="ico">📅</div>No bookings under {email} yet.<br /><Link href="/" className="btn btn-cta" style={{ marginTop: 14 }}>Find a mentor</Link></div>}

      {upcoming.length > 0 && <h3 style={{ fontSize: 15, color: "var(--muted)", margin: "8px 0 14px" }}>Upcoming</h3>}
      <div className="grid">{upcoming.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} h={h} />)}</div>
      {past.length > 0 && <h3 style={{ fontSize: 15, color: "var(--muted)", margin: "30px 0 14px" }}>Past &amp; cancelled</h3>}
      <div className="grid">{past.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} h={h} dim />)}</div>
    </div>
  );
}

type Handlers = {
  cancel: (b: B) => void; accept: (o: number, s: string) => void; reject: (o: number) => void;
  requestDate: (id: number, d: string) => void; customerReschedule: (id: number, s: string) => void; requestReschedule: (id: number) => void;
  flagNoShow: (id: number) => void; resolveMentorNoShow: (id: number, choice: string) => void;
};

function Card({ b, tz, i, h, dim }: { b: B; tz: string; i: number; h: Handlers; dim?: boolean }) {
  const [otherDate, setOtherDate] = useState("");
  const [picking, setPicking] = useState(false);
  const active = !["cancelled", "completed", "no_show"].includes(b.status);
  const mentorOffer = active && b.offer_id && b.offer_by === "mentor" && b.offer_status === "pending" && b.range_start && b.range_end;
  const waitingMentor = active && b.offer_id && b.offer_by === "user" && b.offer_status === "pending";
  const cancelReq = active && b.req_id && b.req_kind === "cancel" && b.req_status === "pending";
  const rsReqPending = active && b.req_id && b.req_kind === "reschedule" && b.req_status === "pending";
  const rsReqApproved = active && b.req_id && b.req_kind === "reschedule" && (b.req_status === "approved" || b.req_status === "auto_approved");
  const rsReqRejected = active && b.req_id && b.req_kind === "reschedule" && b.req_status === "rejected";
  const slots = mentorOffer ? slotsIn(b.range_start!, b.range_end!, b.service_duration) : [];
  const busy = mentorOffer || waitingMentor || cancelReq || rsReqPending;
  const slotPassed = Date.now() > new Date(b.slot_time).getTime() + 10 * 60000;
  const canReport = (b.status === "confirmed" || b.status === "rescheduled") && slotPassed;
  const mentorNoShowOpen = b.status === "no_show" && b.no_show_by === "mentor" && !b.ledger_summary;
  const customerNoShow = b.status === "no_show" && b.no_show_by === "customer";

  function startReschedule() {
    if (isLate(b.slot_time) && !rsReqApproved) h.requestReschedule(b.id);
    else setPicking(true);
  }

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
        <div className="faint" style={{ fontSize: 12, marginTop: 4 }}>Mentor: {fmtTime(b.slot_time, b.mentor_tz)} ({b.mentor_tz}){b.reschedule_count > 0 ? ` · moved ${b.reschedule_count}×` : ""}</div>
      </div>

      {mentorOffer && (
        <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--orange-soft)" }}>
          <div style={{ fontWeight: 700, fontSize: 13.5 }}>📅 Your mentor proposed a new time</div>
          <div className="muted" style={{ fontSize: 12.5, margin: "2px 0 8px" }}>{fmtDate(b.range_start!, tz)} · pick a slot ({tz}):</div>
          <div className="slotgrid">
            {slots.map((s) => (
              <button key={s} className="slot" style={{ height: "auto", padding: "6px 4px", lineHeight: 1.25 }} onClick={() => h.accept(b.offer_id!, s)}>
                <div style={{ fontWeight: 700 }}>{fmtTime(s, tz)}</div>
                <div style={{ fontSize: 10, opacity: 0.7 }}>mentor {fmtTime(s, b.mentor_tz)}</div>
              </button>
            ))}
            {slots.length === 0 && <div className="faint" style={{ fontSize: 12.5 }}>No future slots in that window.</div>}
          </div>
          <div style={{ display: "flex", gap: 8, marginTop: 10, flexWrap: "wrap", alignItems: "center" }}>
            <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => h.reject(b.offer_id!)}>Reject (get credit)</button>
            <span className="faint" style={{ fontSize: 12 }}>· or another day:</span>
            <input type="date" value={otherDate} onChange={(e) => setOtherDate(e.target.value)} style={{ padding: "6px 8px", fontSize: 13 }} />
            <button className="btn-ghost btn-sm" disabled={!otherDate} onClick={() => h.requestDate(b.id, otherDate)}>Ask</button>
          </div>
        </div>
      )}

      {waitingMentor && <Note>⏳ Waiting for {b.mentor_name} to propose times for <b>{b.requested_date}</b>.</Note>}
      {cancelReq && <Note>⏳ Cancellation requested — awaiting your mentor (auto-approved if no reply).</Note>}
      {rsReqPending && <Note>⏳ Reschedule requested — awaiting your mentor's approval.</Note>}
      {rsReqRejected && <Note>Your mentor declined the reschedule. You can keep this session, or cancel it below.</Note>}
      {rsReqApproved && !picking && (
        <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--orange-soft)", fontSize: 12.5 }}>
          ✅ Approved — <button className="btn-cta btn-sm" style={{ marginLeft: 6 }} onClick={() => setPicking(true)}>Pick a new time</button>
        </div>
      )}

      {mentorNoShowOpen && (
        <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--orange-soft)" }}>
          <div style={{ fontWeight: 700, fontSize: 13.5 }}>Your mentor didn't show — what next?</div>
          <div className="actions" style={{ marginTop: 8, gap: 8, flexWrap: "wrap" }}>
            <button className="btn-cta btn-sm" onClick={() => h.resolveMentorNoShow(b.id, "rebook_same")}>Rebook same mentor</button>
            <button className="btn-ghost btn-sm" onClick={() => h.resolveMentorNoShow(b.id, "rebook_different")}>Rebook a different mentor</button>
            <button className="btn-ghost btn-sm" onClick={() => h.resolveMentorNoShow(b.id, "refund")}>Full refund</button>
          </div>
        </div>
      )}
      {customerNoShow && <Note>You were marked as a no-show. Your mentor will decide whether to rebook or close the session.</Note>}

      {picking && <RescheduleSlots b={b} tz={tz} onPick={(s) => { setPicking(false); h.customerReschedule(b.id, s); }} onClose={() => setPicking(false)} />}

      <div style={{ display: "flex", justifyContent: "space-between", padding: "12px 20px", borderTop: "1px solid var(--line)", fontSize: 12, background: "var(--surface-2)" }}>
        <div><div className="faint">You paid</div><b>{b.cost != null ? money(b.cost, b.cost_currency) : "—"}</b></div>
        <div style={{ textAlign: "right" }}><div className="faint">Mentor earns</div><b style={{ color: "var(--orange-d)" }}>{b.mentor_earn != null ? money(b.mentor_earn, b.mentor_currency) : "—"}</b></div>
      </div>
      {b.ledger_summary && <div className="faint" style={{ fontSize: 11.5, padding: "8px 20px", background: "var(--surface-2)" }}>💸 {b.ledger_summary}</div>}

      <div style={{ display: "flex", gap: 10, padding: 16, borderTop: "1px solid var(--line)", flexWrap: "wrap" }}>
        {b.meeting_url && active && !canReport && <a href={b.meeting_url} target="_blank" className="btn btn-cta" style={{ flex: 1, minWidth: 130 }}>🎥 Join video call</a>}
        {active && !busy && !picking && !canReport && <button className="btn-ghost" onClick={startReschedule}>Reschedule</button>}
        {active && !busy && !canReport && <button className="btn-ghost" onClick={() => h.cancel(b)}>Cancel</button>}
        {canReport && !busy && <button className="btn-ghost" style={{ color: "var(--bad)" }} onClick={() => h.flagNoShow(b.id)}>Mentor didn't show</button>}
        {!active && !mentorNoShowOpen && !customerNoShow && !b.ledger_summary && <span className="faint" style={{ fontSize: 13, padding: "6px 0" }}>No actions available</span>}
      </div>
    </div>
  );
}

function Note({ children }: { children: React.ReactNode }) {
  return <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--navy-soft)", fontSize: 12.5 }}>{children}</div>;
}

function RescheduleSlots({ b, tz, onPick, onClose }: { b: B; tz: string; onPick: (slot: string) => void; onClose: () => void }) {
  const supabase = createClient();
  const [slots, setSlots] = useState<{ slot_start: string }[]>([]);
  const [date, setDate] = useState<string>("");
  const [loading, setLoading] = useState(true);
  useEffect(() => {
    (async () => {
      const from = new Date().toISOString().slice(0, 10);
      const to = new Date(Date.now() + 60 * 864e5).toISOString().slice(0, 10);
      const { data } = await supabase.rpc("get_available_slots", { p_mentor_id: b.mentor_id, p_service_id: b.service_id, p_from: from, p_to: to });
      setSlots((data || []) as { slot_start: string }[]); setLoading(false);
    })();
  }, [b.mentor_id, b.service_id, supabase]);
  const dk = (iso: string) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
  const dates = Array.from(new Set(slots.map((s) => dk(s.slot_start))));
  const day = date ? slots.filter((s) => dk(s.slot_start) === date) : [];
  return (
    <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--surface-2)" }}>
      <div style={{ fontWeight: 700, fontSize: 13.5, marginBottom: 8 }}>Pick a new time ({tz})</div>
      {loading ? <div className="faint" style={{ fontSize: 12.5 }}>Loading openings…</div>
        : dates.length === 0 ? <div className="faint" style={{ fontSize: 12.5 }}>No openings in the next 60 days.</div>
          : <>
            <select value={date} onChange={(e) => setDate(e.target.value)} style={{ padding: "6px 8px", fontSize: 13, marginBottom: 8 }}>
              <option value="">Select a date…</option>
              {dates.map((d) => <option key={d} value={d}>{fmtDate(d + "T12:00:00", tz)}</option>)}
            </select>
            {date && <div className="slotgrid">{day.map((s) => (
              <button key={s.slot_start} className="slot" style={{ height: "auto", padding: "6px 4px", lineHeight: 1.25 }} onClick={() => onPick(s.slot_start)}>
                <div style={{ fontWeight: 700 }}>{fmtTime(s.slot_start, tz)}</div>
                <div style={{ fontSize: 10, opacity: 0.7 }}>mentor {fmtTime(s.slot_start, b.mentor_tz)}</div>
              </button>
            ))}</div>}
          </>}
      <button className="btn-ghost btn-sm" style={{ marginTop: 8 }} onClick={onClose}>Close</button>
    </div>
  );
}
