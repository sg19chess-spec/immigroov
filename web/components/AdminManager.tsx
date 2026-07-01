"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

type Booking = {
  id: number; created_at: string; status: string; slot_time: string;
  service_title: string; mentor_name: string; mentor_email: string; mentee_email: string; target_country: string | null;
  cost: number | null; cost_currency: string | null; mentor_payout: number | null;
  reschedule_count: number; no_show_by: string | null; ledger_summary: string | null;
};
type Payout = {
  booking_id: number; created_at: string; status: string; slot_time: string;
  service_title: string; mentor_name: string; mentee_email: string;
  gross: number | null; currency: string | null; fee_pct: number | null;
  deduction: number | null; net_payout: number | null;
  mentor_net: number | null; mentor_currency: string | null; fx_rate: number | null; ppp: number | null;
  method: string | null; payout_status: string;
};
type Ledger = {
  id: number; created_at: string; booking_id: number; party: string; kind: string; pct: number | null;
  amount: number | null; currency: string | null; normalized_inr: number | null; reason: string;
  service_title: string; mentor_name: string; mentee_email: string; booking_status: string;
};

const fmt = (s: string | null) => (s ? new Date(s).toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) : "—");
const fmtZ = (s: string | null, tz?: string) => {
  if (!s) return "—";
  try { return new Date(s).toLocaleString([], { dateStyle: "medium", timeStyle: "short", timeZone: tz || undefined }); }
  catch { return fmt(s); }
};
const money = (a: number | null, c: string | null) => (a == null ? "—" : `${Number(a).toFixed(2)} ${c || ""}`.trim());
const kindColor: Record<string, string> = { refund: "#0f7a44", credit: "#534ab7", charge: "#a32020", penalty: "#a32020" };

type Webinar = {
  id: number; title: string; mentor_name: string; start_time: string; duration: number;
  capacity: number | null; visibility: string; status: string; registrations: number;
};

// Admin overview — cross-mentor activity, ledger, payouts and webinars. Read-only.
// Backed by admin_bookings/ledger/payouts/webinars + webinar_registrants (SECURITY DEFINER; gate for prod).
export default function AdminManager() {
  const supabase = createClient();
  const [bookings, setBookings] = useState<Booking[]>([]);
  const [ledger, setLedger] = useState<Ledger[]>([]);
  const [payouts, setPayouts] = useState<Payout[]>([]);
  const [webinars, setWebinars] = useState<Webinar[]>([]);
  const [view, setView] = useState<"activity" | "payouts" | "ledger" | "webinars">("activity");
  const [loading, setLoading] = useState(true);
  const [detail, setDetail] = useState<any | null>(null);
  const [detailId, setDetailId] = useState<number | null>(null);
  const [regs, setRegs] = useState<{ title: string; rows: any[] } | null>(null);
  const [f, setF] = useState({ mentor: "", custEmail: "", mentorEmail: "", from: "", to: "", status: "", country: "" });
  const [feeDraft, setFeeDraft] = useState("");
  const [feeMsg, setFeeMsg] = useState<string | null>(null);

  async function saveFee() {
    const v = String(Math.max(0, Math.min(100, parseFloat(feeDraft || "0") || 0)));
    const { error } = await supabase.rpc("admin_set_setting", { p_key: "immigroov_commission_pct", p_value: v });
    setFeeMsg(error ? error.message : `Default commission set to ${v}% (applies to new bookings).`);
    load();
  }

  async function openDetail(id: number) {
    setDetailId(id); setDetail(null);
    const { data } = await supabase.rpc("admin_booking_detail", { p_booking_id: id });
    setDetail(data || {});
  }
  async function markPaid(bookingId: number) {
    const ref = window.prompt("Payout reference (transfer id / UTR / note):", "");
    if (ref === null) return;
    const { error } = await supabase.rpc("mark_payout_paid", { p_booking_id: bookingId, p_reference: ref || null });
    if (error) window.alert(error.message); else load();
  }
  async function openRegs(w: Webinar) {
    setRegs({ title: w.title, rows: [] });
    const { data } = await supabase.rpc("webinar_registrants", { p_webinar_id: w.id });
    setRegs({ title: w.title, rows: (data as any[]) || [] });
  }

  const load = useCallback(async () => {
    setLoading(true);
    const [{ data: b }, { data: l }, { data: p }, { data: w }, { data: st }] = await Promise.all([
      supabase.rpc("admin_bookings"),
      supabase.rpc("admin_ledger"),
      supabase.rpc("admin_payouts"),
      supabase.rpc("admin_webinars"),
      supabase.rpc("admin_get_settings"),
    ]);
    setBookings((b as Booking[]) || []);
    setLedger((l as Ledger[]) || []);
    setPayouts((p as Payout[]) || []);
    setWebinars((w as Webinar[]) || []);
    const s0 = (st as any[])?.[0];
    if (s0 && !feeDraft) setFeeDraft(String(s0.commission_pct ?? ""));
    setLoading(false);
  }, [supabase]);
  useEffect(() => { load(); }, [load]);

  const by = (s: string) => bookings.filter((x) => x.status === s).length;
  // Money totals are normalized to INR (mixed-currency-safe).
  const sum = (k: string) => ledger.filter((x) => x.kind === k).reduce((a, x) => a + Number(x.normalized_inr || 0), 0);
  const cur = "INR";

  const statuses = ["confirmed", "rescheduled", "completed", "cancelled", "no_show"];
  const countries = Array.from(new Set(bookings.map((b) => b.target_country).filter(Boolean))) as string[];
  const inRange = (iso: string) =>
    (!f.from || new Date(iso) >= new Date(f.from)) && (!f.to || new Date(iso) <= new Date(f.to + "T23:59:59"));
  const has = (hay: string | null, needle: string) => !needle || (hay || "").toLowerCase().includes(needle.toLowerCase());
  const fBookings = bookings.filter((b) =>
    has(b.mentor_name, f.mentor) && has(b.mentor_email, f.mentorEmail) && has(b.mentee_email, f.custEmail) &&
    (!f.status || b.status === f.status) && (!f.country || (b.target_country || "") === f.country) && inRange(b.created_at));
  const fPayouts = payouts.filter((p) =>
    has(p.mentor_name, f.mentor) && has(p.mentee_email, f.custEmail) &&
    (!f.status || p.status === f.status) && inRange(p.created_at));
  const anyFilter = Object.values(f).some(Boolean);

  const th: React.CSSProperties = { textAlign: "left", padding: "9px 12px", fontSize: 11.5, textTransform: "uppercase", letterSpacing: ".04em", color: "var(--muted)", borderBottom: "1px solid var(--line)", whiteSpace: "nowrap" };
  const td: React.CSSProperties = { padding: "9px 12px", fontSize: 13, borderBottom: "1px solid var(--line)", verticalAlign: "top" };
  const fi: React.CSSProperties = { padding: "6px 9px", fontSize: 12.5, border: "1px solid var(--line)", borderRadius: 8, background: "var(--surface)", color: "inherit" };

  return (
    <div>
      <div className="stats" style={{ marginBottom: 18 }}>
        <div className="stat"><div className="n">{bookings.length}</div><div className="l">Total bookings</div></div>
        <div className="stat"><div className="n" style={{ color: "var(--ok)" }}>{by("confirmed") + by("rescheduled")}</div><div className="l">Active (confirmed / resch.)</div></div>
        <div className="stat"><div className="n" style={{ color: "#a32020" }}>{by("cancelled") + by("no_show")}</div><div className="l">Cancelled / no-show</div></div>
        <div className="stat"><div className="n" style={{ color: "#0f7a44" }}>{sum("refund").toFixed(0)}</div><div className="l">Refunds ({cur})</div></div>
        <div className="stat"><div className="n" style={{ color: "#534ab7" }}>{sum("credit").toFixed(0)}</div><div className="l">Credits ({cur})</div></div>
        <div className="stat"><div className="n" style={{ color: "#a32020" }}>{(sum("charge") + sum("penalty")).toFixed(0)}</div><div className="l">Charges + penalties ({cur})</div></div>
      </div>

      <div className="card" style={{ padding: "12px 16px", marginBottom: 16, display: "flex", alignItems: "center", gap: 12, flexWrap: "wrap" }}>
        <div style={{ fontWeight: 700, fontSize: 13.5 }}>Platform commission</div>
        <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
          <input type="number" min={0} max={100} step={0.5} value={feeDraft} onChange={(e) => { setFeeDraft(e.target.value); setFeeMsg(null); }} style={{ width: 90, padding: "7px 10px" }} />
          <span className="muted" style={{ fontSize: 13 }}>%</span>
        </div>
        <button className="btn-cta btn-sm" onClick={saveFee}>Save</button>
        <span className="faint" style={{ fontSize: 12 }}>Default fee on customer gross. Per-service overrides still win. Applies to new bookings.</span>
        {feeMsg && <span style={{ fontSize: 12.5, color: "var(--ok)", width: "100%" }}>{feeMsg}</span>}
      </div>

      <div className="seg" style={{ marginBottom: 16 }}>
        <button className={view === "activity" ? "on" : ""} onClick={() => setView("activity")}>Activity ({bookings.length})</button>
        <button className={view === "payouts" ? "on" : ""} onClick={() => setView("payouts")}>Payouts ({payouts.length})</button>
        <button className={view === "ledger" ? "on" : ""} onClick={() => setView("ledger")}>Ledger ({ledger.length})</button>
        <button className={view === "webinars" ? "on" : ""} onClick={() => setView("webinars")}>Webinars ({webinars.length})</button>
      </div>

      {(view === "activity" || view === "payouts") && (
        <div style={{ display: "flex", flexWrap: "wrap", gap: 8, marginBottom: 14, alignItems: "center" }}>
          <input placeholder="Mentor name" value={f.mentor} onChange={(e) => setF({ ...f, mentor: e.target.value })} style={fi} />
          <input placeholder="Customer email" value={f.custEmail} onChange={(e) => setF({ ...f, custEmail: e.target.value })} style={fi} />
          {view === "activity" && <input placeholder="Mentor email" value={f.mentorEmail} onChange={(e) => setF({ ...f, mentorEmail: e.target.value })} style={fi} />}
          <select value={f.status} onChange={(e) => setF({ ...f, status: e.target.value })} style={fi}>
            <option value="">Any status</option>
            {statuses.map((s) => <option key={s} value={s}>{s}</option>)}
          </select>
          {view === "activity" && (
            <select value={f.country} onChange={(e) => setF({ ...f, country: e.target.value })} style={fi}>
              <option value="">Any country</option>
              {countries.map((c) => <option key={c} value={c}>{c}</option>)}
            </select>
          )}
          <label style={{ fontSize: 12, color: "var(--muted)" }}>From <input type="date" value={f.from} onChange={(e) => setF({ ...f, from: e.target.value })} style={fi} /></label>
          <label style={{ fontSize: 12, color: "var(--muted)" }}>To <input type="date" value={f.to} onChange={(e) => setF({ ...f, to: e.target.value })} style={fi} /></label>
          {anyFilter && <button className="btn-ghost btn-sm" onClick={() => setF({ mentor: "", custEmail: "", mentorEmail: "", from: "", to: "", status: "", country: "" })}>Clear</button>}
        </div>
      )}

      {loading && <div className="empty">Loading…</div>}

      {!loading && view === "activity" && (
        fBookings.length === 0 ? <div className="empty">{bookings.length ? "No bookings match these filters." : "No bookings yet."}</div> :
        <div style={{ overflowX: "auto", border: "1px solid var(--line)", borderRadius: "var(--r-md)" }}>
          <table className="adm-table" style={{ width: "100%", borderCollapse: "collapse", minWidth: 940 }}>
            <thead><tr>
              <th style={th}>Booked</th><th style={th}>Status</th><th style={th}>Service</th><th style={th}>Mentor</th>
              <th style={th}>Mentee</th><th style={th}>Country</th><th style={th}>Session</th><th style={th}>Paid</th><th style={th}>Resch.</th><th style={th}>Ledger</th>
            </tr></thead>
            <tbody>
              {fBookings.map((b) => (
                <tr key={b.id} onClick={() => openDetail(b.id)} style={{ cursor: "pointer" }}>
                  <td style={td}>{fmt(b.created_at)}</td>
                  <td style={td}><span className={`pill st-${b.status}`}>{b.status}{b.no_show_by ? ` · ${b.no_show_by}` : ""}</span></td>
                  <td style={td}>{b.service_title}</td>
                  <td style={td}>{b.mentor_name}</td>
                  <td style={td}>{b.mentee_email}</td>
                  <td style={td}>{b.target_country || "—"}</td>
                  <td style={td}>{fmt(b.slot_time)}</td>
                  <td style={td}>{money(b.cost, b.cost_currency)}</td>
                  <td style={td}>{b.reschedule_count}</td>
                  <td style={{ ...td, color: "var(--muted)", fontSize: 12 }}>{b.ledger_summary || "—"}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {!loading && view === "payouts" && (
        fPayouts.length === 0 ? <div className="empty">{payouts.length ? "No payouts match these filters." : "No payable sessions yet."}</div> :
        <div style={{ overflowX: "auto", border: "1px solid var(--line)", borderRadius: "var(--r-md)" }}>
          <table className="adm-table" style={{ width: "100%", borderCollapse: "collapse", minWidth: 900 }}>
            <thead><tr>
              <th style={th}>Booked</th><th style={th}>Status</th><th style={th}>Mentor</th><th style={th}>Service</th>
              <th style={th}>Gross</th><th style={th}>Fee %</th><th style={th}>Deduction</th><th style={th}>Net (cust. ccy)</th>
              <th style={th}>Net (mentor ccy)</th><th style={th}>FX</th><th style={th}>PPP</th><th style={th}>Method</th><th style={th}>Payout</th>
            </tr></thead>
            <tbody>
              {fPayouts.map((p) => (
                <tr key={p.booking_id} onClick={() => openDetail(p.booking_id)} style={{ cursor: "pointer" }}>
                  <td style={td}>{fmt(p.created_at)}</td>
                  <td style={td}><span className={`pill st-${p.status}`}>{p.status}</span></td>
                  <td style={td}>{p.mentor_name}</td>
                  <td style={td}>{p.service_title}</td>
                  <td style={td}>{money(p.gross, p.currency)}</td>
                  <td style={td}>{p.fee_pct == null ? "—" : `${p.fee_pct}%`}</td>
                  <td style={{ ...td, color: "#a32020" }}>−{money(p.deduction, p.currency)}</td>
                  <td style={{ ...td, fontWeight: 800, color: "#0f7a44" }}>{money(p.net_payout, p.currency)}</td>
                  <td style={td}>{p.mentor_net == null ? "—" : money(p.mentor_net, p.mentor_currency || "")}</td>
                  <td style={td}>{p.fx_rate == null ? "—" : Number(p.fx_rate).toFixed(2)}</td>
                  <td style={td}>{p.ppp == null ? "—" : `×${Number(p.ppp).toFixed(2)}`}</td>
                  <td style={td}>{p.method === "auto_inr" ? "Auto (INR)" : p.method === "manual" ? "Manual" : "—"}</td>
                  <td style={td} onClick={(e) => e.stopPropagation()}>
                    <span className={`pill ${p.payout_status === "paid" ? "st-completed" : p.payout_status === "void" || p.payout_status === "blocked" ? "st-cancelled" : "st-pending"}`}>{p.payout_status}</span>
                    {p.status === "completed" && !["paid", "void", "blocked"].includes(p.payout_status) && (
                      <button className="btn-ghost btn-sm" style={{ marginLeft: 6 }} onClick={() => markPaid(p.booking_id)}>Mark paid</button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {!loading && view === "ledger" && (
        ledger.length === 0 ? <div className="empty">No ledger entries yet — refunds, credits, charges and penalties show up here.</div> :
        <div style={{ overflowX: "auto", border: "1px solid var(--line)", borderRadius: "var(--r-md)" }}>
          <table className="adm-table" style={{ width: "100%", borderCollapse: "collapse", minWidth: 920 }}>
            <thead><tr>
              <th style={th}>When</th><th style={th}>#</th><th style={th}>Party</th><th style={th}>Kind</th><th style={th}>%</th>
              <th style={th}>Amount</th><th style={th}>Mentor</th><th style={th}>Mentee</th><th style={th}>Reason</th>
            </tr></thead>
            <tbody>
              {ledger.map((l) => (
                <tr key={l.id} onClick={() => openDetail(l.booking_id)} style={{ cursor: "pointer" }}>
                  <td style={td}>{fmt(l.created_at)}</td>
                  <td style={td}>#{l.booking_id}</td>
                  <td style={td}>{l.party}</td>
                  <td style={{ ...td, fontWeight: 700, textTransform: "capitalize", color: kindColor[l.kind] || "inherit" }}>{l.kind}</td>
                  <td style={td}>{l.pct == null ? "—" : `${l.pct}%`}</td>
                  <td style={{ ...td, fontWeight: 700 }}>{money(l.amount, l.currency)}</td>
                  <td style={td}>{l.mentor_name}</td>
                  <td style={td}>{l.mentee_email}</td>
                  <td style={{ ...td, color: "var(--muted)", fontSize: 12 }}>{l.reason}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {!loading && view === "webinars" && (
        webinars.length === 0 ? <div className="empty">No webinars yet.</div> :
        <>
          <div className="stats" style={{ marginBottom: 16 }}>
            <div className="stat"><div className="n">{webinars.length}</div><div className="l">Total webinars</div></div>
            <div className="stat"><div className="n" style={{ color: "var(--ok)" }}>{webinars.filter((w) => w.status === "scheduled" && new Date(w.start_time) > new Date()).length}</div><div className="l">Upcoming</div></div>
            <div className="stat"><div className="n" style={{ color: "#534ab7" }}>{webinars.reduce((a, w) => a + w.registrations, 0)}</div><div className="l">Total registrations</div></div>
          </div>
          <div style={{ overflowX: "auto", border: "1px solid var(--line)", borderRadius: "var(--r-md)" }}>
            <table className="adm-table" style={{ width: "100%", borderCollapse: "collapse", minWidth: 820 }}>
              <thead><tr>
                <th style={th}>Starts</th><th style={th}>Title</th><th style={th}>Mentor</th><th style={th}>Visibility</th>
                <th style={th}>Status</th><th style={th}>Registered</th>
              </tr></thead>
              <tbody>
                {webinars.map((w) => (
                  <tr key={w.id} onClick={() => openRegs(w)} style={{ cursor: "pointer" }} title="See who registered">
                    <td style={td}>{fmt(w.start_time)}</td>
                    <td style={td}>{w.title}</td>
                    <td style={td}>{w.mentor_name}</td>
                    <td style={td}>{w.visibility}</td>
                    <td style={td}><span className={`pill st-${w.status === "scheduled" ? "confirmed" : "cancelled"}`}>{w.status}</span></td>
                    <td style={{ ...td, fontWeight: 700 }}>{w.registrations}{w.capacity != null ? ` / ${w.capacity}` : ""}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}

      {regs && (
        <div onClick={() => setRegs(null)} style={{ position: "fixed", inset: 0, background: "rgba(10,34,64,.45)", zIndex: 1000, display: "flex", alignItems: "flex-start", justifyContent: "center", padding: "32px 16px", overflowY: "auto" }}>
          <div onClick={(e) => e.stopPropagation()} style={{ background: "var(--surface)", borderRadius: "var(--r-lg, 16px)", width: "100%", maxWidth: 520, boxShadow: "0 20px 60px rgba(0,0,0,.3)", overflow: "hidden" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "16px 20px", background: "var(--navy)", color: "#fff" }}>
              <b style={{ fontSize: 15 }}>Registrants · {regs.title}</b>
              <span style={{ marginLeft: "auto", fontSize: 13, opacity: .85 }}>{regs.rows.length}</span>
              <button onClick={() => setRegs(null)} style={{ background: "transparent", border: "none", color: "#fff", fontSize: 22, cursor: "pointer", lineHeight: 1, marginLeft: 8 }}>×</button>
            </div>
            <div style={{ padding: 16 }}>
              {regs.rows.length === 0 ? <div className="empty">No registrants yet.</div> :
                <table style={{ width: "100%", borderCollapse: "collapse" }}>
                  <thead><tr><th style={th}>Name</th><th style={th}>Email</th><th style={th}>Registered</th></tr></thead>
                  <tbody>
                    {regs.rows.map((r, i) => (
                      <tr key={i}><td style={td}>{r.name}</td><td style={td}>{r.email}</td><td style={td}>{fmt(r.registered_at)}</td></tr>
                    ))}
                  </tbody>
                </table>}
            </div>
          </div>
        </div>
      )}

      {detailId !== null && (
        <div onClick={() => { setDetailId(null); setDetail(null); }}
          style={{ position: "fixed", inset: 0, background: "rgba(10,34,64,.45)", zIndex: 1000, display: "flex", alignItems: "flex-start", justifyContent: "center", padding: "32px 16px", overflowY: "auto" }}>
          <div onClick={(e) => e.stopPropagation()}
            style={{ background: "var(--surface)", borderRadius: "var(--r-lg, 16px)", width: "100%", maxWidth: 640, boxShadow: "0 20px 60px rgba(0,0,0,.3)", overflow: "hidden" }}>
            <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "16px 20px", borderBottom: "1px solid var(--line)", background: "var(--navy)", color: "#fff" }}>
              <b style={{ fontSize: 15 }}>Booking #{detailId}</b>
              {detail?.booking && <span className={`pill st-${detail.booking.status}`}>{detail.booking.status}{detail.booking.no_show_by ? ` · ${detail.booking.no_show_by}` : ""}</span>}
              <button onClick={() => { setDetailId(null); setDetail(null); }} style={{ marginLeft: "auto", background: "transparent", border: "none", color: "#fff", fontSize: 22, cursor: "pointer", lineHeight: 1 }}>×</button>
            </div>

            {!detail ? <div className="empty">Loading…</div> : !detail.booking ? <div className="empty">Not found.</div> : (
              <div style={{ padding: 20 }}>
                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "10px 18px", fontSize: 13, marginBottom: 18 }}>
                  <div><span className="faint">Service</span><br />{detail.booking.service} · {detail.booking.duration} min</div>
                  <div><span className="faint">Session</span><br />{fmtZ(detail.booking.slot_time, detail.booking.mentee_tz)} <span className="faint">({detail.booking.mentee_tz})</span></div>
                  <div><span className="faint">Mentor</span><br />{detail.booking.mentor} <span className="faint">({detail.booking.mentor_tz})</span></div>
                  <div><span className="faint">Mentee</span><br />{detail.booking.mentee} <span className="faint">({detail.booking.mentee_tz})</span></div>
                  <div><span className="faint">Mentor country</span><br />{detail.booking.mentor_country || "—"}</div>
                  <div><span className="faint">Mentee country</span><br />{detail.booking.mentee_country || "—"}</div>
                  <div><span className="faint">Booked</span><br />{fmtZ(detail.booking.created_at, detail.booking.mentee_tz)} <span className="faint">({detail.booking.mentee_tz})</span></div>
                  <div><span className="faint">Reschedules</span><br />{detail.booking.reschedule_count} of 2</div>
                </div>

                <div style={{ display: "flex", flexWrap: "wrap", gap: 8, marginBottom: 18 }}>
                  <Money label="Paid (gross)" v={detail.payment?.amount} c={detail.payment?.currency} tone="#0c1b33" />
                  <Money label={`Platform take (${detail.totals?.fee_pct ?? "—"}%)`} v={detail.totals?.platform_take} c={detail.totals?.currency} tone="#0f7a44" />
                  <Money label="Net to mentor" v={detail.totals?.net_to_mentor} c={detail.totals?.mentor_currency || detail.payout?.currency} tone="#0c1b33" />
                  {detail.totals?.ppp_multiplier != null && detail.totals.ppp_multiplier < 1 && (
                    <span className="tag" style={{ background: "var(--orange-soft)", color: "var(--orange-d)", alignSelf: "center" }}>
                      PPP ×{Number(detail.totals.ppp_multiplier).toFixed(2)}
                    </span>
                  )}
                  {detail.totals?.customer_refund > 0 && <Money label="Refunded" v={detail.totals.customer_refund} c={detail.totals.currency} tone="#0f7a44" />}
                  {detail.totals?.customer_credit > 0 && <Money label="Credit" v={detail.totals.customer_credit} c={detail.totals.currency} tone="#534ab7" />}
                  {detail.totals?.customer_charge > 0 && <Money label="Charged" v={detail.totals.customer_charge} c={detail.totals.currency} tone="#a32020" />}
                  {detail.totals?.customer_penalty > 0 && <Money label="Customer penalty" v={detail.totals.customer_penalty} c={detail.totals.currency} tone="#a32020" />}
                  {detail.totals?.mentor_penalty > 0 && <Money label="Mentor penalty" v={detail.totals.mentor_penalty} c={detail.payout?.currency} tone="#a32020" />}
                  {detail.totals?.mentor_credit > 0 && <Money label="Mentor credit" v={detail.totals.mentor_credit} c={detail.payout?.currency} tone="#0f7a44" />}
                </div>

                <div className="faint" style={{ fontSize: 11.5, textTransform: "uppercase", letterSpacing: ".04em", marginBottom: 2 }}>History</div>
                <div className="faint" style={{ fontSize: 11, marginBottom: 10 }}>Times shown in {detail.booking.mentee_tz}</div>
                <div style={{ display: "flex", flexDirection: "column", gap: 0 }}>
                  {(detail.timeline || []).map((e: any, i: number) => (
                    <div key={i} style={{ display: "flex", gap: 12, paddingBottom: 14, position: "relative" }}>
                      <div style={{ flexShrink: 0, width: 8, display: "flex", flexDirection: "column", alignItems: "center" }}>
                        <span style={{ width: 8, height: 8, borderRadius: 999, background: e.actor === "mentor" ? "#0f6e56" : "#185fa5", marginTop: 5 }} />
                        {i < detail.timeline.length - 1 && <span style={{ flex: 1, width: 1.5, background: "var(--line)", marginTop: 3 }} />}
                      </div>
                      <div style={{ flex: 1 }}>
                        <div style={{ fontSize: 11, color: "var(--muted)" }}>{fmtZ(e.at, detail.booking.mentee_tz)} · <span style={{ textTransform: "capitalize" }}>{e.actor}</span></div>
                        <div style={{ fontSize: 13.5, fontWeight: 700 }}>{e.title}</div>
                        {e.detail && <div style={{ fontSize: 12.5, color: "var(--muted)" }}>{e.detail}</div>}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

function Money({ label, v, c, tone }: { label: string; v: number | null | undefined; c: string | null | undefined; tone: string }) {
  if (v == null) return null;
  return (
    <div style={{ border: "1px solid var(--line)", borderRadius: 10, padding: "8px 12px", minWidth: 110 }}>
      <div className="faint" style={{ fontSize: 11 }}>{label}</div>
      <div style={{ fontWeight: 800, color: tone }}>{Number(v).toFixed(2)} {c || ""}</div>
    </div>
  );
}
