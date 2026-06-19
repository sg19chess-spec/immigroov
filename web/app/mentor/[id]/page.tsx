"use client";
import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, fx, guessCurrency, myTz, fmtTime, fmtDate } from "@/lib/format";
import Calendar from "@/components/Calendar";

type Service = { id: number; title: string; description: string; duration: number; type: string; set_price: number; platform_fee: number; set_currency: string; total?: number; you?: number };
type Slot = { slot_start: string };
const dateKey = (iso: string, tz: string) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));

export default function MentorPage({ params }: { params: { id: string } }) {
  const mentorId = Number(params.id);
  const supabase = createClient();
  const mc = guessCurrency();
  const tz = myTz();

  const [mentor, setMentor] = useState<{ name: string; title: string; pic: string; tz: string; rating: number; reviews: number } | null>(null);
  const [services, setServices] = useState<Service[]>([]);
  const [svc, setSvc] = useState<Service | null>(null);
  const [slots, setSlots] = useState<Slot[]>([]);
  const [date, setDate] = useState<string | null>(null);
  const [slot, setSlot] = useState<string | null>(null);
  const [questions, setQuestions] = useState<{ id: number; question_text: string; is_required: boolean }[]>([]);
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [msg, setMsg] = useState<{ t: string; ok: boolean } | null>(null);
  const [busy, setBusy] = useState(false);
  const [loadingSlots, setLoadingSlots] = useState(false);

  useEffect(() => {
    (async () => {
      const [{ data: m }, { data: prof }] = await Promise.all([
        supabase.from("mentors").select("app_timezone,title,profile_pic_url").eq("id", mentorId).single(),
        supabase.rpc("search_mentors", {}),
      ]);
      const meta = (prof || []).find((x: any) => x.mentor_id === mentorId);
      setMentor({ name: meta?.name || "Mentor", title: m?.title || "", pic: m?.profile_pic_url || "", tz: m?.app_timezone || "UTC", rating: meta?.avg_rating || 0, reviews: meta?.review_count || 0 });
      const { data } = await supabase.from("services").select("id,title,description,duration,type,set_price,platform_fee,set_currency").eq("mentor_id", mentorId).eq("is_active", true);
      const list = (data || []) as Service[];
      for (const s of list) { s.total = (Number(s.set_price) || 0) + (Number(s.platform_fee) || 0); const f = await fx(s.set_currency || "USD", mc); s.you = s.total * f.rate; }
      setServices(list);
    })();
  }, [supabase, mentorId, mc]);

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

  async function book() {
    if (!svc || !slot) return;
    setBusy(true); setMsg(null);
    const { data: u } = await supabase.auth.getUser();
    if (!u.user) { const { error } = await supabase.auth.signInAnonymously(); if (error) { setMsg({ t: "Could not start a session: " + error.message, ok: false }); setBusy(false); return; } }
    const f = await fx(svc.set_currency || "USD", mc);
    const cost = (svc.total || 0) * f.rate;
    const ans = questions.map((q) => ({ question_id: q.id, answer_text: answers[q.id] || "" }));
    const { error } = await supabase.rpc("book_session", { p_mentor_id: mentorId, p_service_id: svc.id, p_slot_time: slot, p_mentee_currency: mc, p_mentee_cost: cost, p_answers: ans });
    setBusy(false);
    if (error) { setMsg({ t: error.message, ok: false }); return; }
    setMsg({ t: `Booked! ${fmtDate(slot, tz)}, ${fmtTime(slot, tz)} (your time). See "My sessions".`, ok: true });
    setSlot(null); pickService(svc);
  }

  return (
    <div className="container">
      <Link href="/" className="muted" style={{ fontSize: 14 }}>← All mentors</Link>

      {mentor && (
        <div className="card reveal" style={{ display: "flex", gap: 18, alignItems: "center", margin: "16px 0 20px" }}>
          <img className="avatar" src={mentor.pic || "https://i.pravatar.cc/150"} width={72} height={72} alt="" />
          <div style={{ flex: 1 }}>
            <h1 style={{ fontSize: 26, margin: 0 }}>{mentor.name}</h1>
            <div className="muted">{mentor.title}</div>
            <div className="stars" style={{ marginTop: 4, fontSize: 14 }}>★ {Number(mentor.rating).toFixed(1)} <span className="faint" style={{ fontWeight: 500 }}>({mentor.reviews} reviews)</span></div>
          </div>
          <div className="lead" style={{ textAlign: "right", fontSize: 13 }}>Your time: <b>{tz}</b><br />Mentor: <b>{mentor.tz}</b></div>
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
        {/* main */}
        <div>
          {!svc && (
            <>
              <h2 className="sec" style={{ fontSize: 18, marginBottom: 14 }}>Choose a service</h2>
              <div style={{ display: "grid", gap: 14 }}>
                {services.map((s) => (
                  <div className="card card-hover" key={s.id} onClick={() => pickService(s)} style={{ cursor: "pointer", display: "flex", justifyContent: "space-between", gap: 14, alignItems: "center" }}>
                    <div>
                      <div style={{ fontWeight: 700, fontSize: 16 }}>{s.title}</div>
                      <div className="muted" style={{ fontSize: 13, marginTop: 3 }}>{s.duration} min · {s.type === "video" ? "Video call" : "Direct message"}{s.description ? ` · ${s.description}` : ""}</div>
                    </div>
                    <div style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                      <div className="price-big" style={{ fontSize: 20, color: "var(--orange-d)" }}>≈ {money(s.you || 0, mc)}</div>
                      <div className="faint" style={{ fontSize: 12 }}>{money(s.total || 0, s.set_currency)} {s.set_currency}</div>
                    </div>
                  </div>
                ))}
                {services.length === 0 && <div className="empty"><div className="ico">📭</div>No active services yet.</div>}
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
                  {availableDates.size > 0 && <div className="faint" style={{ fontSize: 12, marginTop: 14, display: "flex", gap: 7, alignItems: "center" }}><span style={{ width: 14, height: 14, borderRadius: 4, background: "#f0fbf4", border: "1px solid #c9e8d6", display: "inline-block" }} /> days with openings</div>}
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

        {/* summary / checkout */}
        <div className="card summary reveal" style={{ background: "var(--surface)" }}>
          <div className="faint" style={{ fontSize: 12, fontWeight: 700, textTransform: "uppercase", letterSpacing: ".06em" }}>Your booking</div>
          {!svc ? <p className="muted" style={{ fontSize: 14, marginTop: 10 }}>Pick a service to get started.</p> : (
            <>
              <div style={{ fontWeight: 700, fontSize: 16, marginTop: 10 }}>{svc.title}</div>
              <div className="muted" style={{ fontSize: 13 }}>{svc.duration} min · {svc.type === "video" ? "Video call" : "Direct message"}</div>
              <div style={{ margin: "14px 0", padding: "14px 0", borderTop: "1px solid var(--line)", borderBottom: "1px solid var(--line)" }}>
                <Row k="When" v={slot ? `${fmtDate(slot, tz)}, ${fmtTime(slot, tz)}` : "—"} />
                <Row k="Mentor's time" v={slot ? fmtTime(slot, mentor?.tz || "UTC") : "—"} />
              </div>
              <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center" }}>
                <span className="muted">Total</span>
                <span className="price-big">≈ {money(svc.you || 0, mc)}</span>
              </div>
              <div className="faint" style={{ fontSize: 11.5, textAlign: "right" }}>{money(svc.total || 0, svc.set_currency)} {svc.set_currency} · incl. platform fee</div>

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
              <button className="btn-cta btn-lg" style={{ width: "100%", marginTop: 16 }} disabled={!slot || busy || reqMissing} onClick={book}>
                {busy ? "Booking…" : !slot ? "Select a time" : "Confirm booking"}
              </button>
              <div className="faint" style={{ fontSize: 11, textAlign: "center", marginTop: 8 }}>You can cancel anytime · mock payment</div>
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
