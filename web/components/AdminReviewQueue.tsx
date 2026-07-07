"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

type PendingReview = {
  review_id: number; booking_id: number; rating: number; title: string | null; review: string | null;
  customer_email: string | null; mentor_name: string; created_at: string;
};

const th: React.CSSProperties = { textAlign: "left", padding: "9px 12px", fontSize: 11.5, textTransform: "uppercase", letterSpacing: ".04em", color: "var(--muted)", borderBottom: "1px solid var(--line)", whiteSpace: "nowrap" };
const td: React.CSSProperties = { padding: "9px 12px", fontSize: 13, borderBottom: "1px solid var(--line)", verticalAlign: "top" };

// Only 1-3* reviews ever reach here — 4-5* auto-publish and never enter this queue.
export default function AdminReviewQueue() {
  const supabase = createClient();
  const [rows, setRows] = useState<PendingReview[]>([]);
  const [loading, setLoading] = useState(true);
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    setLoading(true);
    const { data, error } = await supabase.rpc("admin_reviews_queue");
    if (error) setMsg(error.message); else setRows((data as PendingReview[]) || []);
    setLoading(false);
  }, [supabase]);
  useEffect(() => { load(); }, [load]);

  async function moderate(reviewId: number, decision: "approve" | "reject") {
    const { error } = await supabase.rpc("admin_moderate_review", { p_review_id: reviewId, p_decision: decision });
    if (error) window.alert(error.message); else load();
  }

  if (loading) return <p className="muted">Loading…</p>;

  return (
    <div>
      {msg && <div className="banner bad" style={{ marginBottom: 14 }}>{msg}</div>}
      <h3 className="sec" style={{ fontSize: 15, marginBottom: 8 }}>Pending reviews ({rows.length})</h3>
      {rows.length === 0 ? (
        <p className="muted" style={{ fontSize: 13.5 }}>Nothing awaiting review — only 1-3★ reviews land here; 4-5★ publish automatically.</p>
      ) : (
        <div className="card" style={{ padding: 0, overflowX: "auto" }}>
          <table style={{ width: "100%", borderCollapse: "collapse" }}>
            <thead><tr>
              <th style={th}>Stars</th><th style={th}>Customer</th><th style={th}>Mentor</th>
              <th style={th}>Review</th><th style={th}>Submitted</th><th style={th}>Decision</th>
            </tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.review_id}>
                  <td style={td}>{"★".repeat(r.rating)}{"☆".repeat(5 - r.rating)}</td>
                  <td style={td}>{r.customer_email || "—"}</td>
                  <td style={td}>{r.mentor_name}</td>
                  <td style={td}>{r.title && <b>{r.title}</b>}{r.title && <br />}{r.review}</td>
                  <td style={td}>{new Date(r.created_at).toLocaleDateString()}</td>
                  <td style={td}>
                    <div style={{ display: "flex", gap: 6 }}>
                      <button className="btn-ghost btn-sm" onClick={() => moderate(r.review_id, "approve")}>Approve</button>
                      <button className="btn-ghost btn-sm" style={{ color: "var(--bad)" }} onClick={() => moderate(r.review_id, "reject")}>Reject</button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
