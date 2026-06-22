"use client";
import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, fx, guessCurrency, myTz, fmtTime, fmtDate } from "@/lib/format";
import { getEmail, setEmail as saveEmail } from "@/lib/identity";
import { detectCountry, setCountry as saveCountry, pppFactor } from "@/lib/ppp";
import Calendar from "@/components/Calendar";

type Service = { id: number; title: string; description: string; duration: number; type: string; set_price: number; platform_fee: number; set_currency: string; is_ppp: boolean; base?: number; you?: number; you0?: number };
type Slot = { slot_start: string };
const dateKey = (iso: string, tz: string) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
const COUNTRIES: [string, string][] = [["US","United States"],["IN","India"],["GB","United Kingdom"],["BR","Brazil"],["NL","Netherlands"],["DE","Germany"],["CA","Canada"],["AU","Australia"],["AE","UAE"],["SG","Singapore"],["JP","Japan"],["ZA","South Africa"],["NG","Nigeria"],["PH","Philippines"],["ID","Indonesia"],["MX","Mexico"]];

export default function MentorPage({ params }: { params: { id: string } }) {
  const mentorId = Number(params.id);
  const supabase = createClient();
  const mc = guessCurrency();
  const tz = myTz();

  const [mentor, setMentor] = useState<{ name: string; title: string; pic: string; tz: string; rating: number; reviews: number } | null>(null);
  const [servicesRaw, setServicesRaw] = useState<Service[]>([]);
  const [priced, setPriced] = useState<Service[]>([]);
  const [country, setCountryS] = useState("US");
  const [factor, setFactor] = useState(1);
  const [svc, setSvc] = useState<Service | null>(null);
  const [slots, setSlots] = useState<Slot[]>([]);
  const [date, setDate] = useState<string | null>(null);
  const [slot, setSlot] = useState<string | null>(null);
  const [questions, setQuestions] = useState<{ id: number; question_text: string; is_required: boolean }[]>([]);
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [msg, setMsg] = useState<{ t: string; ok: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const [loadingSlots, setLoadingSlots] = useState(false);
  const [myEmail, setMyEmail] = useState<string | null>(null);
  const [guest, setGuest] = useState({ name: "", email: "" });

  useEffect(() => { setMyEmail(getEmail()); }, []);
  useEffect(() => { (async () => { const cc = await detectCountry(); setCountryS(cc); setFactor(await pppFactor(cc)); })(); }, []);

  useEffect(() => {
    (async () => {
      const [{ data: m }, { data: prof }] = await Promise.all([
        supabase.from("mentors").select("app_timezone,title,profile_pic_url").eq("id", mentorId).single(),
        supabase.rpc("search_mentors", {}),
      ]);
      const meta = (prof || []).find((x: any) => x.mentor_id === mentorId);
      setMentor({ name: meta?.name || "Mentor", title: m?.title || "", pic: m?.profile_pic_url || "", tz: m?.app_timezone || "UTC", rating: meta?.avg_rating || 0, reviews: meta?.review_count || 0 });
      const { data } = await supabase.from("services").select("id,title,description,duration,type,set_price,platform_fee,set_currency,is_ppp").eq("mentor_id", mentorId).eq("is_active", true);
      setServicesRaw((data || []) as Service[]);
    })();
  }, [supabase, mentorId]);

  // recompute prices whenever services, PPP factor, or currency change
  useEffect(() => {
    (async () => {
      const out: Service[] = [];
      for (const s of servicesRaw) {
        const base = (Number(s.set_price) || 0) + (Number(s.platform_fee) || 0);
        const eff = s.is_ppp ? base * factor : base;
        const f = await fx(s.set_currency || "USD", mc);
        out.push({ ...s, base, you: eff * f.rate, you0: base * f.rate });
      }
      setPriced(out);
      setSvc((cur) => (cur ? out.find((x) => x.id === cur.id) || null : null));
    })();
  }, [servicesRaw, factor, mc]);

  async function changeCountry(cc: string) { saveCountry(cc); setCountryS(cc); setFactor(await pppFactor(cc)); }

  async function pickService(s: Service) {
    setSvc(s); setSlot(null); setDate(null); setSlots([]); setLoadingSlots(true); setMsg(null);
    const from = new Date().toISOString().slice(0, 10);
    const to = new Date(Date.now() + 60 * 864e5).toISOString().slice(0, 10);
    const { data } = await supabase.rpc("get_available_slots", { p_mentor_id: mentorId, p_service_id: s.id, p_from: from, p_to: to });
    setSlots((data || []) as Slot[]);
    const { data: q } = await supabase.rpc("demo_list_questions", { p_service_id: s.id });
    setQuestions(q || []); setAnswers({}); setLoadingSlots(false);
  }

  const availableDates = useMemo(() => new Set(slots.map((s) => dateKey(s.slot_start, tz))), [slots, tz]);
  const daySlots = useMemo(() => (date ? slots.filter((s) => dateKey(s.slot_start, tz) === date) : []), [slots, date, tz]);
  const reqMissing = questions.some((q) => q.is_required && !(answers[q.id] || "").trim());
  const stepN = !svc ? 1 : !slot ? 2 : 3;
  const pppOn = !!svc?.is_ppp && factor < 1;

  async function book() {
    if (!svc || !slot) return;
    const email = (myEmail || guest.email).trim();
    if (!email.includes("@")) { setMsg({ t: "Please enter a valid email so we can send your confirmation.", ok: false }); return; }
    setBusy(true); setMsg(null);
    const ans = questions.map((q) => ({ question_id: q.id, answer_text: answers[q.id] || "" }));
    const { error } = await supabase.rpc("book_session_guest", {
      p_mentor_id: mentorId, p_service_id: svc.id, p_slot_time: slot, p_mentee_currency: mc,
      p_mentee_cost: svc.you, p_email: email, p_name: guest.name || null, p_timezone: tz,
      p_answers: ans, p_ppp_factor: svc.is_ppp ? factor : 1.0,
    });
    setBusy(false);
    if (error) { setMsg({ t: error.message, ok: false }); return; }
    if (!myEmail) { saveEmail(email); setMyEmail(email); }
    setMsg({ t: `Booked for ${fmtDate(slot, tz)}, ${fmtTime(slot, tz)} (your time). Confirmation sent to ${email}.`, ok: true });
    setSlot(null); pickService(svc);
  }

  return (
    <div className="container">
      <Link href="/" className="muted" style={{ fontSize: 14 }}>← All mentors</Link>

      {mentor && (
        <div className="card reveal" style={{ display: "flex", gap: 18, alignItems: "center", margin: "16px 0 18px", flexWrap: "wrap" }}>
          <img className="avatar" src={mentor.pic || "https://i.pravatar.cc/150"} width={72} height={72} alt="" />
          <div style={{ flex: 1, minWidth: 180 }}>
            <h1 style={{ fontSize: 26, margin: 0 }}>{mentor.name}</h1>
            <div className="muted">{mentor.title}</div>
            <div className="stars" style={{ marginTop: 4, fontSize: 14 }}>★ {Number(mentor.rating).toFixed(1)} <span className="faint" style={{ fontWeight: 500 }}>({mentor.reviews} reviews)</span></div>
          </div>
          <div style={{ textAlign: "right", fontSize: 13 }}>
            <div className="lead">Your time <b>{tz}</b> · Mentor <b>{mentor.tz}</b></div>
            <div style={{ marginTop: 6, display: "inline-flex", alignItems: "center", gap: 6 }}>
              <span className="faint">🌍 Prices for</span>
              <select value={country} onChange={(e) => changeCountry(e.target.value)} style={{ padding: "5px 8px", fontSize: 13 }}>
                {COUNTRIES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}
              </select>
              {factor < 1 && <span className="tag" style={{ background: "var(--orange-soft)", color: "var(--orange-d)" }}>PPP −{Math.round((1 - factor) * 100)}%</span>}
            </div>
          </div>
        </div>
      )}

      <div className="stepper">
        <div className={`step ${stepN > 1 ? "done" : "active"}`}><span className="num">{stepN > 1 ? "✓" : "1"}</span> Service</div>
        <div className="bar" />
        <div className={`step ${stepN === 2 ? "active" : stepN > 2 ? "done" : ""}`}><span className="num">{stepN > 2 ? "✓" : "2"}</span> Date &amp; time</div>
        <div className="bar" />
        <div className={`step ${stepN === 3 ? "active" : ""}`}><span className="num">3</span> Confirm</div>
      </div>

      {msg && <div className={`banner ${msg.ok ? "ok" : "bad"}`}>{msg.t}</div>}

      <div className="grid two-col" style={{ gridTemplateColumns: "1fr 360px", alignItems: "start" }}>
        <div>
          {!svc && (
            <>
              <h2 className="sec" style={{ fontSize: 18, marginBottom: 14 }}>Choose a service</h2>
              <div style={{ display: "grid", gap: 14 }}>
                {priced.map((s) => (
                  <div className="card card-hover" key={s.id} onClick={() => pickService(s)} style={{ cursor: "pointer", display: "flex", justifyContent: "space-between", gap: 14, alignItems: "center" }}>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: 16 }}>{s.title} {s.is_ppp && factor < 1 && <span className="tag" style={{ background: "var(--orange-soft)", color: "var(--orange-d)" }}>fair price</span>}</div>
                      <div className="muted" style={{ fontSize: 13, marginTop: 3 }}>{s.duration} min · {s.type === "video" ? "Video call" : "Direct message"}{s.description ? ` · ${s.description}` : ""}</div>
                    </div>
                    <div style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                      <div className="price-big" style={{ fontSize: 20, color: "var(--orange-d)" }}>≈ {money(s.you || 0, mc)}</div>
                      {s.is_ppp && factor < 1 && <div className="faint" style={{ fontSize: 12, textDecoration: "line-through" }}>≈ {money(s.you0 || 0, mc)}</div>}
                    </div>
                  </div>
                ))}
                {priced.length === 0 && <div className="empty"><div className="ico">📭</div>No active services yet.</div>}
              </div>
            </>
          )}

          {svc && (
            <div className="card reveal">
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 16 }}>
                <h2 className="sec" style={{ fontSize: 18 }}>Pick a date &amp; time</h2>
                <button className="btn-ghost btn-sm" onClick={() => { setSvc(null); setDate(null); setSlot(null); }}>Change service</button>
              </div>
              <div className="two-col" style={{ display: "grid", gridTemplateColumns: "minmax(0,300px) 1fr", gap: 22, alignItems: "start" }}>
                <div>
                  {loadingSlots ? <div className="skel" style={{ height: 300 }} />
                    : availableDates.size === 0 ? <div className="empty" style={{ padding: "30px 10px" }}><div className="ico">🗓️</div>No openings in 60 days.</div>
                    : <Calendar available={availableDates} selected={date} onSelect={(d) => { setDate(d); setSlot(null); }} />}
                </div>
                <div>
                  {!date && <div className="faint" style={{ fontSize: 14, paddingTop: 8 }}>← Select a highlighted date to see open times.</div>}
                  {date && (
                    <>
                      <b style={{ fontSize: 15 }}>{new Intl.DateTimeFormat("en", { weekday: "long", month: "long", day: "numeric" }).format(new Date(date + "T12:00:00"))}</b>
                      <div className="faint" style={{ fontSize: 12, margin: "2px 0 12px" }}>{daySlots.length} open · your time</div>
                      <div className="slotgrid">
                        {daySlots.map((sl) => (
                          <div key={sl.slot_start} className={`slot ${slot === sl.slot_start ? "sel" : ""}`} onClick={() => setSlot(sl.slot_start)}>
                            {fmtTime(sl.slot_start, tz)}<small>mentor {fmtTime(sl.slot_start, mentor?.tz || "UTC")}</small>
                          </div>
                        ))}
                      </div>
                    </>
                  )}
                </div>
              </div>
            </div>
          )}
        </div>

        <div className="card summary reveal">
          <div className="faint" style={{ fontSize: 12, fontWeight: 700, textTransform: "uppercase", letterSpacing: ".06em" }}>Your booking</div>
          {!svc ? <p className="muted" style={{ fontSize: 14, marginTop: 10 }}>Pick a service to get started.</p> : (
            <>
              <div style={{ fontWeight: 700, fontSize: 16, marginTop: 10 }}>{svc.title}</div>
              <div className="muted" style={{ fontSize: 13 }}>{svc.duration} min · {svc.type === "video" ? "Video call" : "Direct message"}</div>
              <div style={{ margin: "14px 0", padding: "14px 0", borderTop: "1px solid var(--line)", borderBottom: "1px solid var(--line)" }}>
                <Row k="When" v={slot ? `${fmtDate(slot, tz)}, ${fmtTime(slot, tz)}` : "—"} />
                <Row k="Mentor's time" v={slot ? fmtTime(slot, mentor?.tz || "UTC") : "—"} />
              </div>
              {pppOn && (
                <div className="faint" style={{ fontSize: 12, display: "flex", justifyContent: "space-between", marginBottom: 4 }}>
                  <span>Standard</span><span style={{ textDecoration: "line-through" }}>≈ {money(svc.you0 || 0, mc)}</span>
                </div>
              )}
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span className="muted">{pppOn ? `Your price (${country})` : "Total"}</span>
                <span className="price-big">≈ {money(svc.you || 0, mc)}</span>
              </div>
              {pppOn && <div className="faint" style={{ fontSize: 11.5, textAlign: "right", color: "var(--orange-d)" }}>Fair pricing applied · −{Math.round((1 - factor) * 100)}%</div>}

              {slot && questions.length > 0 && (
                <div style={{ marginTop: 16 }}>
                  {questions.map((q) => (
                    <div key={q.id} style={{ marginBottom: 10 }}>
                      <label className="fld">{q.question_text}{q.is_required ? " *" : ""}</label>
                      <input value={answers[q.id] || ""} onChange={(e) => setAnswers({ ...answers, [q.id]: e.target.value })} style={{ width: "100%" }} />
                    </div>
                  ))}
                </div>
              )}
              {slot && !myEmail && (
                <div style={{ marginTop: 16, paddingTop: 14, borderTop: "1px solid var(--line)" }}>
                  <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 8 }}>Booking as a guest</div>
                  <label className="fld">Your name</label>
                  <input value={guest.name} onChange={(e) => setGuest({ ...guest, name: e.target.value })} placeholder="Optional" style={{ width: "100%", marginBottom: 10 }} />
                  <label className="fld">Email — we'll send your confirmation here *</label>
                  <input type="email" value={guest.email} onChange={(e) => setGuest({ ...guest, email: e.target.value })} placeholder="you@email.com" style={{ width: "100%" }} />
                </div>
              )}
              <button className="btn-cta btn-lg" style={{ width: "100%", marginTop: 16 }} disabled={!slot || busy || reqMissing || (!myEmail && !guest.email.includes("@"))} onClick={book}>
                {busy ? "Booking…" : !slot ? "Select a time" : "Confirm booking"}
              </button>
              <div className="faint" style={{ fontSize: 11, textAlign: "center", marginTop: 8 }}>You can cancel anytime · mock payment · confirmation emailed</div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return <div style={{ display: "flex", justifyContent: "space-between", fontSize: 13.5, padding: "3px 0" }}><span className="muted">{k}</span><b style={{ textAlign: "right" }}>{v}</b></div>;
}
