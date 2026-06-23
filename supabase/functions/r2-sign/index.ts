// r2-sign — issues short-lived presigned URLs for direct upload/download to
// Cloudflare R2. JWT-protected: the caller must be an authenticated user, and
// every object is scoped to the caller's organization.
//
// Request (POST, JSON):
//   { "action": "upload",   "ext": "mp4", "contentType": "video/mp4" }
//   { "action": "download", "clipId": "<uuid>" }
//
// Response:
//   upload   -> { "uploadUrl": "...", "key": "orgs/<org>/clips/<uuid>.mp4" }
//   download -> { "downloadUrl": "...", "key": "..." }

import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
import { AwsClient } from "https://esm.sh/aws4fetch@1.0.20";

const URL_TTL_SECONDS = 3600;

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

const R2_ACCOUNT_ID = Deno.env.get("R2_ACCOUNT_ID")!;
const R2_BUCKET = Deno.env.get("R2_BUCKET")!;
const R2_ACCESS_KEY_ID = Deno.env.get("R2_ACCESS_KEY_ID")!;
const R2_SECRET_ACCESS_KEY = Deno.env.get("R2_SECRET_ACCESS_KEY")!;
const R2_ENDPOINT = `https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com`;

const aws = new AwsClient({
  accessKeyId: R2_ACCESS_KEY_ID,
  secretAccessKey: R2_SECRET_ACCESS_KEY,
  region: "auto",
  service: "s3",
});

async function presign(key: string, method: "PUT" | "GET"): Promise<string> {
  const url = new URL(`${R2_ENDPOINT}/${R2_BUCKET}/${key}`);
  url.searchParams.set("X-Amz-Expires", String(URL_TTL_SECONDS));
  const signed = await aws.sign(url.toString(), {
    method,
    aws: { signQuery: true },
  });
  return signed.url;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  // A Supabase client bound to the caller's JWT, so RLS applies to every query.
  const authHeader = req.headers.get("Authorization") ?? "";
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_ANON_KEY")!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: userData, error: userErr } = await supabase.auth.getUser();
  if (userErr || !userData.user) return json({ error: "Unauthorized" }, 401);

  // Resolve the caller's org (RLS lets a user read their own profile row).
  const { data: profile, error: profileErr } = await supabase
    .from("profiles")
    .select("org_id")
    .eq("id", userData.user.id)
    .single();
  if (profileErr || !profile) return json({ error: "No profile/org" }, 403);
  const orgId = profile.org_id as string;

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "Invalid JSON body" }, 400);
  }
  const action = payload.action;

  if (action === "upload") {
    const ext = String(payload.ext ?? "mp4").replace(/[^a-z0-9]/gi, "").toLowerCase() || "mp4";
    const key = `orgs/${orgId}/clips/${crypto.randomUUID()}.${ext}`;
    const uploadUrl = await presign(key, "PUT");
    return json({ uploadUrl, key });
  }

  if (action === "download") {
    const clipId = payload.clipId;
    if (typeof clipId !== "string") return json({ error: "clipId required" }, 400);
    // RLS guarantees the clip is in the caller's org; also confirms it exists.
    const { data: clip, error: clipErr } = await supabase
      .from("clips")
      .select("r2_key")
      .eq("id", clipId)
      .single();
    if (clipErr || !clip?.r2_key) return json({ error: "Clip not found" }, 404);
    const downloadUrl = await presign(clip.r2_key as string, "GET");
    return json({ downloadUrl, key: clip.r2_key });
  }

  return json({ error: "Unknown action" }, 400);
});
