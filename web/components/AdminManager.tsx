"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

type Booking = {
  id: number; created_at: string; status: string; slot_time: string;
  service_title: string; mentor_name: string; mentee_email: string;
  cost: number | null; cost_currency: string | null; mentor_payout: number | null;
  reschedule_count: number; no_show_by: string | null; ledger_summary: string | null;
};
type Ledger = {
  id: number; created_at: string; booking_id: number; party: string; kind: string; pct: number | null;
  amount: number | null; currency: string | null; reason: string;
  service_title: string; mentor_name: string; mentee_email: string; booking_status: string;
};

const fmt = (s: string | null) => (s ? new Date(s).toLocaleString([], { dateStyle: "medium", timeStyle: "short" }) : "—");
const money = (a: number | null, c: string | null) => (a == null ? "—" : `${Number(a).toFixed(2)} ${c || ""}`.trim());
const kindColor: Record<string, string> = { refund: "#0f7a44", credit: "#534ab7", charge: "#a32020", penalty: "#a32020" };

// Admin overview — cross-mentor activity + the full ledger. Read-only.
// Backed by admin_bookings() / admin_ledger() (SECURITY DEFINER; gate to an admin role for prod).
export default function AdminManager() {
  const supabase = createClient();
  const [bookings, setBookings] = useState<Booking[]>([]);
  const [ledger, setLedger] = useState<Ledger[]>([]);
  const [view, setView] = useState<"activity" | "ledger">("activity");
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    const [{ data: b }, { data: l }] = await Promise.all([
      supabase.rpc("admin_bookings"),
      supabase.rpc("admin_ledger"),
    ]);
    setBookings((b as Booking[]) || []);
    setLedger((l as Ledger[]) || []);
    setLoading(false);
  }, [supabase]);
  useEffect(() => { load(); }, [load]);

  const by = (s: string) => bookings.filter((x) => x.status === s).length;
  const sum = (k: string) => ledger.filter((x) => x.kind === k).reduce((a, x) => a + Number(x.amount || 0), 0);
  const cur = ledger[0]?.currency || "USD";

  const th: React.CSSProperties = { textAlign: "left", padding: "9px 12px", fontSize: 11.5, textTransform: "uppercase", letterSpacing: ".04em", color: "var(--muted)", borderBottom: "1px solid var(--line)", whiteSpace: "nowrap" };
  const td: React.CSSProperties = { padding: "9px 12px", fontSize: 13, borderBottom: "1px solid var(--line)", verticalAlign: "top" };

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

      <div className="seg" style={{ marginBottom: 16 }}>
        <button className={view === "activity" ? "on" : ""} onClick={() => setView("activity")}>Activity ({bookings.length})</button>
        <button className={view === "ledger" ? "on" : ""} onClick={() => setView("ledger")}>Ledger ({ledger.length})</button>
      </div>

      {loading && <div className="empty">Loading…</div>}

      {!loading && view === "activity" && (
        bookings.length === 0 ? <div className="empty">No bookings yet.</div> :
        <div style={{ overflowX: "auto", border: "1px solid var(--line)", borderRadius: "var(--r-md)" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 860 }}>
            <thead><tr>
              <th style={th}>Booked</th><th style={th}>Status</th><th style={th}>Service</th><th style={th}>Mentor</th>
              <th style={th}>Mentee</th><th style={th}>Session</th><th style={th}>Paid</th><th style={th}>Resch.</th><th style={th}>Ledger</th>
            </tr></thead>
            <tbody>
              {bookings.map((b) => (
                <tr key={b.id}>
                  <td style={td}>{fmt(b.created_at)}</td>
                  <td style={td}><span className={`pill st-${b.status}`}>{b.status}{b.no_show_by ? ` · ${b.no_show_by}` : ""}</span></td>
                  <td style={td}>{b.service_title}</td>
                  <td style={td}>{b.mentor_name}</td>
                  <td style={td}>{b.mentee_email}</td>
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

      {!loading && view === "ledger" && (
        ledger.length === 0 ? <div className="empty">No ledger entries yet — refunds, credits, charges and penalties show up here.</div> :
        <div style={{ overflowX: "auto", border: "1px solid var(--line)", borderRadius: "var(--r-md)" }}>
          <table style={{ width: "100%", borderCollapse: "collapse", minWidth: 920 }}>
            <thead><tr>
              <th style={th}>When</th><th style={th}>#</th><th style={th}>Party</th><th style={th}>Kind</th><th style={th}>%</th>
              <th style={th}>Amount</th><th style={th}>Mentor</th><th style={th}>Mentee</th><th style={th}>Reason</th>
            </tr></thead>
            <tbody>
              {ledger.map((l) => (
                <tr key={l.id}>
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
    </div>
  );
}
