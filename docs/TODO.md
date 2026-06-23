# BetterContentLibrary — Progress & TODO

Living checklist of where we are. See [ARCHITECTURE.md](ARCHITECTURE.md) for the why.

**Legend:** `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked (needs Nicolas)

---

## Phase 0 — Scaffolding & infrastructure

### Project structure
- [ ] Restructure into a shared local Swift package `BetterContentCore`
- [ ] Add iOS app target alongside the existing macOS target
- [ ] Add `supabase-swift` dependency

### Supabase (project ref: srltmrcwpdtjiiflwwkb — connected via MCP)
- [x] Create Supabase project (Nicolas)
- [x] Schema migration: organizations, profiles, clips, schedules, tags, clip_tags, downloads, devices (migrations 0001)
- [x] Row-Level Security policies (org-scoped via current_org_id()) (migration 0002)
- [x] Signup trigger (create org + owner profile) + clips.updated_at + Realtime on clips/schedules (migration 0003)
- [x] Locked down SECURITY DEFINER functions; security advisor clean (migration 0004)
- [ ] Auth provider config in dashboard (enable email and/or Sign in with Apple) — Nicolas
- [ ] Edge Function: presigned R2 upload/download URLs (needs R2 creds)
- [ ] Edge Function: APNs push sender (needs .p8)
- [ ] pg_cron job: scan schedules due ~15 min out → push (Phase 4)

### Cloudflare R2 (needs account setup)
- [!] Create R2 bucket + API token (Nicolas)
- [ ] CORS config for direct browser/app uploads
- [ ] Wire bucket credentials into Supabase Edge Function secrets

### Push (Apple)
- [!] Create APNs auth key (`.p8`) in Apple Developer (Nicolas)
- [ ] Configure push entitlement on iOS target
- [ ] Store `.p8` + key id + team id as Edge Function secrets

---

## Phase 1 — Ingest (macOS)
- [ ] FSEvents folder watcher with write-completion debounce
- [ ] AVFoundation metadata extraction (duration, dimensions → orientation) + thumbnail
- [ ] Content hashing / dedupe
- [ ] Background URLSession upload to R2 via presigned URL
- [ ] Library grid view with filters (status/platform/tag/orientation)

## Phase 2 — Scheduling (macOS)
- [ ] Calendar view (month/week) with clips placed on dates
- [ ] Inspector: platform, date/time, tags, status editing
- [ ] Realtime sync subscription

## Phase 3 — iOS
- [ ] Auth flow
- [ ] Calendar of scheduled clips
- [ ] Download manager (to Files / Photos) + mark-used
- [ ] APNs device registration

## Phase 4 — Push
- [ ] End-to-end scheduled notification with deep link to clip
- [ ] Notification → download deep-link handling

## Phase 5 — Productize (later)
- [ ] Onboarding / org invites
- [ ] Billing
- [ ] Web app

---

## Decisions still open
- Which social platforms first?
- Desktop auto-post via platform APIs, or download-only?
- Single vs. multiple watched folders?
