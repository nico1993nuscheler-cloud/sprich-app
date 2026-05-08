// redeem-license — LemonSqueezy `order_created` webhook receiver.
//
// Verifies the X-Signature HMAC, looks up the buyer by email in
// public.users, inserts a row into public.licenses (single-tier Phase 1
// → tier='starter', source='lemonsqueezy'), and flips any matching
// active trial to status='converted'.
//
// Idempotency: licenses_external_order_id_unique partial index rejects
// duplicate inserts when LS retries the same order. We treat the unique
// violation as a 200 no-op so LS stops retrying.
//
// verify_jwt=false — LemonSqueezy does not send a Supabase JWT; this
// function authenticates the caller via the HMAC signature alone.
//
// Required env vars (set via `supabase secrets set` or dashboard):
//   - LEMONSQUEEZY_WEBHOOK_SECRET — the signing secret from the LS
//     webhook configuration page. Sprint 2C uses the test-mode secret;
//     Sprint 2D will rotate to production.
//   - SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY — auto-populated by the
//     Supabase Edge runtime.

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const WEBHOOK_SECRET = Deno.env.get("LEMONSQUEEZY_WEBHOOK_SECRET");

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function hexToBytes(hex: string): Uint8Array {
  const clean = hex.trim().toLowerCase();
  if (clean.length % 2 !== 0) return new Uint8Array(0);
  const out = new Uint8Array(clean.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(clean.substr(i * 2, 2), 16);
  }
  return out;
}

async function verifySignature(rawBody: string, signatureHex: string, secret: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"],
  );
  const sigBytes = hexToBytes(signatureHex);
  if (sigBytes.length === 0) return false;
  return crypto.subtle.verify("HMAC", key, sigBytes, encoder.encode(rawBody));
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }
  if (!WEBHOOK_SECRET) {
    console.error("redeem-license: LEMONSQUEEZY_WEBHOOK_SECRET not configured");
    return json({ error: "server_misconfigured" }, 500);
  }

  // Read raw body BEFORE parsing — HMAC is computed over the bytes
  // exactly as LemonSqueezy serialized them.
  const rawBody = await req.text();
  const signature = req.headers.get("x-signature") ?? req.headers.get("X-Signature") ?? "";
  if (!signature) {
    return json({ error: "missing_signature" }, 401);
  }
  const valid = await verifySignature(rawBody, signature, WEBHOOK_SECRET);
  if (!valid) {
    return json({ error: "bad_signature" }, 401);
  }

  let payload: any;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const eventName = payload?.meta?.event_name;
  const testMode = payload?.meta?.test_mode === true;

  // Sprint 2C accepts both test-mode and production events. Sprint 2D
  // narrows to test_mode === false once production cuts over.
  if (eventName !== "order_created") {
    return json({ ok: true, skipped: eventName ?? "unknown_event" });
  }

  const orderId = String(payload?.data?.id ?? "");
  const email = String(payload?.data?.attributes?.user_email ?? "").trim().toLowerCase();
  const productName = payload?.data?.attributes?.first_order_item?.product_name ?? null;
  const variantId = payload?.data?.attributes?.first_order_item?.variant_id ?? null;

  if (!orderId || !email) {
    console.error("redeem-license: malformed payload (missing order id or email)", { orderId, email, testMode });
    return json({ error: "malformed_payload" }, 400);
  }

  const admin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

  // Idempotency: if a license already exists for this order, no-op so LS
  // stops retrying. The partial unique index (sprint_2c_licenses_idempotency)
  // also enforces this at the DB layer; we check first to avoid the
  // round-trip + error log.
  const { data: existing } = await admin
    .from("licenses")
    .select("id")
    .eq("external_order_id", orderId)
    .maybeSingle();
  if (existing) {
    return json({ ok: true, idempotent: true, license_id: existing.id });
  }

  // Look up the user. public.users.email is citext, so case-insensitive.
  const { data: userRow, error: userErr } = await admin
    .from("users")
    .select("id, email")
    .eq("email", email)
    .maybeSingle();
  if (userErr) {
    console.error("redeem-license: user lookup failed", userErr.message);
    return json({ error: "db_error" }, 500);
  }
  if (!userRow) {
    // The funnel forces sign-in before checkout, so this branch should
    // be rare (user paid before signing up, or paid with a different
    // email than the one on their Sprich account). Return 200 so LS
    // doesn't retry; log to function_logs for manual reconciliation.
    console.warn("redeem-license: no Sprich user for email — manual reconciliation needed", { email, orderId, testMode, productName });
    return json({ ok: false, reason: "user_not_found" });
  }

  // Insert the license. tier='starter' for Phase 1 single-tier; if a
  // future migration adds multi-seat, map variantId → tier here.
  const { data: inserted, error: insertErr } = await admin
    .from("licenses")
    .insert({
      user_id: userRow.id,
      tier: "starter",
      source: "lemonsqueezy",
      external_order_id: orderId,
    })
    .select("id")
    .single();
  if (insertErr) {
    // Race: another delivery beat us to the unique index. Treat as idempotent.
    if (insertErr.code === "23505") {
      return json({ ok: true, idempotent: true });
    }
    // user_id is UNIQUE on public.licenses — if the user already has a
    // license, treat as idempotent too (a buyer purchasing a second
    // time is unexpected for a 1-seat LTD; we keep their first license).
    if (insertErr.message?.includes("licenses_user_id")) {
      console.warn("redeem-license: user already has a license, ignoring duplicate purchase", { userId: userRow.id, orderId });
      return json({ ok: true, idempotent: true, reason: "user_already_licensed" });
    }
    console.error("redeem-license: insert failed", insertErr);
    return json({ error: "db_error" }, 500);
  }

  // Flip any active trial to 'converted'. Idempotent — if no active
  // trial row exists, the update touches zero rows.
  await admin
    .from("trials")
    .update({ status: "converted" })
    .eq("user_id", userRow.id)
    .eq("status", "active");

  console.log("redeem-license: license attached", { userId: userRow.id, orderId, testMode, variantId });
  return json({ ok: true, license_id: inserted.id, test_mode: testMode });
});
