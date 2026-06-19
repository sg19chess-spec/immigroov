// =============================================================================
// send-reminders   (invoked on a schedule by pg_cron — see Phase 5 migration)
// Emails confirmed bookings that start within a window and haven't been
// reminded yet. Idempotent: records each (booking, kind) in booking_reminders
// so a reminder is never sent twice.
//
// Requires table booking_reminders(booking_id, kind, sent_at) — added in the
// reminders migration. Call with body { "kind": "24h" } or { "kind": "1h" }.
// =============================================================================
import { adminClient } from "../_shared/clients.ts";
import { fmt, sendEmail } from "../_shared/email.ts";
import { json } from "../_shared/cors.ts";

const WINDOWS: Record<string, { lo: string; hi: string; label: string }> = {
  "24h": { lo: "23 hours", hi: "25 hours", label: "in 24 hours" },
  "1h": { lo: "30 minutes", hi: "90 minutes", label: "in about an hour" },
};

Deno.serve(async (req) => {
  try {
    const { kind = "24h" } = await req.json().catch(() => ({}));
    const w = WINDOWS[kind];
    if (!w) return json({ error: "kind must be 24h or 1h" }, 400);
    const admin = adminClient();

    // Confirmed bookings starting inside the window, not yet reminded for `kind`.
    const { data: due, error } = await admin.rpc("due_reminders", {
      p_kind: kind, p_lo: w.lo, p_hi: w.hi,
    });
    if (error) return json({ error: error.message }, 500);

    let sent = 0;
    for (const r of (due ?? []) as any[]) {
      await sendEmail(
        r.email, `Reminder: your Immigroov session is ${w.label}`,
        `<p>Hi ${r.first_name ?? ""}, your session is ${w.label} — ` +
          `<b>${fmt(r.slot_utc, r.customer_tz)}</b> (your time).</p>`,
      );
      await admin.from("booking_reminders")
        .insert({ booking_id: r.booking_id, kind });
      sent++;
    }
    return json({ kind, sent });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
