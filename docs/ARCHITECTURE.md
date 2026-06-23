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
ensures users only see their org's rows.

- **organizations** — the tenant (`id`, `name`)
- **profiles** — one per auth user (`id`, `org_id`, `display_name`, `role`: owner / editor / manager / viewer)
- **clips** — `id`, `org_id`, `uploaded_by`, `title`, `r2_key`, `file_size`, `duration_s`, `width`, `height`, `orientation` (vertical/horizontal/square), `content_hash`, `status`, `created_at`
- **schedules** — `id`, `clip_id`, `platform`, `scheduled_at`, `timezone`, `status` (planned/posted/skipped), `posted_at`, `notes` — *separate table: one clip → many platforms/dates*
- **tags** + **clip_tags** — free-form labels with colors
- **downloads** — `clip_id`, `profile_id`, `downloaded_at` — "has it been pulled/used?"
- **devices** — `profile_id`, `apns_token` — for push

### Clip status lifecycle

```
Ingesting → Uploading → Ready → Scheduled → Downloaded → Posted
```

Tags and the "used" flag are orthogonal — a clip can be `Posted` and tagged "evergreen".

## Key flows

- **Upload:** macOS requests presigned `PUT` from an Edge Function → uploads directly to R2 (background URLSession) → confirms → server writes the `clips` row.
- **Download:** client requests presigned `GET` (short TTL) → pulls from R2 → logs a `downloads` row.
- **Live sync:** both apps subscribe to Realtime on `clips`/`schedules` for their org.
- **Scheduled push:** `pg_cron` runs each minute → finds `schedules` due in ~15 min and not yet notified → Edge Function signs an APNs JWT (`.p8`) and pushes to the org's devices with a deep link → marks notified.

## Clients

### macOS
- **Folder watcher:** FSEvents; debounce until the file stops growing, then hash + read metadata via AVFoundation (duration, dimensions → orientation) + thumbnail, then background upload.
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
