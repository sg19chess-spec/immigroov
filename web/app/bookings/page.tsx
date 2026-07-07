"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, myTz, fmtTime, fmtDate } from "@/lib/format";
import { getEmail } from "@/lib/identity";
import ChatThread from "@/components/ChatThread";

type B = {
  id: number; status: string; slot_time: string; meeting_url: string | null;
  service_title: string; mentor_name: string; mentor_tz: string; customer_tz: string;
  cost: number; cost_currency: string; mentor_earn: number; mentor_currency: string;
  service_duration: number; mentor_id: number; service_id: number; reschedule_count: number; no_show_by: string | null;
  offer_id: number | null; offer_by: string | null; offer_status: string | null; offer_date: string | null;
  range_start: string | null; range_end: string | null; requested_date: string | null; selected_time: string | null; offer_was_late: boolean | null;
  req_id: number | null; req_kind: string | null; req_initiated_by: string | null; req_status: string | null;
  ledger_summary: string | null; customer_join_token: string | null;
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
      <div className="sessions-wrap">
        <div className="section-head"><div><h2 className="sec">Your sessions</h2><div className="lead">Manage your upcoming and past mentoring sessions.</div></div></div>
        {msg && <div className="banner ok" style={{ marginBottom: 14 }}>{msg}</div>}

        {email === null && <div className="empty"><div className="ico">🔑</div>Sign in with your email to see your sessions.<br /><Link href="/login" className="btn btn-cta" style={{ marginTop: 14 }}>Sign in</Link></div>}
        {email && rows.length === 0 && <div className="empty"><div className="ico">📅</div>No bookings under {email} yet.<br /><Link href="/" className="btn btn-cta" style={{ marginTop: 14 }}>Find a mentor</Link></div>}

        {upcoming.length > 0 && <div className="sess-group-h">Upcoming <span className="cnt">{upcoming.length}</span></div>}
        <div className="sess-list">{upcoming.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} h={h} email={email || ""} />)}</div>
        {past.length > 0 && <div className="sess-group-h" style={{ marginTop: 34 }}>Past &amp; cancelled <span className="cnt">{past.length}</span></div>}
        <div className="sess-list">{past.map((b, i) => <Card key={b.id} b={b} tz={tz} i={i} h={h} email={email || ""} dim />)}</div>
      </div>
    </div>
  );
}

const monBadge = (iso: string, tz: string) => new Intl.DateTimeFormat("en", { timeZone: tz, month: "short" }).format(new Date(iso)).toUpperCase();
const dayBadge = (iso: string, tz: string) => new Intl.DateTimeFormat("en", { timeZone: tz, day: "numeric" }).format(new Date(iso));

type Handlers = {
  cancel: (b: B) => void; accept: (o: number, s: string) => void; reject: (o: number) => void;
  requestDate: (id: number, d: string) => void; customerReschedule: (id: number, s: string) => void; requestReschedule: (id: number) => void;
  flagNoShow: (id: number) => void; resolveMentorNoShow: (id: number, choice: string) => void;
};

function Card({ b, tz, i, h, email, dim }: { b: B; tz: string; i: number; h: Handlers; email: string; dim?: boolean }) {
  const [otherDate, setOtherDate] = useState("");
  const [picking, setPicking] = useState(false);
  const [chatOpen, setChatOpen] = useState(false);
  const [acceptSlot, setAcceptSlot] = useState<string | null>(null);
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
      <div style={{ display: "flex", gap: 14, padding: "16px 18px" }}>
        <div className="sess-date"><div className="m">{monBadge(b.slot_time, tz)}</div><div className="d">{dayBadge(b.slot_time, tz)}</div></div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: "flex", justifyContent: "space-between", gap: 8, alignItems: "flex-start" }}>
            <div style={{ minWidth: 0 }}>
              <div style={{ fontWeight: 800, fontSize: 16 }}>{b.service_title}</div>
              <div className="muted" style={{ fontSize: 13 }}>with {b.mentor_name}</div>
            </div>
            <span className={`pill st-${b.status}`}>{b.status.replace("_", "-")}</span>
          </div>
          <div style={{ marginTop: 9 }}>
            <span style={{ fontSize: 18, fontWeight: 800, letterSpacing: "-.02em" }}>{fmtTime(b.slot_time, tz)}</span>
            <span className="muted" style={{ fontSize: 13 }}> · {fmtDate(b.slot_time, tz)}</span>
          </div>
          <div className="faint" style={{ fontSize: 12, marginTop: 3 }}>Your time ({tz}) · mentor {fmtTime(b.slot_time, b.mentor_tz)} ({b.mentor_tz}){b.reschedule_count > 0 ? ` · moved ${b.reschedule_count}×` : ""}</div>
        </div>
      </div>

      {mentorOffer && (
        <div style={{ padding: "12px 20px", borderTop: "1px solid var(--line)", background: "var(--orange-soft)" }}>
          <div style={{ fontWeight: 700, fontSize: 13.5 }}>📅 Your mentor proposed a new time</div>
          <div className="muted" style={{ fontSize: 12.5, margin: "2px 0 8px" }}>{fmtDate(b.range_start!, tz)} · pick a slot ({tz}):</div>
          <div className="slotgrid">
            {slots.map((s) => (
              <button key={s} className={`slot ${acceptSlot === s ? "sel" : ""}`} style={{ height: "auto", padding: "6px 4px", lineHeight: 1.25 }} onClick={() => setAcceptSlot(s)}>
                <div style={{ fontWeight: 700 }}>{fmtTime(s, tz)}</div>
                <div style={{ fontSize: 10, opacity: 0.7 }}>mentor {fmtTime(s, b.mentor_tz)}</div>
              </button>
            ))}
            {slots.length === 0 && <div className="faint" style={{ fontSize: 12.5 }}>No future slots in that window.</div>}
          </div>
          {acceptSlot && (
            <div style={{ marginTop: 10, padding: "10px 12px", background: "#fff", border: "1px solid var(--orange)", borderRadius: 10 }}>
              <div style={{ fontSize: 13 }}>Confirm new time: <b>{fmtDate(acceptSlot, tz)} · {fmtTime(acceptSlot, tz)}</b> <span className="faint">({tz})</span></div>
              <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
                <button className="btn btn-cta btn-sm" onClick={() => h.accept(b.offer_id!, acceptSlot)}>Confirm</button>
                <button className="btn-ghost btn-sm" onClick={() => setAcceptSlot(null)}>Back</button>
              </div>
            </div>
          )}
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

      <div className="sess-meta">
        <span><span className="faint">You paid </span><b>{b.cost != null ? money(b.cost, b.cost_currency) : "—"}</b></span>
        <span className="faint">Booking #{b.id}{b.service_duration ? ` · ${b.service_duration} min` : ""}</span>
      </div>
      {b.ledger_summary && <div className="faint" style={{ fontSize: 11.5, padding: "8px 18px", background: "var(--surface-2)" }}>💸 {b.ledger_summary}</div>}

      <div className="sess-foot">
        {b.customer_join_token && active && !canReport && <a href={`/join/${b.customer_join_token}`} target="_blank" className="btn btn-cta">🎥 Join video call</a>}
        <div className="sess-btn-row">
          {active && !busy && !picking && !canReport && <button className="btn-ghost btn-sm" onClick={startReschedule}>↻ Reschedule</button>}
          {email && <button className="btn-ghost btn-sm" onClick={() => setChatOpen((v) => !v)}>{chatOpen ? "Hide chat" : "💬 Message mentor"}</button>}
          {active && !busy && !canReport && <button className="btn-ghost btn-sm" style={{ color: "var(--bad)", marginLeft: "auto" }} onClick={() => h.cancel(b)}>Cancel</button>}
        </div>
        {canReport && !busy && <button className="btn-ghost btn-sm" style={{ color: "var(--bad)", width: "100%" }} onClick={() => h.flagNoShow(b.id)}>⚠ Report: mentor didn't show up</button>}
        {!active && !mentorNoShowOpen && !customerNoShow && !b.ledger_summary && <span className="faint" style={{ fontSize: 12.5 }}>This session is closed — no actions available.</span>}
      </div>
      {chatOpen && email && <div style={{ padding: "0 16px 16px" }}><ChatThread bookingId={b.id} email={email} /></div>}
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
  const [chosen, setChosen] = useState<string | null>(null);
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
            <select value={date} onChange={(e) => { setDate(e.target.value); setChosen(null); }} style={{ padding: "6px 8px", fontSize: 13, marginBottom: 8 }}>
              <option value="">Select a date…</option>
              {dates.map((d) => <option key={d} value={d}>{fmtDate(d + "T12:00:00", tz)}</option>)}
            </select>
            {date && <div className="slotgrid">{day.map((s) => (
              <button key={s.slot_start} className={`slot ${chosen === s.slot_start ? "sel" : ""}`} style={{ height: "auto", padding: "6px 4px", lineHeight: 1.25 }} onClick={() => setChosen(s.slot_start)}>
                <div style={{ fontWeight: 700 }}>{fmtTime(s.slot_start, tz)}</div>
                <div style={{ fontSize: 10, opacity: 0.7 }}>mentor {fmtTime(s.slot_start, b.mentor_tz)}</div>
              </button>
            ))}</div>}
          </>}
      {chosen ? (
        <div style={{ marginTop: 12, padding: "10px 12px", background: "var(--orange-soft)", border: "1px solid var(--orange)", borderRadius: 10 }}>
          <div style={{ fontSize: 13 }}>Move this session to <b>{fmtDate(chosen, tz)} · {fmtTime(chosen, tz)}</b> <span className="faint">({tz})</span>?</div>
          <div style={{ display: "flex", gap: 8, marginTop: 10 }}>
            <button className="btn btn-cta btn-sm" onClick={() => onPick(chosen)}>Confirm reschedule</button>
            <button className="btn-ghost btn-sm" onClick={() => setChosen(null)}>Back</button>
          </div>
        </div>
      ) : (
        <button className="btn-ghost btn-sm" style={{ marginTop: 8 }} onClick={onClose}>Close</button>
      )}
    </div>
  );
}
