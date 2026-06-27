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

// NOTE: currency conversion is now done SERVER-SIDE (convert_prices / the pricing
// engine in migration 0065). The old client-side fx() — which silently fell back to
// rate=1 on any network error and could mis-price by ~80x — has been removed.

export const fmtTime = (iso: string, tz: string) =>
  new Intl.DateTimeFormat("en", { timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: true }).format(new Date(iso));
export const fmtDate = (iso: string, tz: string) =>
  new Intl.DateTimeFormat("en", { timeZone: tz, weekday: "short", month: "short", day: "numeric" }).format(new Date(iso));
