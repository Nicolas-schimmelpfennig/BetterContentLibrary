# BetterContentLibrary — Progress & TODO

Living checklist of where we are. See [ARCHITECTURE.md](ARCHITECTURE.md) for the why.

**Legend:** `[ ]` todo · `[~]` in progress · `[x]` done · `[!]` blocked (needs Nicolas)

---

## Phase 0 — Scaffolding & infrastructure

### Project structure
- [x] Shared local Swift package `BetterContentCore` (models, Supabase client, AuthService); builds clean
- [x] `supabase-swift` dependency wired into the macOS app target
- [x] macOS app: email/password sign-in + sign-up UI, authenticated landing, sandbox entitlements (network client + user-selected files)
- [x] First commit pushed to GitHub (Nicolas-schimmelpfennig/BetterContentLibrary, main)
- [ ] Add iOS app target alongside the existing macOS target (deferred to start of Phase 3)

### Supabase (project ref: srltmrcwpdtjiiflwwkb — connected via MCP)
- [x] Create Supabase project (Nicolas)
- [x] Schema migration: organizations, profiles, clips, schedules, tags, clip_tags, downloads, devices (migrations 0001)
- [x] Row-Level Security policies (org-scoped via current_org_id()) (migration 0002)
- [x] Signup trigger (create org + owner profile) + clips.updated_at + Realtime on clips/schedules (migration 0003)
- [x] Locked down SECURITY DEFINER functions; security advisor clean (migration 0004)
- [x] Auth provider config in dashboard (email enabled, confirm-on-signup) — Nicolas
- [x] Edge Function: presigned R2 upload/download URLs (`r2-sign`, deployed & tested end-to-end)
- [ ] Edge Function: APNs push sender (needs .p8)
- [ ] pg_cron job: scan schedules due ~15 min out → push (Phase 4)

### Cloudflare R2
- [x] Create R2 bucket (`better-content-libray-bucket`) + S3 API token (Nicolas)
- [x] ~~CORS config~~ — not needed: native macOS/iOS clients use URLSession, CORS is browser-only (revisit if a web app is added)
- [x] Wire bucket credentials into Supabase Edge Function secrets (R2_ACCOUNT_ID / R2_BUCKET / R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY)

### Push (Apple)
- [!] Create APNs auth key (`.p8`) in Apple Developer (Nicolas)
- [ ] Configure push entitlement on iOS target
- [ ] Store `.p8` + key id + team id as Edge Function secrets

---

## Phase 1 — Ingest (macOS)
All ingest logic lives in `BetterContentCore` (builds + unit-tested):
- [x] `StorageService`: presign via `r2-sign` + URLSession download to R2
- [x] `BackgroundUploadService`: **true background URLSession** uploads (survive app suspension/quit, replay on relaunch via `taskDescription`; progress via `events()`, status reconciled via `onFinished`/`onFailed`)
- [x] `FolderWatcher` (FSEvents, file-level, with size-stability write-completion debounce)
- [x] `VideoIngest`: AVFoundation metadata (duration, dimensions → orientation) + JPEG thumbnail
- [x] `ContentHasher` (streaming SHA-256) + `ClipsService.findByHash` dedupe
- [x] `ClipsService`: create/applyMetadata/markUploading/setStatus around the lifecycle
- [x] `IngestCoordinator` (macOS): watch → hash/dedupe → create row → metadata → presign → background upload → mark ready
- [x] First UI: folder-watch + library grid (BUILD SUCCEEDED, end-to-end upload confirmed by Nicolas)

### UI overhaul (2026-06-23) — pivot to a 3-view app
Watch-folder shelved for now (core `FolderWatcher`/`IngestCoordinator` kept, app no longer uses them; `WatchedFolderStore` deleted). New structure = sidebar `NavigationSplitView` with three sections:
- [x] **Upload view** — drag-and-drop (or pick) a video → editable metadata sheet pre-filled from the file (title, orientation, creation date; read-only duration/dimensions/size + thumbnail) → background upload. Files copied into the app container (`Application Support/.../PendingUploads`) so the background session keeps access; cleaned up on finish. Core: `ClipDraft` + `ClipUploader` + `VideoIngest.capturedDate`. `clips.captured_at` added (migration 0005). App builds.
- [x] **Library view** — frame.io-style: breadcrumb path, folder tiles + clip grid, create/delete folder, **drag-a-clip-onto-a-folder (or breadcrumb) to move**, thumbnails. Folders table + `clips.folder_id`/`thumb_key` (migration 0006). Thumbnails generated on upload, stored in R2 at `orgs/{org}/thumbs/{clipId}.jpg` via extended `r2-sign` v2 (smoke-tested), loaded + cached by `ThumbnailLoader` (adapted from VideoTag). New core: `Folder`, `FoldersService`, thumbnail + `streamURL` methods on `StorageService`
- [x] **Library hover-skim + AVPlayer preview** — hover a card to scrub frames (`SkimProvider`, frames from presigned R2 stream URLs, playhead overlay); double-click (or context menu) opens an `AVKit` `VideoPlayer` preview. Folders global per org (RLS), confirmed.
- [x] **Schedule view** — month calendar (`ScheduleModel`/`ScheduleView`): per-day schedule chips (platform-colored, with time), add-schedule sheet (clip + platform + time + notes), **drag a chip to another day to reschedule** (keeps time of day), delete via context menu. Backed by new core `SchedulesService`.
- [ ] Library grid filters (status/platform/tag/orientation)
- [ ] Realtime subscription so the grid updates live (currently loads on appear + after uploads + manual refresh)
- [ ] Thumbnails: generated on ingest but not persisted (no `clips` thumbnail column). Decide: add column + upload to `thumbs/` key
- [ ] Add a `failed` clip_status (failed uploads currently revert to `ingesting` for retry)

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
