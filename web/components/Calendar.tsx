"use client";
import { useState } from "react";

const ymd = (y: number, m: number, d: number) => `${y}-${String(m + 1).padStart(2, "0")}-${String(d).padStart(2, "0")}`;

export default function Calendar({
  available, selected, onSelect,
}: { available: Set<string>; selected: string | null; onSelect: (d: string) => void }) {
  const today = new Date();
  const [cur, setCur] = useState({ y: today.getFullYear(), m: today.getMonth() });

  const first = new Date(cur.y, cur.m, 1);
  const lead = (first.getDay() + 6) % 7; // Monday-first
  const dim = new Date(cur.y, cur.m + 1, 0).getDate();
  const todayK = ymd(today.getFullYear(), today.getMonth(), today.getDate());

  const cells: JSX.Element[] = [];
  for (let i = 0; i < lead; i++) cells.push(<div key={"e" + i} className="cal-day empty" />);
  for (let d = 1; d <= dim; d++) {
    const k = ymd(cur.y, cur.m, d);
    const avail = available.has(k);
    const past = k < todayK;
    const cls = ["cal-day"];
    if (k === selected) cls.push("sel");
    else if (avail) cls.push("avail");
    if (past || !avail) cls.push("disabled");
    if (k === todayK) cls.push("today");
    cells.push(
      <button key={k} className={cls.join(" ")} disabled={past || !avail} onClick={() => onSelect(k)}>
        {d}{avail && k !== selected && <span className="dot" />}
      </button>
    );
  }

  return (
    <div className="cal">
      <div className="cal-head">
        <button className="btn-ghost btn-sm" onClick={() => setCur((c) => (c.m === 0 ? { y: c.y - 1, m: 11 } : { y: c.y, m: c.m - 1 }))} aria-label="Previous month">‹</button>
        <b>{first.toLocaleDateString("en", { month: "long", year: "numeric" })}</b>
        <button className="btn-ghost btn-sm" onClick={() => setCur((c) => (c.m === 11 ? { y: c.y + 1, m: 0 } : { y: c.y, m: c.m + 1 }))} aria-label="Next month">›</button>
      </div>
      <div className="cal-dows">
        {["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].map((d) => <div key={d} className="cal-dow">{d}</div>)}
      </div>
      <div className="cal-grid">{cells}</div>
    </div>
  );
}
