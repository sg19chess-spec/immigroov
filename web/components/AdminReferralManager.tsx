"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

type FraudFlag = {
  flag_id: number; affiliate_id: number; booking_id: number; vector_type: string;
  created_at: string; escalated_to_cofounder_at: string | null;
  commission_amount_inr: number | null; split_snapshot: any;
};
type AttendanceReview = { review_id: number; booking_id: number; reason: string; created_at: string };
type Affiliate = {
  affiliate_id: number; email: string; first_name: string; type: string; status: string; tier: string;
  this_month_referrals: number; lifetime_paid_inr: number; active_flag_count: number; total_flag_count: number;
  link_slug: string | null; code_string: string | null;
};
type BatchPreviewRow = { commission_ledger_id: number; affiliate_id: number; amount_inr: number; booking_id: number };
type SteeringRow = { affiliate_id: number; top_mentor_id: number; concentration_pct: number };
type AffiliateType = "mentor" | "non_mentor";

const money = (a: number | null) => (a == null ? "—" : `₹${Number(a).toFixed(2)}`);
const th: React.CSSProperties = { textAlign: "left", padding: "9px 12px", fontSize: 11.5, textTransform: "uppercase", letterSpacing: ".04em", color: "var(--muted)", borderBottom: "1px solid var(--line)", whiteSpace: "nowrap" };
const td: React.CSSProperties = { padding: "9px 12px", fontSize: 13, borderBottom: "1px solid var(--line)", verticalAlign: "top" };

export default function AdminReferralManager() {
  const supabase = createClient();
  const [tab, setTab] = useState<"queue" | "affiliates" | "payouts" | "reports">("queue");
  const [flags, setFlags] = useState<FraudFlag[]>([]);
  const [attReviews, setAttReviews] = useState<AttendanceReview[]>([]);
  const [affiliates, setAffiliates] = useState<Affiliate[]>([]);
  const [steering, setSteering] = useState<SteeringRow[]>([]);
  const [batchDate, setBatchDate] = useState("");
  const [preview, setPreview] = useState<BatchPreviewRow[] | null>(null);
  const [msg, setMsg] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [mentors, setMentors] = useState<{ mentor_id: number; name: string }[]>([]);
  const [showAdd, setShowAdd] = useState(false);
  const [addBusy, setAddBusy] = useState(false);
  const [addErr, setAddErr] = useState<string | null>(null);
  const [form, setForm] = useState({
    email: "", firstName: "", type: "non_mentor" as AffiliateType, mentorId: "",
    payoutDetails: "", audienceCorridor: "", agreedTerms: false,
    slug: "", isHouseChannel: false,
    code: "", redemptionCap: "100", expiresAt: "", discountPct: "10",
  });

  const load = useCallback(async () => {
    setLoading(true);
    const [q, ar, aff, st] = await Promise.all([
      supabase.rpc("admin_referral_review_queue"),
      supabase.rpc("admin_attendance_review_queue"),
      supabase.rpc("admin_affiliates_overview"),
      supabase.rpc("admin_mentor_steering_report"),
    ]);
    const err = q.error || ar.error || aff.error || st.error;
    if (err) setMsg(`Couldn't load referral data: ${err.message}`);
    setFlags((q.data as FraudFlag[]) || []);
    setAttReviews((ar.data as AttendanceReview[]) || []);
    setAffiliates((aff.data as Affiliate[]) || []);
    setSteering((st.data as SteeringRow[]) || []);
    setLoading(false);
  }, [supabase]);
  useEffect(() => { load(); }, [load]);
  useEffect(() => {
    supabase.rpc("search_mentors", {}).then(({ data }) => {
      setMentors(((data as any[]) || []).map((m) => ({ mentor_id: m.mentor_id, name: m.name })));
    });
  }, [supabase]);

  async function submitAdd() {
    setAddErr(null);
    if (!form.email.includes("@")) { setAddErr("A valid email is required."); return; }
    if (!form.agreedTerms) { setAddErr("Confirm the affiliate has agreed to the commission terms."); return; }
    if (!form.slug.trim()) { setAddErr("A link slug is required."); return; }
    if (!form.code.trim()) { setAddErr("A referral code is required."); return; }
    if (!form.expiresAt) { setAddErr("A code expiry date is required."); return; }
    if (form.type === "mentor" && !form.mentorId) { setAddErr("Pick which mentor this affiliate is."); return; }
    setAddBusy(true);
    const { error } = await supabase.rpc("admin_onboard_affiliate", {
      p_email: form.email, p_type: form.type, p_slug: form.slug, p_code: form.code,
      p_redemption_cap: Number(form.redemptionCap) || 100,
      p_expires_at: new Date(form.expiresAt + "T23:59:59").toISOString(),
      p_discount_pct: Number(form.discountPct) || 0,
      p_first_name: form.firstName || null,
      p_mentor_id: form.type === "mentor" ? Number(form.mentorId) : null,
      p_payout_details: form.type === "non_mentor" && form.payoutDetails ? { note: form.payoutDetails } : null,
      p_audience_corridor: form.type === "non_mentor" ? form.audienceCorridor || null : null,
      p_is_house_channel: form.isHouseChannel,
    });
    setAddBusy(false);
    if (error) { setAddErr(error.message); return; }
    setShowAdd(false);
    setForm({ email: "", firstName: "", type: "non_mentor", mentorId: "", payoutDetails: "", audienceCorridor: "", agreedTerms: false, slug: "", isHouseChannel: false, code: "", redemptionCap: "100", expiresAt: "", discountPct: "10" });
    setMsg("Affiliate created.");
    load();
  }

  async function resolveFraud(flagId: number, decision: "approve" | "approve_with_note" | "reject_and_hold") {
    const note = decision === "approve" ? "" : window.prompt("Note for the audit trail:", "");
    if (decision !== "approve" && note === null) return;
    const { error } = await supabase.rpc("admin_resolve_fraud_flag", { p_flag_id: flagId, p_decision: decision, p_note: note || null });
    if (error) window.alert(error.message); else load();
  }

  async function resolveAttendance(reviewId: number, outcome: "mentor_fault" | "customer_fault" | "no_fault") {
    const note = window.prompt("Note for the audit trail (required):", "");
    if (!note) return;
    const { error } = await supabase.rpc("admin_resolve_attendance_review", { p_review_id: reviewId, p_outcome: outcome, p_note: note });
    if (error) window.alert(error.message); else load();
  }

  async function toggleFreeze(a: Affiliate) {
    const note = window.prompt(`Note for ${a.status === "frozen" ? "unfreezing" : "freezing"} this affiliate (required):`, "");
    if (!note) return;
    const fn = a.status === "frozen" ? "admin_unfreeze_affiliate" : "admin_freeze_affiliate";
    const { error } = await supabase.rpc(fn, { p_affiliate_id: a.affiliate_id, p_note: note });
    if (error) window.alert(error.message); else load();
  }

  async function loadPreview() {
    if (!batchDate) return;
    const { data, error } = await supabase.rpc("admin_payout_batch_preview", { p_batch_date: batchDate });
    if (error) { window.alert(error.message); return; }
    setPreview((data as BatchPreviewRow[]) || []);
  }
  async function finalizeBatch() {
    if (!batchDate || !preview) return;
    if (!window.confirm(`Finalize the payout batch for ${batchDate}? This marks ${preview.length} entries as paid.`)) return;
    const { error } = await supabase.rpc("admin_finalize_payout_batch", { p_batch_date: batchDate });
    setMsg(error ? error.message : `Batch finalized for ${batchDate}.`);
    setPreview(null);
    load();
  }

  if (loading) return <p className="muted">Loading…</p>;

  return (
    <div>
      {msg && <div className={`banner ${msg.startsWith("Couldn't") ? "bad" : "ok"}`} style={{ marginBottom: 14 }}>{msg}</div>}
      <div className="stats" style={{ marginBottom: 18 }}>
        <div className="stat"><div className="n" style={{ color: "#a32020" }}>{flags.length}</div><div className="l">Fraud flags awaiting review</div></div>
        <div className="stat"><div className="n" style={{ color: "#a32020" }}>{attReviews.length}</div><div className="l">Attendance reviews (neither joined)</div></div>
        <div className="stat"><div className="n">{affiliates.length}</div><div className="l">Total affiliates</div></div>
        <div className="stat"><div className="n" style={{ color: "var(--ok)" }}>₹{affiliates.reduce((sum, a) => sum + Number(a.lifetime_paid_inr || 0), 0).toFixed(0)}</div><div className="l">Lifetime paid (all affiliates)</div></div>
      </div>

      <div className="seg" style={{ marginBottom: 16 }}>
        <button className={tab === "queue" ? "on" : ""} onClick={() => setTab("queue")}>Review Queue ({flags.length + attReviews.length})</button>
        <button className={tab === "affiliates" ? "on" : ""} onClick={() => setTab("affiliates")}>Affiliates ({affiliates.length})</button>
        <button className={tab === "payouts" ? "on" : ""} onClick={() => setTab("payouts")}>Payout Batches</button>
        <button className={tab === "reports" ? "on" : ""} onClick={() => setTab("reports")}>Reports</button>
      </div>

      {tab === "queue" && (
        <>
          <h3 className="sec" style={{ fontSize: 15, marginBottom: 8 }}>Fraud flags</h3>
          {flags.length === 0 ? <p className="muted" style={{ fontSize: 13.5, marginBottom: 20 }}>Nothing awaiting review.</p> : (
            <div className="card" style={{ padding: 0, marginBottom: 20, overflowX: "auto" }}>
              <table style={{ width: "100%", borderCollapse: "collapse" }}>
                <thead><tr><th style={th}>Booking</th><th style={th}>Affiliate</th><th style={th}>Vector</th><th style={th}>Flagged</th><th style={th}>Escalated</th><th style={th}>Amount (INR)</th><th style={th}>Decision</th></tr></thead>
                <tbody>
                  {flags.map((f) => (
                    <tr key={f.flag_id}>
                      <td style={td}>#{f.booking_id}</td>
                      <td style={td}>#{f.affiliate_id}</td>
                      <td style={td}>{f.vector_type.replace(/_/g, " ")}</td>
                      <td style={td}>{new Date(f.created_at).toLocaleString()}</td>
                      <td style={td}>{f.escalated_to_cofounder_at ? new Date(f.escalated_to_cofounder_at).toLocaleString() : "—"}</td>
                      <td style={td}>{money(f.commission_amount_inr)}</td>
                      <td style={td}>
                        <div style={{ display: "flex", gap: 6 }}>
                          <button className="btn-ghost btn-sm" onClick={() => resolveFraud(f.flag_id, "approve")}>Approve</button>
                          <button className="btn-ghost btn-sm" onClick={() => resolveFraud(f.flag_id, "approve_with_note")}>Approve w/ note</button>
                          <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => resolveFraud(f.flag_id, "reject_and_hold")}>Reject &amp; hold</button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}

          <h3 className="sec" style={{ fontSize: 15, marginBottom: 8 }}>Attendance reviews (neither party joined)</h3>
          {attReviews.length === 0 ? <p className="muted" style={{ fontSize: 13.5 }}>Nothing awaiting review.</p> : (
            <div className="card" style={{ padding: 0, overflowX: "auto" }}>
              <table style={{ width: "100%", borderCollapse: "collapse" }}>
                <thead><tr><th style={th}>Booking</th><th style={th}>Flagged</th><th style={th}>Decision</th></tr></thead>
                <tbody>
                  {attReviews.map((r) => (
                    <tr key={r.review_id}>
                      <td style={td}>#{r.booking_id}</td>
                      <td style={td}>{new Date(r.created_at).toLocaleString()}</td>
                      <td style={td}>
                        <div style={{ display: "flex", gap: 6 }}>
                          <button className="btn-ghost btn-sm" onClick={() => resolveAttendance(r.review_id, "mentor_fault")}>Mentor at fault</button>
                          <button className="btn-ghost btn-sm" onClick={() => resolveAttendance(r.review_id, "customer_fault")}>Customer at fault</button>
                          <button className="btn-ghost btn-sm" onClick={() => resolveAttendance(r.review_id, "no_fault")}>No fault — refund</button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </>
      )}

      {tab === "affiliates" && (
        <>
          <div style={{ marginBottom: 14 }}>
            <button className="btn-cta btn-sm" onClick={() => setShowAdd((v) => !v)}>{showAdd ? "Cancel" : "+ Add affiliate"}</button>
          </div>

          {showAdd && (
            <div className="card" style={{ padding: 20, marginBottom: 18 }}>
              <h3 className="sec" style={{ fontSize: 15, marginBottom: 12 }}>New affiliate</h3>
              <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14 }}>
                <div>
                  <label className="fld">Email *</label>
                  <input value={form.email} onChange={(e) => setForm({ ...form, email: e.target.value })} placeholder="affiliate@email.com" style={{ width: "100%" }} />
                </div>
                <div>
                  <label className="fld">Name</label>
                  <input value={form.firstName} onChange={(e) => setForm({ ...form, firstName: e.target.value })} style={{ width: "100%" }} />
                </div>

                <div>
                  <label className="fld">Type *</label>
                  <select value={form.type} onChange={(e) => setForm({ ...form, type: e.target.value as AffiliateType })} style={{ width: "100%" }}>
                    <option value="non_mentor">Non-mentor influencer</option>
                    <option value="mentor">Mentor (referring own/other sessions)</option>
                  </select>
                </div>
                {form.type === "mentor" ? (
                  <div>
                    <label className="fld">Which mentor? *</label>
                    <select value={form.mentorId} onChange={(e) => setForm({ ...form, mentorId: e.target.value })} style={{ width: "100%" }}>
                      <option value="">Select…</option>
                      {mentors.map((m) => <option key={m.mentor_id} value={m.mentor_id}>{m.name}</option>)}
                    </select>
                  </div>
                ) : (
                  <div>
                    <label className="fld">Audience / geography</label>
                    <input value={form.audienceCorridor} onChange={(e) => setForm({ ...form, audienceCorridor: e.target.value })} placeholder="e.g. US-based YouTube, immigration content" style={{ width: "100%" }} />
                  </div>
                )}

                {form.type === "non_mentor" && (
                  <div style={{ gridColumn: "1 / -1" }}>
                    <label className="fld">Payout details (bank / PayPal / Razorpay reference)</label>
                    <input value={form.payoutDetails} onChange={(e) => setForm({ ...form, payoutDetails: e.target.value })} style={{ width: "100%" }} />
                  </div>
                )}

                <div>
                  <label className="fld">Link slug *</label>
                  <input value={form.slug} onChange={(e) => setForm({ ...form, slug: e.target.value })} placeholder="e.g. john-doe" style={{ width: "100%" }} />
                </div>
                <div style={{ display: "flex", alignItems: "flex-end", paddingBottom: 8 }}>
                  <label style={{ fontSize: 13, display: "flex", alignItems: "center", gap: 6 }}>
                    <input type="checkbox" checked={form.isHouseChannel} onChange={(e) => setForm({ ...form, isHouseChannel: e.target.checked })} />
                    Founder's own house channel (0% promoter fee)
                  </label>
                </div>

                <div>
                  <label className="fld">Referral code *</label>
                  <input value={form.code} onChange={(e) => setForm({ ...form, code: e.target.value.toUpperCase() })} placeholder="e.g. JOHN10" style={{ width: "100%" }} />
                </div>
                <div>
                  <label className="fld">Customer discount %</label>
                  <input type="number" min={0} max={100} value={form.discountPct} onChange={(e) => setForm({ ...form, discountPct: e.target.value })} style={{ width: "100%" }} />
                </div>
                <div>
                  <label className="fld">Redemption cap</label>
                  <input type="number" min={1} value={form.redemptionCap} onChange={(e) => setForm({ ...form, redemptionCap: e.target.value })} style={{ width: "100%" }} />
                </div>
                <div>
                  <label className="fld">Code expires *</label>
                  <input type="date" value={form.expiresAt} onChange={(e) => setForm({ ...form, expiresAt: e.target.value })} style={{ width: "100%" }} />
                </div>

                <div style={{ gridColumn: "1 / -1" }}>
                  <label style={{ fontSize: 13, display: "flex", alignItems: "center", gap: 6 }}>
                    <input type="checkbox" checked={form.agreedTerms} onChange={(e) => setForm({ ...form, agreedTerms: e.target.checked })} />
                    This affiliate has agreed to the commission terms *
                  </label>
                </div>
              </div>

              {addErr && <div className="banner bad" style={{ marginTop: 14 }}>{addErr}</div>}
              <button className="btn-cta" style={{ marginTop: 16 }} disabled={addBusy} onClick={submitAdd}>{addBusy ? "Creating…" : "Create affiliate"}</button>
            </div>
          )}

          <div className="card" style={{ padding: 0, overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr>
              <th style={th}>Name / Email</th><th style={th}>Type</th><th style={th}>Status</th><th style={th}>Tier</th>
              <th style={th}>This month</th><th style={th}>Lifetime paid</th><th style={th}>Flags</th><th style={th}>Link / Code</th><th style={th}>Action</th>
            </tr></thead>
            <tbody>
              {affiliates.map((a) => (
                <tr key={a.affiliate_id}>
                  <td style={td}><b>{a.first_name}</b><br /><span className="faint">{a.email}</span></td>
                  <td style={td}>{a.type}</td>
                  <td style={td}><span className="pill">{a.status}</span></td>
                  <td style={td}>{a.tier}</td>
                  <td style={td}>{a.this_month_referrals}</td>
                  <td style={td}>{money(a.lifetime_paid_inr)}</td>
                  <td style={td}>{a.active_flag_count > 0 ? <span style={{ color: "var(--bad)" }}>{a.active_flag_count} active / {a.total_flag_count} total</span> : a.total_flag_count}</td>
                  <td style={td}>{a.link_slug ? `/r/${a.link_slug}` : "—"}{a.code_string ? ` · ${a.code_string}` : ""}</td>
                  <td style={td}><button className="btn-ghost btn-sm" onClick={() => toggleFreeze(a)}>{a.status === "frozen" ? "Unfreeze" : "Freeze"}</button></td>
                </tr>
              ))}
              {affiliates.length === 0 && <tr><td style={td} colSpan={9}>No affiliates yet.</td></tr>}
            </tbody>
          </table>
          </div>
        </>
      )}

      {tab === "payouts" && (
        <div className="card" style={{ padding: 18 }}>
          <div style={{ display: "flex", gap: 10, alignItems: "center", flexWrap: "wrap" }}>
            <label className="fld" style={{ margin: 0 }}>Batch date</label>
            <input type="date" value={batchDate} onChange={(e) => { setBatchDate(e.target.value); setPreview(null); }} />
            <button className="btn-ghost btn-sm" onClick={loadPreview} disabled={!batchDate}>Preview</button>
          </div>
          {preview && (
            <>
              <div style={{ marginTop: 16, marginBottom: 10, fontWeight: 700, fontSize: 13.5 }}>
                {preview.length} entries eligible · {money(preview.reduce((s, p) => s + Number(p.amount_inr), 0))} total
              </div>
              {preview.length > 0 && (
                <div style={{ overflowX: "auto" }}>
                  <table style={{ width: "100%", borderCollapse: "collapse" }}>
                    <thead><tr><th style={th}>Affiliate</th><th style={th}>Booking</th><th style={th}>Amount (INR)</th></tr></thead>
                    <tbody>
                      {preview.map((p) => (
                        <tr key={p.commission_ledger_id}><td style={td}>#{p.affiliate_id}</td><td style={td}>#{p.booking_id}</td><td style={td}>{money(p.amount_inr)}</td></tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
              {preview.length > 0 && <button className="btn-cta btn-sm" style={{ marginTop: 14 }} onClick={finalizeBatch}>Finalize batch</button>}
            </>
          )}
          <div className="faint" style={{ fontSize: 11.5, marginTop: 14 }}>
            Finalizing marks entries "paid" for tracking — it does not move money. Send the actual transfer manually per your payout_details on file.
          </div>
        </div>
      )}

      {tab === "reports" && (
        <div className="card" style={{ padding: 0, overflowX: "auto" }}>
          <div style={{ padding: "14px 18px 0" }}>
            <h3 className="sec" style={{ fontSize: 15 }}>Mentor-steering concentration (this month)</h3>
            <p className="faint" style={{ fontSize: 12 }}>Informational only — no auto-escalation until a threshold is set in settings.</p>
          </div>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr><th style={th}>Affiliate</th><th style={th}>Top mentor</th><th style={th}>Concentration</th></tr></thead>
            <tbody>
              {steering.map((s, i) => (
                <tr key={i}><td style={td}>#{s.affiliate_id}</td><td style={td}>#{s.top_mentor_id}</td><td style={td}>{s.concentration_pct}%</td></tr>
              ))}
              {steering.length === 0 && <tr><td style={td} colSpan={3}>No referral activity this month yet.</td></tr>}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
