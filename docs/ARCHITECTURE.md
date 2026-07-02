# BetterContentLibrary — Architecture

A content-management tool for video creators. Finished videos are exported to a
watched folder, ingested by the macOS app, stored in the cloud, scheduled against
a calendar, and pulled down on iOS for posting.

## Components

- **macOS app** (SwiftUI) — folder watcher, ingest, upload, library + scheduling/calendar.
- **iOS app** (SwiftUI) — calendar, download manager, push notifications.
- **Cloud backend** — Supabase (metadata/coordination) + Cloudflare R2 (video files).
- **Web app** — explicitly out of scope for now; schema is kept web-ready.

## System diagram

```
   macOS app                 iOS app                (web later)
  ┌──────────┐            ┌──────────┐
  │ folder   │            │ calendar │
  │ watcher  │            │ download │
  │ library  │            │ push     │
  │ calendar │            └────┬─────┘
  └────┬─────┘                 │
       │   shared Swift package (models, API, R2 client)
       └──────────┬────────────┘
                  │  HTTPS + Realtime
        ┌─────────▼──────────┐         presigned URLs
        │     Supabase       │◄───────────────────────┐
        │  Postgres + RLS    │                        │
        │  Auth (multi-org)  │      direct up/download │
        │  Edge Functions    │                  ┌─────▼──────┐
        │  pg_cron scheduler │                  │ Cloudflare │
        └─────────┬──────────┘                  │     R2     │
                  │ APNs (.p8)                   │  (videos)  │
                  ▼                              └────────────┘
            Apple Push (iOS)
```

**Golden rule:** metadata flows through Supabase; video bytes never do. Clients
get a short-lived presigned URL and talk straight to R2.

## Locked decisions

| Decision | Choice | Why |
|---|---|---|
| Scale | Personal now, multi-tenant-ready | Build for one user, grow into a product without a rewrite |
| Users | Creator + collaborators with roles | Shared org library; explains "uploaded by" metadata |
| Apple Developer | Active | APNs push + real-device testing from day one |
| Backend | Supabase (managed) | Postgres fits relational scheduling data; Auth, Realtime, Edge Functions, pg_cron |
| Video storage | Cloudflare R2 | S3-compatible, **zero egress** — download-heavy mobile workflow is free |
| Push | APNs via `.p8` from Edge Function | Server-side scheduled push, ~15 min before post time |
| Clients | SwiftUI + shared `BetterContentCore` package | Write core (models/API/R2) once for both apps |

**Rejected:** CloudKit (blocks web app, awkward scheduled push, clumsy large assets);
Firebase (video egress cost, Firestore worse fit than SQL for relational data).

## Data model (Postgres)

Multi-tenant from day one: every row carries `org_id`, and Row-Level Security
ensures users only see their org's rows. The schema lives in
`supabase/migrations/` — the repo is the source of truth; changes go through
new migration files, never ad-hoc DDL.

- **organizations** — the tenant (`id`, `name`)
- **profiles** — one per auth user (`id`, `org_id`, `display_name`, `role`: owner / editor / manager / viewer)
- **clips** — `id`, `org_id`, `uploaded_by`, `title`, `r2_key`, `file_size`, `duration_s`, `width`, `height`, `orientation` (vertical/horizontal/square), `content_hash`, `folder_id`, `thumb_key`, `captured_at`, `status`, `created_at`
- **folders** — nestable, org-scoped library folders
- **schedules** — `id`, `clip_id`, `platform`, `scheduled_at`, `timezone`, `status` (planned/posted/skipped), `posted_at`, `notes`, `notify_profile_id`, `notified_at` — *separate table: one clip → many platforms/dates*
- **tags** + **clip_tags** — free-form labels with colors
- **downloads** — `clip_id`, `profile_id`, `downloaded_at` — "has it been pulled/used?"
- **devices** — `profile_id`, `apns_token`, `environment` — for push

### Clip status = transfer state only

```
Ingesting → Uploading → Ready
                 ↘ Failed (dead transfer; re-upload replaces it)
```

Whether a clip is *scheduled / downloaded / posted* is *derived* from the
`schedules` and `downloads` tables — one clip can have many schedules, so a
clip-level "posted" flag would be ambiguous. `clips.status` answers exactly one
question: are the bytes in R2?

Upload durability: files are staged in an app-container directory and tracked
in a persistent registry (`PendingUploadStore`); `UploadReconciler` is the one
place that turns background-upload outcomes into status writes, and its launch
sweep marks device-owned uploads with no surviving task as `failed` and cleans
orphaned staged files. Tags and the "used" flag are orthogonal — a clip can be
posted and tagged "evergreen".

## Key flows

- **Upload:** the app stages a copy of the picked file, dedupes by content hash
  (a `failed` twin is replaced; a live one is rejected), creates the `clips` row,
  requests a presigned `PUT` from the `r2-sign` Edge Function, and uploads
  directly to R2 on a background URLSession. `UploadReconciler` resolves the row
  to `ready`/`failed` — including transfers that finish while the app is dead.
- **Download:** client requests presigned `GET` (short TTL) → pulls from R2 → logs a `downloads` row.
- **Delete:** one server-side call (`r2-sign` delete) removes the R2 objects and
  then the row, in that order, so a half-failed delete never orphans bytes.
- **Live sync:** both apps subscribe to Realtime on `clips`/`schedules`
  (`RealtimeSync` in the core); a change made on one device reloads the other.
- **Scheduled push:** `pg_cron` runs each minute → Edge Function finds `planned`
  schedules due within the lead window (default 15 min, `NOTIFY_LEAD_SECONDS`),
  skips anything more than 24 h stale, signs an APNs JWT (`.p8`) and pushes to
  the notify-target's devices with a deep link → stamps `notified_at`.

## Clients

### macOS
- **Upload view:** drag-and-drop / file picker → editable draft (metadata via
  AVFoundation, streaming SHA-256, poster) → background upload. (The FSEvents
  folder watcher from the original plan is shelved but kept in the core.)
- **Library view:** thumbnail grid; filter by status/platform/tag/orientation.
- **Scheduling view:** month/week calendar with clips on dates; inspector for platform, date/time, tags, status.

### iOS
Auth → calendar of scheduled clips → tap → download to device → mark used.
Registers for APNs; handles the deep-link notification.

## Project structure

- **`BetterContentCore`** — local Swift package: models, Supabase client wrapper, R2 up/download, business logic. Used by both apps. Uses `supabase-swift`.
- **macOS app target** + **iOS app target** — thin SwiftUI UI layers on the core.

## Rough cost

Apple Developer $99/yr · Supabase free tier (then $25/mo Pro) · R2 ≈ $0.015/GB-month,
zero egress (~$15/mo per TB, downloads free) · APNs free. Early on ≈ **$0–25/month**.

## Open questions

- Which social platforms to support first?
- Should the desktop app ever auto-post via platform APIs, or stay download-only?
- Single export folder vs. multiple watched folders?
