// =============================================================================
// razorpay-create-order
// Reserves the booking (holds the slot + freezes the price) and creates a
// Razorpay Order for the mentee-currency gross. Returns the order for Checkout.
// The browser NEVER confirms the booking — the webhook does.
// =============================================================================
import { adminClient, rzp, KEY_ID, toMinor } from "../_shared/razorpay.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const b = await req.json();
    const { quote_id, mentor_id, service_id, slot_time, email, name, timezone, answers, target_country } = b;
    if (!quote_id || !mentor_id || !service_id || !slot_time || !email) {
      return json({ error: "quote_id, mentor_id, service_id, slot_time, email are required" }, 400);
    }
    const admin = adminClient();

    // 1) Reserve — server-priced, slot held for 10 min, payment row 'initiated'.
    const { data: reserved, error: rErr } = await admin.rpc("reserve_booking", {
      p_quote_id: quote_id, p_mentor_id: mentor_id, p_service_id: service_id, p_slot_time: slot_time,
      p_email: email, p_name: name ?? null, p_timezone: timezone ?? "UTC",
      p_answers: answers ?? [], p_target_country: target_country ?? null,
    });
    if (rErr) {
      // QUOTE_EXPIRED / slot-taken → client should re-quote and retry.
      const expired = /QUOTE_EXPIRED|just taken|not available/i.test(rErr.message);
      return json({ error: rErr.message, code: expired ? "REQUOTE" : "RESERVE_FAILED" }, 409);
    }
    const booking_id = (reserved as any).booking_id as number;
    const amountMajor = Number((reserved as any).amount);
    const currency = String((reserved as any).currency).toUpperCase();
    const amountMinor = toMinor(amountMajor, currency);

    // 2) Create the Razorpay order (idempotency key derived from booking id).
    let order;
    try {
      order = await rzp("/orders", {
        method: "POST",
        headers: { "X-Razorpay-Idempotency-Key": `booking-${booking_id}` },
        body: JSON.stringify({
          amount: amountMinor, currency, receipt: `booking-${booking_id}`,
          notes: { booking_id: String(booking_id), quote_id: String(quote_id) },
        }),
      });
    } catch (e) {
      // Reservation exists but order failed — let the hold expire (janitor frees it).
      return json({ error: (e as Error).message, code: "ORDER_FAILED", booking_id }, 502);
    }

    // 3) Persist order id + raw payload on the reserved payment row.
    await admin.rpc("set_provider_order", { p_booking_id: booking_id, p_order_id: order.id });
    await admin.from("customer_payments").update({ provider_payload: order })
      .eq("booking_id", booking_id).eq("status", "initiated");

    return json({
      order_id: order.id, key_id: await KEY_ID(), amount: amountMinor, currency,
      booking_id, name: name ?? null, email,
    });
  } catch (e) {
    console.error("create-order error:", e);
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
