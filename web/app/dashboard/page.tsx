"use client";
import { useEffect, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";
import ServicesManager from "@/components/ServicesManager";
import AvailabilityManager from "@/components/AvailabilityManager";
import SessionsManager from "@/components/SessionsManager";
import ResourcesManager from "@/components/ResourcesManager";

// Mentor console. For the demo you pick which mentor you are; in production this
// resolves from the signed-in user (current_mentor_id) and the editor RPCs are
// gated to the owning mentor.
export default function Dashboard() {
  const supabase = createClient();
  const [mentors, setMentors] = useState<{ mentor_id: number; name: string; mentor_tz: string }[]>([]);
  const [mentorId, setMentorId] = useState<number | null>(null);
  const [tz, setTz] = useState("UTC");
  const [tab, setTab] = useState<"services" | "availability" | "sessions" | "resources">("services");
  const [stats, setStats] = useState({ services: 0, active: 0, days: 0, currency: "USD" });

  useEffect(() => {
    supabase.rpc("search_mentors", {}).then(({ data }) => {
      const list = (data || []).map((m: any) => ({ mentor_id: m.mentor_id, name: m.name, mentor_tz: m.mentor_tz }));
      setMentors(list);
      if (list.length) { setMentorId(list[0].mentor_id); setTz(list[0].mentor_tz); }
    });
  }, []);

  const loadStats = useCallback(async (id: number) => {
    const [{ data: svc }, { data: wk }] = await Promise.all([
      supabase.rpc("demo_list_services", { p_mentor_id: id }),
      supabase.rpc("demo_list_weekly", { p_mentor_id: id }),
    ]);
    setStats({
      services: (svc || []).length,
      active: (svc || []).filter((s: any) => s.is_active).length,
      days: new Set((wk || []).map((w: any) => w.weekday)).size,
      currency: (svc || [])[0]?.set_currency || "USD",
    });
  }, [supabase]);
  useEffect(() => { if (mentorId) loadStats(mentorId); }, [mentorId, tab, loadStats]);

  return (
    <div className="container">
      <div className="section-head">
        <div>
          <h2 className="sec">Mentor console</h2>
          <div className="lead">Manage your services and availability.</div>
        </div>
        <select className="full-sm" value={mentorId ?? ""} onChange={(e) => { const id = Number(e.target.value); setMentorId(id); setTz(mentors.find((m) => m.mentor_id === id)?.mentor_tz || "UTC"); }}>
          {mentors.map((m) => <option key={m.mentor_id} value={m.mentor_id}>{m.name} ({m.mentor_tz})</option>)}
        </select>
      </div>

      <div className="stats reveal" style={{ marginBottom: 22 }}>
        <div className="stat"><div className="n">{stats.services}</div><div className="l">Services</div></div>
        <div className="stat"><div className="n" style={{ color: "var(--ok)" }}>{stats.active}</div><div className="l">Active &amp; bookable</div></div>
        <div className="stat"><div className="n">{stats.days}<span style={{ fontSize: 15, color: "var(--muted)" }}>/7</span></div><div className="l">Days with weekly hours</div></div>
        <div className="stat"><div className="n" style={{ fontSize: 20 }}>{stats.currency}</div><div className="l">Payout currency · {tz}</div></div>
      </div>

      <div style={{ marginBottom: 20 }}>
        <div className="seg">
          {(["services", "availability", "sessions", "resources"] as const).map((t) => (
            <button key={t} className={tab === t ? "on" : ""} onClick={() => setTab(t)} style={{ textTransform: "capitalize" }}>{t}</button>
          ))}
        </div>
      </div>

      {mentorId && tab === "services" && <div className="reveal"><ServicesManager mentorId={mentorId} /></div>}
      {mentorId && tab === "availability" && <div className="reveal"><AvailabilityManager mentorId={mentorId} mentorTz={tz} /></div>}
      {mentorId && tab === "sessions" && <div className="reveal"><SessionsManager mentorId={mentorId} mentorTz={tz} /></div>}
      {tab === "resources" && <div className="reveal"><ResourcesManager /></div>}
    </div>
  );
}
