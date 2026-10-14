// send-due-notifications — called every minute by pg_cron. For each planned
// post with a notify target it sends up to two APNs pushes to that user's
// devices:
//  - the lead push, NOTIFY_LEAD_SECONDS (15 min) ahead ("Upcoming post"),
//    tracked by notified_at;
//  - the due push at scheduled_at ("Time to post"), tracked by
//    due_notified_at (migration 0017). Both carry the schedule id as
//    apns-collapse-id, so the second replaces the first in Notification
//    Center rather than stacking. A lead push that itself went out at or
//    after post time counts as the due push too.
// Pushes are marked time-sensitive so a Focus or the Scheduled Summary
// doesn't hold them (needs the app's time-sensitive entitlement; without it
// iOS just treats them as active).
//
// Also answers a signed-in user's {"action":"test"} (Settings → Send Test
// Notification): pushes to the caller's own devices and returns each device's
// APNs verdict, so delivery can be checked end to end from the phone.
//
// Delivery semantics (v9):
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
// Auth: invoked by pg_cron with a shared secret in the `x-cron-secret` header,
// or by a signed-in app user (Authorization: Bearer <user JWT>, validated
// here) for the test action only. The cron job sends no Authorization
// header, so this function MUST be deployed with
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

// The due push retries until this long past scheduled_at, then is stamped
// anyway — a "time to post" alert half an hour late is noise.
const DUE_RETRY_WINDOW_SECONDS = 1800;

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

type GatewayResult = { ok: boolean; gateway: ApnsEnv; status: number; reason: string | null };

/// One push: the alert payload plus the headers that vary per send.
type Push = {
  payload: Record<string, unknown>;
  /// Unix seconds after which APNs stops trying to deliver.
  expiration: number;
  /// Pushes sharing an id replace each other on the device (≤ 64 bytes).
  collapseId: string;
};

async function postToGateway(
  env: ApnsEnv,
  jwt: string,
  token: string,
  push: Push,
): Promise<GatewayResult> {
  const res = await fetch(`https://${APNS_HOSTS[env]}/3/device/${token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${jwt}`,
      "apns-topic": APNS_BUNDLE_ID!,
      "apns-push-type": "alert",
      "apns-priority": "10",
      // Store-and-forward: keep the push deliverable until it expires, so a
      // device that's offline at send time still gets it when it reconnects.
      "apns-expiration": String(push.expiration),
      "apns-collapse-id": push.collapseId,
    },
    body: JSON.stringify(push.payload),
  });
  let reason: string | null = null;
  if (!res.ok) {
    const text = await res.text();
    try { reason = JSON.parse(text)?.reason ?? null; } catch { /* non-JSON body */ }
    console.error(`APNs ${res.status} (${reason ?? "?"}) on ${env} for ${token.slice(0, 8)}…: ${text}`);
  }
  return { ok: res.ok, gateway: env, status: res.status, reason };
}

type Device = { id: string; apns_token: string; environment: string };

/// Sends one push to one device, falling back to the other gateway when the
/// first says it doesn't know the token. Returns the deciding gateway's
/// answer, plus whether the row was dropped as dead.
async function sendToDevice(
  // deno-lint-ignore no-explicit-any
  admin: any,
  jwt: string,
  device: Device,
  push: Push,
): Promise<GatewayResult & { removed: boolean }> {
  const primary: ApnsEnv = device.environment === "production" ? "production" : "sandbox";
  const other: ApnsEnv = primary === "production" ? "sandbox" : "production";

  const res = await postToGateway(primary, jwt, device.apns_token, push);
  if (res.ok) return { ...res, removed: false };

  // Anything else (429, 5xx, InvalidProviderToken, TopicDisallowed…) is either
  // transient or a provider-config problem — never the token's fault. Keep the
  // row and let the schedule retry on a later pass.
  if (!unknownOnThisGateway(res)) return { ...res, removed: false };

  const retry = await postToGateway(other, jwt, device.apns_token, push);
  if (retry.ok) {
    // The stored environment was wrong. Correct it so future sends hit the
    // right gateway first instead of always double-posting.
    await admin.from("devices").update({ environment: other }).eq("id", device.id);
    return { ...retry, removed: false };
  }

  // Unknown on *both* gateways: the app is genuinely gone (uninstalled, or
  // replaced by a differently-signed build). Only now is it safe to drop the
  // row — deleting on the first gateway's answer alone would throw away live
  // tokens whose recorded environment is simply mislabelled, and nothing
  // re-creates the row until the app is next launched.
  if (unknownOnThisGateway(retry)) {
    await admin.from("devices").delete().eq("id", device.id);
    return { ...retry, removed: true };
  }
  return { ...retry, removed: false };
}

/// The alert for one schedule. `isUpcoming` picks the lead wording.
function schedulePush(
  s: { id: string; clip_id: string; platform: string; scheduled_at: string; timezone: string | null },
  title: string,
  isUpcoming: boolean,
  now: number,
): Push {
  const platform = PLATFORM_NAMES[s.platform] ?? s.platform;
  return {
    payload: {
      aps: {
        alert: {
          title: isUpcoming ? "Upcoming post ⏰" : "Time to post 📲",
          body: `Post “${title}” to ${platform} at ${localTime(s.scheduled_at, s.timezone)}`,
        },
        sound: "default",
        // Breaks through Focus modes and the Scheduled Summary — a post
        // reminder that waits for the evening digest is a missed post.
        "interruption-level": "time-sensitive",
      },
      schedule_id: s.id,
      clip_id: s.clip_id,
      scheduled_at: s.scheduled_at,
    },
    // Keep the push deliverable until an hour past post time (or an hour from
    // now for already-late sends), rather than discard-if-offline.
    expiration: Math.max(
      Math.floor(new Date(s.scheduled_at).getTime() / 1000),
      Math.floor(now / 1000),
    ) + EXPIRY_GRACE_SECONDS,
    collapseId: s.id,
  };
}

/// Pushes to every device of `profileId`. `delivered` counts APNs acceptances;
/// `lookupError` is set when the device list itself couldn't be read.
async function sendToProfile(
  // deno-lint-ignore no-explicit-any
  admin: any,
  jwt: string,
  profileId: string,
  push: Push,
): Promise<{ delivered: number; devices: number; lookupError: string | null }> {
  // Capture the error: on a failed lookup supabase-js returns data === null,
  // which is indistinguishable from "this user has no devices" unless the
  // error is checked — and retiring the schedule on that mistake is
  // permanent (see the stamping rules in the handler).
  const { data, error } = await admin
    .from("devices")
    .select("id, apns_token, environment")
    .eq("profile_id", profileId);
  if (error) return { delivered: 0, devices: 0, lookupError: error.message };

  const devices = (data ?? []) as Device[];
  let delivered = 0;
  for (const device of devices) {
    if ((await sendToDevice(admin, jwt, device, push)).ok) delivered++;
  }
  return { delivered, devices: devices.length, lookupError: null };
}

/// {"action":"test"} from a signed-in user: push to the caller's own devices
/// and report what APNs said for each, so "do pushes work on this phone?" is
/// answerable from the phone itself.
// deno-lint-ignore no-explicit-any
async function handleTest(admin: any, req: Request): Promise<Response> {
  const bearer = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!bearer) return json({ error: "unauthorized" }, 401);
  const { data: userData, error: userErr } = await admin.auth.getUser(bearer);
  if (userErr || !userData?.user) return json({ error: "unauthorized" }, 401);

  const { data, error } = await admin
    .from("devices")
    .select("id, apns_token, environment, install_id, updated_at")
    .eq("profile_id", userData.user.id);
  if (error) return json({ error: error.message }, 500);

  const jwt = await apnsJwt();
  const now = Date.now();
  const push: Push = {
    payload: {
      aps: {
        alert: { title: "Test notification ✅", body: "Push delivery to this device works." },
        sound: "default",
        "interruption-level": "time-sensitive",
      },
    },
    expiration: Math.floor(now / 1000) + 300,
    collapseId: `test-${userData.user.id}`.slice(0, 64),
  };

  const results = [];
  for (const device of (data ?? []) as (Device & { install_id: string | null; updated_at: string })[]) {
    const r = await sendToDevice(admin, jwt, device, push);
    results.push({
      install_id: device.install_id,
      token_prefix: device.apns_token.slice(0, 8),
      registered_at: device.updated_at,
      ok: r.ok,
      gateway: r.gateway,
      status: r.status,
      reason: r.reason,
      removed: r.removed,
    });
  }
  return json({ devices: results });
}

Deno.serve(async (req) => {
  if (!APNS_KEY_ID || !APNS_TEAM_ID || !APNS_PRIVATE_KEY || !APNS_BUNDLE_ID) {
    return json({ skipped: "APNs not configured" });
  }

  const admin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const CRON_SECRET = Deno.env.get("CRON_SECRET");
  if (!CRON_SECRET || req.headers.get("x-cron-secret") !== CRON_SECRET) {
    // Not the cron job: the only other caller is a signed-in user's test.
    let body: Record<string, unknown> = {};
    try { body = await req.json(); } catch { /* empty or non-JSON body */ }
    if (body.action === "test") return handleTest(admin, req);
    return json({ error: "unauthorized" }, 401);
  }

  const now = Date.now();
  const nowIso = new Date(now).toISOString();
  const horizon = new Date(now + NOTIFY_LEAD_SECONDS * 1000).toISOString();
  const staleCutoff = new Date(now - STALE_AFTER_HOURS * 3600 * 1000).toISOString();
  const dueCutoff = new Date(now - DUE_RETRY_WINDOW_SECONDS * 1000).toISOString();

  // Retire long-past schedules without sending, so they stop matching the scan.
  await admin
    .from("schedules")
    .update({ notified_at: nowIso })
    .is("notified_at", null)
    .not("notify_profile_id", "is", null)
    .lt("scheduled_at", staleCutoff);
  // Same for due pushes past their retry window. (Posted/skipped posts are
  // never sent one — the scan below only reads planned rows.)
  await admin
    .from("schedules")
    .update({ due_notified_at: nowIso })
    .is("due_notified_at", null)
    .not("notify_profile_id", "is", null)
    .lt("scheduled_at", dueCutoff);

  const columns = "id, clip_id, platform, scheduled_at, timezone, notify_profile_id, notify_attempts, clips(title)";

  const { data: lead, error } = await admin
    .from("schedules")
    .select(columns)
    .is("notified_at", null)
    .eq("status", "planned")
    .not("notify_profile_id", "is", null)
    .lte("scheduled_at", horizon)
    .order("scheduled_at", { ascending: true })
    .limit(50);
  if (error) return json({ error: error.message }, 500);

  const jwt = (lead?.length ?? 0) > 0 ? await apnsJwt() : null;
  let sent = 0;
  let retrying = 0;
  const leadIds = new Set<string>();

  for (const s of lead ?? []) {
    leadIds.add(s.id);
    // deno-lint-ignore no-explicit-any
    const title = (s as any).clips?.title ?? "your video";
    const isUpcoming = new Date(s.scheduled_at).getTime() > now;
    const r = await sendToProfile(admin, jwt!, s.notify_profile_id, schedulePush(s, title, isUpcoming, now));
    if (r.lookupError) console.error(`devices lookup failed for schedule ${s.id}: ${r.lookupError}`);
    sent += r.delivered;

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
    if (r.delivered > 0) {
      // A lead push sent at/after post time already said "Time to post".
      const stamp: Record<string, string> = { notified_at: new Date().toISOString() };
      if (!isUpcoming) stamp.due_notified_at = stamp.notified_at;
      await admin.from("schedules").update(stamp).eq("id", s.id);
    } else if (attempts >= MAX_NOTIFY_ATTEMPTS) {
      const why = r.lookupError
        ? `devices lookup failing (${r.lookupError})`
        : r.devices === 0
        ? "notify target has no registered device"
        : `${r.devices} device(s), all rejected by APNs`;
      console.error(`giving up on schedule ${s.id} after ${attempts} passes: ${why}`);
      await admin.from("schedules").update({ notified_at: new Date().toISOString() }).eq("id", s.id);
    } else {
      retrying++;
      await admin.from("schedules").update({ notify_attempts: attempts }).eq("id", s.id);
    }
  }

  // Due pushes: post time has arrived, the lead pass is finished (sent or
  // given up), and the post is still planned. Retried every minute until
  // DUE_RETRY_WINDOW_SECONDS past post time (retired above after that).
  const { data: due, error: dueError } = await admin
    .from("schedules")
    .select(columns)
    .is("due_notified_at", null)
    .not("notified_at", "is", null)
    .eq("status", "planned")
    .not("notify_profile_id", "is", null)
    .lte("scheduled_at", nowIso)
    .order("scheduled_at", { ascending: true })
    .limit(50);
  if (dueError) return json({ error: dueError.message }, 500);

  let dueSent = 0;
  const dueJwt = (due?.length ?? 0) > 0 ? (jwt ?? await apnsJwt()) : null;
  for (const s of due ?? []) {
    // Stamped by the lead loop above in this same pass; don't double-send.
    if (leadIds.has(s.id)) continue;
    // deno-lint-ignore no-explicit-any
    const title = (s as any).clips?.title ?? "your video";
    const r = await sendToProfile(admin, dueJwt!, s.notify_profile_id, schedulePush(s, title, false, now));
    if (r.lookupError) console.error(`devices lookup failed for schedule ${s.id}: ${r.lookupError}`);
    if (r.delivered > 0) {
      dueSent += r.delivered;
      await admin.from("schedules").update({ due_notified_at: new Date().toISOString() }).eq("id", s.id);
    } else {
      retrying++;
    }
  }

  return json({ due: (lead?.length ?? 0) + (due?.length ?? 0), sent: sent + dueSent, retrying });
});
