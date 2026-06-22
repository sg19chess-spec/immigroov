import { createClient } from "@/lib/supabase/client";

const TZ_COUNTRY: Record<string, string> = {
  "Asia/Kolkata": "IN", "Asia/Calcutta": "IN", "Europe/Amsterdam": "NL", "Europe/Paris": "FR",
  "Europe/Berlin": "DE", "America/Sao_Paulo": "BR", "America/New_York": "US", "America/Los_Angeles": "US",
  "Europe/London": "GB", "Asia/Dubai": "AE", "Australia/Sydney": "AU", "Asia/Singapore": "SG",
  "Asia/Tokyo": "JP", "Africa/Johannesburg": "ZA", "America/Toronto": "CA", "Asia/Manila": "PH",
};

export function tzCountry(): string {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  return TZ_COUNTRY[tz] || "US";
}

function withTimeout<T>(p: Promise<T>, ms: number): Promise<T> {
  return Promise.race([p, new Promise<T>((_, rej) => setTimeout(() => rej(new Error("timeout")), ms))]);
}

// HTTPS geo (ip-api free is HTTP-only and blocked on https); falls back to timezone.
export async function detectCountry(): Promise<string> {
  if (typeof window !== "undefined") {
    const saved = localStorage.getItem("ig_country");
    if (saved) return saved;
  }
  try {
    const res = await withTimeout(fetch("https://ipapi.co/json/"), 2500);
    const j = await res.json();
    if (j && j.country_code) return String(j.country_code).toUpperCase();
  } catch { /* ignore */ }
  return tzCountry();
}

export function setCountry(cc: string) {
  localStorage.setItem("ig_country", cc.toUpperCase());
  window.dispatchEvent(new Event("ig-country"));
}

const factorCache: Record<string, number> = {};
export async function pppFactor(cc: string): Promise<number> {
  const k = (cc || "US").toUpperCase();
  if (factorCache[k] != null) return factorCache[k];
  try {
    const { data } = await createClient().rpc("get_ppp_factor", { p_cc: k });
    factorCache[k] = Number(data ?? 1) || 1;
  } catch { factorCache[k] = 1; }
  return factorCache[k];
}
