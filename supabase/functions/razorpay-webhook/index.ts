// =============================================================================
// razorpay-webhook  (authoritative confirmation — verify_jwt disabled; Razorpay signs)
// Verifies HMAC, stores + dedups the event, RE-FETCHES the payment from Razorpay
// (never trusts webhook JSON for money), then drives the booking/payment state.
// Handles: payment.captured, payment.failed, refund.created/processed.
// =============================================================================
import { adminClient, rzp, verifyWebhook, fromMinor } from "../_shared/razorpay.ts";
import { corsHeaders } from "../_shared/cors.ts";

const ok = () => new Response(JSON.stringify({ ok: true }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const raw = await req.text();
  const sig = req.headers.get("x-razorpay-signature");
  let valid = false;
  try { valid = await verifyWebhook(raw, sig); }
  catch (e) { console.error("verify error:", (e as Error)?.message); return new Response("verify unavailable", { status: 503 }); } // retryable
  if (!valid) return new Response("bad signature", { status: 400 });

  const admin = adminClient();
  const event = JSON.parse(raw);
  const eventId = req.headers.get("x-razorpay-event-id") ?? event?.payload?.payment?.entity?.id ?? crypto.randomUUID();

  // Dedup + audit: first writer wins; a replay finds processed_at set and no-ops.
  const { data: existing } = await admin.from("payment_events").select("processed_at").eq("event_id", eventId).maybeSingle();
  if (existing?.processed_at) return ok();
  await admin.from("payment_events").upsert({
    event_id: eventId, type: event.event, payload: event, signature: sig,
    attempt_count: (existing ? undefined : 0), last_attempt_at: new Date().toISOString(),
  }, { onConflict: "event_id" });

  let errMsg: string | null = null;
  try {
    switch (event.event) {
      case "payment.captured":
      case "order.paid": {
        const pid = event.payload.payment.entity.id;
        const pay = await rzp(`/payments/${pid}`);              // authoritative
        const orderId = pay.order_id;
        const { data: cp } = await admin.from("customer_payments")
          .select("id, booking_id, currency").eq("provider_order_id", orderId).maybeSingle();
        if (!cp) { errMsg = `no payment row for order ${orderId}`; break; }

        const { data: res, error: cErr } = await admin.rpc("confirm_booking_payment", {
          p_booking_id: cp.booking_id, p_provider_ref: pid,
        });
        if (cErr && /HOLD_EXPIRED/.test(cErr.message)) {
          // Money captured but the hold already lapsed → mark paid + full auto-refund.
          await admin.from("customer_payments").update({
            status: "paid", state: "captured", provider_payment_id: pid, provider_payload: pay,
          }).eq("id", cp.id).eq("status", "initiated");
          await admin.rpc("add_ledger", {
            p_booking: cp.booking_id, p_party: "customer", p_kind: "refund",
            p_amount: fromMinor(pay.amount, pay.currency), p_pct: 100, p_reason: "Payment captured after hold expired — auto-refund",
          });
        } else if (cErr) {
          errMsg = cErr.message;
        } else {
          await admin.from("customer_payments").update({ provider_payload: pay }).eq("id", cp.id);
          void res;
        }
        break;
      }
      case "payment.failed": {
        const ent = event.payload.payment.entity;
        await admin.from("customer_payments").update({
          status: "failed", state: "failed",
          provider_error_code: ent.error_code ?? null, provider_error_description: ent.error_description ?? null,
          provider_payload: ent,
        }).eq("provider_order_id", ent.order_id).eq("status", "initiated");
        break;
      }
      case "refund.created":
      case "refund.processed": {
        const ent = event.payload.refund.entity;
        await admin.from("payment_refunds").update({
          status: event.event === "refund.processed" ? "processed" : "created", provider_payload: ent,
        }).eq("provider_refund_id", ent.id);
        // Update payment state from refund totals.
        const { data: cp } = await admin.from("customer_payments")
          .select("id, booking_id, amount, currency").eq("provider_payment_id", ent.payment_id).maybeSingle();
        if (cp) {
          const { data: owed } = await admin.rpc("refund_owed_minor", { p_booking_id: cp.booking_id });
          await admin.rpc("set_payment_state", {
            p_payment_id: cp.id, p_new: Number(owed) > 0 ? "partially_refunded" : "refunded",
          });
        }
        break;
      }
      case "payout.processed":
      case "payout.reversed":
      case "payout.failed":
      case "payout.updated": {
        const ent = event.payload.payout.entity;              // RazorpayX payout status
        await admin.rpc("apply_payout_status", { p_payout_id: ent.id, p_status: ent.status });
        break;
      }
      default:
        break; // ignore other events
    }
  } catch (e) {
    errMsg = String((e as Error)?.message ?? e);
    console.error("webhook handler error:", errMsg);
  }

  await admin.from("payment_events").update({
    processed_at: errMsg ? null : new Date().toISOString(),
    error: errMsg, attempt_count: 1,
    next_retry_at: errMsg ? new Date(Date.now() + 5 * 60_000).toISOString() : null,
  }).eq("event_id", eventId);

  return ok(); // always 200 so Razorpay doesn't hammer retries; unprocessed rows are retried by us
});
