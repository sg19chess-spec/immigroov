// Shared Razorpay helpers (self-contained; no Stripe coupling).
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const BASE = "https://api.razorpay.com/v1";

// Service-role client — bypasses RLS for payment writes.
export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
}

// Secrets: prefer edge-function env (supabase secrets set …); otherwise fall back
// to Supabase Vault via the service-role-only get_app_secret RPC. Cached per cold start.
let _secrets: { id: string; secret: string; whsec: string } | null = null;
async function secrets() {
  if (_secrets) return _secrets;
  const envId = Deno.env.get("RAZORPAY_KEY_ID");
  if (envId) {
    _secrets = { id: envId, secret: Deno.env.get("RAZORPAY_KEY_SECRET") ?? "", whsec: Deno.env.get("RAZORPAY_WEBHOOK_SECRET") ?? "" };
    return _secrets;
  }
  const a = adminClient();
  const [id, secret, whsec] = await Promise.all([
    a.rpc("get_app_secret", { p_name: "razorpay_key_id" }),
    a.rpc("get_app_secret", { p_name: "razorpay_key_secret" }),
    a.rpc("get_app_secret", { p_name: "razorpay_webhook_secret" }),
  ]);
  _secrets = { id: id.data ?? "", secret: secret.data ?? "", whsec: whsec.data ?? "" };
  return _secrets;
}

export const KEY_ID = async () => (await secrets()).id;

// Call the Razorpay REST API. Throws on non-2xx with the provider error attached.
export async function rzp(path: string, init: RequestInit = {}): Promise<any> {
  const s = await secrets();
  const res = await fetch(BASE + path, {
    ...init,
    headers: { Authorization: "Basic " + btoa(`${s.id}:${s.secret}`), "Content-Type": "application/json", ...(init.headers ?? {}) },
  });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw Object.assign(new Error(body?.error?.description || `Razorpay HTTP ${res.status}`), {
      rzp: body?.error ?? body, status: res.status,
    });
  }
  return body;
}

async function hmacHex(message: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (!a || !b || a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// Verify the webhook signature (HMAC-SHA256 of the raw body with the webhook secret).
export async function verifyWebhook(rawBody: string, signature: string | null): Promise<boolean> {
  const { whsec } = await secrets();
  if (!whsec || !signature) return false;
  return timingSafeEqual(await hmacHex(rawBody, whsec), signature);
}

// Verify a Checkout handler response: HMAC-SHA256(order_id|payment_id) with the key secret.
export async function verifyCheckout(orderId: string, paymentId: string, signature: string): Promise<boolean> {
  const { secret } = await secrets();
  if (!secret) return false;
  return timingSafeEqual(await hmacHex(`${orderId}|${paymentId}`, secret), signature);
}

// Currencies Razorpay expects in the major unit (no *100). Everything else = *100.
const ZERO_DECIMAL = new Set(["JPY", "KRW", "VND"]);
export function toMinor(amountMajor: number, currency: string): number {
  return ZERO_DECIMAL.has(currency.toUpperCase()) ? Math.round(amountMajor) : Math.round(amountMajor * 100);
}
export function fromMinor(amountMinor: number, currency: string): number {
  return ZERO_DECIMAL.has(currency.toUpperCase()) ? amountMinor : amountMinor / 100;
}
