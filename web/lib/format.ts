export const money = (a: number, c = "USD") =>
  new Intl.NumberFormat("en", { style: "currency", currency: c }).format(a || 0);

export const guessCurrency = () => {
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
  const map: Record<string, string> = {
    "Asia/Kolkata": "INR", "Asia/Calcutta": "INR", "Europe/Amsterdam": "EUR",
    "Europe/London": "GBP", "America/New_York": "USD", "America/Sao_Paulo": "BRL",
    "Asia/Dubai": "AED", "Australia/Sydney": "AUD",
  };
  return map[tz] || "USD";
};

export const myTz = () => Intl.DateTimeFormat().resolvedOptions().timeZone;

const fxCache: Record<string, { rate: number; date: string | null }> = {};
export async function fx(from: string, to: string) {
  if (!from || !to || from === to) return { rate: 1, date: null };
  const k = `${from}>${to}`;
  if (fxCache[k]) return fxCache[k];
  try {
    const res = await fetch(`https://api.frankfurter.dev/v2/rates?base=${from}&quotes=${to}`);
    const j = await res.json();
    const row = Array.isArray(j) ? j.find((x: any) => x.quote === to) : null;
    fxCache[k] = { rate: row ? row.rate : 1, date: row ? row.date : null };
  } catch {
    fxCache[k] = { rate: 1, date: null };
  }
  return fxCache[k];
}

export const fmtTime = (iso: string, tz: string) =>
  new Intl.DateTimeFormat("en", { timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: true }).format(new Date(iso));
export const fmtDate = (iso: string, tz: string) =>
  new Intl.DateTimeFormat("en", { timeZone: tz, weekday: "short", month: "short", day: "numeric" }).format(new Date(iso));
