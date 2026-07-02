// Shared Razorpay helpers — the ONE canonical module for all payment functions.
// Always fully exported (adminClient, KEY_ID, rzp, verifyWebhook, verifyCheckout,
// toMinor, fromMinor) so no importer can boot-crash on a missing symbol.
// Robust: loud on missing secrets, network timeout + one retry, never caches
// an incomplete secret set.
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const BASE = "https://api.razorpay.com/v1";

export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
}

// Secrets: env first, else Supabase Vault (get_app_secret). Cached only when the
// API keys are present; throws a clear error otherwise (no silent 401s later).
let _secrets: { id: string; secret: string; whsec: string } | null = null;
async function secrets() {
  if (_secrets) return _secrets;
  let s = {
    id: Deno.env.get("RAZORPAY_KEY_ID") ?? "",
    secret: Deno.env.get("RAZORPAY_KEY_SECRET") ?? "",
    whsec: Deno.env.get("RAZORPAY_WEBHOOK_SECRET") ?? "",
  };
  if (!s.id || !s.secret || !s.whsec) {
    try {
      const a = adminClient();
      const [id, secret, whsec] = await Promise.all([
        a.rpc("get_app_secret", { p_name: "razorpay_key_id" }),
        a.rpc("get_app_secret", { p_name: "razorpay_key_secret" }),
        a.rpc("get_app_secret", { p_name: "razorpay_webhook_secret" }),
      ]);
      s = { id: s.id || (id.data ?? ""), secret: s.secret || (secret.data ?? ""), whsec: s.whsec || (whsec.data ?? "") };
    } catch (e) {
      throw new Error(`Could not load Razorpay secrets from Vault: ${(e as Error)?.message ?? e}`);
    }
  }
  if (!s.id || !s.secret) throw new Error("Razorpay API keys not configured (env RAZORPAY_KEY_ID/SECRET or Vault razorpay_key_id/secret)");
  _secrets = s; // cache only a valid set
  return _secrets;
}
export const KEY_ID = async () => (await secrets()).id;

// Razorpay REST call: 15s timeout, one retry on network error / 5xx.
export async function rzp(path: string, init: RequestInit = {}, attempt = 0): Promise<any> {
  const s = await secrets();
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), 15_000);
  let res: Response;
  try {
    res = await fetch(BASE + path, {
      ...init, signal: ctl.signal,
      headers: { Authorization: "Basic " + btoa(`${s.id}:${s.secret}`), "Content-Type": "application/json", ...(init.headers ?? {}) },
    });
  } catch (e) {
    clearTimeout(timer);
    if (attempt < 1) return rzp(path, init, attempt + 1);
    throw new Error(`Razorpay request failed (${path}): ${(e as Error)?.message ?? e}`);
  }
  clearTimeout(timer);
  if (res.status >= 500 && attempt < 1) return rzp(path, init, attempt + 1);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) throw Object.assign(new Error(body?.error?.description || `Razorpay HTTP ${res.status}`), { rzp: body?.error ?? body, status: res.status });
  return body;
}

async function hmacHex(message: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
function timingSafeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0; for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i); return diff === 0;
}

// Webhook signature (HMAC-SHA256 of the raw body). Missing signature → false
// (reject as 400); missing configured secret → throw (infra error, retryable).
export async function verifyWebhook(rawBody: string, signature: string | null): Promise<boolean> {
  if (!signature) return false;
  const { whsec } = await secrets();
  if (!whsec) throw new Error("RAZORPAY_WEBHOOK_SECRET not configured");
  return timingSafeEqual(await hmacHex(rawBody, whsec), signature);
}

// Checkout handler signature: HMAC-SHA256(order_id|payment_id) with the key secret.
export async function verifyCheckout(orderId: string, paymentId: string, signature: string): Promise<boolean> {
  if (!signature) return false;
  const { secret } = await secrets();
  return timingSafeEqual(await hmacHex(`${orderId}|${paymentId}`, secret), signature);
}

const ZERO_DECIMAL = new Set(["JPY", "KRW", "VND"]);
export function toMinor(amountMajor: number, currency: string): number {
  return ZERO_DECIMAL.has(currency.toUpperCase()) ? Math.round(amountMajor) : Math.round(amountMajor * 100);
}
export function fromMinor(amountMinor: number, currency: string): number {
  return ZERO_DECIMAL.has(currency.toUpperCase()) ? amountMinor : amountMinor / 100;
}
