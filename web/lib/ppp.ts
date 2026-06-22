import { createClient } from "@/lib/supabase/client";

const TZ_COUNTRY: Record<string, string> = {
  "Asia/Kolkata": "IN", "Asia/Calcutta": "IN", "Europe/Amsterdam": "NL", "Europe/Paris": "FR",
  "Europe/Berlin": "DE", "America/Sao_Paulo": "BR", "America/New_York": "US", "America/Los_Angeles": "US",
  "Europe/London": "GB", "Asia/Dubai": "AE", "Australia/Sydney": "AU", "Asia/Singapore": "SG",
  "Asia/Tokyo": "JP", "Africa/Johannesburg": "ZA", "America/Toronto": "CA", "Asia/Manila": "PH",
};
export function tzCountry(): string {
  return TZ_COUNTRY[Intl.DateTimeFormat().resolvedOptions().timeZone] || "US";
}
const withTimeout = <T,>(p: Promise<T>, ms: number) =>
  Promise.race([p, new Promise<T>((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);

// Free, no-key, HTTPS, CORS-enabled geo providers (tried in order).
const PROVIDERS: (() => Promise<string>)[] = [
  async () => (await (await withTimeout(fetch("https://get.geojs.io/v1/ip/country.json"), 2500)).json()).country,
  async () => (await (await withTimeout(fetch("https://ipwho.is/"), 2500)).json()).country_code,
  async () => (await (await withTimeout(fetch("https://ipapi.co/json/"), 2500)).json()).country_code,
];

// The visitor's *real* detected country (cached). Falls back to timezone.
export async function geoLocate(): Promise<string> {
  if (typeof window !== "undefined") {
    const c = localStorage.getItem("ig_country_detected");
    if (c) return c;
  }
  for (const fn of PROVIDERS) {
    try { const cc = (await fn() || "").toUpperCase(); if (/^[A-Z]{2}$/.test(cc)) { localStorage.setItem("ig_country_detected", cc); return cc; } } catch { /* next */ }
  }
  const t = tzCountry();
  if (typeof window !== "undefined") localStorage.setItem("ig_country_detected", t);
  return t;
}

export function setCountry(cc: string) { localStorage.setItem("ig_country", cc.toUpperCase()); window.dispatchEvent(new Event("ig-country")); }

// Active country = manual override if set, else detected. Reports if overridden.
export async function activeCountry(): Promise<{ cc: string; detected: string; overridden: boolean }> {
  const detected = await geoLocate();
  const chosen = typeof window !== "undefined" ? localStorage.getItem("ig_country") : null;
  return { cc: chosen || detected, detected, overridden: !!chosen && chosen !== detected };
}

const factorCache: Record<string, number> = {};
export async function pppFactor(cc: string): Promise<number> {
  const k = (cc || "US").toUpperCase();
  if (factorCache[k] != null) return factorCache[k];
  try { const { data } = await createClient().rpc("get_ppp_factor", { p_cc: k }); factorCache[k] = Number(data ?? 1) || 1; }
  catch { factorCache[k] = 1; }
  return factorCache[k];
}
