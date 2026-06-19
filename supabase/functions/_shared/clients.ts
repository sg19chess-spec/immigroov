import { createClient, SupabaseClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

// Auto-injected by the Supabase runtime:
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

// Trusted client — bypasses RLS. Use for price lookups, payments, writes the
// user shouldn't be able to forge.
export function adminClient(): SupabaseClient {
  return createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });
}

// User-scoped client — carries the caller's JWT so RLS + auth.uid() apply.
// Use this when calling RPCs like create_guest_booking / cancel_booking so the
// database authorizes the real caller.
export function userClient(req: Request): SupabaseClient {
  const authHeader = req.headers.get("Authorization") ?? "";
  return createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
    auth: { persistSession: false },
  });
}

export const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2024-12-18.acacia",
  httpClient: Stripe.createFetchHttpClient(),
});

// Resolve the calling user's profile id (public.users.id) from their JWT.
export async function currentProfileId(
  req: Request,
): Promise<{ authId: string | null; profileId: number | null }> {
  const uc = userClient(req);
  const { data: { user } } = await uc.auth.getUser();
  if (!user) return { authId: null, profileId: null };
  const admin = adminClient();
  const { data } = await admin
    .from("users").select("id").eq("auth_id", user.id).maybeSingle();
  return { authId: user.id, profileId: data?.id ?? null };
}
