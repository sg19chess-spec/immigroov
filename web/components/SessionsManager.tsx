"use client";
import { useCallback, useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { fmtDate, fmtTime } from "@/lib/format";

type S = {
  id: number; status: string; slot_time: string; meeting_url: string | null;
  service_title: string; service_duration: number; mentee_name: string; mentee_email: string;
  mentor_tz: string; mentee_tz: string; mentor_confirmed_at: string | null; reschedule_count: number;
  offer_id: number | null; offer_by: string | null; offer_status: string | null; offer_date: string | null;
  range_start: string | null; range_end: string | null; requested_date: string | null; selected_time: string | null; offer_was_late: boolean | null;
  req_id: number | null; req_kind: string | null; req_initiated_by: string | null; req_status: string | null;
  ledger_summary: string | null;
};

// Wall-clock date+time in tz -> UTC ISO (DST-aware).
function wallToUtcISO(dateStr: string, timeStr: string, tz: string) {
  const [y, m, d] = dateStr.split("-").map(Number);
  const [hh, mm] = timeStr.split(":").map(Number);
  const guess = Date.UTC(y, (m || 1) - 1, d || 1, hh || 0, mm || 0);
  const p = new Intl.DateTimeFormat("en-US", { timeZone: tz, hour12: false, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit" })
    .formatToParts(new Date(guess)).reduce((a: any, x) => { a[x.type] = x.value; return a; }, {});
  const asTz = Date.UTC(+p.year, +p.month - 1, +p.day, +p.hour, +p.minute, +(p.second || 0));
  return new Date(guess - (asTz - guess)).toISOString();
}

const isActive = (st: string) => !["cancelled", "completed", "no_show"].includes(st);

export default function SessionsManager({ mentorId, mentorTz }: { mentorId: number; mentorTz: string }) {
  const supabase = createClient();
  const [rows, setRows] = useState<S[]>([]);
  const [noticeDraft, setNoticeDraft] = useState("24");
  const [msg, setMsg] = useState<string | null>(null);
  const [proposing, setProposing] = useState<number | null>(null);

  const load = useCallback(async () => {
    const [{ data }, { data: m }] = await Promise.all([
      supabase.rpc("mentor_sessions", { p_mentor_id: mentorId }),
      supabase.from("mentors").select("cancel_notice_hours").eq("id", mentorId).single(),
    ]);
    setRows((data || []) as S[]);
    setNoticeDraft(String(m?.cancel_notice_hours ?? 24));
  }, [supabase, mentorId]);
  useEffect(() => { load(); }, [load]);

  async function saveNotice() {
    const h = Math.max(0, parseInt(noticeDraft || "0", 10) || 0);
    const { error } = await supabase.rpc("demo_set_cancel_notice", { p_mentor_id: mentorId, p_hours: h });
    setMsg(error ? error.message : `Cancellation notice set to ${h} hours.`); load();
  }
  async function confirmAttend(id: number) { await supabase.rpc("mentor_confirm_attendance", { p_booking_id: id }); setMsg("Marked as available — see you there!"); load(); }
  async function respond(reqId: number, accept: boolean) {
    const { error } = await supabase.rpc("respond_booking_request", { p_request_id: reqId, p_accept: accept });
    setMsg(error ? error.message : accept ? "Request approved." : "Request rejected."); load();
  }
  async function cancel(id: number) {
    const late = new Date(id && rows.find((r) => r.id === id)!.slot_time).getTime() - Date.now() < 24 * 3600 * 1000;
    if (!confirm(late ? "This is within 24h — cancelling now applies a 25% penalty to your payout. Continue?" : "Cancel this session? The customer is fully refunded.")) return;
    const { error } = await supabase.rpc("cancel_booking", { p_booking_id: id, p_cancelled_by: "mentor" });
    setMsg(error ? error.message : "Session cancelled."); load();
  }
  async function propose(id: number, date: string, start: string, end: string) {
    if (!date || !start || !end) { setMsg("Pick a date, start and end time."); return; }
    const rs = wallToUtcISO(date, start, mentorTz), re = wallToUtcISO(date, end, mentorTz);
    if (new Date(re) <= new Date(rs)) { setMsg("End time must be after start time."); return; }
    const { data, error } = await supabase.rpc("mentor_propose_reschedule", { p_booking_id: id, p_date: date, p_start: rs, p_end: re });
    if (error) { setMsg(error.message); return; }
    setMsg(data === -1 ? "Reschedule limit reached — the booking was auto-cancelled with a full refund." : "Proposed — the customer can now pick a time in your window.");
    setProposing(null); load();
  }

  const now = Date.now();
  const upcoming = rows.filter((b) => isActive(b.status) && new Date(b.slot_time).getTime() >= now).sort((a, b) => +new Date(a.slot_time) - +new Date(b.slot_time));
  const past = rows.filter((b) => !(isActive(b.status) && new Date(b.slot_time).getTime() >= now));

  function manageRow(b: S) {
    const slotMs = new Date(b.slot_time).getTime();
    const pendingCustReq = b.req_id && b.req_status === "pending" && b.req_initiated_by === "customer";
    const waitingMentee = b.offer_id && b.offer_by === "mentor" && b.offer_status === "pending";
    const menteeAskedDate = b.offer_id && b.offer_by === "user" && b.offer_status === "pending";
    const soon = slotMs > now && slotMs - now < 60 * 60 * 1000 && !b.mentor_confirmed_at && !b.offer_id && !pendingCustReq;
    const showActions = !waitingMentee && !menteeAskedDate && !pendingCustReq && proposing !== b.id;
    return (
      <div className="sess-card" key={b.id}>
        <div className="sess-card-head">
          <div className="sess-info">
            <div style={{ fontWeight: 700 }}>{b.service_title} <span className={`pill st-${b.status}`} style={{ marginLeft: 4 }}>{b.status}</span></div>
            <div className="muted" style={{ fontSize: 12.5, marginTop: 2 }}>with {b.mentee_name} · {b.mentee_email}</div>
            <div style={{ fontSize: 13, marginTop: 4 }}><b>{fmtTime(b.slot_time, mentorTz)}</b> · {fmtDate(b.slot_time, mentorTz)}{b.reschedule_count > 0 ? ` · moved ${b.reschedule_count}×` : ""}{b.mentor_confirmed_at ? " · ✓ confirmed" : ""}</div>
          </div>
          {showActions && (
            <div className="sess-actions">
              {b.meeting_url && <a href={b.meeting_url} target="_blank" className="btn-ghost btn-sm">🎥 Join</a>}
              <button className="btn-ghost btn-sm" onClick={() => setProposing(b.id)}>Reschedule</button>
              <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => cancel(b.id)}>Cancel</button>
            </div>
          )}
        </div>

        {pendingCustReq && (
          <div className="banner" style={{ background: "var(--orange-soft)", border: "1px solid var(--orange)", marginTop: 10 }}>
            <b>{b.mentee_name} requested to {b.req_kind === "cancel" ? "cancel" : "reschedule"} this session.</b>
            <div className="muted" style={{ fontSize: 12, marginTop: 2 }}>
              {b.req_kind === "cancel" ? "Approve = full refund. Reject = customer pays 50%." : "Approve so they can pick a new time."} No reply auto-approves.
            </div>
            <div className="actions" style={{ marginTop: 8, gap: 8 }}>
              <button className="btn-cta btn-sm" onClick={() => respond(b.req_id!, true)}>Approve</button>
              <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => respond(b.req_id!, false)}>Reject</button>
            </div>
          </div>
        )}

        {soon && (
          <div className="banner" style={{ background: "var(--orange-soft)", border: "1px solid var(--orange)", marginTop: 10 }}>
            <b>Starting within the hour — are you available?</b>
            <div className="actions" style={{ marginTop: 8, gap: 8 }}>
              <button className="btn-cta btn-sm" onClick={() => confirmAttend(b.id)}>Yes, available</button>
              <button className="btn-ghost btn-sm" onClick={() => setProposing(b.id)}>No, reschedule</button>
            </div>
          </div>
        )}

        {waitingMentee && (
          <div className="banner ok" style={{ marginTop: 10 }}>
            Waiting for {b.mentee_name} to pick a time on <b>{b.offer_date}</b>, between {fmtTime(b.range_start!, mentorTz)}–{fmtTime(b.range_end!, mentorTz)} ({mentorTz}).
            {b.offer_was_late && <span className="muted"> · within 24h → 25% penalty if accepted.</span>}
          </div>
        )}

        {menteeAskedDate && (
          <div className="banner" style={{ background: "var(--navy-soft)", border: "1px solid var(--line)", marginTop: 10 }}>
            <b>{b.mentee_name} asked for a different day: {b.requested_date}.</b> Offer a time range for that day below.
            <ProposeForm tz={mentorTz} defaultDate={b.requested_date || ""} onCancel={() => {}} onSend={(d, s, e) => propose(b.id, d, s, e)} inline />
          </div>
        )}

        {proposing === b.id && !menteeAskedDate && (
          <ProposeForm tz={mentorTz} defaultDate={b.slot_time.slice(0, 10)} onCancel={() => setProposing(null)} onSend={(d, s, e) => propose(b.id, d, s, e)} />
        )}
      </div>
    );
  }

  function pastRow(b: S) {
    return (
      <div className="sess-card past" key={b.id}>
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 700 }}>{b.service_title} <span className={`pill st-${b.status}`} style={{ marginLeft: 4 }}>{b.status}</span></div>
          <div className="muted" style={{ fontSize: 12.5, marginTop: 2 }}>with {b.mentee_name} · {b.mentee_email}</div>
          <div style={{ fontSize: 13, marginTop: 4 }}>{fmtTime(b.slot_time, mentorTz)} · {fmtDate(b.slot_time, mentorTz)} ({mentorTz})</div>
          {b.ledger_summary && <div className="faint" style={{ fontSize: 11.5, marginTop: 4 }}>💸 {b.ledger_summary}</div>}
        </div>
      </div>
    );
  }

  return (
    <div className="card">
      <div className="row-between sess-head" style={{ marginBottom: 6, flexWrap: "wrap", gap: 10 }}>
        <div>
          <h2 className="sec" style={{ fontSize: 18 }}>Your sessions</h2>
          <div className="muted" style={{ fontSize: 12.5 }}>Respond to requests, reschedule, or cancel. Times shown in {mentorTz}.</div>
        </div>
        <div className="sess-notice" style={{ display: "flex", alignItems: "flex-end", gap: 8 }}>
          <div style={{ flex: 1 }}><label className="fld">Cancellation notice (hrs)</label><input type="number" min={0} style={{ width: 110 }} value={noticeDraft} onChange={(e) => setNoticeDraft(e.target.value)} /></div>
          <button className="btn-ghost btn-sm" onClick={saveNotice}>Save</button>
        </div>
      </div>
      {msg && <div className="banner ok">{msg}</div>}

      {upcoming.length > 0 && <h3 style={{ fontSize: 14, color: "var(--muted)", margin: "14px 0 8px" }}>Upcoming ({upcoming.length})</h3>}
      {upcoming.map(manageRow)}
      {past.length > 0 && <h3 style={{ fontSize: 14, color: "var(--muted)", margin: "22px 0 8px" }}>Past &amp; completed ({past.length})</h3>}
      {past.map(pastRow)}
      {rows.length === 0 && <div className="empty" style={{ padding: "32px 10px" }}><div className="ico">📅</div>No sessions yet.</div>}
    </div>
  );
}

function ProposeForm({ tz, defaultDate, onSend, onCancel, inline }: { tz: string; defaultDate: string; onSend: (d: string, s: string, e: string) => void; onCancel: () => void; inline?: boolean }) {
  const [d, setD] = useState(defaultDate);
  const [s, setS] = useState("09:00");
  const [e, setE] = useState("17:00");
  return (
    <div style={inline ? { marginTop: 10 } : { background: "var(--surface-2)", border: "1px solid var(--line)", borderRadius: 12, padding: 12, marginTop: 10 }}>
      {!inline && <div style={{ fontWeight: 700, fontSize: 13, marginBottom: 8 }}>Propose a time range you're free ({tz})</div>}
      <div className="form-grid">
        <div><label className="fld">Date</label><input type="date" style={{ width: "100%" }} value={d} onChange={(ev) => setD(ev.target.value)} /></div>
        <div><label className="fld">From</label><input type="time" style={{ width: "100%" }} value={s} onChange={(ev) => setS(ev.target.value)} /></div>
        <div><label className="fld">To</label><input type="time" style={{ width: "100%" }} value={e} onChange={(ev) => setE(ev.target.value)} /></div>
      </div>
      <div className="actions" style={{ marginTop: 10, gap: 8 }}>
        <button className="btn-cta btn-sm" onClick={() => onSend(d, s, e)}>Send proposal</button>
        {!inline && <button className="btn-ghost btn-sm" onClick={onCancel}>Cancel</button>}
      </div>
    </div>
  );
}
