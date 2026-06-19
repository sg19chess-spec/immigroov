"use client";
import { useState } from "react";
import { setEmail } from "@/lib/identity";

export default function Login() {
  const [e, setE] = useState("");
  const go = () => { if (e.includes("@")) { setEmail(e); location.href = "/"; } };
  return (
    <div className="container" style={{ maxWidth: 440 }}>
      <h2 className="sec">Sign in</h2>
      <div className="card">
        <p className="muted" style={{ marginTop: 0, fontSize: 14 }}>
          Demo sign-in — just enter your email to continue. Any session you book with this email will appear under <b>My sessions</b>.
        </p>
        <label className="fld">Email</label>
        <input type="email" value={e} onChange={(ev) => setE(ev.target.value)} onKeyDown={(ev) => ev.key === "Enter" && go()}
          placeholder="you@email.com" style={{ width: "100%" }} autoFocus />
        <button className="btn-cta" style={{ width: "100%", marginTop: 12 }} disabled={!e.includes("@")} onClick={go}>Continue</button>
      </div>
    </div>
  );
}
