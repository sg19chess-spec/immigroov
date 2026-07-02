// =============================================================================
// razorpay-verify  (webhook-independent confirmation + cron backstop)
// The webhook can be delayed/dropped (esp. test mode), leaving a captured
// payment with a still-pending booking. This function fetches the order's
// payments straight from Razorpay (authoritative — never trusts the browser)
// and, if a payment is captured, confirms the booking via confirm_booking_payment
// (idempotent with the webhook).
//
// Modes:
//   • { order_id } or { booking_id } → verify that one booking (client calls this
//     right after Checkout succeeds).
//   • no body / {} → SWEEP: verify all recent still-pending bookings that have an
//     order (cron backstop for closed tabs / missed webhooks).
// =============================================================================
import { adminClient, rzp, fromMinor } from "../_shared/razorpay.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

async function verifyOne(admin: ReturnType<typeof adminClient>, orderId: string) {
  const { data: cp } = await admin.from("customer_payments")
    .select("id, booking_id, status").eq("provider_order_id", orderId).order("id", { ascending: false }).limit(1).maybeSingle();
  if (!cp) return { order_id: orderId, error: "unknown order" };
  if (cp.status === "paid") return { order_id: orderId, confirmed: true, status: "already" };

  const res = await rzp(`/orders/${orderId}/payments`);
  const captured = (res.items ?? []).find((p: { status: string }) => p.status === "captured");
  if (!captured) return { order_id: orderId, confirmed: false, status: res.items?.[0]?.status ?? "none" };

  const { error } = await admin.rpc("confirm_booking_payment", { p_booking_id: cp.booking_id, p_provider_ref: captured.id });
  if (error && /HOLD_EXPIRED/.test(error.message)) {
    // Captured after the hold lapsed → mark paid + auto-refund (mirrors the webhook).
    await admin.from("customer_payments").update({ status: "paid", state: "captured", provider_payment_id: captured.id, provider_payload: captured })
      .eq("id", cp.id).eq("status", "initiated");
    await admin.rpc("add_ledger", { p_booking: cp.booking_id, p_party: "customer", p_kind: "refund", p_amount: fromMinor(captured.amount, captured.currency), p_pct: 100, p_reason: "Payment captured after hold expired — auto-refund" });
    return { order_id: orderId, confirmed: false, refunded: true };
  }
  if (error) return { order_id: orderId, error: error.message };
  await admin.from("customer_payments").update({ provider_payload: captured }).eq("id", cp.id);
  return { order_id: orderId, confirmed: true, status: "captured" };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const admin = adminClient();
  let body: { order_id?: string; booking_id?: number } = {};
  try { body = await req.json(); } catch { /* empty = sweep */ }

  try {
    let orderId = body.order_id;
    if (!orderId && body.booking_id) {
      const { data } = await admin.from("customer_payments").select("provider_order_id").eq("booking_id", body.booking_id).order("id", { ascending: false }).limit(1).maybeSingle();
      orderId = data?.provider_order_id ?? undefined;
    }

    // Single-booking verify (post-checkout).
    if (orderId) return json(await verifyOne(admin, orderId));

    // Sweep: recent still-'initiated' payments with an order id (missed-webhook backstop).
    const since = new Date(Date.now() - 60 * 60_000).toISOString();
    const { data: rows } = await admin.from("customer_payments")
      .select("provider_order_id").eq("status", "initiated").not("provider_order_id", "is", null).gte("created_at", since).limit(100);
    const results = [];
    for (const r of rows ?? []) results.push(await verifyOne(admin, r.provider_order_id as string));
    return json({ ok: true, swept: results.length, confirmed: results.filter((x) => (x as { confirmed?: boolean }).confirmed).length, results });
  } catch (e) {
    console.error("verify error:", e);
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
