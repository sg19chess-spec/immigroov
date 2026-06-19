"use client";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { money, fx, guessCurrency, myTz, fmtTime, fmtDate } from "@/lib/format";

type Service = { id: number; title: string; description: string; duration: number; type: string; set_price: number; platform_fee: number; set_currency: string; total?: number; you?: number };

export default function MentorPage({ params }: { params: { id: string } }) {
  const mentorId = Number(params.id);
  const supabase = createClient();
  const mc = guessCurrency();
  const tz = myTz();

  const [mentorTz, setMentorTz] = useState("UTC");
  const [services, setServices] = useState<Service[]>([]);
  const [svc, setSvc] = useState<Service | null>(null);
  const [slots, setSlots] = useState<{ slot_start: string }[]>([]);
  const [slot, setSlot] = useState<string | null>(null);
  const [questions, setQuestions] = useState<{ id: number; question_text: string; is_required: boolean }[]>([]);
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [msg, setMsg] = useState<{ t: string; ok: boolean } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    (async () => {
      const { data: m } = await supabase.from("mentors").select("app_timezone").eq("id", mentorId).single();
      setMentorTz(m?.app_timezone || "UTC");
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
    setSvc(s); setSlot(null); setSlots([]);
    const from = new Date().toISOString().slice(0, 10);
    const to = new Date(Date.now() + 21 * 864e5).toISOString().slice(0, 10);
    const { data } = await supabase.rpc("get_available_slots", { p_mentor_id: mentorId, p_service_id: s.id, p_from: from, p_to: to });
    setSlots((data || []).slice(0, 24));
    const { data: q } = await supabase.rpc("demo_list_questions", { p_service_id: s.id });
    setQuestions(q || []);
    setAnswers({});
  }

  async function book() {
    if (!svc || !slot) return;
    setBusy(true); setMsg(null);
    // ensure a session (anonymous is fine)
    const { data: u } = await supabase.auth.getUser();
    if (!u.user) {
      const { error } = await supabase.auth.signInAnonymously();
      if (error) { setMsg({ t: "Could not start a session: " + error.message, ok: false }); setBusy(false); return; }
    }
    const f = await fx(svc.set_currency || "USD", mc);
    const cost = (svc.total || 0) * f.rate;
    const ans = questions.map((q) => ({ question_id: q.id, answer_text: answers[q.id] || "" }));
    const { data, error } = await supabase.rpc("book_session", {
      p_mentor_id: mentorId, p_service_id: svc.id, p_slot_time: slot,
      p_mentee_currency: mc, p_mentee_cost: cost, p_answers: ans,
    });
    setBusy(false);
    if (error) { setMsg({ t: error.message, ok: false }); return; }
    setMsg({ t: `Booked! You pay ${money(cost, mc)} · session at ${fmtTime(slot, tz)} ${fmtDate(slot, tz)} (your time).`, ok: true });
    pickService(svc); // refresh slots (booked one disappears)
  }

  return (
    <div className="container">
      <a href="/" className="muted">← All mentors</a>
      <h2 className="sec">Choose a service</h2>
      <div className="muted" style={{ fontSize: 13, marginBottom: 12 }}>Your timezone <b>{tz}</b> · Mentor timezone <b>{mentorTz}</b></div>
      {msg && <div className={`banner ${msg.ok ? "ok" : "bad"}`}>{msg.t}</div>}

      <div className="grid" style={{ gridTemplateColumns: "1fr 1fr" }}>
        {services.map((s) => (
          <div className="card" key={s.id} onClick={() => pickService(s)}
            style={{ cursor: "pointer", border: svc?.id === s.id ? "2px solid var(--orange)" : undefined }}>
            <div style={{ display: "flex", justifyContent: "space-between", gap: 10 }}>
              <div>
                <div style={{ fontWeight: 600 }}>{s.title}</div>
                <div className="muted" style={{ fontSize: 12 }}>{s.duration} min · {s.type === "video" ? "Video call" : "DM"}</div>
                {s.description && <div className="muted" style={{ fontSize: 12, marginTop: 4 }}>{s.description}</div>}
              </div>
              <div style={{ textAlign: "right", whiteSpace: "nowrap" }}>
                <div style={{ fontWeight: 700, color: "var(--orange-d)" }}>≈ {money(s.you || 0, mc)}</div>
                <div className="muted" style={{ fontSize: 11 }}>{money(s.total || 0, s.set_currency)} {s.set_currency}</div>
              </div>
            </div>
          </div>
        ))}
        {services.length === 0 && <p className="muted">No active services.</p>}
      </div>

      {svc && (
        <div className="card" style={{ marginTop: 20 }}>
          <b>{svc.title}</b> — pick a time <span className="muted">(your time, {tz})</span>
          <div style={{ marginTop: 8 }}>
            {slots.length === 0 && <span className="muted">No open slots in the next 3 weeks.</span>}
            {slots.map((sl) => (
              <span key={sl.slot_start} className={`slot ${slot === sl.slot_start ? "sel" : ""}`} onClick={() => setSlot(sl.slot_start)}>
                {fmtTime(sl.slot_start, tz)} · {fmtDate(sl.slot_start, tz)}
              </span>
            ))}
          </div>
          {questions.length > 0 && slot && (
            <div style={{ marginTop: 14 }}>
              {questions.map((q) => (
                <div key={q.id} style={{ marginBottom: 8 }}>
                  <label className="muted" style={{ fontSize: 13 }}>{q.question_text}{q.is_required ? " *" : ""}</label><br />
                  <input value={answers[q.id] || ""} onChange={(e) => setAnswers({ ...answers, [q.id]: e.target.value })} style={{ width: "100%", marginTop: 4 }} />
                </div>
              ))}
            </div>
          )}
          <div style={{ marginTop: 14 }}>
            <button className="btn-cta" disabled={!slot || busy} onClick={book}>{busy ? "Booking…" : "Confirm booking"}</button>
          </div>
        </div>
      )}
    </div>
  );
}
