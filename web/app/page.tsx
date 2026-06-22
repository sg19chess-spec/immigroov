"use client";
import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, fx, guessCurrency } from "@/lib/format";
import { effectivePpp } from "@/lib/ppp";

type Mentor = {
  mentor_id: number; name: string; title: string; profile_pic_url: string;
  avg_rating: number; review_count: number; min_price: number; currency: string;
  specializations: string[]; languages: string[]; mentor_tz: string; ppp: boolean;
  you?: number; you0?: number;
};

export default function Home() {
  const supabase = createClient();
  const [mentors, setMentors] = useState<Mentor[]>([]);
  const [mc] = useState(guessCurrency());
  const [loading, setLoading] = useState(true);
  const [spec, setSpec] = useState("All");
  const [country, setCountry] = useState("US");
  const [factor, setFactor] = useState(1);
  const [suspect, setSuspect] = useState(false);

  useEffect(() => {
    (async () => {
      const { country, factor, suspect } = await effectivePpp();
      setCountry(country); setFactor(factor); setSuspect(suspect);
    })();
  }, []);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.rpc("search_mentors", { p_sort: "rating" });
      const list = (data || []) as Mentor[];
      for (const m of list) {
        const f = await fx(m.currency || "USD", mc);
        const base = m.min_price != null ? m.min_price * f.rate : undefined;
        m.you0 = base;
        m.you = base != null ? (m.ppp ? base * factor : base) : undefined;
      }
      setMentors(list); setLoading(false);
    })();
  }, [supabase, mc, factor]);

  const specs = useMemo(() => {
    const s = new Set<string>(); mentors.forEach((m) => (m.specializations || []).forEach((x) => s.add(x)));
    return ["All", ...Array.from(s)];
  }, [mentors]);
  const shown = spec === "All" ? mentors : mentors.filter((m) => (m.specializations || []).includes(spec));

  return (
    <>
      <section className="hero">
        <span className="eyebrow">1:1 immigration mentoring</span>
        <h1>Guidance from people who've<br /><span className="accent">actually done it.</span></h1>
        <p>Book a video session with vetted immigration experts — in your language, your timezone, and your currency.</p>
        <div className="trust"><span>★ 4.8 avg rating</span><span>Pay in {mc}</span><span>{suspect ? "Standard pricing (location unverified)" : `Fair pricing for ${country}`}</span><span>No subscription</span></div>
      </section>

      <div className="container">
        <div className="section-head">
          <h2 className="sec">Browse mentors</h2>
          <span className="lead">{shown.length} available</span>
        </div>

        {specs.length > 1 && (
          <div style={{ display: "flex", gap: 9, flexWrap: "wrap", marginBottom: 22 }}>
            {specs.map((s) => <button key={s} className={`chip ${spec === s ? "on" : ""}`} onClick={() => setSpec(s)}>{s}</button>)}
          </div>
        )}

        {loading ? (
          <div className="grid">{[0, 1, 2].map((i) => <div key={i} className="skel" style={{ height: 250 }} />)}</div>
        ) : (
          <div className="grid">
            {shown.map((m, i) => {
              const fair = m.ppp && factor < 1 && m.you0 != null;
              return (
                <Link href={`/mentor/${m.mentor_id}`} key={m.mentor_id} className="card card-hover reveal" style={{ animationDelay: `${i * 60}ms`, display: "block", color: "inherit" }}>
                  <div style={{ display: "flex", gap: 14, alignItems: "center" }}>
                    <img className="avatar" src={m.profile_pic_url || "https://i.pravatar.cc/150"} width={62} height={62} alt="" />
                    <div style={{ minWidth: 0 }}>
                      <div style={{ fontWeight: 700, fontSize: 16.5 }}>{m.name}</div>
                      <div className="muted" style={{ fontSize: 13, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>{m.title}</div>
                      <div className="stars" style={{ marginTop: 3, fontSize: 13.5 }}>★ {Number(m.avg_rating).toFixed(1)} <span className="faint" style={{ fontWeight: 500 }}>({m.review_count})</span></div>
                    </div>
                  </div>
                  <div style={{ margin: "14px 0 10px", minHeight: 26 }}>{(m.specializations || []).slice(0, 3).map((s) => <span className="tag" key={s}>{s}</span>)}</div>
                  <div className="faint" style={{ fontSize: 12 }}>🌐 {(m.languages || []).join(", ")}</div>
                  <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-end", marginTop: 18, paddingTop: 16, borderTop: "1px solid var(--line)" }}>
                    <div>
                      <div className="price-big">{m.you != null ? `≈ ${money(m.you, mc)}` : "—"}</div>
                      {fair
                        ? <div className="faint" style={{ fontSize: 12 }}><s>≈ {money(m.you0!, mc)}</s> · <span style={{ color: "var(--orange-d)" }}>fair price</span></div>
                        : <div className="faint" style={{ fontSize: 12 }}>{m.min_price != null ? `from ${money(m.min_price, m.currency)}` : ""}</div>}
                    </div>
                    <span className="btn btn-cta btn-sm">Book →</span>
                  </div>
                </Link>
              );
            })}
            {shown.length === 0 && <div className="empty"><div className="ico">🔍</div>No mentors match this filter.</div>}
          </div>
        )}
      </div>
    </>
  );
}
