// =============================================================================
// reconcile-payments  (nightly cron)
// Cross-checks local customer_payments against Razorpay's record of the payment
// and logs any mismatch (amount / status / missing) to payment_reconciliation_log
// for ops review. Should normally find nothing.
// =============================================================================
import { adminClient, rzp, toMinor } from "../_shared/razorpay.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const admin = adminClient();

  // Look at recently-captured payments (bounded window).
  const since = new Date(Date.now() - 36 * 3600_000).toISOString();
  const { data: payments } = await admin.from("customer_payments")
    .select("id, booking_id, amount, currency, status, provider_payment_id")
    .not("provider_payment_id", "is", null).gte("created_at", since).limit(500);

  let mismatches = 0;
  for (const p of payments ?? []) {
    let pay;
    try { pay = await rzp(`/payments/${p.provider_payment_id}`); }
    catch (e) {
      mismatches++;
      await admin.from("payment_reconciliation_log").insert({
        kind: "fetch_failed", provider_payment_id: p.provider_payment_id, booking_id: p.booking_id,
        detail: { error: String((e as Error)?.message ?? e) },
      });
      continue;
    }
    const localMinor = toMinor(Number(p.amount), p.currency);
    const problems: Record<string, unknown> = {};
    if (pay.amount !== localMinor) problems.amount = { local: localMinor, provider: pay.amount };
    if (String(pay.currency).toUpperCase() !== String(p.currency).toUpperCase()) problems.currency = { local: p.currency, provider: pay.currency };
    if (p.status === "paid" && pay.status !== "captured" && pay.status !== "refunded") problems.status = { local: p.status, provider: pay.status };
    if (Object.keys(problems).length) {
      mismatches++;
      await admin.from("payment_reconciliation_log").insert({
        kind: "mismatch", provider_payment_id: p.provider_payment_id, booking_id: p.booking_id, detail: problems,
      });
    }
  }
  return json({ ok: true, checked: payments?.length ?? 0, mismatches });
});
