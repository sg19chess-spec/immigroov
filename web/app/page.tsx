"use client";
import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money } from "@/lib/format";
import { effectivePpp } from "@/lib/ppp";

type Mentor = {
  mentor_id: number; name: string; title: string; profile_pic_url: string;
  avg_rating: number; review_count: number; min_price: number; currency: string;
  specializations: string[]; languages: string[]; mentor_tz: string; ppp: boolean;
  you?: number; you0?: number;
};

export default function Home() {
  const supabase = createClient();
  const [raw, setRaw] = useState<Mentor[]>([]);
  const [priced, setPriced] = useState<Mentor[]>([]);
  const [mc, setMc] = useState("USD");
  const [country, setCountry] = useState("US");
  const [factor, setFactor] = useState(1);
  const [suspect, setSuspect] = useState(false);
  const [loading, setLoading] = useState(true);
  const [spec, setSpec] = useState("All");

  useEffect(() => {
    (async () => {
      const { country, factor, suspect, currency } = await effectivePpp();
      setCountry(country); setFactor(factor); setSuspect(suspect); setMc(currency);
    })();
  }, []);

  useEffect(() => {
    (async () => {
      const { data } = await supabase.rpc("search_mentors", { p_sort: "rating" });
      setRaw((data || []) as Mentor[]); setLoading(false);
    })();
  }, [supabase]);

  // Display prices via the SERVER pricing engine (convert_prices): mentor base ->
  // visitor currency, with PPP applied server-side. The client computes no money.
  useEffect(() => {
    (async () => {
      if (!raw.length) { setPriced([]); return; }
      const items = raw.map((m) => ({ key: String(m.mentor_id), amount: m.min_price ?? 0, from: m.currency || "USD", is_ppp: !!m.ppp }));
      const { data } = await supabase.rpc("convert_prices", { p_customer_country: country, p_items: items });
      const byKey: Record<string, { you: number; you0: number }> = {};
      (data || []).forEach((r: { key: string; you: number; you0: number }) => { byKey[String(r.key)] = { you: Number(r.you), you0: Number(r.you0) }; });
      setPriced(raw.map((m) => ({
        ...m,
        you0: m.min_price != null ? byKey[String(m.mentor_id)]?.you0 : undefined,
        you: m.min_price != null ? byKey[String(m.mentor_id)]?.you : undefined,
      })));
    })();
  }, [raw, country, supabase]);

  const specs = useMemo(() => {
    const s = new Set<string>(); priced.forEach((m) => (m.specializations || []).forEach((x) => s.add(x)));
    return ["All", ...Array.from(s)];
  }, [priced]);
  const shown = spec === "All" ? priced : priced.filter((m) => (m.specializations || []).includes(spec));

  return (
    <>
      <section className="hero">
        <span className="eyebrow">1:1 immigration mentoring</span>
        <h1>Guidance from people who've<br /><span className="accent">actually done it.</span></h1>
        <p>Book a video session with vetted immigration experts — in your language, your timezone, and your currency.</p>
        <div className="trust"><span>★ 4.8 avg rating</span><span>Prices in {mc}</span><span>{suspect ? "Standard pricing (location unverified)" : `Fair pricing for ${country}`}</span><span>No subscription</span></div>
        <div className="hero-cta">
          <a href="#mentors" className="btn btn-cta btn-lg">Find your mentor</a>
          <a href="#how" className="btn btn-ghost btn-lg">How it works</a>
        </div>
      </section>

      <div className="container">
        <div className="section-head" id="mentors" style={{ scrollMarginTop: 80 }}>
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
                      <div className="price-big">{m.you != null ? `${money(m.you, mc)}` : "—"}</div>
                      {fair
                        ? <div className="faint" style={{ fontSize: 12 }}><s>{money(m.you0!, mc)}</s> · <span style={{ color: "var(--orange-d)" }}>fair price</span></div>
                        : <div className="faint" style={{ fontSize: 12 }}>from</div>}
                    </div>
                    <span className="btn btn-cta btn-sm">Book →</span>
                  </div>
                </Link>
              );
            })}
            {shown.length === 0 && <div className="empty"><div className="ico">🔍</div>No mentors match this filter.</div>}
          </div>
        )}

        {/* How it works */}
        <section className="band" id="how" style={{ scrollMarginTop: 80 }}>
          <div className="band-eyebrow">Simple from start to finish</div>
          <h2 className="band-h">How Immigroov works</h2>
          <div className="how">
            <div className="how-step reveal">
              <div className="hn">1</div>
              <h4>Find your match</h4>
              <p>Tell Groovia AI your goal and country, or browse vetted mentors. See real ratings and fair local pricing up front.</p>
            </div>
            <div className="how-step reveal" style={{ animationDelay: "80ms" }}>
              <div className="hn">2</div>
              <h4>Book a 1:1 session</h4>
              <p>Pick a time in your own timezone and pay in your currency. Get an instant confirmation and a private video link.</p>
            </div>
            <div className="how-step reveal" style={{ animationDelay: "160ms" }}>
              <div className="hn">3</div>
              <h4>Get a real plan</h4>
              <p>Meet your mentor, get personalized next steps, and keep chatting securely afterwards — no contact details exchanged.</p>
            </div>
          </div>
        </section>

        {/* Why Immigroov */}
        <section className="band">
          <div className="band-eyebrow">Why people trust us</div>
          <h2 className="band-h">Built to feel safe and fair</h2>
          <div className="why">
            <div className="why-card"><span className="ic">✅</span><h5>Vetted experts</h5><p>Mentors who have actually navigated the journey — rated and reviewed by people like you.</p></div>
            <div className="why-card"><span className="ic">🔒</span><h5>Private by design</h5><p>Chat in-app with phone numbers, emails and links automatically blocked. Your details stay yours.</p></div>
            <div className="why-card"><span className="ic">🌍</span><h5>Fair local pricing</h5><p>Prices adjust to your country and show in your currency — no surprises, no subscription.</p></div>
            <div className="why-card"><span className="ic">🔄</span><h5>Flexible &amp; protected</h5><p>Clear cancellation and reschedule rules, with refunds or credits handled transparently.</p></div>
          </div>
        </section>
      </div>
    </>
  );
}
