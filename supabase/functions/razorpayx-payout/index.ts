// =============================================================================
// razorpayx-payout  (admin-initiated INR mentor payout via RazorpayX)
// For a completed, pending, auto_inr payout: ensures the mentor has a RazorpayX
// contact + fund account (created once, hardcoded TEST bank details for sandbox),
// then creates a payout from the business RazorpayX account. Status is finalized
// by the payout.* webhook. Idempotent via reference_id + X-Payout-Idempotency.
//
// NOTE: not admin-gated yet (consistent with the app's other admin_* endpoints —
// "gate before prod"). Add an admin check before real money.
// =============================================================================
import { adminClient, rzp } from "../_shared/razorpay.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

// Sandbox test fund-account details (replaced by real mentor bank details later).
const TEST_BANK = { name: "Immigroov Test Mentor", ifsc: "HDFC0000053", account_number: "1121431121541121" };

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const { booking_id } = await req.json();
    if (!booking_id) return json({ error: "booking_id required" }, 400);
    const admin = adminClient();

    const { data: c } = await admin.rpc("payout_candidate", { p_booking_id: booking_id });
    if (!c) return json({ error: "No payout for that booking" }, 404);
    if (c.existing_payout_id) return json({ ok: true, status: "already_initiated", payout_id: c.existing_payout_id });
    if (c.booking_status !== "completed") return json({ error: `Payout only after completion (status ${c.booking_status})` }, 409);
    if (c.method !== "auto_inr" || String(c.mentor_currency).toUpperCase() !== "INR")
      return json({ error: "RazorpayX payout is INR-mentor only; this one is manual" }, 409);
    if (c.payout_state !== "pending") return json({ error: `Payout is ${c.payout_state}` }, 409);
    if (!Number(c.net_minor)) return json({ error: "Nothing to pay" }, 409);

    const { data: accountNumber } = await admin.rpc("get_app_secret", { p_name: "razorpayx_account_number" });
    if (!accountNumber) return json({ error: "RazorpayX account number not configured (set razorpayx_account_number in Vault)" }, 400);

    // 1) Ensure fund account (create contact + fund account once, cache on mentor).
    let fundAccountId = c.fund_account_id as string | null;
    if (!fundAccountId) {
      const contact = await rzp("/contacts", {
        method: "POST",
        body: JSON.stringify({ name: c.mentor_name || `Mentor ${c.mentor_id}`, type: "vendor", reference_id: `mentor-${c.mentor_id}` }),
      });
      const fa = await rzp("/fund_accounts", {
        method: "POST",
        body: JSON.stringify({ contact_id: contact.id, account_type: "bank_account", bank_account: TEST_BANK }),
      });
      fundAccountId = fa.id;
      await admin.from("mentors").update({ razorpay_contact_id: contact.id, razorpay_fund_account_id: fa.id }).eq("id", c.mentor_id);
    }

    // 2) Create the payout (idempotent).
    let payout;
    try {
      payout = await rzp("/payouts", {
        method: "POST",
        headers: { "X-Payout-Idempotency": `payout-${booking_id}` },
        body: JSON.stringify({
          account_number: accountNumber, fund_account_id: fundAccountId,
          amount: Number(c.net_minor), currency: "INR", mode: "IMPS", purpose: "payout",
          queue_if_low_balance: true, reference_id: `payout-${booking_id}`,
          narration: "Immigroov mentor payout", notes: { booking_id: String(booking_id) },
        }),
      });
    } catch (e) {
      return json({ error: (e as Error).message, code: "PAYOUT_FAILED" }, 502);
    }

    // 3) Record on the payout row; webhook finalizes to 'paid'.
    await admin.from("mentor_payouts").update({
      razorpay_payout_id: payout.id, payout_provider_status: payout.status,
    }).eq("booking_id", booking_id);
    if (payout.status === "processed") await admin.rpc("apply_payout_status", { p_payout_id: payout.id, p_status: "processed" });

    return json({ ok: true, payout_id: payout.id, status: payout.status });
  } catch (e) {
    console.error("razorpayx-payout error:", e);
    return json({ error: String((e as Error)?.message ?? e) }, 500);
  }
});
