"use client";
import { useEffect, useState } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, fx, guessCurrency } from "@/lib/format";

type Mentor = {
  mentor_id: number; name: string; title: string; profile_pic_url: string;
  avg_rating: number; review_count: number; min_price: number; currency: string;
  specializations: string[]; languages: string[]; mentor_tz: string;
};

export default function Home() {
  const supabase = createClient();
  const [mentors, setMentors] = useState<(Mentor & { you?: number })[]>([]);
  const [mc] = useState(guessCurrency());
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.rpc("search_mentors", { p_sort: "rating" });
      const list = (data || []) as Mentor[];
      for (const m of list as any[]) {
        const f = await fx(m.currency || "USD", mc);
        m.you = m.min_price != null ? m.min_price * f.rate : null;
      }
      setMentors(list as any);
      setLoading(false);
    })();
  }, [supabase, mc]);

  return (
    <>
      <section className="hero">
        <h1>Find your immigration mentor</h1>
        <p>Book a 1:1 video session with vetted experts — in your language, timezone, and currency.</p>
      </section>
      <div className="container">
        <h2 className="sec">Available mentors</h2>
        {loading ? <p className="muted">Loading…</p> : (
          <div className="grid">
            {mentors.map((m) => (
              <div className="card" key={m.mentor_id}>
                <div style={{ display: "flex", gap: 13, alignItems: "center" }}>
                  <img src={m.profile_pic_url || "https://i.pravatar.cc/150"} width={60} height={60} style={{ borderRadius: "50%", objectFit: "cover" }} alt="" />
                  <div>
                    <div style={{ fontWeight: 600 }}>{m.name}</div>
                    <div className="muted" style={{ fontSize: 13 }}>{m.title}</div>
                    <div className="stars">★ {Number(m.avg_rating).toFixed(1)} <span className="muted" style={{ fontWeight: 400 }}>({m.review_count})</span></div>
                  </div>
                </div>
                <div style={{ margin: "10px 0" }}>{(m.specializations || []).map((s) => <span className="tag" key={s}>{s}</span>)}</div>
                <div className="muted" style={{ fontSize: 12 }}>{(m.languages || []).join(" · ")} · {m.mentor_tz}</div>
                <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginTop: 14 }}>
                  <div>
                    <div style={{ fontSize: 20, fontWeight: 700, color: "var(--orange-d)" }}>
                      {m.you != null ? `≈ ${money(m.you, mc)}` : "—"} <span className="muted" style={{ fontSize: 12, fontWeight: 400 }}>for you</span>
                    </div>
                    <div className="muted" style={{ fontSize: 12 }}>{m.min_price != null ? `${money(m.min_price, m.currency)} (${m.currency})` : ""} /from</div>
                  </div>
                  <Link href={`/mentor/${m.mentor_id}`} className="btn btn-cta" style={{ padding: "9px 14px" }}>View services</Link>
                </div>
              </div>
            ))}
            {mentors.length === 0 && <p className="muted">No mentors found.</p>}
          </div>
        )}
      </div>
    </>
  );
}
