// =============================================================================
// review-verification   (admin only)
// Approve or reject a mentor's submitted verification document.
//   - admin-gated
//   - stamps reviewed_at + comments
//   - if ALL of a mentor's verifications are approved, marks their user verified
// =============================================================================
import { adminClient } from "../_shared/clients.ts";
import { corsHeaders, json } from "../_shared/cors.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  try {
    const admin = adminClient();
    const token = (req.headers.get("Authorization") ?? "").replace("Bearer ", "");
    const { data: { user } } = await admin.auth.getUser(token);
    const { data: me } = user
      ? await admin.from("users").select("role").eq("auth_id", user.id).maybeSingle()
      : { data: null };
    if (!me || !["admin", "super_admin"].includes(me.role)) {
      return json({ error: "Admins only" }, 403);
    }

    const { verification_id, decision, comments } = await req.json();
    if (!verification_id || !["approved", "rejected"].includes(decision)) {
      return json({ error: "verification_id and decision (approved|rejected) required" }, 400);
    }

    const { data: v, error } = await admin.from("mentor_verifications")
      .update({ status: decision, reviewed_at: new Date().toISOString(), comments })
      .eq("id", verification_id).select("mentor_id").single();
    if (error) return json({ error: error.message }, 400);

    // If the mentor now has no pending/rejected docs, mark them verified.
    const { count: unresolved } = await admin.from("mentor_verifications")
      .select("id", { count: "exact", head: true })
      .eq("mentor_id", v.mentor_id).neq("status", "approved");
    if ((unresolved ?? 0) === 0) {
      const { data: m } = await admin.from("mentors")
        .select("user_id").eq("id", v.mentor_id).single();
      await admin.from("users").update({ is_verified: true }).eq("id", m.user_id);
    }

    return json({ ok: true, decision });
  } catch (e) {
    console.error(e);
    return json({ error: String(e) }, 500);
  }
});
