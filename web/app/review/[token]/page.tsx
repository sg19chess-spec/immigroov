"use client";
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type TokenInfo = {
  booking_id: number; mentor_name: string; service_title: string | null;
  expired: boolean; already_submitted: boolean; rating: number | null;
};
type PageState = "loading" | "invalid" | "expired" | "form" | "submitted";

const STARS = [1, 2, 3, 4, 5];

export default function ReviewPage() {
  const params = useParams();
  const token = params?.token as string;
  const supabase = createClient();

  const [pageState, setPageState] = useState<PageState>("loading");
  const [info, setInfo] = useState<TokenInfo | null>(null);
  const [rating, setRating] = useState(0);
  const [hoverRating, setHoverRating] = useState(0);
  const [title, setTitle] = useState("");
  const [review, setReview] = useState("");
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  const [submittedRating, setSubmittedRating] = useState(0);

  useEffect(() => {
    if (!token) return;
    (async () => {
      const { data, error } = await supabase.rpc("get_review_token_info", { p_token: token });
      if (error) { setPageState("invalid"); return; }
      const d = data as TokenInfo;
      setInfo(d);
      if (d.already_submitted) { setSubmittedRating(d.rating || 0); setPageState("submitted"); return; }
      if (d.expired) { setPageState("expired"); return; }
      setPageState("form");
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  async function handleSubmit() {
    if (rating < 1) { setErr("Please pick a star rating."); return; }
    setBusy(true); setErr(null);
    const { error } = await supabase.rpc("submit_review", {
      p_token: token, p_rating: rating, p_title: title.trim() || null, p_review: review.trim() || null,
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setSubmittedRating(rating);
    setPageState("submitted");
  }

  return (
    <div className="container" style={{ maxWidth: 520 }}>
      <div className="card" style={{ textAlign: "center", padding: "32px 24px" }}>
        {pageState === "loading" && <p className="muted">Loading…</p>}

        {pageState === "invalid" && (
          <>
            <h2 className="sec">Link not recognized</h2>
            <p className="muted">This review link doesn't match a session we can find.</p>
          </>
        )}

        {pageState === "expired" && (
          <>
            <h2 className="sec">This review link has expired</h2>
            <p className="muted">Review links are only valid for a limited time after your session.</p>
          </>
        )}

        {pageState === "form" && info && (
          <>
            <h2 className="sec">How was your session with {info.mentor_name}?</h2>
            {info.service_title && <p className="muted" style={{ fontSize: 13 }}>{info.service_title}</p>}
            <div style={{ fontSize: 36, margin: "18px 0 8px", cursor: "pointer" }}>
              {STARS.map((s) => (
                <span key={s} onClick={() => setRating(s)} onMouseEnter={() => setHoverRating(s)} onMouseLeave={() => setHoverRating(0)}
                  style={{ color: s <= (hoverRating || rating) ? "var(--orange-d)" : "var(--line)" }}>★</span>
              ))}
            </div>
            <input value={title} onChange={(e) => setTitle(e.target.value)} placeholder="Title (optional)" style={{ width: "100%", marginBottom: 10 }} />
            <textarea value={review} onChange={(e) => setReview(e.target.value)} placeholder="Tell us about your experience (optional)" rows={5} style={{ width: "100%", resize: "vertical" }} />
            {err && <div className="banner bad" style={{ marginTop: 10 }}>{err}</div>}
            <button className="btn-cta btn-lg" style={{ width: "100%", marginTop: 16 }} disabled={busy} onClick={handleSubmit}>
              {busy ? "Submitting…" : "Submit review"}
            </button>
          </>
        )}

        {pageState === "submitted" && (
          <>
            <div style={{ fontSize: 32, color: "var(--orange-d)" }}>{"★".repeat(submittedRating)}{"☆".repeat(5 - submittedRating)}</div>
            <h2 className="sec" style={{ marginTop: 10 }}>Thank you for your feedback.</h2>
            <p className="muted">Your review has been received.</p>
          </>
        )}
      </div>
    </div>
  );
}
