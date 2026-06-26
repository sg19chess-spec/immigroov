"use client";
import { useEffect, useRef, useState, useCallback } from "react";
import { createClient } from "@/lib/supabase/client";

type Msg = { id: number; sender_role: string; body: string; created_at: string; mine: boolean };

// Masked in-app chat for one booking. Polls every 4s (Realtime can replace this once the app
// moves to Supabase Auth). Identity is the caller's email; the server checks participation.
export default function ChatThread({ bookingId, email, height = 240 }: { bookingId: number; email: string; height?: number }) {
  const supabase = createClient();
  const [msgs, setMsgs] = useState<Msg[]>([]);
  const [text, setText] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const boxRef = useRef<HTMLDivElement>(null);

  const load = useCallback(async () => {
    if (!email) return;
    const { data, error } = await supabase.rpc("list_messages", { p_booking_id: bookingId, p_email: email });
    if (error) { setErr(error.message); return; }
    setErr(null); setMsgs((data as Msg[]) || []);
  }, [supabase, bookingId, email]);

  useEffect(() => { load(); const t = setInterval(load, 4000); return () => clearInterval(t); }, [load]);
  useEffect(() => { boxRef.current?.scrollTo(0, boxRef.current.scrollHeight); }, [msgs]);

  async function send() {
    const b = text.trim(); if (!b) return;
    setText("");
    const { error } = await supabase.rpc("send_message", { p_booking_id: bookingId, p_email: email, p_body: b });
    if (error) { setErr(error.message); return; }
    load();
  }

  return (
    <div style={{ border: "1px solid var(--line)", borderRadius: "var(--r-md)", overflow: "hidden", marginTop: 10 }}>
      <div ref={boxRef} style={{ height, overflowY: "auto", padding: 12, display: "flex", flexDirection: "column", gap: 8, background: "var(--surface-2)" }}>
        {msgs.length === 0 && <div className="faint" style={{ fontSize: 12.5, textAlign: "center", padding: 12 }}>No messages yet. Say hello — contact details are hidden automatically.</div>}
        {msgs.map((m) => (
          <div key={m.id} style={{ alignSelf: m.mine ? "flex-end" : "flex-start", maxWidth: "78%" }}>
            <div style={{
              background: m.mine ? "var(--grad-cta, #fb7321)" : "var(--surface)",
              color: m.mine ? "#fff" : "var(--ink, #0c1b33)",
              border: m.mine ? "none" : "1px solid var(--line)",
              borderRadius: 12, padding: "7px 11px", fontSize: 13.5, whiteSpace: "pre-wrap", wordBreak: "break-word",
            }}>{m.body}</div>
            <div className="faint" style={{ fontSize: 10.5, marginTop: 2, textAlign: m.mine ? "right" : "left" }}>
              {new Date(m.created_at).toLocaleString([], { hour: "numeric", minute: "2-digit" })}
            </div>
          </div>
        ))}
      </div>
      {err && <div style={{ color: "var(--bad)", fontSize: 12, padding: "6px 12px" }}>{err}</div>}
      <div style={{ display: "flex", gap: 8, padding: 10, borderTop: "1px solid var(--line)" }}>
        <input value={text} onChange={(e) => setText(e.target.value)} placeholder="Type a message…"
          onKeyDown={(e) => { if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); send(); } }} style={{ flex: 1 }} />
        <button className="btn btn-cta btn-sm" onClick={send}>Send</button>
      </div>
      <div className="faint" style={{ fontSize: 10.5, padding: "0 12px 8px" }}>🔒 Emails, phone numbers and links are hidden to keep everyone safe.</div>
    </div>
  );
}
