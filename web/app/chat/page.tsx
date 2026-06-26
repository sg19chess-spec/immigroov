"use client";
import { useEffect, useState, useCallback } from "react";
import Link from "next/link";
import { createClient } from "@/lib/supabase/client";
import { getEmail } from "@/lib/identity";
import ChatThread from "@/components/ChatThread";

type Convo = {
  booking_id: number; role: string; other_name: string; service_title: string; status: string;
  last_body: string | null; last_at: string | null; unread: number;
};
type Identity = { mentor_id: number; name: string; email: string };

const initials = (s: string) => (s || "?").trim().slice(0, 1).toUpperCase();
const fmtTime = (s: string | null) => (s ? new Date(s).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "");

export default function ChatInbox() {
  const supabase = createClient();
  const [myEmail, setMyEmail] = useState<string | null>(null);
  const [mentors, setMentors] = useState<Identity[]>([]);
  const [asEmail, setAsEmail] = useState<string>("");          // active identity
  const [convos, setConvos] = useState<Convo[]>([]);
  const [active, setActive] = useState<Convo | null>(null);
  const [narrow, setNarrow] = useState(false);

  useEffect(() => {
    const e = getEmail(); setMyEmail(e); setAsEmail(e || "");
    supabase.rpc("demo_mentor_identities").then(({ data }) => setMentors((data as Identity[]) || []));
  }, [supabase]);
  useEffect(() => {
    const f = () => setNarrow(window.innerWidth < 760); f();
    window.addEventListener("resize", f); return () => window.removeEventListener("resize", f);
  }, []);

  const load = useCallback(async () => {
    if (!asEmail) return;
    const { data } = await supabase.rpc("my_conversations", { p_email: asEmail });
    setConvos((data as Convo[]) || []);
  }, [supabase, asEmail]);
  useEffect(() => { setActive(null); load(); const t = setInterval(load, 6000); return () => clearInterval(t); }, [load]);

  if (!myEmail) return (
    <div className="container"><div className="empty">Please <Link href="/login" className="link">sign in</Link> to see your chats.</div></div>
  );

  const showList = !narrow || !active;
  const showThread = !narrow || !!active;
  const asMentor = mentors.find((m) => m.email === asEmail);

  return (
    <div className="container" style={{ paddingTop: 18 }}>
      <div className="section-head" style={{ alignItems: "center" }}>
        <div>
          <h2 className="sec" style={{ marginBottom: 2 }}>Messages</h2>
          <div className="lead" style={{ fontSize: 13.5 }}>All your conversations in one place.</div>
        </div>
        <label className="fld" style={{ minWidth: 220 }}>View as
          <select value={asEmail} onChange={(e) => setAsEmail(e.target.value)}>
            <option value={myEmail}>You — mentee ({myEmail})</option>
            {mentors.map((m) => <option key={m.mentor_id} value={m.email}>{m.name} — mentor</option>)}
          </select>
        </label>
      </div>

      <div style={{ display: "flex", alignItems: "center", gap: 8, background: "#fff7ef", border: "1px solid #f6d9bf", color: "#7a3e00", borderRadius: 12, padding: "10px 14px", margin: "10px 0 16px", fontSize: 13 }}>
        <span style={{ fontSize: 18 }}>🔒</span>
        <span>For everyone's safety, <b>phone numbers, emails and links are automatically blocked</b> in chat — keep all communication inside Immigroov.</span>
      </div>

      <div style={{ display: "flex", border: "1px solid var(--line)", borderRadius: 16, overflow: "hidden", height: 600, background: "var(--surface)", boxShadow: "var(--sh-xs)" }}>
        {showList && (
          <div style={{ width: narrow ? "100%" : 340, borderRight: narrow ? "none" : "1px solid var(--line)", overflowY: "auto", background: "var(--surface)" }}>
            <div style={{ padding: "12px 16px", borderBottom: "1px solid var(--line)", fontWeight: 800, fontSize: 13, color: "var(--navy2,#15375f)", position: "sticky", top: 0, background: "var(--surface)", zIndex: 1 }}>
              {asMentor ? `${asMentor.name}'s chats (mentor)` : "Your chats (mentee)"}
            </div>
            {convos.length === 0 && <div className="empty" style={{ fontSize: 13 }}>No conversations yet.</div>}
            {convos.map((c) => {
              const otherRole = c.role === "customer" ? "Mentor" : "Customer";
              const on = active?.booking_id === c.booking_id;
              return (
                <button key={c.booking_id} onClick={() => setActive(c)} style={{
                  display: "flex", gap: 11, alignItems: "center", width: "100%", textAlign: "left",
                  padding: "12px 14px", border: "none", borderBottom: "1px solid var(--line)",
                  background: on ? "var(--navy-soft)" : "transparent", cursor: "pointer", transition: "background .12s",
                }}>
                  <span style={{ flexShrink: 0, width: 44, height: 44, borderRadius: "50%", background: "var(--grad-cta,#fb7321)", color: "#fff", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 800, fontSize: 17 }}>{initials(c.other_name)}</span>
                  <span style={{ flex: 1, minWidth: 0 }}>
                    <span style={{ display: "flex", justifyContent: "space-between", gap: 6 }}>
                      <b style={{ fontSize: 14.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.other_name}</b>
                      <span className="faint" style={{ fontSize: 10.5, whiteSpace: "nowrap" }}>{fmtTime(c.last_at)}</span>
                    </span>
                    <span style={{ display: "flex", justifyContent: "space-between", gap: 6, alignItems: "center", marginTop: 2 }}>
                      <span className="faint" style={{ fontSize: 12.5, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis", display: "flex", alignItems: "center", gap: 5 }}>
                        <span className="pill" style={{ fontSize: 9, padding: "1px 6px" }}>{otherRole}</span>
                        {c.last_body || <span style={{ fontStyle: "italic" }}>{c.service_title}</span>}
                      </span>
                      {c.unread > 0 && <span style={{ flexShrink: 0, background: "#25d366", color: "#fff", borderRadius: 999, fontSize: 10.5, fontWeight: 800, padding: "1px 7px" }}>{c.unread}</span>}
                    </span>
                  </span>
                </button>
              );
            })}
          </div>
        )}

        {showThread && (
          <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
            {!active ? (
              <div className="empty" style={{ margin: "auto", fontSize: 13.5, textAlign: "center" }}>
                <div style={{ fontSize: 40, marginBottom: 8 }}>💬</div>
                Select a conversation to start chatting.
              </div>
            ) : (
              <>
                <div style={{ display: "flex", alignItems: "center", gap: 11, padding: "12px 16px", borderBottom: "1px solid var(--line)", background: "var(--surface)" }}>
                  {narrow && <button className="btn-ghost btn-sm" onClick={() => setActive(null)}>←</button>}
                  <span style={{ width: 38, height: 38, borderRadius: "50%", background: "var(--grad-cta,#fb7321)", color: "#fff", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 800 }}>{initials(active.other_name)}</span>
                  <span>
                    <b style={{ fontSize: 15 }}>{active.other_name}</b>
                    <span className="faint" style={{ fontSize: 12, display: "block" }}>
                      {active.role === "customer" ? "Your mentor" : "Your mentee"} · {active.service_title} · {active.status}
                    </span>
                  </span>
                </div>
                <div style={{ flex: 1, padding: "0 14px 14px", overflow: "hidden" }}>
                  <ChatThread bookingId={active.booking_id} email={asEmail} height={430} />
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
