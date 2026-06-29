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
- [x] Add iOS app target alongside the existing macOS target (done — Universal `BetterContentLibrary-iOS`, see Phase 3)

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

#### Finder-style Library + thumbnail fix (2026-06-25 → 26)
- [x] **Library browser ported (literally) from VideoTag**, adapted to BCL's `Clip`/R2 model with folders + move added. Grid is VideoTag's `ClipGridView` (flexible columns @ `targetItemWidth 240`, manual click handling: single-click select, ⌘/⇧ multi-select, **double-click opens**, scroll-into-view on selection). List is VideoTag's `ClipTableView` — a native **`NSTableView`** (`LibraryTableView`) for snappy selection + native column sorting + inline rename + double-click open + context menu. Keyboard via ported **`BrowserKeyController`** (one `NSEvent` local monitor: arrows move grid selection, Space opens preview, ⌘A select-all). Hover-skim (`SkimProvider`) + `AVPlayer` preview preserved. Toolbar = Icon/List switcher + Sort menu (`@AppStorage`-persisted); `navigationSubtitle` item count; bottom **path bar** (BCL folders). Unified `LibraryItem` (folder|clip) selection/sort model. **Move**: drag clip→folder/breadcrumb (grid) or "Move to" submenu (both); moves whole selection if a selected clip is dragged. Core additions: `ClipsService.setTitle`, `LibraryModel.renameClip/renameFolder`.
- [x] **Thumbnail-creation bug fixed** — `VideoIngest.thumbnailJPEG` was grabbing frame 0 (usually a black/blank lead-in). Now seeks ~10% in (clamped), 640px/0.8 quality, matching VideoTag's `ThumbnailGenerator`. Added **Regenerate Thumbnail** (single + bulk) context action: re-downloads from R2, re-posters, re-uploads, busts the `ThumbnailLoader` cache (`invalidate(clipId:)`); poster card refreshes via `.task(id: clip.updatedAt)`. Existing black thumbnails fix on demand; new uploads already correct.
- [x] **Inconsistent posters fixed** — `thumbnailJPEG` left `requestedTimeTolerance` at the default `kCMTimePositiveInfinity`, so `AVAssetImageGenerator` returned the nearest keyframe (frame 0 … past the seek point, varying per clip's GOP). Pinned tolerance to `.zero` for the exact frame at the seek point — deterministic across clips (the skim generator already pinned tolerance, which is why skimming looked consistent and static posters didn't). Existing posters need a one-time Regenerate (⌘A → Regenerate N Thumbnails) to pick up the change.
#### Settings, delete, history nav + thumbnail persistence (2026-06-29)
- [x] **Settings window** (`Settings` scene, ⌘,) — `SettingsView` with a **Video skimming** toggle (`@AppStorage` key `videoSkimmingEnabled`, default on). `ClipThumbnail` gates hover-scrub on it (`canSkim = skimEnabled && skimmingEnabled`); skim frames still generated at runtime by `SkimProvider`.
- [x] **Thumbnails generated once, persisted, displayed without round-trips** — root cause of "not displaying" was mostly legacy clips with no `thumb_key` (they predate poster upload). `ThumbnailLoader` now stores posters in **Application Support** (survives cache purges), checks local disk *before* the `thumb_key`/R2 path, and exposes `store(_:for:)`; `AppModel.upload` seeds the draft's poster so new cards show instantly. `VideoIngest.thumbnailJPEG` falls back to a tolerant seek if the exact frame can't be decoded. **Auto-backfill** (`backfillMissingThumbnails`, once per session, persisted) renders posters for legacy/failed clips on load — no more manual regenerate. Shared core `renderThumbnail(for:)` used by regenerate + backfill.
- [x] **Delete videos** — `ClipsService.delete`, `StorageService.deleteObjects` + new `r2-sign` **delete** action (v3, deletes video + thumb server-side), `AppModel.deleteClips` (R2 → DB → local cache). Wired into grid + list context menus (selection-aware) with a destructive confirmation dialog.
- [x] **Back/forward history navigation** — `LibraryModel` back/forward stacks (`goBack`/`goForward`/`canGoBack`/`canGoForward`), top-left toolbar `ControlGroup` (`.navigation` style) with ⌘[ / ⌘]; history pruned when a folder is deleted.
- [ ] Library grid filters (status/platform/tag/orientation)
- [ ] Realtime subscription so the grid updates live (currently loads on appear + after uploads + manual refresh)
- [ ] Multi-clip drag (currently drags the single clip under the cursor) and arrow-key scroll-into-view
- [ ] Add a `failed` clip_status (failed uploads currently revert to `ingesting` for retry)

## Phase 2 — Scheduling (macOS)
- [ ] Calendar view (month/week) with clips placed on dates
- [ ] Inspector: platform, date/time, tags, status editing
- [ ] Realtime sync subscription

## Phase 3 — iOS

#### Universal iOS app with desktop feature parity (2026-06-29)
- [x] **Shared controller layer promoted to `BetterContentCore`** — `AppModel`, `LibraryModel`, `ScheduleModel`, `ThumbnailLoader`, `SkimProvider`, `LibraryEntry` (renamed from `LibraryItem` to avoid the `DeveloperToolsSupport.LibraryItem` clash), `LibrarySortKey`, `SettingsKey`, and the `Clip` display/`isPlayable` helpers now live in core, made `public`. New `Platform/PlatformImage.swift` typealias (NSImage on macOS, UIImage on iOS) lets the thumbnail/skim code be shared. macOS app rebuilt clean; both apps are now thin SwiftUI view layers over identical logic.
- [x] **iOS app target added** (`BetterContentLibrary-iOS`, Universal iPhone+iPad, bundle id `Nicolas.BetterContentLibrary`, iOS 17) via pbxproj surgery using the project's filesystem-synchronized groups; shared scheme added. Builds, installs, and launches in the simulator.
- [x] **Auth flow** — `LoginView` (email/password sign-in + sign-up) over the shared `AuthService`; `RootView` gate; `MainTabView` (Library/Upload/Schedule/Settings) owns the session `AppModel`. Background-upload completion handed off via `UIApplicationDelegateAdaptor`.
- [x] **Library** — grid + native `List` (swipe-to-delete), folders, breadcrumb, **back/forward** (shared history), sort, thumbnails, **drag-to-skim** (touch analog of hover, honors the skim toggle), tap-to-preview (AVKit), context menu (preview/rename/regenerate/move/delete), one-time poster backfill. Drag-a-clip-to-folder on iPad.
- [x] **Upload** — `PhotosPicker` (camera roll) + Files importer → shared import pipeline → draft review sheet → background upload with progress.
- [x] **Schedule** — month calendar reusing `ScheduleModel`: chips, add sheet, drag-to-reschedule, long-press delete, prev/next/today.
- [x] **Day detail + download** — tapping a calendar day opens a sheet with a horizontally swipeable gallery (`TabView .page`) of `ScheduledPostCard`s (one per post): title → tappable thumbnail (→ preview) → metadata (uploaded-by via new `ProfilesService`/`ScheduleModel.uploaderName`, scheduled time, platform, duration, description) → **pinned "Download to Photos"** button. Download via new `AppModel.downloadVideoFile(for:)` (R2 → temp file) + `PhotoSaver` (`PHPhotoLibrary` add-only; `INFOPLIST_KEY_NSPhotoLibraryAddUsageDescription` set). The "+" still adds a post for that day.
- [x] **Settings** — video-skimming toggle (shared `SettingsKey`), account info, sign out.
- [x] Verified signed-in on simulator: library + thumbnails load from live backend; build green. (Card gallery/download exercised via build + live data; tap-through left to manual QA.)
- [ ] Download: also offer "Save to Files", and mark-used (set `downloaded` status / `downloads` row) after a successful save

## Phase 4 — Push notifications (2026-06-29)
- [x] **"Notify whom" field** — migration 0007 added `schedules.notify_profile_id` (→ `profiles`, null = no notification); single-member picker in the add-schedule sheet on both iOS and macOS, defaulting to the scheduling user (`ScheduleModel.currentProfileId`/`orgMembers`). Plumbed through `SchedulesService.create` and `ScheduleModel.add`.
- [x] **iOS APNs registration** — `aps-environment` entitlement added; `PushManager` requests permission, registers for remote notifications, and upserts the token into `devices` (new `DevicesService`, conflict on `apns_token`, environment sandbox/production via `#if DEBUG`). Activated from `MainTabView` once signed in.
- [x] **Scheduled send** — edge function `send-due-notifications` (deployed): finds due schedules (`scheduled_at <= now`, `notified_at is null`, has notify target), signs an ES256 APNs JWT from the `.p8` (cached ~40 min), pushes to the notify-user's devices (sandbox/prod host per device), stamps `notified_at` so each fires once. Driven by a `pg_cron` job (migration 0008) every minute via `pg_net`, authed with the service-role key read from Vault (`service_role_key`).
- [x] **Deep link** — notification payload carries `scheduled_at`/`schedule_id`/`clip_id`; tap routes via `DeepLinkCenter` to the Schedule tab and opens that day's `DayDetailSheet` (cold launch + running).
- [ ] **BLOCKED on user setup** (see below) — create the APNs `.p8` Auth Key + enable Push capability on the App ID; set edge secrets `APNS_KEY_ID`/`APNS_TEAM_ID`/`APNS_PRIVATE_KEY`/`APNS_BUNDLE_ID`; store the service-role key in Vault as `service_role_key`. Until done the cron call 401s / the function returns "APNs not configured" (safe no-op).
- [ ] Notification → download deep-link handling (currently opens the post card; download is one more tap)

## Phase 5 — Productize (later)
- [ ] Onboarding / org invites
- [ ] Billing
- [ ] Web app

---

## Decisions still open
- Which social platforms first?
- Desktop auto-post via platform APIs, or download-only?
- Single vs. multiple watched folders?
