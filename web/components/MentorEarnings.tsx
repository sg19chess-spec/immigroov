"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { money } from "@/lib/format";

type E = {
  booking_id: number; created_at: string; status: string; slot_time: string;
  service_title: string; mentee_name: string;
  gross_amount: number | null; customer_currency: string | null; fee_pct: number | null; platform_fee_amount: number | null;
  net_amount_customer_currency: number | null; net_amount_mentor_currency: number | null; mentor_currency: string | null;
  exchange_rate_used: number | null; ppp_multiplier: number | null;
  net_inr: number | null; penalty_inr: number | null; payout_status: string;
};

const inr = (n: number) => money(Math.round((n || 0) * 100) / 100, "INR");
const mon = (s: string) => new Intl.DateTimeFormat("en", { month: "short" }).format(new Date(s)).toUpperCase();
const day = (s: string) => new Date(s).getDate();

export default function MentorEarnings({ mentorId }: { mentorId: number }) {
  const supabase = createClient();
  const [rows, setRows] = useState<E[]>([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    const { data } = await supabase.rpc("mentor_earnings", { p_mentor_id: mentorId });
    setRows((data as E[]) || []); setLoading(false);
  }, [supabase, mentorId]);
  useEffect(() => { load(); }, [load]);

  const netOf = (r: E) => Number(r.net_inr || 0) - Number(r.penalty_inr || 0);
  const totalNet = rows.reduce((a, r) => a + netOf(r), 0);
  const pending = rows.filter((r) => r.payout_status !== "paid").reduce((a, r) => a + netOf(r), 0);
  const paid = rows.filter((r) => r.payout_status === "paid").reduce((a, r) => a + netOf(r), 0);
  const feesInr = rows.reduce((a, r) => {
    const fx = r.net_amount_customer_currency ? Number(r.net_inr || 0) / Number(r.net_amount_customer_currency) : 1;
    return a + Number(r.platform_fee_amount || 0) * (fx || 1);
  }, 0);

  if (loading) return <div className="empty">Loading earnings…</div>;

  return (
    <div className="reveal">
      <div className="stats" style={{ marginBottom: 18 }}>
        <div className="stat"><div className="n" style={{ color: "var(--ok)", fontSize: 22 }}>{inr(totalNet)}</div><div className="l">Your net earnings (≈INR)</div></div>
        <div className="stat"><div className="n" style={{ fontSize: 22 }}>{inr(pending)}</div><div className="l">Pending payout</div></div>
        <div className="stat"><div className="n" style={{ fontSize: 22, color: "var(--navy2)" }}>{inr(paid)}</div><div className="l">Paid out</div></div>
        <div className="stat"><div className="n" style={{ fontSize: 22, color: "#a32020" }}>{inr(feesInr)}</div><div className="l">Platform fees</div></div>
      </div>

      <div className="banner" style={{ background: "var(--navy-soft)", border: "1px solid var(--line)", fontSize: 12.5 }}>
        You receive the session price minus Immigroov's commission. Amounts are shown in your currency and approximate INR. Payments are not live yet.
      </div>

      {rows.length === 0 ? <div className="empty">No earnings yet.</div> :
        <div className="sess-list">
          {rows.map((r) => {
            const mCcy = r.mentor_currency || "EUR";
            return (
              <div key={r.booking_id} className="card" style={{ padding: 0, overflow: "hidden" }}>
                <div style={{ display: "flex", gap: 14, padding: "14px 16px" }}>
                  <div className="sess-date"><div className="m">{mon(r.slot_time)}</div><div className="d">{day(r.slot_time)}</div></div>
                  <div style={{ flex: 1, minWidth: 0 }}>
                    <div style={{ display: "flex", justifyContent: "space-between", gap: 8 }}>
                      <div style={{ fontWeight: 800 }}>{r.service_title}</div>
                      <span className={`pill st-${r.status}`}>{r.status.replace("_", "-")}</span>
                    </div>
                    <div className="muted" style={{ fontSize: 12.5 }}>with {r.mentee_name} · #{r.booking_id}</div>
                  </div>
                </div>

                <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", borderTop: "1px solid var(--line)", fontSize: 13 }}>
                  <div style={{ padding: "10px 14px", borderRight: "1px solid var(--line)" }}>
                    <div className="faint" style={{ fontSize: 11 }}>Customer paid</div>
                    <b>{r.gross_amount != null ? money(r.gross_amount, r.customer_currency || "INR") : "—"}</b>
                  </div>
                  <div style={{ padding: "10px 14px", borderRight: "1px solid var(--line)" }}>
                    <div className="faint" style={{ fontSize: 11 }}>Platform fee ({r.fee_pct ?? "—"}%)</div>
                    <b style={{ color: "#a32020" }}>−{r.platform_fee_amount != null ? money(r.platform_fee_amount, r.customer_currency || "INR") : "—"}</b>
                  </div>
                  <div style={{ padding: "10px 14px" }}>
                    <div className="faint" style={{ fontSize: 11 }}>Your net</div>
                    <b style={{ color: "var(--ok)" }}>{r.net_amount_mentor_currency != null ? money(r.net_amount_mentor_currency, mCcy) : "—"}</b>
                    <div className="faint" style={{ fontSize: 11 }}>≈ {inr(Number(r.net_inr || 0))}</div>
                  </div>
                </div>

                <div className="faint" style={{ fontSize: 11.5, padding: "8px 14px", background: "var(--surface-2)", display: "flex", gap: 12, flexWrap: "wrap" }}>
                  {r.ppp_multiplier != null && <span>PPP ×{Number(r.ppp_multiplier).toFixed(2)}</span>}
                  {r.exchange_rate_used != null && <span>FX {Number(r.exchange_rate_used).toFixed(2)} {r.customer_currency}/{mCcy}</span>}
                  <span>Payout: <b className={r.payout_status === "paid" ? "" : ""} style={{ color: r.payout_status === "paid" ? "var(--ok)" : "var(--amber)" }}>{r.payout_status}</b></span>
                  {Number(r.penalty_inr || 0) > 0 && <span style={{ color: "#a32020" }}>Penalty −{inr(Number(r.penalty_inr))}</span>}
                </div>
              </div>
            );
          })}
        </div>}
    </div>
  );
}
