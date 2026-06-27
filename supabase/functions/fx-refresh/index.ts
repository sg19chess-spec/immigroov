// =============================================================================
// fx-refresh
// The single trusted FX source. Fetches Frankfurter (base=EUR -> all supported
// quote currencies), upserts them into public.fx_rates, and logs every run to
// fx_refresh_log (with the raw payload). Retries on failure (1s / 3s / 10s).
//
// Called every 6h by pg_cron (see migration 0065). The booking engine reads
// fx_rates and refuses to price if rates are missing or >24h old — so this
// function never decides prices, it just keeps the cache fresh.
//
// Self-contained (no ../_shared imports) so it carries no Stripe coupling.
// =============================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, "Content-Type": "application/json" } });

// Trusted client (service role) — bypasses RLS for the price-cache writes.
const adminClient = () =>
  createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });

// Currencies we price in (must be Frankfurter/ECB-supported). Mirrors COUNTRY_CCY
// in web/lib/format.ts. EUR is the pivot/base and is implicitly 1.
const BASE_SYMBOLS = [
  "USD", "GBP", "INR", "CAD", "AUD", "NZD", "SGD", "HKD", "JPY", "KRW", "CNY",
  "MXN", "BRL", "ZAR", "CHF", "SEK", "NOK", "DKK", "PLN", "RON", "CZK", "HUF",
  "BGN", "ILS", "IDR", "PHP", "MYR", "THB", "TRY",
];

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type Row = { base: string; quote: string; rate: number; as_of: string };

// Frankfurter v2 returns an array of { quote, rate, date }. Stay robust to the
// classic shape ({ date, rates: { CCY: n } }) too.
async function fetchRatesWithRetry(symbols: string[]): Promise<Row[]> {
  const url = `https://api.frankfurter.dev/v2/rates?base=EUR&quotes=${symbols.join(",")}`;
  const backoff = [1000, 3000, 10000]; // 3 attempts, escalating delay
  let lastErr: unknown;
  for (let i = 0; i < backoff.length; i++) {
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`Frankfurter HTTP ${res.status}`);
      const j = await res.json();
      let rows: Row[] = [];
      if (Array.isArray(j)) {
        rows = j.map((x: { quote: string; rate: number; date: string }) =>
          ({ base: "EUR", quote: x.quote, rate: x.rate, as_of: x.date }));
      } else if (j?.rates && typeof j.rates === "object") {
        rows = Object.entries(j.rates as Record<string, number>).map(
          ([quote, rate]) => ({ base: "EUR", quote, rate, as_of: j.date }));
      }
      if (rows.length === 0) throw new Error("Frankfurter: no rates in payload");
      return rows;
    } catch (e) {
      lastErr = e;
      if (i < backoff.length - 1) await sleep(backoff[i]);
    }
  }
  throw lastErr ?? new Error("Frankfurter: unknown error");
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const admin = adminClient();

  // Symbols = static supported set ∪ every distinct active mentor set_currency ∪ INR.
  const symbols = new Set(BASE_SYMBOLS);
  symbols.add("INR");
  try {
    const { data } = await admin.from("services").select("set_currency").eq("is_active", true);
    for (const r of data ?? []) {
      const c = (r as { set_currency: string | null }).set_currency?.toUpperCase();
      if (c && c !== "EUR") symbols.add(c);
    }
  } catch { /* fall back to the static set */ }
  const symbolList = [...symbols];

  try {
    const parsed = await fetchRatesWithRetry(symbolList);
    const now = new Date().toISOString();
    const rows = parsed.map((r) => ({ ...r, fetched_at: now }));
    const asOf = parsed[0]?.as_of ?? null;

    const { error } = await admin.from("fx_rates").upsert(rows, { onConflict: "base,quote" });
    if (error) throw error;

    await admin.from("fx_refresh_log").insert({
      provider: "frankfurter", as_of: asOf, raw_json: parsed, success: true, error: null,
    });
    return json({ ok: true, as_of: asOf, count: rows.length });
  } catch (e) {
    const message = e instanceof Error ? e.message : String(e);
    await admin.from("fx_refresh_log").insert({
      provider: "frankfurter", as_of: null, raw_json: null, success: false, error: message,
    });
    console.error("fx-refresh failed:", message);
    return json({ ok: false, error: message }, 502);
  }
});
