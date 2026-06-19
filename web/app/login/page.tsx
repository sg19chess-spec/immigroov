"use client";
import { useState } from "react";
import { createClient } from "@/lib/supabase/client";

export default function Login() {
  const supabase = createClient();
  const [email, setEmail] = useState("");
  const [msg, setMsg] = useState<string | null>(null);

  async function magicLink() {
    if (!email) return;
    const { error } = await supabase.auth.signInWithOtp({ email, options: { emailRedirectTo: location.origin } });
    setMsg(error ? error.message : "Check your email for a magic sign-in link.");
  }
  async function guest() {
    const { error } = await supabase.auth.signInAnonymously();
    if (error) setMsg(error.message); else location.href = "/";
  }

  return (
    <div className="container" style={{ maxWidth: 440 }}>
      <h2 className="sec">Sign in</h2>
      <div className="card">
        <label className="muted" style={{ fontSize: 13 }}>Email (magic link)</label>
        <div style={{ display: "flex", gap: 8, marginTop: 6 }}>
          <input value={email} onChange={(e) => setEmail(e.target.value)} placeholder="you@email.com" style={{ flex: 1 }} />
          <button className="btn-cta" onClick={magicLink}>Send link</button>
        </div>
        <div style={{ margin: "16px 0", textAlign: "center" }} className="muted">or</div>
        <button className="btn-ghost" style={{ width: "100%" }} onClick={guest}>Continue as guest</button>
        {msg && <div className="banner ok" style={{ marginTop: 14 }}>{msg}</div>}
        <p className="muted" style={{ fontSize: 12, marginTop: 14 }}>
          Magic-link needs email auth configured; “Continue as guest” needs Anonymous sign-ins enabled in Supabase Auth settings.
        </p>
      </div>
    </div>
  );
}
