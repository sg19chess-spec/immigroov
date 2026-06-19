// =============================================================================
// cancel-and-refund
// Cancels a booking AND refunds the customer if they had paid.
//   - cancel_booking() RPC runs as the CALLER (RLS-authorized: only a
//     participant can cancel; mentor cancels bump the cancellation counter)
//   - if a paid payment exists, issue a Stripe refund (webhook flips status)
// =============================================================================
import { adminClient, userClient } from "../_shared/clients.ts";
import { stripe } from "../_shared/clients.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { booking_id, cancelled_by = "user" } = await req.json();
    if (!booking_id) return json({ error: "booking_id required" }, 400);

    // 1) Cancel via RPC under the caller's identity (enforces authorization).
    const uc = userClient(req);
    const { error: cancelErr } = await uc.rpc("cancel_booking", {
      p_booking_id: booking_id, p_cancelled_by: cancelled_by,
    });
    if (cancelErr) return json({ error: cancelErr.message }, 403);

    // 2) Refund any captured payment (service-role; webhook marks 'refunded').
    const admin = adminClient();
    const { data: pay } = await admin.from("customer_payments")
      .select("stripe_payment_id, status")
      .eq("booking_id", booking_id).eq("status", "paid").maybeSingle();

    let refunded = false;
    if (pay?.stripe_payment_id) {
      await stripe.refunds.create({ payment_intent: pay.stripe_payment_id });
      refunded = true;
    }

    return json({ cancelled: true, refunded });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
