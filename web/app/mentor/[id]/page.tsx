"use client";
import { useEffect, useState, useMemo } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { money, myTz, fmtTime, fmtDate } from "@/lib/format";
import { getEmail, setEmail as saveEmail } from "@/lib/identity";
import { effectivePpp, setCountry as saveCountry, pppFactor, currencyForCountry } from "@/lib/ppp";
import Calendar from "@/components/Calendar";
import { isEngaged, openGroovia } from "@/lib/groovia";

type Service = { id: number; title: string; description: string; duration: number; type: string; set_price: number; platform_fee: number; set_currency: string; is_ppp: boolean; base?: number; you?: number; you0?: number };
type Slot = { slot_start: string };
const dateKey = (iso: string, tz: string) => new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(new Date(iso));
const COUNTRIES: [string, string][] = [["US","United States"],["IN","India"],["GB","United Kingdom"],["BR","Brazil"],["NL","Netherlands"],["DE","Germany"],["CA","Canada"],["AU","Australia"],["AE","UAE"],["SG","Singapore"],["JP","Japan"],["ZA","South Africa"],["NG","Nigeria"],["PH","Philippines"],["ID","Indonesia"],["MX","Mexico"]];

let rzpScriptPromise: Promise<void> | null = null;
function loadRazorpayScript(): Promise<void> {
  if (typeof window !== "undefined" && (window as unknown as { Razorpay?: unknown }).Razorpay) return Promise.resolve();
  if (rzpScriptPromise) return rzpScriptPromise;
  rzpScriptPromise = new Promise<void>((resolve, reject) => {
    const s = document.createElement("script");
    s.src = "https://checkout.razorpay.com/v1/checkout.js";
    s.onload = () => resolve();
    s.onerror = () => { rzpScriptPromise = null; reject(new Error("Could not load the payment window — check your connection and retry.")); };
    document.body.appendChild(s);
  });
  return rzpScriptPromise;
}

export default function MentorPage({ params }: { params: { id: string } }) {
  const mentorId = Number(params.id);
  const supabase = createClient();
  const tz = myTz();
  const [mc, setMc] = useState("USD");

  const [mentor, setMentor] = useState<{ name: string; title: string; pic: string; tz: string; rating: number; reviews: number } | null>(null);
  const [servicesRaw, setServicesRaw] = useState<Service[]>([]);
  const [priced, setPriced] = useState<Service[]>([]);
  const [country, setCountryS] = useState("US");
  const [detected, setDetected] = useState("US");
  const [factor, setFactor] = useState(1);
  const [suspect, setSuspect] = useState(false);
  const [svc, setSvc] = useState<Service | null>(null);
  const [slots, setSlots] = useState<Slot[]>([]);
  const [date, setDate] = useState<string | null>(null);
  const [slot, setSlot] = useState<string | null>(null);
  const [questions, setQuestions] = useState<{ id: number; question_text: string; is_required: boolean }[]>([]);
  const [answers, setAnswers] = useState<Record<number, string>>({});
  const [msg, setMsg] = useState<{ t: string; ok: boolean } | null>(null);
  const [booked, setBooked] = useState<{ when: string; email: string } | null>(null);
  const [busy, setBusy] = useState(false);
  const [loadingSlots, setLoadingSlots] = useState(false);
  const [myEmail, setMyEmail] = useState<string | null>(null);
  const [guest, setGuest] = useState({ name: "", email: "" });
  const [engaged, setEngagedS] = useState(true); // assume true until mount to avoid SSR flash
  const [payEnabled, setPayEnabled] = useState(false);

  useEffect(() => { setMyEmail(getEmail()); }, []);
  useEffect(() => { (async () => { const { data } = await supabase.rpc("public_setting", { p_key: "payments_enabled" }); setPayEnabled(String(data) === "true"); })(); }, [supabase]);
  useEffect(() => {
    setEngagedS(isEngaged());
    const on = () => setEngagedS(true);
    window.addEventListener("groovia-engaged", on);
    return () => window.removeEventListener("groovia-engaged", on);
  }, []);
  useEffect(() => { (async () => { const { country, detected, factor, suspect, currency } = await effectivePpp(); setCountryS(country); setDetected(detected); setFactor(factor); setSuspect(suspect); setMc(currency); })(); }, []);

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

  // Display prices come from the SERVER pricing engine (convert_prices). PPP + FX
  // are applied server-side; the client never computes money. The customer pays the
  // mentor's set_price (the gross) — the platform commission is deducted from the
  // mentor's payout server-side, NOT added on top of what the customer sees.
  useEffect(() => {
    (async () => {
      if (!servicesRaw.length) { setPriced([]); return; }
      const items = servicesRaw.map((s) => ({ key: String(s.id), amount: Number(s.set_price) || 0, from: s.set_currency || "USD", is_ppp: !!s.is_ppp }));
      const { data } = await supabase.rpc("convert_prices", { p_customer_country: country, p_items: items });
      const byKey: Record<string, { you: number; you0: number }> = {};
      (data || []).forEach((r: { key: string; you: number; you0: number }) => { byKey[String(r.key)] = { you: Number(r.you), you0: Number(r.you0) }; });
      const out = servicesRaw.map((s) => ({ ...s, base: Number(s.set_price) || 0, you: byKey[String(s.id)]?.you, you0: byKey[String(s.id)]?.you0 }));
      setPriced(out);
      setSvc((cur) => (cur ? out.find((x) => x.id === cur.id) || null : null));
    })();
  }, [servicesRaw, country, supabase]);

  async function changeCountry(cc: string) {
    if (cc !== detected) {
      const ok = window.confirm(`Prices are set for your detected location (${detected}). Viewing ${cc} prices may not reflect where you live — are you sure?`);
      if (!ok) return; // keep current selection
    }
    saveCountry(cc); setCountryS(cc); setMc(currencyForCountry(cc)); setFactor(await pppFactor(cc));
  }

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
    if (!isEngaged()) { setMsg({ t: "Chat with Groovia AI first to make sure this mentor fits — then you can book.", ok: false }); openGroovia(); return; }
    const email = (myEmail || guest.email).trim();
    if (!email.includes("@")) { setMsg({ t: "Please enter a valid email so we can send your confirmation.", ok: false }); return; }
    setBusy(true); setMsg(null);
    const ans = questions.map((q) => ({ question_id: q.id, answer_text: answers[q.id] || "" }));
    const svcId = svc.id, slotTime = slot;
    const finish = () => { if (!myEmail) { saveEmail(email); setMyEmail(email); } setBooked({ when: `${fmtDate(slotTime, tz)}, ${fmtTime(slotTime, tz)}`, email }); window.scrollTo({ top: 0, behavior: "smooth" }); };

    try {
      if (payEnabled) { await payAndBook(svcId, slotTime, email, ans); finish(); }
      else { await mockBook(svcId, slotTime, email, ans); finish(); }
    } catch (e) {
      const m = String((e as Error)?.message || e);
      if (m === "DISMISSED") { setMsg(null); }                 // user closed Checkout — hold expires on its own
      else if (m.includes("FX_UNAVAILABLE")) setMsg({ t: "We couldn't fetch live exchange rates just now — please try again in a moment.", ok: false });
      else if (m.includes("CONFIRMING")) setMsg({ t: "Payment received — we're confirming it. Your session will appear under ‘My sessions’ shortly.", ok: true });
      else setMsg({ t: m, ok: false });
    } finally { setBusy(false); }
  }

  // Mock path (payments disabled): server-priced quote committed instantly.
  async function mockBook(svcId: number, slotTime: string, email: string, ans: { question_id: number; answer_text: string }[]) {
    const doBook = async () => {
      const { data: quote, error: qErr } = await supabase.rpc("get_booking_quote", { p_service_id: svcId, p_customer_country: country });
      if (qErr) throw qErr;
      const { error } = await supabase.rpc("book_session_guest", {
        p_quote_id: (quote as { quote_id: string }).quote_id, p_mentor_id: mentorId, p_service_id: svcId,
        p_slot_time: slotTime, p_email: email, p_name: guest.name || null, p_timezone: tz, p_answers: ans,
      });
      if (error) throw error;
    };
    try { await doBook(); } catch (e) { if (String((e as Error)?.message || e).includes("QUOTE_EXPIRED")) await doBook(); else throw e; }
  }

  // Real path: quote → reserve+order (edge) → Razorpay Checkout → poll for webhook confirmation.
  async function payAndBook(svcId: number, slotTime: string, email: string, ans: { question_id: number; answer_text: string }[], retried = false): Promise<void> {
    const { data: quote, error: qErr } = await supabase.rpc("get_booking_quote", { p_service_id: svcId, p_customer_country: country });
    if (qErr) throw qErr;
    const { data: order, error: oErr } = await supabase.functions.invoke("razorpay-create-order", {
      body: { quote_id: (quote as { quote_id: string }).quote_id, mentor_id: mentorId, service_id: svcId, slot_time: slotTime, email, name: guest.name || null, timezone: tz, answers: ans },
    });
    if (oErr) throw new Error(oErr.message);
    if ((order as { error?: string })?.error) {
      if ((order as { code?: string }).code === "REQUOTE" && !retried) return payAndBook(svcId, slotTime, email, ans, true);
      throw new Error((order as { error: string }).error);
    }
    await loadRazorpayScript();
    await new Promise<void>((resolve, reject) => {
      const rzp = new (window as unknown as { Razorpay: new (o: unknown) => { open: () => void } }).Razorpay({
        key: order.key_id, order_id: order.order_id, amount: order.amount, currency: order.currency,
        name: "Immigroov", description: svc?.title || "Mentoring session", prefill: { email, name: guest.name || "" },
        theme: { color: "#e8622c" },
        handler: async () => {
          setMsg({ t: "Confirming payment…", ok: true });
          // Confirm via our server verifying with Razorpay (webhook-independent);
          // the webhook + cron sweep are backups. All idempotent.
          try { await supabase.functions.invoke("razorpay-verify", { body: { order_id: order.order_id } }); } catch { /* poll/backups will catch it */ }
          const okConfirmed = await pollConfirmed(order.booking_id);
          if (okConfirmed) resolve(); else reject(new Error("CONFIRMING"));
        },
        modal: { ondismiss: () => reject(new Error("DISMISSED")) },
      });
      rzp.open();
    });
  }

  async function pollConfirmed(bookingId: number): Promise<boolean> {
    for (let i = 0; i < 20; i++) {                             // ~40s: webhook is usually a few seconds
      const { data } = await supabase.rpc("booking_status", { p_booking_id: bookingId });
      if (data === "confirmed") return true;
      if (data === "cancelled" || data === "expired") return false;
      await new Promise((r) => setTimeout(r, 2000));
    }
    return false;
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
              {suspect && <span className="faint" style={{ fontSize: 11 }} title="Your IP location and device timezone disagree (possible VPN), so we apply standard pricing.">· location unverified</span>}
            </div>
          </div>
        </div>
      )}

      {booked && (
        <div className="card reveal" style={{ textAlign: "center", padding: "40px 24px", maxWidth: 520, margin: "10px auto" }}>
          <div style={{ fontSize: 42 }}>✅</div>
          <h2 className="sec" style={{ fontSize: 22, marginTop: 10 }}>You&rsquo;re booked!</h2>
          <p style={{ marginTop: 6, fontWeight: 600 }}>{svc?.title} · {booked.when}</p>
          <p className="faint" style={{ fontSize: 13, marginTop: 6 }}>Your time ({tz}) · a confirmation has been emailed to {booked.email}.</p>
          <div style={{ display: "flex", gap: 10, justifyContent: "center", marginTop: 22, flexWrap: "wrap" }}>
            <Link href="/bookings" className="btn btn-cta">View my sessions</Link>
            <button className="btn-ghost" onClick={() => { setBooked(null); setSlot(null); setMsg(null); if (svc) pickService(svc); }}>Book another time</button>
          </div>
        </div>
      )}

      {!booked && (<>
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
              <button className="btn-cta btn-lg" style={{ width: "100%", marginTop: 16 }} disabled={busy || !slot || (engaged && (reqMissing || (!myEmail && !guest.email.includes("@"))))} onClick={engaged ? book : openGroovia}>
                {busy ? "Booking…" : !slot ? "Select a time" : !engaged ? "💬 Chat with Groovia AI to book" : "Confirm booking"}
              </button>
              <div className="faint" style={{ fontSize: 11, textAlign: "center", marginTop: 8 }}>You can cancel anytime · mock payment · confirmation emailed</div>
            </>
          )}
        </div>
      </div>
      </>)}
    </div>
  );
}

function Row({ k, v }: { k: string; v: string }) {
  return <div style={{ display: "flex", justifyContent: "space-between", fontSize: 13.5, padding: "3px 0" }}><span className="muted">{k}</span><b style={{ textAlign: "right" }}>{v}</b></div>;
}
