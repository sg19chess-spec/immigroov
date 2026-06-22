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

// Country -> display currency (only currencies our FX (Frankfurter) supports;
// anything else falls back to USD so conversion stays correct).
const COUNTRY_CCY: Record<string, string> = {
  US:"USD", GB:"GBP", IN:"INR", DE:"EUR", FR:"EUR", NL:"EUR", IE:"EUR", ES:"EUR", IT:"EUR", PT:"EUR",
  CA:"CAD", AU:"AUD", NZ:"NZD", SG:"SGD", HK:"HKD", JP:"JPY", KR:"KRW", CN:"CNY", MX:"MXN", BR:"BRL",
  ZA:"ZAR", CH:"CHF", SE:"SEK", NO:"NOK", DK:"DKK", PL:"PLN", RO:"RON", CZ:"CZK", HU:"HUF", BG:"BGN",
  IL:"ILS", ID:"IDR", PH:"PHP", MY:"MYR", TH:"THB", TR:"TRY",
};
export const currencyForCountry = (cc: string) => COUNTRY_CCY[(cc || "").toUpperCase()] || "USD";
const withTimeout = <T,>(p: Promise<T>, ms: number) =>
  Promise.race([p, new Promise<T>((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);

// Free, no-key, HTTPS, CORS-enabled geo providers (tried in order).
const PROVIDERS: (() => Promise<string>)[] = [
  async () => (await (await withTimeout(fetch("https://get.geojs.io/v1/ip/country.json"), 2500)).json()).country,
  async () => (await (await withTimeout(fetch("https://ipwho.is/"), 2500)).json()).country_code,
  async () => (await (await withTimeout(fetch("https://ipapi.co/json/"), 2500)).json()).country_code,
];

function cookie(name: string): string | null {
  if (typeof document === "undefined") return null;
  const m = document.cookie.match(new RegExp("(?:^|; )" + name + "=([^;]*)"));
  return m ? decodeURIComponent(m[1]) : null;
}

// The visitor's *real* detected country (cached). Order: cached -> edge cookie
// (Vercel, free, server-side) -> client geo providers -> timezone.
export async function geoLocate(): Promise<string> {
  if (typeof window !== "undefined") {
    const c = localStorage.getItem("ig_country_detected");
    if (c) return c;
    const edge = (cookie("ig_geo") || "").toUpperCase();
    if (/^[A-Z]{2}$/.test(edge)) { localStorage.setItem("ig_country_detected", edge); return edge; }
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

// Anti-abuse: if the IP country and the browser timezone disagree (a classic
// VPN tell) and the user hasn't manually picked a region, use the LESS-discounted
// factor so a VPN can't unlock a cheaper price. No external service / key needed.
export async function effectivePpp(): Promise<{ country: string; detected: string; factor: number; suspect: boolean; currency: string }> {
  const { cc, detected, overridden } = await activeCountry();
  if (overridden) return { country: cc, detected, factor: await pppFactor(cc), suspect: false, currency: currencyForCountry(cc) };
  const tzc = tzCountry();
  if (detected !== tzc) {
    const f = Math.max(await pppFactor(detected), await pppFactor(tzc)); // higher factor = less discount
    return { country: detected, detected, factor: f, suspect: true, currency: currencyForCountry(detected) };
  }
  return { country: detected, detected, factor: await pppFactor(detected), suspect: false, currency: currencyForCountry(detected) };
}
