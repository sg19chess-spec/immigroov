"use client";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import ServicesManager from "@/components/ServicesManager";
import AvailabilityManager from "@/components/AvailabilityManager";

// Mentor console. For the demo you pick which mentor you are; in production this
// resolves from the signed-in user (current_mentor_id) and the editor RPCs are
// gated to the owning mentor.
export default function Dashboard() {
  const supabase = createClient();
  const [mentors, setMentors] = useState<{ mentor_id: number; name: string; mentor_tz: string }[]>([]);
  const [mentorId, setMentorId] = useState<number | null>(null);
  const [tz, setTz] = useState("UTC");
  const [tab, setTab] = useState<"services" | "availability">("services");

  useEffect(() => {
    supabase.rpc("search_mentors", {}).then(({ data }) => {
      const list = (data || []).map((m: any) => ({ mentor_id: m.mentor_id, name: m.name, mentor_tz: m.mentor_tz }));
      setMentors(list);
      if (list.length) { setMentorId(list[0].mentor_id); setTz(list[0].mentor_tz); }
    });
  }, []);

  return (
    <div className="container">
      <h2 className="sec">Mentor console</h2>
      <div className="card" style={{ marginBottom: 18, display: "flex", gap: 12, alignItems: "center", flexWrap: "wrap" }}>
        <label className="muted" style={{ fontSize: 13 }}>You are</label>
        <select value={mentorId ?? ""} onChange={(e) => {
          const id = Number(e.target.value); setMentorId(id);
          setTz(mentors.find((m) => m.mentor_id === id)?.mentor_tz || "UTC");
        }}>
          {mentors.map((m) => <option key={m.mentor_id} value={m.mentor_id}>{m.name} ({m.mentor_tz})</option>)}
        </select>
        <div style={{ flex: 1 }} />
        <div style={{ display: "flex", gap: 3, background: "#eef3fa", borderRadius: 999, padding: 3 }}>
          {(["services", "availability"] as const).map((t) => (
            <button key={t} onClick={() => setTab(t)}
              style={{ background: tab === t ? "var(--navy)" : "transparent", color: tab === t ? "#fff" : "var(--navy)", padding: "6px 14px", borderRadius: 999, fontSize: 13, textTransform: "capitalize" }}>
              {t}
            </button>
          ))}
        </div>
      </div>

      {mentorId && tab === "services" && <ServicesManager mentorId={mentorId} />}
      {mentorId && tab === "availability" && <AvailabilityManager mentorId={mentorId} mentorTz={tz} />}
    </div>
  );
}
