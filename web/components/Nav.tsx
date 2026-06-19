"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState } from "react";
import { getEmail, clearEmail } from "@/lib/identity";

export default function Nav() {
  const pathname = usePathname();
  const isMentor = pathname?.startsWith("/dashboard");
  const [email, setEmailS] = useState<string | null>(null);
  const [hidden, setHidden] = useState(false);

  useEffect(() => {
    const sync = () => setEmailS(getEmail());
    sync();
    window.addEventListener("ig-auth", sync);
    window.addEventListener("storage", sync);
    return () => { window.removeEventListener("ig-auth", sync); window.removeEventListener("storage", sync); };
  }, []);

  useEffect(() => {
    let last = window.scrollY;
    const onScroll = () => {
      const y = window.scrollY;
      if (Math.abs(y - last) > 6) { setHidden(y > last && y > 90); last = y; }
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const seg = (active: boolean): React.CSSProperties => ({
    padding: "7px 16px", borderRadius: 999, fontWeight: 700, fontSize: 13.5, whiteSpace: "nowrap",
    background: active ? "var(--navy)" : "transparent",
    color: active ? "#fff" : "var(--muted)",
    boxShadow: active ? "0 2px 8px rgba(10,34,64,.25)" : "none",
    transition: "all .18s",
  });

  return (
    <nav className="nav" style={{ transform: hidden ? "translateY(-110%)" : "translateY(0)", transition: "transform .25s ease" }}>
      <Link href="/" className="brand"><span className="logo">I<b>G</b></span> <span className="hide-mobile">Immigroov</span></Link>

      <div style={{ display: "inline-flex", background: "var(--navy-soft)", border: "1px solid var(--line)", borderRadius: 999, padding: 4, gap: 4 }} title="Switch view">
        <Link href="/" style={seg(!isMentor)}>Mentee</Link>
        <Link href="/dashboard" style={seg(!!isMentor)}>Mentor</Link>
      </div>

      <div className="navspace" />
      {!isMentor && <Link href="/bookings">My sessions</Link>}
      {email && <span className="muted hide-mobile" style={{ fontSize: 13 }}>{email}</span>}
      {email ? (
        <button className="btn-ghost btn-sm" onClick={() => { clearEmail(); location.href = "/"; }}>Sign out</button>
      ) : (
        <Link href="/login" className="btn btn-cta btn-sm">Sign in</Link>
      )}
    </nav>
  );
}
