"use client";
import { useEffect, useState } from "react";
import { useParams } from "next/navigation";
import { createClient } from "@/lib/supabase/client";

type ExistingReview = {
  rating: number; title: string | null; review: string | null; status: string;
  created_at: string; editable: boolean;
};
type TokenInfo = {
  booking_id: number; mentor_name: string; service_title: string | null;
  expired: boolean; existing_review: ExistingReview | null;
};
type PageState = "loading" | "invalid" | "expired" | "form" | "readonly" | "submitted";

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
  const [submittedStatus, setSubmittedStatus] = useState<string | null>(null);

  useEffect(() => {
    if (!token) return;
    (async () => {
      const { data, error } = await supabase.rpc("get_review_token_info", { p_token: token });
      if (error) { setPageState("invalid"); return; }
      const d = data as TokenInfo;
      setInfo(d);
      if (d.expired) { setPageState("expired"); return; }
      if (d.existing_review) {
        setRating(d.existing_review.rating);
        setTitle(d.existing_review.title || "");
        setReview(d.existing_review.review || "");
        setPageState(d.existing_review.editable ? "form" : "readonly");
      } else {
        setPageState("form");
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [token]);

  async function handleSubmit() {
    if (rating < 1) { setErr("Please pick a star rating."); return; }
    setBusy(true); setErr(null);
    const isEdit = !!info?.existing_review;
    const { data, error } = await supabase.rpc(isEdit ? "edit_review" : "submit_review", {
      p_token: token, p_rating: rating, p_title: title.trim() || null, p_review: review.trim() || null,
    });
    setBusy(false);
    if (error) { setErr(error.message); return; }
    setSubmittedStatus((data as { status: string }).status);
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

        {pageState === "readonly" && info?.existing_review && (
          <>
            <h2 className="sec">Your review</h2>
            <div style={{ fontSize: 28, margin: "10px 0" }}>{"★".repeat(info.existing_review.rating)}{"☆".repeat(5 - info.existing_review.rating)}</div>
            {info.existing_review.title && <p style={{ fontWeight: 700 }}>{info.existing_review.title}</p>}
            <p className="muted">{info.existing_review.review}</p>
            <p className="faint" style={{ fontSize: 12, marginTop: 10 }}>The edit window for this review has closed.</p>
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
              {busy ? "Submitting…" : info.existing_review ? "Save changes" : "Submit review"}
            </button>
          </>
        )}

        {pageState === "submitted" && (
          <>
            <div style={{ fontSize: 42 }}>✅</div>
            <h2 className="sec" style={{ marginTop: 10 }}>Review submitted!</h2>
            {submittedStatus === "published"
              ? <p className="muted">Thanks — your review is live now.</p>
              : <p className="muted">Thanks — your review is being reviewed and will appear shortly once approved.</p>}
          </>
        )}
      </div>
    </div>
  );
}
