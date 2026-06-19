"use client";
import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, fx, guessCurrency, myTz, fmtTime, fmtDate } from "@/lib/format";
import Calendar from "@/components/Calendar";

type Service = { id: number; title: string; description: string; duration: number; type: string; set_price: number; platform_fee: number; set_currency: string; total?: number; you?: number };
type Slot = { slot_start: string };

const dateKey = (iso: string, tz: string) =>
  new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));

export default function MentorPage({ params }: { params: { id: string } }) {
  const mentorId = Number(params.id);
  const supabase = createClient();
  const mc = guessCurrency();
  const tz = myTz();

  const [mentor, setMentor] = useState<{ name: string; title: string; pic: string; tz: string } | null>(null);
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
        supabase.from("mentors").select("app_timezone,title,profile_pic_url,user_id").eq("id", mentorId).single(),
        supabase.rpc("search_mentors", {}),
      ]);
      const meta = (prof || []).find((x: any) => x.mentor_id === mentorId);
      setMentor({ name: meta?.name || "Mentor", title: m?.title || "", pic: m?.profile_pic_url || "", tz: m?.app_timezone || "UTC" });
      const { data } = await supabase.from("services").select("id,title,description,duration,type,set_price,platform_fee,set_currency").eq("mentor_id", mentorId).eq("is_active", true);
      const list = (data || []) as Service[];
      for (const s of list) {
        s.total = (Number(s.set_price) || 0) + (Number(s.platform_fee) || 0);
        const f = await fx(s.set_currency || "USD", mc);
        s.you = s.total * f.rate;
      }
      setServices(list);
    })();
  }, [supabase, mentorId, mc]);

  async function pickService(s: Service) {
    setSvc(s); setSlot(null); setDate(null); setSlots([]); setLoadingSlots(true);
    const from = new Date().toISOString().slice(0, 10);
    const to = new Date(Date.now() + 60 * 864e5).toISOString().slice(0, 10);
    const { data } = await supabase.rpc("get_available_slots", { p_mentor_id: mentorId, p_service_id: s.id, p_from: from, p_to: to });
    setSlots((data || []) as Slot[]);
    const { data: q } = await supabase.rpc("demo_list_questions", { p_service_id: s.id });
    setQuestions(q || []); setAnswers({}); setLoadingSlots(false);
  }

  const availableDates = useMemo(() => new Set(slots.map((s) => dateKey(s.slot_start, tz))), [slots, tz]);
  const daySlots = useMemo(() => (date ? slots.filter((s) => dateKey(s.slot_start, tz) === date) : []), [slots, date, tz]);

  async function book() {
    if (!svc || !slot) return;
    setBusy(true); setMsg(null);
    const { data: u } = await supabase.auth.getUser();
    if (!u.user) {
      const { error } = await supabase.auth.signInAnonymously();
      if (error) { setMsg({ t: "Could not start a session: " + error.message, ok: false }); setBusy(false); return; }
    }
    const f = await fx(svc.set_currency || "USD", mc);
    const cost = (svc.total || 0) * f.rate;
    const ans = questions.map((q) => ({ question_id: q.id, answer_text: answers[q.id] || "" }));
    const { error } = await supabase.rpc("book_session", {
      p_mentor_id: mentorId, p_service_id: svc.id, p_slot_time: slot,
      p_mentee_currency: mc, p_mentee_cost: cost, p_answers: ans,
    });
    setBusy(false);
    if (error) { setMsg({ t: error.message, ok: false }); return; }
    setMsg({ t: `Booked! You pay ${money(cost, mc)} — ${fmtDate(slot, tz)}, ${fmtTime(slot, tz)} (your time). Check "My sessions".`, ok: true });
    setSlot(null);
    pickService(svc);
  }

  const reqMissing = questions.some((q) => q.is_required && !(answers[q.id] || "").trim());

  return (
    <div className="container">
      <Link href="/" className="muted" style={{ fontSize: 14 }}>← All mentors</Link>

      {mentor && (
        <div style={{ display: "flex", gap: 16, alignItems: "center", margin: "16px 0 6px" }}>
          <img src={mentor.pic || "https://i.pravatar.cc/150"} width={64} height={64} style={{ borderRadius: "50%", objectFit: "cover" }} alt="" />
          <div>
            <h1 style={{ fontSize: 24, margin: 0 }}>{mentor.name}</h1>
            <div className="muted">{mentor.title}</div>
          </div>
        </div>
      )}
      <div className="lead" style={{ marginBottom: 18 }}>Your timezone <b>{tz}</b> · Mentor timezone <b>{mentor?.tz}</b> — times below are shown in <b>your</b> timezone.</div>
      {msg && <div className={`banner ${msg.ok ? "ok" : "bad"}`}>{msg.t}</div>}

      <h2 className="sec" style={{ marginTop: 8 }}>1 · Choose a service</h2>
      <div className="grid" style={{ gridTemplateColumns: "repeat(auto-fill,minmax(260px,1fr))" }}>
        {services.map((s) => (
          <div className="card card-hover" key={s.id} onClick={() => pickService(s)}
            style={{ cursor: "pointer", border: svc?.id === s.id ? "2px solid var(--orange)" : undefined }}>
            <div style={{ fontWeight: 700, fontSize: 16 }}>{s.title}</div>
            <div className="muted" style={{ fontSize: 12.5, margin: "4px 0 10px" }}>{s.duration} min · {s.type === "video" ? "Video call" : "Direct message"}{s.description ? ` · ${s.description}` : ""}</div>
            <div className="price-big">≈ {money(s.you || 0, mc)}</div>
            <div className="muted" style={{ fontSize: 12 }}>{money(s.total || 0, s.set_currency)} {s.set_currency}</div>
          </div>
        ))}
        {services.length === 0 && <p className="muted">No active services.</p>}
      </div>

      {svc && (
        <>
          <h2 className="sec">2 · Pick a date &amp; time</h2>
          <div className="grid two-col" style={{ gridTemplateColumns: "minmax(300px,360px) 1fr", alignItems: "start" }}>
            <div className="card">
              {loadingSlots ? <div className="skel" style={{ height: 300 }} />
                : availableDates.size === 0 ? <p className="muted">No availability in the next 60 days.</p>
                : <Calendar available={availableDates} selected={date} onSelect={(d) => { setDate(d); setSlot(null); }} />}
              {availableDates.size > 0 && <div className="muted" style={{ fontSize: 12, marginTop: 12, display: "flex", gap: 6, alignItems: "center" }}><span className="cal-day avail" style={{ width: 18, height: 18, aspectRatio: "auto", display: "inline-flex" }} /> = days with openings</div>}
            </div>

            <div className="card">
              {!date && <p className="muted">Select an available date to see open times.</p>}
              {date && (
                <>
                  <b>{new Intl.DateTimeFormat("en", { weekday: "long", month: "long", day: "numeric" }).format(new Date(date + "T12:00:00"))}</b>
                  <div className="muted" style={{ fontSize: 12, marginBottom: 12 }}>{daySlots.length} open {daySlots.length === 1 ? "slot" : "slots"} · your time</div>
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fill,minmax(96px,1fr))", gap: 8 }}>
                    {daySlots.map((sl) => (
                      <div key={sl.slot_start} className={`slot ${slot === sl.slot_start ? "sel" : ""}`} onClick={() => setSlot(sl.slot_start)}>
                        {fmtTime(sl.slot_start, tz)}
                        <small>mentor {fmtTime(sl.slot_start, mentor?.tz || "UTC")}</small>
                      </div>
                    ))}
                  </div>

                  {slot && questions.length > 0 && (
                    <div style={{ marginTop: 18 }}>
                      <b style={{ fontSize: 14 }}>A few questions</b>
                      {questions.map((q) => (
                        <div key={q.id} style={{ marginTop: 10 }}>
                          <label className="fld">{q.question_text}{q.is_required ? " *" : ""}</label>
                          <input value={answers[q.id] || ""} onChange={(e) => setAnswers({ ...answers, [q.id]: e.target.value })} style={{ width: "100%" }} />
                        </div>
                      ))}
                    </div>
                  )}

                  {slot && (
                    <div style={{ marginTop: 18, display: "flex", alignItems: "center", gap: 14, flexWrap: "wrap" }}>
                      <button className="btn-cta" disabled={busy || reqMissing} onClick={book}>
                        {busy ? "Booking…" : `Confirm · ${money(svc.you || 0, mc)}`}
                      </button>
                      <span className="muted" style={{ fontSize: 13 }}>{fmtDate(slot, tz)}, {fmtTime(slot, tz)} (your time)</span>
                    </div>
                  )}
                </>
              )}
            </div>
          </div>
        </>
      )}
    </div>
  );
}
