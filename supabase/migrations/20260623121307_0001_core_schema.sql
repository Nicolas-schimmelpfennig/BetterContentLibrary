-- Enums
create type user_role as enum ('owner', 'editor', 'manager', 'viewer');
create type clip_status as enum ('ingesting', 'uploading', 'ready', 'scheduled', 'downloaded', 'posted');
create type clip_orientation as enum ('vertical', 'horizontal', 'square');
create type platform as enum ('instagram', 'tiktok', 'youtube', 'youtube_shorts', 'x', 'facebook', 'linkedin', 'other');
create type schedule_status as enum ('planned', 'posted', 'skipped');

-- Organizations (the tenant)
create table organizations (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  created_at timestamptz not null default now()
);

-- Profiles (one per auth user)
create table profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  org_id       uuid not null references organizations(id) on delete cascade,
  display_name text,
  role         user_role not null default 'owner',
  created_at   timestamptz not null default now()
);
create index profiles_org_id_idx on profiles(org_id);

-- Clips (a video file + its metadata)
create table clips (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references organizations(id) on delete cascade,
  uploaded_by  uuid references profiles(id) on delete set null,
  title        text not null default '',
  r2_key       text,
  file_size    bigint,
  duration_s   numeric,
  width        integer,
  height       integer,
  orientation  clip_orientation,
  content_hash text,
  status       clip_status not null default 'ingesting',
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index clips_org_id_idx on clips(org_id);
create index clips_status_idx on clips(org_id, status);
-- Dedupe: same file content can't be ingested twice within an org
create unique index clips_org_content_hash_idx on clips(org_id, content_hash) where content_hash is not null;

-- Schedules (a clip slotted to a platform + time; one clip -> many schedules)
create table schedules (
  id           uuid primary key default gen_random_uuid(),
  org_id       uuid not null references organizations(id) on delete cascade,
  clip_id      uuid not null references clips(id) on delete cascade,
  platform     platform not null,
  scheduled_at timestamptz not null,
  timezone     text not null default 'UTC',
  status       schedule_status not null default 'planned',
  posted_at    timestamptz,
  notes        text,
  notified_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index schedules_org_id_idx on schedules(org_id);
create index schedules_clip_id_idx on schedules(clip_id);
create index schedules_due_idx on schedules(scheduled_at) where status = 'planned';

-- Tags
create table tags (
  id     uuid primary key default gen_random_uuid(),
  org_id uuid not null references organizations(id) on delete cascade,
  name   text not null,
  color  text,
  unique (org_id, name)
);

create table clip_tags (
  clip_id uuid not null references clips(id) on delete cascade,
  tag_id  uuid not null references tags(id) on delete cascade,
  primary key (clip_id, tag_id)
);

-- Downloads (tracks "has it been pulled/used?")
create table downloads (
  id            uuid primary key default gen_random_uuid(),
  org_id        uuid not null references organizations(id) on delete cascade,
  clip_id       uuid not null references clips(id) on delete cascade,
  profile_id    uuid references profiles(id) on delete set null,
  downloaded_at timestamptz not null default now()
);
create index downloads_clip_id_idx on downloads(clip_id);

-- Devices (APNs tokens for push)
create table devices (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references organizations(id) on delete cascade,
  profile_id  uuid not null references profiles(id) on delete cascade,
  apns_token  text not null unique,
  environment text not null default 'production',
  updated_at  timestamptz not null default now()
);
create index devices_org_id_idx on devices(org_id);
