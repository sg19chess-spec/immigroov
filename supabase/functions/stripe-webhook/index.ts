// =============================================================================
// stripe-webhook
// Stripe calls this after a payment changes state. It is the SOURCE OF TRUTH
// for payment status — never trust the browser to tell you a payment succeeded.
//   payment_intent.succeeded      -> customer_payments=paid, booking=confirmed, email
//   payment_intent.payment_failed -> customer_payments=failed
//   charge.refunded               -> customer_payments=refunded
// Deploy with: supabase functions deploy stripe-webhook --no-verify-jwt
// (Stripe can't send a Supabase JWT; we verify the Stripe signature instead.)
// =============================================================================
import { adminClient, stripe } from "../_shared/clients.ts";

const WEBHOOK_SECRET = Deno.env.get("STRIPE_WEBHOOK_SECRET")!;

Deno.serve(async (req) => {
  const sig = req.headers.get("stripe-signature")!;
  const raw = await req.text();
  let event: any;
  try {
    event = await stripe.webhooks.constructEventAsync(raw, sig, WEBHOOK_SECRET);
  } catch (e) {
    return new Response(`Webhook signature failed: ${e}`, { status: 400 });
  }

  const admin = adminClient();

  if (event.type === "payment_intent.succeeded") {
    const pi = event.data.object;
    const bookingId = Number(pi.metadata.booking_id);
    await admin.from("customer_payments").update({ status: "paid" })
      .eq("stripe_payment_id", pi.id);
    // Setting status to 'confirmed' fires the DB trigger booking_status_email,
    // which sends the confirmation email (single source — do NOT email here too).
    await admin.from("bookings").update({ status: "confirmed" }).eq("id", bookingId);
  } else if (event.type === "payment_intent.payment_failed") {
    await admin.from("customer_payments").update({ status: "failed" })
      .eq("stripe_payment_id", event.data.object.id);
  } else if (event.type === "charge.refunded") {
    const pi = event.data.object.payment_intent;
    await admin.from("customer_payments").update({ status: "refunded" })
      .eq("stripe_payment_id", pi);
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
