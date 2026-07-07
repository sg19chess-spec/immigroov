import { NextResponse, type NextRequest } from "next/server";
import { createClient } from "@/lib/supabase/server";

// Referral link landing page. Logs the click server-side, drops a session
// cookie for the checkout page to read later, and redirects into the site.
// Unknown slugs redirect too (log_referral_click no-ops silently) — a bad
// referral link should never break someone's visit.
export async function GET(request: NextRequest, { params }: { params: { slug: string } }) {
  const supabase = createClient();
  const sessionToken = crypto.randomUUID();

  await supabase.rpc("log_referral_click", { p_slug: params.slug, p_session_token: sessionToken });

  const res = NextResponse.redirect(new URL("/", request.url));
  res.cookies.set("ig_ref", sessionToken, {
    path: "/",
    maxAge: 60 * 60 * 24 * 90, // 90 days — comfortably past the 60-day attribution window
    sameSite: "lax",
  });
  return res;
}
