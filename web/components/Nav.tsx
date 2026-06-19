"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { createClient } from "@/lib/supabase/client";

export default function Nav() {
  const supabase = createClient();
  const [email, setEmail] = useState<string | null>(null);
  const [anon, setAnon] = useState(false);

  useEffect(() => {
    supabase.auth.getUser().then(({ data }) => {
      setEmail(data.user?.email ?? null);
      setAnon(!!data.user?.is_anonymous);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((_e, s) => {
      setEmail(s?.user?.email ?? null);
      setAnon(!!s?.user?.is_anonymous);
    });
    return () => sub.subscription.unsubscribe();
  }, [supabase]);

  return (
    <nav className="nav">
      <Link href="/" className="brand"><span className="logo">I<b>G</b></span> Immigroov</Link>
      <div className="navspace" />
      <Link href="/bookings">My sessions</Link>
      <Link href="/dashboard">Mentor</Link>
      {email ? (
        <span className="muted" style={{ fontSize: 13 }}>{email}</span>
      ) : anon ? (
        <span className="muted" style={{ fontSize: 13 }}>guest</span>
      ) : null}
      {(email || anon) ? (
        <button className="btn-ghost" onClick={async () => { await supabase.auth.signOut(); location.href = "/"; }}>
          Sign out
        </button>
      ) : (
        <Link href="/login" className="btn btn-cta" style={{ padding: "8px 14px" }}>Sign in</Link>
      )}
    </nav>
  );
}
