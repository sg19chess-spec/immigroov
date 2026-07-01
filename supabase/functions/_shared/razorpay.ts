// Shared Razorpay helpers (self-contained; no Stripe coupling).
import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";

const BASE = "https://api.razorpay.com/v1";

export const KEY_ID = () => Deno.env.get("RAZORPAY_KEY_ID")!;

// Service-role client — bypasses RLS for payment writes.
export function adminClient(): SupabaseClient {
  return createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false },
  });
}

function authHeader(): string {
  return "Basic " + btoa(`${Deno.env.get("RAZORPAY_KEY_ID")}:${Deno.env.get("RAZORPAY_KEY_SECRET")}`);
}

// Call the Razorpay REST API. Throws on non-2xx with the provider error attached.
export async function rzp(path: string, init: RequestInit = {}): Promise<any> {
  const res = await fetch(BASE + path, {
    ...init,
    headers: { Authorization: authHeader(), "Content-Type": "application/json", ...(init.headers ?? {}) },
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
  const secret = Deno.env.get("RAZORPAY_WEBHOOK_SECRET");
  if (!secret || !signature) return false;
  return timingSafeEqual(await hmacHex(rawBody, secret), signature);
}

// Verify a Checkout handler response: HMAC-SHA256(order_id|payment_id) with the key secret.
export async function verifyCheckout(orderId: string, paymentId: string, signature: string): Promise<boolean> {
  const secret = Deno.env.get("RAZORPAY_KEY_SECRET");
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
