"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getEmail } from "@/lib/identity";
import { money } from "@/lib/format";

type Summary = {
  affiliate: { id: number; type: string; status: string };
  link: { slug: string | null; is_house_channel: boolean };
  code: { code: string | null; expires_at: string | null; redemption_count: number; redemption_cap: number; discount_pct: number };
  tier: string;
  pending_commission_inr: number;
  paid_commission_inr: number;
  upcoming: { booking_id: number; slot_time: string | null; status: string }[];
  referrals: { booking_id: number; status: string; amount_inr: number; created_at: string; under_review: boolean }[];
  payouts: { batch_date: string; amount_inr: number; entry_count: number }[];
};

const TIER_LABEL: Record<string, string> = {
  starter: "Starter", growth: "Growth", partner: "Partner", flat_peer_rate: "Mentor referral (flat rate)",
};

function copy(text: string) {
  navigator.clipboard?.writeText(text);
}

export default function AffiliatePage() {
  const supabase = createClient();
  const [email, setEmailS] = useState<string | null>(null);
  const [summary, setSummary] = useState<Summary | null>(null);
  const [notAffiliate, setNotAffiliate] = useState(false);
  const [loading, setLoading] = useState(true);
  const [copied, setCopied] = useState<string | null>(null);

  useEffect(() => { setEmailS(getEmail()); }, []);

  useEffect(() => {
    if (!email) { setLoading(false); return; }
    setLoading(true);
    supabase.rpc("affiliate_dashboard_summary", { p_email: email }).then(({ data, error }) => {
      if (error) { setNotAffiliate(true); setSummary(null); }
      else { setSummary(data as Summary); setNotAffiliate(false); }
      setLoading(false);
    });
  }, [email, supabase]);

  function doCopy(label: string, text: string) {
    copy(text);
    setCopied(label);
    setTimeout(() => setCopied(null), 1500);
  }

  if (!email) {
    return (
      <div className="container" style={{ maxWidth: 480 }}>
        <div className="card" style={{ textAlign: "center", padding: 30 }}>
          <h2 className="sec">Affiliate dashboard</h2>
          <p className="muted">Sign in with the email your affiliate account was created with.</p>
          <Link href="/login" className="btn btn-cta" style={{ marginTop: 12 }}>Sign in</Link>
        </div>
      </div>
    );
  }

  if (loading) return <div className="container"><p className="muted">Loading…</p></div>;

  if (notAffiliate) {
    return (
      <div className="container" style={{ maxWidth: 480 }}>
        <div className="card" style={{ textAlign: "center", padding: 30 }}>
          <h2 className="sec">Not an affiliate account</h2>
          <p className="muted">{email} isn&rsquo;t set up as an affiliate. Affiliate accounts are created by an admin — reach out if you were expecting access.</p>
        </div>
      </div>
    );
  }

  if (!summary) return null;
  const siteUrl = typeof window !== "undefined" ? window.location.origin : "";
  const linkUrl = summary.link.slug ? `${siteUrl}/r/${summary.link.slug}` : null;

  return (
    <div className="container">
      <div className="section-head">
        <div>
          <h2 className="sec">Affiliate dashboard</h2>
          <div className="lead">{email}</div>
        </div>
        <span className="tag">{TIER_LABEL[summary.tier] || summary.tier}</span>
      </div>

      <div className="stats reveal" style={{ marginBottom: 22 }}>
        <div className="stat"><div className="n">{money(summary.pending_commission_inr, "INR")}</div><div className="l">Pending commission</div></div>
        <div className="stat"><div className="n" style={{ color: "var(--ok)" }}>{money(summary.paid_commission_inr, "INR")}</div><div className="l">Paid out</div></div>
        <div className="stat"><div className="n">{summary.referrals.length}</div><div className="l">Total referrals</div></div>
        <div className="stat"><div className="n">{summary.code.redemption_count}<span style={{ fontSize: 15, color: "var(--muted)" }}>/{summary.code.redemption_cap || "—"}</span></div><div className="l">Code redemptions</div></div>
      </div>

      <div className="grid two-col" style={{ gridTemplateColumns: "1fr 1fr", gap: 18, marginBottom: 22 }}>
        <div className="card">
          <div className="faint" style={{ fontSize: 12, fontWeight: 700, textTransform: "uppercase" }}>Your referral link</div>
          {linkUrl ? (
            <div style={{ display: "flex", gap: 8, marginTop: 10, alignItems: "center" }}>
              <input readOnly value={linkUrl} style={{ flex: 1, fontSize: 13 }} onFocus={(e) => e.target.select()} />
              <button className="btn-ghost btn-sm" onClick={() => doCopy("link", linkUrl)}>{copied === "link" ? "Copied!" : "Copy"}</button>
            </div>
          ) : <p className="muted" style={{ fontSize: 13 }}>No link set up yet.</p>}
        </div>
        <div className="card">
          <div className="faint" style={{ fontSize: 12, fontWeight: 700, textTransform: "uppercase" }}>Your referral code</div>
          {summary.code.code ? (
            <>
              <div style={{ display: "flex", gap: 8, marginTop: 10, alignItems: "center" }}>
                <input readOnly value={summary.code.code} style={{ flex: 1, fontSize: 13, fontWeight: 700 }} onFocus={(e) => e.target.select()} />
                <button className="btn-ghost btn-sm" onClick={() => doCopy("code", summary.code.code!)}>{copied === "code" ? "Copied!" : "Copy"}</button>
              </div>
              <div className="faint" style={{ fontSize: 12, marginTop: 8 }}>
                {summary.code.discount_pct}% off for the customer{summary.code.expires_at ? ` · expires ${new Date(summary.code.expires_at).toLocaleDateString()}` : ""}
              </div>
            </>
          ) : <p className="muted" style={{ fontSize: 13 }}>No code set up yet.</p>}
        </div>
      </div>

      {summary.upcoming.length > 0 && (
        <div className="card" style={{ padding: "12px 16px", marginBottom: 18, fontSize: 13 }}>
          <div className="faint" style={{ fontWeight: 700, textTransform: "uppercase", fontSize: 11.5, marginBottom: 6 }}>Upcoming referrals</div>
          {summary.upcoming.map((u) => (
            <div key={u.booking_id} style={{ display: "flex", justifyContent: "space-between", padding: "4px 0" }}>
              <span>Booking #{u.booking_id} — booked ✓</span>
              <span className="faint">{u.slot_time ? new Date(u.slot_time).toLocaleDateString() : "—"} · awaiting session completion</span>
            </div>
          ))}
        </div>
      )}

      <h3 className="sec" style={{ fontSize: 16, marginBottom: 10 }}>Referral history</h3>
      <div className="card" style={{ padding: 0, marginBottom: 22 }}>
        {summary.referrals.length === 0 ? (
          <div className="empty" style={{ padding: 24 }}><div className="ico">📭</div>No referrals yet.</div>
        ) : (
          <table className="adm-table" style={{ width: "100%", borderCollapse: "collapse", fontSize: 13.5 }}>
            <thead><tr><th style={{ textAlign: "left", padding: "9px 12px" }}>Booking</th><th style={{ textAlign: "left", padding: "9px 12px" }}>Date</th><th style={{ textAlign: "left", padding: "9px 12px" }}>Status</th><th style={{ textAlign: "right", padding: "9px 12px" }}>Commission (INR)</th></tr></thead>
            <tbody>
              {summary.referrals.map((r) => (
                <tr key={r.booking_id}>
                  <td style={{ padding: "9px 12px" }}>#{r.booking_id}</td>
                  <td style={{ padding: "9px 12px" }}>{new Date(r.created_at).toLocaleDateString()}</td>
                  <td style={{ padding: "9px 12px" }}>
                    {r.under_review ? <span className="pill">Under review</span> : <span className="pill">{r.status.replace("_", " ")}</span>}
                  </td>
                  <td style={{ padding: "9px 12px", textAlign: "right" }}>{money(r.amount_inr, "INR")}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>

      <h3 className="sec" style={{ fontSize: 16, marginBottom: 10 }}>Payout history</h3>
      <div className="card" style={{ padding: 0 }}>
        {summary.payouts.length === 0 ? (
          <div className="empty" style={{ padding: 24 }}><div className="ico">💸</div>No payouts yet.</div>
        ) : (
          <table className="adm-table" style={{ width: "100%", borderCollapse: "collapse", fontSize: 13.5 }}>
            <thead><tr><th style={{ textAlign: "left", padding: "9px 12px" }}>Batch date</th><th style={{ textAlign: "left", padding: "9px 12px" }}>Referrals paid</th><th style={{ textAlign: "right", padding: "9px 12px" }}>Amount (INR)</th></tr></thead>
            <tbody>
              {summary.payouts.map((p) => (
                <tr key={p.batch_date}>
                  <td style={{ padding: "9px 12px" }}>{new Date(p.batch_date).toLocaleDateString()}</td>
                  <td style={{ padding: "9px 12px" }}>{p.entry_count}</td>
                  <td style={{ padding: "9px 12px", textAlign: "right" }}>{money(p.amount_inr, "INR")}</td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
