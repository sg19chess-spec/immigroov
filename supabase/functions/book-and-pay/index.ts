// =============================================================================
// book-and-pay
// Creates a (pending) booking + a Stripe PaymentIntent in one call.
//   - resolves the correct regional price (offer_price ?? base_price)
//   - applies a discount code if valid
//   - adds the Immigroov platform fee (service_pricing.immigroov_price)
//   - records a customer_payments row (status 'initiated')
//   - returns the PaymentIntent client_secret for the frontend to confirm
// Works for logged-in users AND anonymous guests (via create_guest_booking).
// =============================================================================
import { adminClient, stripe, userClient } from "../_shared/clients.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const body = await req.json();
    const {
      mentor_id, service_id, slot_time, country_code,
      discount_code, specific_availability_id,
      guest, // { email, first_name, timezone } — required only for guests
    } = body;

    if (!mentor_id || !service_id || !slot_time || !country_code) {
      return json({ error: "mentor_id, service_id, slot_time, country_code required" }, 400);
    }

    const admin = adminClient();

    // 1) Resolve price for this service + country (fallback to any active row).
    let { data: pricing } = await admin
      .from("service_pricing")
      .select("currency, base_price, offer_price, immigroov_price")
      .eq("service_id", service_id).eq("country_code", country_code)
      .eq("is_active", true).maybeSingle();
    if (!pricing) {
      const fallback = await admin
        .from("service_pricing")
        .select("currency, base_price, offer_price, immigroov_price")
        .eq("service_id", service_id).eq("is_active", true).limit(1).maybeSingle();
      pricing = fallback.data;
    }
    if (!pricing) return json({ error: "No pricing for this service" }, 400);

    const mentorPrice = Number(pricing.offer_price ?? pricing.base_price);
    const platformFee = Number(pricing.immigroov_price ?? 0);

    // 2) Apply discount (validated server-side) to the mentor price only.
    let discountId: number | null = null;
    let discountPct = 0;
    if (discount_code) {
      const { data: d } = await admin
        .from("discounts")
        .select("id, percentage, max_uses, expires_at, is_active")
        .eq("code", discount_code).maybeSingle();
      const valid = d && d.is_active &&
        (!d.expires_at || new Date(d.expires_at) > new Date());
      if (valid) { discountId = d!.id; discountPct = d!.percentage ?? 0; }
    }
    const discountedMentorPrice = mentorPrice * (1 - discountPct / 100);
    const customerTotal = +(discountedMentorPrice + platformFee).toFixed(2);
    const currency = (pricing.currency ?? "usd").toLowerCase();

    // 3) Create the booking (guest path links the anonymous auth user).
    let bookingId: number;
    const uc = userClient(req);
    const { data: { user } } = await uc.auth.getUser();
    if (!user) return json({ error: "No session" }, 401);

    const { data: profile } = await admin
      .from("users").select("id").eq("auth_id", user.id).maybeSingle();

    if (profile) {
      const { data: b, error } = await admin.from("bookings").insert({
        user_id: profile.id, mentor_id, service_id, slot_time,
        status: "pending", discount_id: discountId,
        customer_timezone: guest?.timezone ?? null,
        specific_availability_id: specific_availability_id ?? null,
      }).select("id").single();
      if (error) return json({ error: error.message }, 409); // e.g. overlap
      bookingId = b.id;
    } else {
      if (!guest?.email) return json({ error: "guest.email required" }, 400);
      const { data: b, error } = await uc.rpc("create_guest_booking", {
        p_mentor_id: mentor_id, p_service_id: service_id, p_slot_time: slot_time,
        p_email: guest.email, p_first_name: guest.first_name ?? null,
        p_timezone: guest.timezone ?? "UTC",
        p_specific_availability_id: specific_availability_id ?? null,
      }).single();
      if (error) return json({ error: error.message }, 409);
      bookingId = (b as { id: number }).id;
      if (discountId) await admin.from("bookings").update({ discount_id: discountId }).eq("id", bookingId);
    }

    // 4) Create the PaymentIntent (amount in the smallest currency unit).
    const zeroDecimal = ["jpy", "krw", "vnd"].includes(currency);
    const amountMinor = Math.round(customerTotal * (zeroDecimal ? 1 : 100));
    const pi = await stripe.paymentIntents.create({
      amount: amountMinor,
      currency,
      metadata: {
        booking_id: String(bookingId),
        mentor_price: String(discountedMentorPrice.toFixed(2)),
        immigroov_fee: String(platformFee.toFixed(2)),
      },
    });

    // 5) Record the payment attempt.
    await admin.from("customer_payments").insert({
      booking_id: bookingId, amount: customerTotal, currency: currency.toUpperCase(),
      status: "initiated", stripe_payment_id: pi.id,
    });

    return json({
      booking_id: bookingId,
      client_secret: pi.client_secret,
      amount: customerTotal,
      currency: currency.toUpperCase(),
      breakdown: { mentor_price: +discountedMentorPrice.toFixed(2), immigroov_fee: platformFee },
    });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
