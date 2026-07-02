// send-due-notifications — called every minute by pg_cron. Finds planned posts
// coming up within the lead window (scheduled_at <= now + NOTIFY_LEAD_SECONDS,
// not yet notified, with a notify target) and sends an APNs "time to post" push
// to that user's devices, then stamps notified_at so each fires once.
//
// Schedules more than STALE_AFTER_HOURS past are retired silently (stamped
// without sending) so a backlog — e.g. cron downtime or rows edited into the
// past — never triggers a blast of stale pushes.
//
// Auth: invoked by pg_cron with a shared secret in the `x-cron-secret` header
// (verify_jwt is off so the gateway lets the call through to this check). DB
// access uses the auto-injected service role to bypass RLS.
//
// Required secrets (set via `supabase secrets set` or the dashboard):
//   APNS_KEY_ID, APNS_TEAM_ID, APNS_PRIVATE_KEY (the .p8 PEM contents),
//   APNS_BUNDLE_ID (e.g. Nicolas.BetterContentLibrary)

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const APNS_KEY_ID = Deno.env.get("APNS_KEY_ID");
const APNS_TEAM_ID = Deno.env.get("APNS_TEAM_ID");
const APNS_PRIVATE_KEY = Deno.env.get("APNS_PRIVATE_KEY");
const APNS_BUNDLE_ID = Deno.env.get("APNS_BUNDLE_ID");

// How far ahead of scheduled_at the push fires (default 15 min, per the
// architecture doc), and how far past it a never-notified schedule is
// considered dead rather than due.
const NOTIFY_LEAD_SECONDS = Number(Deno.env.get("NOTIFY_LEAD_SECONDS") ?? "900");
const STALE_AFTER_HOURS = 24;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// --- APNs provider JWT (ES256), cached up to ~40 min per Apple's guidance ---

let cachedJwt: string | null = null;
let cachedAt = 0;

function b64url(bytes: Uint8Array): string {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): Uint8Array {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const der = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) der[i] = bin.charCodeAt(i);
  return der;
}

async function apnsJwt(): Promise<string> {
  const now = Date.now();
  if (cachedJwt && now - cachedAt < 40 * 60 * 1000) return cachedJwt;

  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: APNS_KEY_ID })));
  const claims = b64url(new TextEncoder().encode(JSON.stringify({ iss: APNS_TEAM_ID, iat: Math.floor(now / 1000) })));
  const signingInput = `${header}.${claims}`;

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(APNS_PRIVATE_KEY!),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  cachedJwt = `${signingInput}.${b64url(new Uint8Array(sig))}`;
  cachedAt = now;
  return cachedJwt;
}

const PLATFORM_NAMES: Record<string, string> = {
  instagram: "Instagram", tiktok: "TikTok", youtube: "YouTube",
  youtube_shorts: "YouTube Shorts", x: "X", facebook: "Facebook",
  linkedin: "LinkedIn", other: "the platform",
};

/// The post's local wall-clock time, using the timezone captured when it was
/// scheduled (falls back to UTC if the stored zone is invalid).
function localTime(iso: string, tz: string | null): string {
  const opts = { hour: "2-digit", minute: "2-digit" } as const;
  try {
    return new Intl.DateTimeFormat("en-GB", { ...opts, timeZone: tz ?? "UTC" }).format(new Date(iso));
  } catch {
    return new Intl.DateTimeFormat("en-GB", { ...opts, timeZone: "UTC" }).format(new Date(iso));
  }
}

async function sendToDevice(
  jwt: string,
  device: { apns_token: string; environment: string },
  payload: Record<string, unknown>,
): Promise<boolean> {
  const host = device.environment === "production"
    ? "api.push.apple.com"
    : "api.sandbox.push.apple.com";
  const res = await fetch(`https://${host}/3/device/${device.apns_token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID!,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
    },
    body: JSON.stringify(payload),
  });
  if (!res.ok) {
    console.error(`APNs ${res.status} for ${device.apns_token.slice(0, 8)}…: ${await res.text()}`);
  }
  return res.ok;
}

Deno.serve(async (req) => {
  const CRON_SECRET = Deno.env.get("CRON_SECRET");
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) {
    return json({ error: "unauthorized" }, 401);
  }

  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY || !APNS_BUNDLE_ID) {
    return json({ skipped: "APNs not configured" });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const now = Date.now();
  const horizon = new Date(now + NOTIFY_LEAD_SECONDS * 1000).toISOString();
  const staleCutoff = new Date(now - STALE_AFTER_HOURS * 3600 * 1000).toISOString();

  // Retire long-past schedules without sending, so they stop matching the scan.
  await admin
    .from("schedules")
    .update({ notified_at: new Date().toISOString() })
    .is("notified_at", null)
    .not("notify_profile_id", "is", null)
    .lt("scheduled_at", staleCutoff);

  const { data: due, error } = await admin
    .from("schedules")
    .select("id, clip_id, platform, scheduled_at, timezone, notify_profile_id, clips(title)")
    .is("notified_at", null)
    .eq("status", "planned")
    .not("notify_profile_id", "is", null)
    .lte("scheduled_at", horizon)
    .order("scheduled_at", { ascending: true })
    .limit(50);

  if (error) return json({ error: error.message }, 500);
  if (!due || due.length === 0) return json({ sent: 0 });

  const jwt = await apnsJwt();
  let sent = 0;

  for (const s of due) {
    const { data: devices } = await admin
      .from("devices")
      .select("apns_token, environment")
      .eq("profile_id", s.notify_profile_id);

    // deno-lint-ignore no-explicit-any
    const title = (s as any).clips?.title ?? "your video";
    const platform = PLATFORM_NAMES[s.platform] ?? s.platform;
    const isUpcoming = new Date(s.scheduled_at).getTime() > now;
    const payload = {
      aps: {
        alert: {
          title: isUpcoming ? "Upcoming post ⏰" : "Time to post 📲",
          body: `Post “${title}” to ${platform} at ${localTime(s.scheduled_at, s.timezone)}`,
        },
        sound: "default",
      },
      schedule_id: s.id,
      clip_id: s.clip_id,
      scheduled_at: s.scheduled_at,
    };

    for (const device of devices ?? []) {
      if (await sendToDevice(jwt, device, payload)) sent++;
    }

    // Stamp once so it never re-fires, even if the user had no registered device.
    await admin.from("schedules").update({ notified_at: new Date().toISOString() }).eq("id", s.id);
  }

  return json({ due: due.length, sent });
});
