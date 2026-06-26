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

const initials = (s: string) => (s || "?").trim().slice(0, 1).toUpperCase();
const fmtTime = (s: string | null) => (s ? new Date(s).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" }) : "");

export default function ChatInbox() {
  const supabase = createClient();
  const [email, setEmail] = useState<string | null>(null);
  const [convos, setConvos] = useState<Convo[]>([]);
  const [active, setActive] = useState<Convo | null>(null);
  const [narrow, setNarrow] = useState(false);

  useEffect(() => { setEmail(getEmail()); }, []);
  useEffect(() => {
    const f = () => setNarrow(window.innerWidth < 760);
    f(); window.addEventListener("resize", f); return () => window.removeEventListener("resize", f);
  }, []);

  const load = useCallback(async () => {
    if (!email) return;
    const { data } = await supabase.rpc("my_conversations", { p_email: email });
    setConvos((data as Convo[]) || []);
  }, [supabase, email]);
  useEffect(() => { load(); const t = setInterval(load, 6000); return () => clearInterval(t); }, [load]);

  if (!email) return (
    <div className="container"><div className="empty">
      Please <Link href="/login" className="link">sign in</Link> to see your chats.
    </div></div>
  );

  const showList = !narrow || !active;
  const showThread = !narrow || !!active;

  return (
    <div className="container" style={{ paddingTop: 18 }}>
      <h2 className="sec" style={{ marginBottom: 4 }}>Messages</h2>
      <div className="banner" style={{ background: "var(--navy-soft)", border: "1px solid var(--line)", color: "var(--ink,#0c1b33)", marginBottom: 14, fontSize: 13 }}>
        🔒 To keep everyone safe, <b>phone numbers, email addresses and links are automatically blocked</b> in chat. Please keep all communication inside Immigroov.
      </div>

      <div style={{ display: "flex", gap: 0, border: "1px solid var(--line)", borderRadius: "var(--r-md)", overflow: "hidden", minHeight: 460, background: "var(--surface)" }}>
        {/* Conversation list */}
        {showList && (
          <div style={{ width: narrow ? "100%" : 320, borderRight: narrow ? "none" : "1px solid var(--line)", overflowY: "auto", maxHeight: 560 }}>
            {convos.length === 0 && <div className="empty" style={{ fontSize: 13 }}>No conversations yet.</div>}
            {convos.map((c) => {
              const otherRole = c.role === "customer" ? "Mentor" : "Customer";
              const on = active?.booking_id === c.booking_id;
              return (
                <button key={c.booking_id} onClick={() => setActive(c)} style={{
                  display: "flex", gap: 10, alignItems: "center", width: "100%", textAlign: "left",
                  padding: "11px 13px", border: "none", borderBottom: "1px solid var(--line)",
                  background: on ? "var(--navy-soft)" : "transparent", cursor: "pointer",
                }}>
                  <span style={{ flexShrink: 0, width: 40, height: 40, borderRadius: "50%", background: "var(--grad-cta,#fb7321)", color: "#fff", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 800 }}>{initials(c.other_name)}</span>
                  <span style={{ flex: 1, minWidth: 0 }}>
                    <span style={{ display: "flex", justifyContent: "space-between", gap: 6 }}>
                      <b style={{ fontSize: 14, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>{c.other_name}</b>
                      <span className="faint" style={{ fontSize: 10.5, whiteSpace: "nowrap" }}>{fmtTime(c.last_at)}</span>
                    </span>
                    <span style={{ display: "flex", justifyContent: "space-between", gap: 6, alignItems: "center" }}>
                      <span className="faint" style={{ fontSize: 12, whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis" }}>
                        <span className="pill" style={{ fontSize: 9, padding: "1px 6px", marginRight: 5 }}>{otherRole}</span>
                        {c.last_body || c.service_title}
                      </span>
                      {c.unread > 0 && <span style={{ flexShrink: 0, background: "var(--grad-cta,#fb7321)", color: "#fff", borderRadius: 999, fontSize: 10.5, fontWeight: 800, padding: "1px 7px" }}>{c.unread}</span>}
                    </span>
                  </span>
                </button>
              );
            })}
          </div>
        )}

        {/* Active thread */}
        {showThread && (
          <div style={{ flex: 1, display: "flex", flexDirection: "column", minWidth: 0 }}>
            {!active ? (
              <div className="empty" style={{ margin: "auto", fontSize: 13 }}>Select a conversation to start chatting.</div>
            ) : (
              <>
                <div style={{ display: "flex", alignItems: "center", gap: 10, padding: "12px 14px", borderBottom: "1px solid var(--line)" }}>
                  {narrow && <button className="btn-ghost btn-sm" onClick={() => setActive(null)}>←</button>}
                  <span style={{ width: 34, height: 34, borderRadius: "50%", background: "var(--grad-cta,#fb7321)", color: "#fff", display: "flex", alignItems: "center", justifyContent: "center", fontWeight: 800 }}>{initials(active.other_name)}</span>
                  <span>
                    <b style={{ fontSize: 14.5 }}>{active.other_name}</b>
                    <span className="faint" style={{ fontSize: 12, display: "block" }}>
                      {active.role === "customer" ? "Your mentor" : "Your mentee"} · {active.service_title} · {active.status}
                    </span>
                  </span>
                </div>
                <div style={{ padding: "0 14px 14px" }}>
                  <ChatThread bookingId={active.booking_id} email={email} height={380} />
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}
