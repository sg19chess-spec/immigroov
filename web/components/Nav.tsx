"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { getEmail, clearEmail } from "@/lib/identity";

export default function Nav() {
  const [email, setEmailS] = useState<string | null>(null);
  useEffect(() => {
    const sync = () => setEmailS(getEmail());
    sync();
    window.addEventListener("ig-auth", sync);
    window.addEventListener("storage", sync);
    return () => { window.removeEventListener("ig-auth", sync); window.removeEventListener("storage", sync); };
  }, []);

  return (
    <nav className="nav">
      <Link href="/" className="brand"><span className="logo">I<b>G</b></span> Immigroov</Link>
      <div className="navspace" />
      <Link href="/bookings">My sessions</Link>
      <Link href="/dashboard">Mentor</Link>
      {email ? (
        <>
          <span className="muted" style={{ fontSize: 13 }}>{email}</span>
          <button className="btn-ghost btn-sm" onClick={() => { clearEmail(); location.href = "/"; }}>Sign out</button>
        </>
      ) : (
        <Link href="/login" className="btn btn-cta btn-sm">Sign in</Link>
      )}
    </nav>
  );
}
