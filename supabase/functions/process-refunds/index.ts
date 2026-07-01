// =============================================================================
// process-refunds  (worker — cron-driven; never depends on the browser)
// Finds bookings that still owe a refund (refund ledger minus refunds issued)
// and issues Razorpay refunds against the original payment. Supports multiple
// partial refunds per payment. Idempotency key = refund-{booking}-{version}.
// =============================================================================
import { adminClient, rzp } from "../_shared/razorpay.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const admin = adminClient();

  // Candidate payments: captured, with a provider payment id.
  const { data: payments } = await admin.from("customer_payments")
    .select("id, booking_id, provider_payment_id, currency")
    .not("provider_payment_id", "is", null).eq("status", "paid").limit(200);

  let issued = 0, failed = 0;
  for (const p of payments ?? []) {
    const { data: owed } = await admin.rpc("refund_owed_minor", { p_booking_id: p.booking_id });
    const owedMinor = Number(owed ?? 0);
    if (owedMinor <= 0) continue;

    const { count } = await admin.from("payment_refunds")
      .select("*", { count: "exact", head: true }).eq("booking_id", p.booking_id);
    const version = count ?? 0;
    const key = `refund-${p.booking_id}-${version}`;

    try {
      const refund = await rzp(`/payments/${p.provider_payment_id}/refund`, {
        method: "POST",
        headers: { "X-Razorpay-Idempotency-Key": key },
        body: JSON.stringify({ amount: owedMinor, notes: { booking_id: String(p.booking_id) } }),
      });
      await admin.from("payment_refunds").insert({
        payment_id: p.id, booking_id: p.booking_id, provider_refund_id: refund.id,
        amount_minor: owedMinor, currency: p.currency,
        status: refund.status === "processed" ? "processed" : "created",
        provider_payload: refund, ledger_version: version,
      });
      issued++;
    } catch (e) {
      failed++;
      await admin.from("payment_refunds").insert({
        payment_id: p.id, booking_id: p.booking_id, amount_minor: owedMinor, currency: p.currency,
        status: "failed", ledger_version: version,
        provider_error_code: (e as any)?.rzp?.code ?? null,
        provider_error_description: String((e as Error)?.message ?? e),
      });
      console.error(`refund failed for booking ${p.booking_id}:`, (e as Error)?.message);
    }
  }
  return json({ ok: true, issued, failed });
});
