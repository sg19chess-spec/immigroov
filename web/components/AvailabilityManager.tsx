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

  async function addWeekly(day: string, s: string, e: string) {
    if (!s || !e || e <= s) { setMsg("End must be after start."); return; }
    await supabase.rpc("demo_add_weekly", { p_mentor_id: mentorId, p_day: day, p_start: s, p_end: e }); load();
  }
  async function rmWeekly(id: string) { await supabase.rpc("demo_remove_weekly", { p_id: id }); load(); }
  async function saveRules() { await supabase.rpc("demo_set_rules", { p_mentor_id: mentorId, p_days_ahead: rules.days, p_min_notice_hours: rules.notice }); setMsg("Booking rules saved."); }
  async function block() { if (!sel) return; await supabase.rpc("demo_block_date", { p_mentor_id: mentorId, p_date: sel }); setMsg(`${sel} blocked.`); load(); }
  async function override() { if (!sel) return; await supabase.rpc("demo_override_date", { p_mentor_id: mentorId, p_date: sel, p_start: ovr.s, p_end: ovr.e }); setMsg(`${sel} custom hours set.`); load(); }
  async function reset() { if (!sel) return; const info = dates[sel]; if (info) for (const id of info.ids) await supabase.rpc("demo_remove_slot", { p_id: id }); setMsg(`${sel} reset to weekly.`); load(); }
  async function preview() {
    if (!prev.svc || !prev.date) { setPrev({ ...prev, out: "Pick a service and date." }); return; }
    const { data } = await supabase.rpc("get_available_slots", { p_mentor_id: mentorId, p_service_id: prev.svc, p_from: prev.date, p_to: prev.date });
    if (!data || data.length === 0) { setPrev({ ...prev, out: "No bookable slots that day." }); return; }
    setPrev({ ...prev, out: `${data.length} slots: ` + data.map((s: any) => fmtTime(s.slot_start, mentorTz)).join(", ") });
  }

  const weekdaySet = new Set(Object.keys(weekly));
  const first = new Date(cal.y, cal.m, 1);
  const lead = (first.getDay() + 6) % 7;
  const dim = new Date(cal.y, cal.m + 1, 0).getDate();
  const todayK = ymd(new Date().getFullYear(), new Date().getMonth(), new Date().getDate());
  const cells: JSX.Element[] = [];
  for (let i = 0; i < lead; i++) cells.push(<td key={"x" + i} />);
  for (let day = 1; day <= dim; day++) {
    const k = ymd(cal.y, cal.m, day); const past = k < todayK; const info = dates[k];
    const wd = DAYS[(new Date(cal.y, cal.m, day).getDay() + 6) % 7];
    let bg = "transparent"; if (info?.block) bg = "#fdecec"; else if (info?.ovr.length) bg = "var(--orange-soft)";
    cells.push(
      <td key={k} onClick={() => !past && setSel(k)}
        style={{ height: 54, border: "1px solid var(--line)", verticalAlign: "top", padding: 5, fontSize: 13, cursor: past ? "default" : "pointer", color: past ? "#c2cbd9" : undefined, background: bg, outline: k === sel ? "2px solid var(--orange)" : undefined }}>
        {day}
        {info?.block ? <div style={{ fontSize: 10, color: "#9b1c1c" }}>blocked</div>
          : info?.ovr.length ? <div style={{ fontSize: 10, color: "var(--orange-d)" }}>{info.ovr.join(", ")}</div>
          : weekdaySet.has(wd) && !past ? <span style={{ display: "inline-block", width: 6, height: 6, borderRadius: "50%", background: "var(--ok)" }} /> : null}
      </td>
    );
  }
  const rows: JSX.Element[] = [];
  for (let i = 0; i < cells.length; i += 7) rows.push(<tr key={i}>{cells.slice(i, i + 7)}</tr>);

  return (
    <div>
      {msg && <div className="banner ok">{msg}</div>}

      <div className="card">
        <h2 style={{ marginTop: 0 }}>Weekly hours <span className="muted" style={{ fontSize: 13, fontWeight: 400 }}>({mentorTz})</span></h2>
        {DAYS.map((d) => <DayRow key={d} day={d} ranges={weekly[d] || []} onAdd={addWeekly} onRemove={rmWeekly} />)}
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>Booking rules</h2>
        <div style={{ display: "flex", gap: 18, flexWrap: "wrap", alignItems: "flex-end" }}>
          <div><label className="muted" style={{ fontSize: 12 }}>Accept bookings up to</label><br /><input type="number" min={1} value={rules.days} onChange={(e) => setRules({ ...rules, days: Number(e.target.value) })} style={{ width: 90 }} /> <span className="muted">days ahead</span></div>
          <div><label className="muted" style={{ fontSize: 12 }}>Minimum notice</label><br /><input type="number" min={0} step={0.5} value={rules.notice} onChange={(e) => setRules({ ...rules, notice: Number(e.target.value) })} style={{ width: 90 }} /> <span className="muted">hours</span></div>
          <button className="btn-cta" onClick={saveRules}>Save rules</button>
        </div>
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>Date overrides</h2>
        <p className="muted" style={{ fontSize: 13, marginTop: -6 }}>Click a date to block it or set custom hours (overrides replace weekly).</p>
        <div style={{ display: "flex", alignItems: "center", gap: 12, marginBottom: 10 }}>
          <button className="btn-ghost" onClick={() => setCal(({ y, m }) => m === 0 ? { y: y - 1, m: 11 } : { y, m: m - 1 })}>‹</button>
          <b>{new Date(cal.y, cal.m, 1).toLocaleDateString("en", { month: "long", year: "numeric" })}</b>
          <button className="btn-ghost" onClick={() => setCal(({ y, m }) => m === 11 ? { y: y + 1, m: 0 } : { y, m: m + 1 })}>›</button>
        </div>
        <table style={{ width: "100%", borderCollapse: "collapse" }}>
          <thead><tr>{["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((d) => <th key={d} style={{ fontSize: 11, color: "var(--muted)", padding: 6 }}>{d}</th>)}</tr></thead>
          <tbody>{rows}</tbody>
        </table>
        {sel && (
          <div className="banner ok" style={{ display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center", marginTop: 12 }}>
            <b>{sel}</b>
            <button className="btn-ghost" onClick={block}>Block day</button>
            <span className="muted">or hours:</span>
            <input type="time" value={ovr.s} onChange={(e) => setOvr({ ...ovr, s: e.target.value })} /> –
            <input type="time" value={ovr.e} onChange={(e) => setOvr({ ...ovr, e: e.target.value })} />
            <button className="btn-cta" onClick={override}>Set</button>
            <button className="btn-ghost" onClick={reset}>Reset to weekly</button>
          </div>
        )}
      </div>

      <div className="card">
        <h2 style={{ marginTop: 0 }}>Preview bookable slots</h2>
        <div style={{ display: "flex", gap: 10, flexWrap: "wrap", alignItems: "center" }}>
          <select value={prev.svc ?? ""} onChange={(e) => setPrev({ ...prev, svc: Number(e.target.value) })}>
            <option value="">Select service</option>
            {services.map((s) => <option key={s.id} value={s.id}>{s.title} · {s.duration}m</option>)}
          </select>
          <input type="date" value={prev.date} onChange={(e) => setPrev({ ...prev, date: e.target.value })} />
          <button onClick={preview}>Show slots</button>
        </div>
        {prev.out && <p className="muted" style={{ marginTop: 10 }}>{prev.out}</p>}
      </div>
    </div>
  );
}

function DayRow({ day, ranges, onAdd, onRemove }: { day: string; ranges: Weekly[]; onAdd: (d: string, s: string, e: string) => void; onRemove: (id: string) => void }) {
  const [s, setS] = useState("09:00"); const [e, setE] = useState("17:00");
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "10px 0", borderBottom: "1px solid var(--line)", flexWrap: "wrap" }}>
      <div style={{ width: 50, fontWeight: 600 }}>{day.slice(0, 3)}</div>
      <div style={{ flex: 1, display: "flex", flexWrap: "wrap", gap: 8, alignItems: "center" }}>
        {ranges.length === 0 && <span className="muted" style={{ fontSize: 13 }}>Unavailable</span>}
        {ranges.map((r) => <span key={r.id} className="tag" style={{ fontSize: 12 }}>{hm(r.start_time)}–{hm(r.end_time)} <span style={{ color: "var(--bad)", cursor: "pointer" }} onClick={() => onRemove(r.id)}>×</span></span>)}
        <input type="time" value={s} onChange={(ev) => setS(ev.target.value)} style={{ padding: "5px 8px" }} />–
        <input type="time" value={e} onChange={(ev) => setE(ev.target.value)} style={{ padding: "5px 8px" }} />
        <button className="btn-ghost" onClick={() => onAdd(day, s, e)}>+ Add</button>
      </div>
    </div>
  );
}
