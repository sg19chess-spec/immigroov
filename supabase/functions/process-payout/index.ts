// =============================================================================
// process-payout   (admin only)
// Pays a mentor for a completed, paid booking via Stripe Connect transfer, and
// records it in mentor_payouts. The mentor's Immigroov fee was already kept by
// the platform at charge time, so the payout = the mentor's share.
//
// NOTE: requires the mentor's Stripe Connect account id. That column isn't in
// the base schema yet — see the note in the response; add
// mentors.stripe_account_id before using real transfers.
// =============================================================================
import { adminClient, stripe } from "../_shared/clients.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

async function requireAdmin(req: Request, admin: ReturnType<typeof adminClient>) {
  const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
  const { data: { user } } = await admin.auth.getUser(token);
  if (!user) return false;
  const { data } = await admin.from("users").select("role").eq("auth_id", user.id).maybeSingle();
  return data?.role === "admin" || data?.role === "super_admin";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const admin = adminClient();
    if (!await requireAdmin(req, admin)) return json({ error: "Admins only" }, 403);

    const { booking_id } = await req.json();
    if (!booking_id) return json({ error: "booking_id required" }, 400);

    // Pull the booking + the mentor's share recorded at payment time.
    const { data: bk } = await admin.from("bookings")
      .select("id, mentor_id, status").eq("id", booking_id).single();
    if (!bk || bk.status !== "completed") {
      return json({ error: "Booking must be 'completed'" }, 400);
    }
    const { data: pay } = await admin.from("customer_payments")
      .select("currency, status").eq("booking_id", booking_id).eq("status", "paid").maybeSingle();
    if (!pay) return json({ error: "No captured payment for this booking" }, 400);

    // Already paid out?
    const { data: existing } = await admin.from("mentor_payouts")
      .select("id, status").eq("booking_id", booking_id).maybeSingle();
    if (existing?.status === "paid") return json({ error: "Already paid out" }, 409);

    // mentor's connected Stripe account + the mentor share from PI metadata
    const { data: mentor } = await admin.from("mentors")
      .select("stripe_account_id").eq("id", bk.mentor_id).maybeSingle();
    const { data: piRow } = await admin.from("customer_payments")
      .select("stripe_payment_id").eq("booking_id", booking_id).eq("status", "paid").single();
    const pi = await stripe.paymentIntents.retrieve(piRow!.stripe_payment_id);
    const mentorShare = Number(pi.metadata.mentor_price ?? 0);

    let transferId: string | null = null;
    if ((mentor as any)?.stripe_account_id) {
      const tr = await stripe.transfers.create({
        amount: Math.round(mentorShare * 100),
        currency: (pay.currency ?? "usd").toLowerCase(),
        destination: (mentor as any).stripe_account_id,
        metadata: { booking_id: String(booking_id) },
      });
      transferId = tr.id;
    }

    await admin.from("mentor_payouts").upsert({
      mentor_id: bk.mentor_id, booking_id, amount: mentorShare,
      currency: pay.currency, status: transferId ? "paid" : "pending",
      stripe_payment_id: transferId, paid_date: transferId ? new Date().toISOString() : null,
    }, { onConflict: "booking_id" });

    return json({ paid: !!transferId, amount: mentorShare, transfer_id: transferId });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
