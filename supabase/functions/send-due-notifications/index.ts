// send-due-notifications — called every minute by pg_cron. Finds planned posts
// coming up within the lead window (scheduled_at <= now + NOTIFY_LEAD_SECONDS,
// not yet notified, with a notify target) and sends an APNs "time to post" push
// to that user's devices.
//
// Delivery semantics (v8):
//  - Pushes carry an apns-expiration of scheduled_at + 1h, so APNs stores and
//    forwards to a device that's briefly offline instead of discarding.
//  - notified_at is stamped only after at least one device send succeeds. Every
//    other outcome (no device registered yet, gateway rejection, a failed
//    devices lookup) increments notify_attempts and retries next minute,
//    giving up at MAX_NOTIFY_ATTEMPTS.
//  - Rescheduling clears notified_at via DB trigger (migration 0015), so a
//    moved post gets a fresh push at its new time.
//  - Tokens rejected as unknown by *both* gateways are deleted from `devices`
//    so they stop accumulating. One gateway's rejection is never enough: a
//    live token with a mislabelled environment draws exactly that answer.
//
// Schedules more than STALE_AFTER_HOURS past are retired silently (stamped
// without sending) so a backlog — e.g. cron downtime or rows edited into the
// past — never triggers a blast of stale pushes.
//
// Auth: invoked by pg_cron with a shared secret in the `x-cron-secret` header.
// The job sends no Authorization header, so this function MUST be deployed with
// verify_jwt off or the platform gateway 401s every call before this check ever
// runs — that setting is pinned in supabase/config.toml, not passed by hand.
// DB access uses the auto-injected service role to bypass RLS.
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

// How many failed passes (one per cron minute) before a schedule is stamped
// anyway, and how long past scheduled_at APNs should keep an undelivered push.
const MAX_NOTIFY_ATTEMPTS = 10;
const EXPIRY_GRACE_SECONDS = 3600;

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

const APNS_HOSTS = {
  production: "api.push.apple.com",
  sandbox: "api.sandbox.push.apple.com",
} as const;
type ApnsEnv = keyof typeof APNS_HOSTS;

// APNs rejects a token sent to the wrong gateway with one of these reasons. A
// device's recorded environment can be wrong (e.g. a dev-signed Release build
// mints a sandbox token but the app labels it "production"), so on these we
// retry the other gateway rather than giving up.
const WRONG_GATEWAY_REASONS = new Set(["BadDeviceToken", "BadEnvironmentKeyInToken"]);

/// Whether APNs is saying "I have no such registration" — either because the
/// token belongs to the *other* gateway (400 BadDeviceToken /
/// BadEnvironmentKeyInToken) or because this gateway once knew it and no
/// longer does (410 Unregistered).
///
/// Both answers are ambiguous on their own: a device whose stored environment
/// is wrong can draw either one from the gateway it doesn't belong to. So this
/// is the signal to *try the other gateway*, never on its own the signal to
/// delete the token — only a rejection from both gateways means that.
function unknownOnThisGateway(res: { status: number; reason: string | null }): boolean {
  return res.status === 410 || (!!res.reason && WRONG_GATEWAY_REASONS.has(res.reason));
}

async function postToGateway(
  env: ApnsEnv,
  jwt: string,
  token: string,
  payload: Record<string, unknown>,
  expiration: number,
): Promise<{ ok: boolean; status: number; reason: string | null }> {
  const res = await fetch(`https://${APNS_HOSTS[env]}/3/device/${token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID!,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // Store-and-forward: keep the push deliverable until it expires, so a
      // device that's offline at send time still gets it when it reconnects.
      "apns-expiration": String(expiration),
    },
    body: JSON.stringify(payload),
  });
  let reason: string | null = null;
  if (!res.ok) {
    const text = await res.text();
    try { reason = JSON.parse(text)?.reason ?? null; } catch { /* non-JSON body */ }
    console.error(`APNs ${res.status} (${reason ?? "?"}) on ${env} for ${token.slice(0, 8)}…: ${text}`);
  }
  return { ok: res.ok, status: res.status, reason };
}

// deno-lint-ignore no-explicit-any
async function sendToDevice(
  admin: any,
  jwt: string,
  device: { id: string; apns_token: string; environment: string },
  payload: Record<string, unknown>,
  expiration: number,
): Promise<boolean> {
  const primary: ApnsEnv = device.environment === "production" ? "production" : "sandbox";
  const other: ApnsEnv = primary === "production" ? "sandbox" : "production";

  const res = await postToGateway(primary, jwt, device.apns_token, payload, expiration);
  if (res.ok) return true;

  // Anything else (429, 5xx, InvalidProviderToken, TopicDisallowed…) is either
  // transient or a provider-config problem — never the token's fault. Keep the
  // row and let the schedule retry on a later pass.
  if (!unknownOnThisGateway(res)) return false;

  const retry = await postToGateway(other, jwt, device.apns_token, payload, expiration);
  if (retry.ok) {
    // The stored environment was wrong. Correct it so future sends hit the
    // right gateway first instead of always double-posting.
    await admin.from("devices").update({ environment: other }).eq("id", device.id);
    return true;
  }

  // Unknown on *both* gateways: the app is genuinely gone (uninstalled, or
  // replaced by a differently-signed build). Only now is it safe to drop the
  // row — deleting on the first gateway's answer alone would throw away live
  // tokens whose recorded environment is simply mislabelled, and nothing
  // re-creates the row until the app is next launched.
  if (unknownOnThisGateway(retry)) {
    await admin.from("devices").delete().eq("id", device.id);
  }
  return false;
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
    .select("id, clip_id, platform, scheduled_at, timezone, notify_profile_id, notify_attempts, clips(title)")
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
  let retrying = 0;

  for (const s of due) {
    // Capture the error: on a failed lookup supabase-js returns data === null,
    // which is indistinguishable from "this user has no devices" unless the
    // error is checked — and retiring the schedule on that mistake is
    // permanent (see the stamping rules below).
    const { data: devices, error: devicesError } = await admin
      .from("devices")
      .select("id, apns_token, environment")
      .eq("profile_id", s.notify_profile_id);
    if (devicesError) {
      console.error(`devices lookup failed for schedule ${s.id}: ${devicesError.message}`);
    }

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
    // Keep the push deliverable until an hour past post time (or an hour from
    // now for already-late sends), rather than discard-if-offline.
    const expiration = Math.max(
      Math.floor(new Date(s.scheduled_at).getTime() / 1000),
      Math.floor(now / 1000),
    ) + EXPIRY_GRACE_SECONDS;

    const registered = devicesError ? [] : (devices ?? []);
    let delivered = 0;
    for (const device of registered) {
      if (await sendToDevice(admin, jwt, device, payload, expiration)) delivered++;
    }
    sent += delivered;

    // Stamp only once APNs has actually accepted a send. Every other outcome —
    // a failed lookup, a target with no registered device yet, a gateway
    // rejection — leaves the row due so it retries next minute, because all of
    // them are recoverable *within the lead window*: a phone that registers its
    // token a few minutes after the scan first ran still gets its push.
    //
    // Only MAX_NOTIFY_ATTEMPTS passes end that, so a genuinely undeliverable
    // schedule (notify target who has never opened the iOS app, permanently
    // dead token) can't retry forever.
    const attempts = (s.notify_attempts ?? 0) + 1;
    if (delivered > 0) {
      await admin.from("schedules").update({ notified_at: new Date().toISOString() }).eq("id", s.id);
    } else if (attempts >= MAX_NOTIFY_ATTEMPTS) {
      const why = devicesError
        ? `devices lookup failing (${devicesError.message})`
        : registered.length === 0
        ? "notify target has no registered device"
        : `${registered.length} device(s), all rejected by APNs`;
      console.error(`giving up on schedule ${s.id} after ${attempts} passes: ${why}`);
      await admin.from("schedules").update({ notified_at: new Date().toISOString() }).eq("id", s.id);
    } else {
      retrying++;
      await admin.from("schedules").update({ notify_attempts: attempts }).eq("id", s.id);
    }
  }

  return json({ due: due.length, sent, retrying });
});
