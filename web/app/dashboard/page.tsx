"use client";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";
import { money } from "@/lib/format";

type Svc = { id: number; title: string; duration: number; type: string; set_price: number; set_currency: string; platform_fee: number; is_active: boolean };

// NOTE: this is a starter mentor dashboard. It reads a mentor by the chosen id
// for demo purposes. In production you'd resolve the mentor from the signed-in
// user (current_mentor_id) and gate the editor RPCs to the owner.
export default function Dashboard() {
  const supabase = createClient();
  const [mentors, setMentors] = useState<{ mentor_id: number; name: string }[]>([]);
  const [mentorId, setMentorId] = useState<number | null>(null);
  const [services, setServices] = useState<Svc[]>([]);

  useEffect(() => {
    supabase.rpc("search_mentors", {}).then(({ data }) => {
      setMentors((data || []).map((m: any) => ({ mentor_id: m.mentor_id, name: m.name })));
      if (data && data.length) { setMentorId(data[0].mentor_id); }
    });
  }, []);
  useEffect(() => {
    if (!mentorId) return;
    supabase.rpc("demo_list_services", { p_mentor_id: mentorId }).then(({ data }) => setServices((data || []) as Svc[]));
  }, [mentorId]);

  return (
    <div className="container">
      <h2 className="sec">Mentor dashboard</h2>
      <p className="muted" style={{ marginTop: -8 }}>
        Starter view. Full service + availability editing lives in the standalone
        availability manager for now; this is where it will be ported behind mentor auth.
      </p>
      <div className="card" style={{ marginBottom: 18 }}>
        <label className="muted" style={{ fontSize: 13 }}>Mentor</label>{" "}
        <select value={mentorId ?? ""} onChange={(e) => setMentorId(Number(e.target.value))}>
          {mentors.map((m) => <option key={m.mentor_id} value={m.mentor_id}>{m.name}</option>)}
        </select>
      </div>
      <h2 className="sec">Services</h2>
      <div className="grid">
        {services.map((s) => (
          <div className="card" key={s.id}>
            <div style={{ fontWeight: 600 }}>{s.title} {s.is_active ? "" : <span className="muted">(inactive)</span>}</div>
            <div className="muted" style={{ fontSize: 13 }}>{s.duration} min · {s.type}</div>
            <div style={{ marginTop: 8 }}>{money(s.set_price, s.set_currency)} {s.set_currency} <span className="muted">(fee {money(s.platform_fee, s.set_currency)})</span></div>
          </div>
        ))}
        {services.length === 0 && <p className="muted">No services.</p>}
      </div>
    </div>
  );
}
