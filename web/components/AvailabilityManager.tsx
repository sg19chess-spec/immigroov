"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import { fmtTime } from "@/lib/format";

const DAYS = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"];
const ymd = (y: number, m: number, d: number) => `${y}-${String(m + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;
const hm = (t: string) => (t ? String(t).slice(0, 5) : "");

type Weekly = { id: string; weekday: string; start_time: string; end_time: string };
type DateRow = { id: string; slot_date: string; start_time: string | null; end_time: string | null; is_blackout: boolean };

export default function AvailabilityManager({ mentorId, mentorTz }: { mentorId: number; mentorTz: string }) {
  const supabase = createClient();
  const [weekly, setWeekly] = useState<Record<string, Weekly[]>>({});
  const [rules, setRules] = useState({ days: 30, notice: 2 });
  const [dates, setDates] = useState<Record<string, { block: boolean; ovr: string[]; ids: string[] }>>({});
  const [cal, setCal] = useState({ y: new Date().getFullYear(), m: new Date().getMonth() });
  const [sel, setSel] = useState<string | null>(null);
  const [ovr, setOvr] = useState({ s: "10:00", e: "14:00" });
  const [services, setServices] = useState<{ id: number; title: string; duration: number }[]>([]);
  const [prev, setPrev] = useState<{ svc: number | null; date: string; out: string }>({ svc: null, date: "", out: "" });
  const [msg, setMsg] = useState<string | null>(null);

  const load = useCallback(async () => {
    const [{ data: wk }, { data: r }, { data: ds }, { data: sv }] = await Promise.all([
      supabase.rpc("demo_list_weekly", { p_mentor_id: mentorId }),
      supabase.rpc("demo_get_rules", { p_mentor_id: mentorId }),
      supabase.rpc("demo_list_slots", { p_mentor_id: mentorId }),
      supabase.rpc("demo_list_services", { p_mentor_id: mentorId }),
    ]);
    const byDay: Record<string, Weekly[]> = {};
    (wk || []).forEach((x: Weekly) => { (byDay[x.weekday] = byDay[x.weekday] || []).push(x); });
    setWeekly(byDay);
    if (r && r[0]) setRules({ days: r[0].days_ahead, notice: Number(r[0].min_notice_hours) });
    const dmap: Record<string, { block: boolean; ovr: string[]; ids: string[] }> = {};
    (ds || []).forEach((x: DateRow) => {
      const k = String(x.slot_date).slice(0, 10);
      const e = (dmap[k] = dmap[k] || { block: false, ovr: [], ids: [] });
      e.ids.push(x.id);
      if (x.is_blackout) e.block = true; else e.ovr.push(`${hm(x.start_time!)}–${hm(x.end_time!)}`);
    });
    setDates(dmap);
    setServices((sv || []).filter((s: any) => s.is_active).map((s: any) => ({ id: s.id, title: s.title, duration: s.duration })));
  }, [supabase, mentorId]);
  useEffect(() => { load(); }, [load]);

  async function addWeekly(day: string, s: string, e: string) { if (!s || !e || e <= s) { setMsg("End must be after start."); return; } await supabase.rpc("demo_add_weekly", { p_mentor_id: mentorId, p_day: day, p_start: s, p_end: e }); load(); }
  async function rmWeekly(id: string) { await supabase.rpc("demo_remove_weekly", { p_id: id }); load(); }
  async function saveRules() { await supabase.rpc("demo_set_rules", { p_mentor_id: mentorId, p_days_ahead: rules.days, p_min_notice_hours: rules.notice }); setMsg("Booking rules saved."); }
  async function block() { if (!sel) return; await supabase.rpc("demo_block_date", { p_mentor_id: mentorId, p_date: sel }); setMsg(`${sel} blocked.`); load(); }
  async function override() { if (!sel || ovr.e <= ovr.s) { setMsg("End must be after start."); return; } await supabase.rpc("demo_override_date", { p_mentor_id: mentorId, p_date: sel, p_start: ovr.s, p_end: ovr.e }); setMsg(`${sel} custom hours set.`); load(); }
  async function reset() { if (!sel) return; const info = dates[sel]; if (info) for (const id of info.ids) await supabase.rpc("demo_remove_slot", { p_id: id }); setMsg(`${sel} reset to weekly.`); load(); }
  async function preview() {
    if (!prev.svc || !prev.date) { setPrev({ ...prev, out: "Pick a service and date." }); return; }
    const { data } = await supabase.rpc("get_available_slots", { p_mentor_id: mentorId, p_service_id: prev.svc, p_from: prev.date, p_to: prev.date });
    setPrev({ ...prev, out: !data || data.length === 0 ? "No bookable slots that day." : `${data.length} slots: ` + data.map((s: any) => fmtTime(s.slot_start, mentorTz)).join(", ") });
  }

  // calendar (grid)
  const weekdaySet = new Set(Object.keys(weekly));
  const first = new Date(cal.y, cal.m, 1);
  const lead = (first.getDay() + 6) % 7;
  const dim = new Date(cal.y, cal.m + 1, 0).getDate();
  const todayK = ymd(new Date().getFullYear(), new Date().getMonth(), new Date().getDate());
  const cells: JSX.Element[] = [];
  for (let i = 0; i < lead; i++) cells.push(<div key={"e" + i} className="cal-day empty" />);
  for (let day = 1; day <= dim; day++) {
    const k = ymd(cal.y, cal.m, day); const past = k < todayK; const info = dates[k];
    const wd = DAYS[(new Date(cal.y, cal.m, day).getDay() + 6) % 7];
    const cls = ["cal-day"];
    if (k === sel) cls.push("sel"); else if (info?.block) cls.push("blk"); else if (info?.ovr.length) cls.push("ovr");
    if (past) cls.push("disabled");
    let pin = ""; if (!k.startsWith("sel")) { if (info?.block) pin = "var(--bad)"; else if (info?.ovr.length) pin = "var(--orange)"; else if (weekdaySet.has(wd) && !past) pin = "var(--ok)"; }
    cells.push(
      <button key={k} className={cls.join(" ")} disabled={past} onClick={() => setSel(k)}>
        {day}{pin && k !== sel && <span className="pin" style={{ background: pin }} />}
      </button>
    );
  }

  const info = sel ? dates[sel] : null;

  return (
    <div style={{ display: "grid", gap: 18 }}>
      {msg && <div className="banner ok">{msg}</div>}

      <div className="card">
        <h2 className="sec" style={{ fontSize: 18 }}>Weekly hours <span className="faint" style={{ fontSize: 13, fontWeight: 400 }}>· {mentorTz}</span></h2>
        {DAYS.map((d) => <DayRow key={d} day={d} ranges={weekly[d] || []} onAdd={addWeekly} onRemove={rmWeekly} />)}
      </div>

      <div className="card">
        <h2 className="sec" style={{ fontSize: 18 }}>Booking rules</h2>
        <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit,minmax(150px,1fr))", gap: 14, alignItems: "end" }}>
          <div><label className="fld">Accept up to (days ahead)</label><input type="number" min={1} value={rules.days} onChange={(e) => setRules({ ...rules, days: Number(e.target.value) })} style={{ width: "100%" }} /></div>
          <div><label className="fld">Minimum notice (hours)</label><input type="number" min={0} step={0.5} value={rules.notice} onChange={(e) => setRules({ ...rules, notice: Number(e.target.value) })} style={{ width: "100%" }} /></div>
          <button className="btn-cta full-sm" onClick={saveRules}>Save rules</button>
        </div>
      </div>

      <div className="card">
        <h2 className="sec" style={{ fontSize: 18 }}>Date overrides</h2>
        <p className="lead" style={{ marginTop: -4 }}>Tap a date to block it or set custom hours. <span style={{ color: "var(--ok)" }}>●</span> weekly <span style={{ color: "var(--orange)" }}>●</span> custom <span style={{ color: "var(--bad)" }}>●</span> blocked</p>
        <div className="cal" style={{ maxWidth: 420 }}>
          <div className="cal-head">
            <button className="btn-ghost btn-sm" onClick={() => setCal(({ y, m }) => m === 0 ? { y: y - 1, m: 11 } : { y, m: m - 1 })}>‹</button>
            <b>{new Date(cal.y, cal.m, 1).toLocaleDateString("en", { month: "long", year: "numeric" })}</b>
            <button className="btn-ghost btn-sm" onClick={() => setCal(({ y, m }) => m === 11 ? { y: y + 1, m: 0 } : { y, m: m + 1 })}>›</button>
          </div>
          <div className="cal-grid">
            {["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((d) => <div key={d} className="cal-dow">{d}</div>)}
            {cells}
          </div>
        </div>

        {sel && (
          <div className="card reveal" style={{ background: "var(--surface-2)", marginTop: 14 }}>
            <div className="row-between" style={{ marginBottom: 10 }}>
              <b>{new Intl.DateTimeFormat("en", { weekday: "long", month: "long", day: "numeric" }).format(new Date(sel + "T12:00:00"))}</b>
              <span className="muted" style={{ fontSize: 13 }}>{info?.block ? "Blocked" : info?.ovr.length ? `Custom: ${info.ovr.join(", ")}` : "Uses weekly hours"}</span>
            </div>
            <div className="actions stack-sm" style={{ alignItems: "stretch" }}>
              <button className="btn-ghost full-sm" onClick={block}>Block this day</button>
              <div className="actions" style={{ flex: 1, alignItems: "center" }}>
                <input type="time" value={ovr.s} onChange={(e) => setOvr({ ...ovr, s: e.target.value })} /> <span className="muted">to</span>
                <input type="time" value={ovr.e} onChange={(e) => setOvr({ ...ovr, e: e.target.value })} />
                <button className="btn-cta" onClick={override}>Set hours</button>
              </div>
            </div>
            {info && <button className="btn-ghost btn-sm full-sm" style={{ marginTop: 10 }} onClick={reset}>Reset to weekly</button>}
          </div>
        )}
      </div>

      <div className="card">
        <h2 className="sec" style={{ fontSize: 18 }}>Preview bookable slots</h2>
        <div className="actions stack-sm" style={{ alignItems: "stretch" }}>
          <select className="full-sm" value={prev.svc ?? ""} onChange={(e) => setPrev({ ...prev, svc: Number(e.target.value) })}>
            <option value="">Select service</option>
            {services.map((s) => <option key={s.id} value={s.id}>{s.title} · {s.duration}m</option>)}
          </select>
          <input className="full-sm" type="date" value={prev.date} onChange={(e) => setPrev({ ...prev, date: e.target.value })} />
          <button className="full-sm" onClick={preview}>Show slots</button>
        </div>
        {prev.out && <p className="muted" style={{ marginTop: 10 }}>{prev.out}</p>}
      </div>
    </div>
  );
}

function DayRow({ day, ranges, onAdd, onRemove }: { day: string; ranges: Weekly[]; onAdd: (d: string, s: string, e: string) => void; onRemove: (id: string) => void }) {
  const [s, setS] = useState("09:00"); const [e, setE] = useState("17:00"); const [open, setOpen] = useState(false);
  return (
    <div className="day-row">
      <div className="day-name">{day.slice(0, 3)}</div>
      <div style={{ flex: 1, display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
        {ranges.length === 0 && !open && <span className="faint" style={{ fontSize: 13 }}>Unavailable</span>}
        {ranges.map((r) => <span key={r.id} className="range-pill">{hm(r.start_time)}–{hm(r.end_time)} <span className="x" onClick={() => onRemove(r.id)}>×</span></span>)}
        {open ? (
          <span style={{ display: "inline-flex", gap: 6, alignItems: "center", flexWrap: "wrap" }}>
            <input type="time" value={s} onChange={(ev) => setS(ev.target.value)} style={{ padding: "7px 9px" }} />–
            <input type="time" value={e} onChange={(ev) => setE(ev.target.value)} style={{ padding: "7px 9px" }} />
            <button className="btn-cta btn-sm" onClick={() => { onAdd(day, s, e); setOpen(false); }}>Add</button>
            <button className="btn-ghost btn-sm" onClick={() => setOpen(false)}>✕</button>
          </span>
        ) : <button className="btn-ghost btn-sm" onClick={() => setOpen(true)}>+ Add hours</button>}
      </div>
    </div>
  );
}
