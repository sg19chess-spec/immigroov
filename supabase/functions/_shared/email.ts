// Minimal transactional-email helper using Resend (https://resend.com).
// Swap the fetch body for SES/Postmark if you prefer — the interface stays.
const RESEND_API_KEY = Deno.env.get("RESEND_API_KEY");
const FROM_EMAIL = Deno.env.get("FROM_EMAIL") ?? "Immigroov <noreply@immigroov.com>";

export async function sendEmail(to: string, subject: string, html: string) {
  if (!RESEND_API_KEY) {
    console.warn("RESEND_API_KEY not set — skipping email to", to);
    return;
  }
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ from: FROM_EMAIL, to, subject, html }),
  });
  if (!res.ok) console.error("Email send failed:", await res.text());
}

// Pretty-print a booking time in a given IANA timezone.
export function fmt(utc: string, tz: string) {
  return new Intl.DateTimeFormat("en", {
    dateStyle: "full", timeStyle: "short", timeZone: tz,
  }).format(new Date(utc));
}
