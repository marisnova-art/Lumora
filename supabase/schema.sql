-- =====================================================================================
-- Lumora Studio — Supabase schema, RLS, RPC and storage policies
-- Run once in Supabase SQL Editor (or `supabase db push`). Then run seed.sql.
-- Idempotent where practical (create if not exists / or replace).
-- =====================================================================================
create extension if not exists pgcrypto;
create extension if not exists pg_trgm;

create or replace function public.touch_updated_at() returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

-- -------------------------------------------------------------------------------------
-- 1. profiles
-- -------------------------------------------------------------------------------------
create table if not exists public.profiles (
  id                   uuid primary key references auth.users(id) on delete cascade,
  email                text,
  username             text check (char_length(username) between 1 and 40),
  avatar_url           text,
  country              text,
  language             text not null default 'en',
  subscription_plan    text not null default 'free' check (subscription_plan in ('free','premium','ai_premium')),
  subscription_status  text not null default 'none',
  account_status       text not null default 'active' check (account_status in ('active','suspended')),
  ai_credits_used      int  not null default 0,
  ai_credits_period    text,                                   -- 'YYYY-MM'
  last_seen_at         timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create index if not exists profiles_created_idx on public.profiles (created_at desc);
create index if not exists profiles_username_trgm on public.profiles using gin (username gin_trgm_ops);
create index if not exists profiles_email_trgm on public.profiles using gin (email gin_trgm_ops);
drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();

-- -------------------------------------------------------------------------------------
-- 2. user_roles  (admin | super_admin | editor) — granted only through set_user_role()
-- -------------------------------------------------------------------------------------
create table if not exists public.user_roles (
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null check (role in ('admin','super_admin','editor')),
  granted_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create or replace function public.has_role(r text) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = r) $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role in ('admin','super_admin')) $$;
create or replace function public.is_super_admin() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role = 'super_admin') $$;
create or replace function public.is_content_editor() returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.user_roles where user_id = auth.uid() and role in ('admin','super_admin','editor')) $$;
create or replace function public.is_active_user() returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and not exists (select 1 from public.profiles where id = auth.uid() and account_status = 'suspended') $$;

-- -------------------------------------------------------------------------------------
-- 3. preset_categories
-- -------------------------------------------------------------------------------------
create table if not exists public.preset_categories (
  slug       text primary key check (slug ~ '^[a-z0-9-]+$'),
  name       jsonb not null default '{}'::jsonb,            -- {"en": "...", "ko": "..."}
  kind       text  not null default 'static' check (kind in ('static','dynamic')),
  sort_order int   not null default 0,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists cats_touch on public.preset_categories;
create trigger cats_touch before update on public.preset_categories for each row execute function public.touch_updated_at();

-- -------------------------------------------------------------------------------------
-- 4. presets  (parameters = non-destructive effect JSON consumed by the WebGL engine)
-- -------------------------------------------------------------------------------------
create table if not exists public.presets (
  preset_id        text primary key check (preset_id ~ '^[a-z0-9][a-z0-9_-]{1,80}$'),
  name             text not null,
  name_i18n        jsonb not null default '{}'::jsonb,
  description      text,
  description_i18n jsonb not null default '{}'::jsonb,
  category         text not null,                            -- soft reference to preset_categories.slug
  subcategory      text,
  tags             text[] not null default '{}',
  thumbnail_url    text,
  preview_url      text,
  effect_type      text not null default 'adjust',
  parameters       jsonb not null default '{}'::jsonb check (jsonb_typeof(parameters) = 'object'),
  supported_media  text[] not null default '{image,video,camera}',
  is_free          boolean not null default true,
  is_premium       boolean not null default false,
  is_published     boolean not null default false,
  is_featured      boolean not null default false,
  version          int not null default 1,
  sort_order       int not null default 0,
  usage_count      bigint not null default 0,
  search_text      text,
  created_by       uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create index if not exists presets_pub_cat_idx   on public.presets (is_published, category, sort_order);
create index if not exists presets_pub_usage_idx on public.presets (is_published, usage_count desc);
create index if not exists presets_created_idx   on public.presets (created_at desc);
create index if not exists presets_featured_idx  on public.presets (is_featured) where is_featured;
create index if not exists presets_search_trgm   on public.presets using gin (search_text gin_trgm_ops);
create index if not exists presets_tags_gin      on public.presets using gin (tags);
create index if not exists presets_media_gin     on public.presets using gin (supported_media);

create or replace function public.presets_before_write() returns trigger language plpgsql as $$
begin
  new.is_free := not new.is_premium;
  new.search_text := lower(concat_ws(' ', new.preset_id, new.name, new.description, new.category, new.subcategory,
                        new.name_i18n::text, new.description_i18n::text, array_to_string(new.tags, ' ')));
  if tg_op = 'INSERT' and new.created_by is null then new.created_by := auth.uid(); end if;
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists presets_bw on public.presets;
create trigger presets_bw before insert or update on public.presets for each row execute function public.presets_before_write();

-- preset_versions (extra table) — history of parameter changes so existing projects never break
create table if not exists public.preset_versions (
  id         bigint generated always as identity primary key,
  preset_id  text not null references public.presets(preset_id) on delete cascade on update cascade,
  version    int  not null,
  parameters jsonb not null,
  changed_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (preset_id, version)
);

-- -------------------------------------------------------------------------------------
-- 5. preset_favorites
-- -------------------------------------------------------------------------------------
create table if not exists public.preset_favorites (
  user_id    uuid not null references auth.users(id) on delete cascade,
  preset_id  text not null references public.presets(preset_id) on delete cascade on update cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, preset_id)
);
create index if not exists favs_preset_idx on public.preset_favorites (preset_id);

-- -------------------------------------------------------------------------------------
-- 6. projects  /  7. project_media
-- -------------------------------------------------------------------------------------
create table if not exists public.projects (
  project_id         uuid primary key,
  user_id            uuid not null references auth.users(id) on delete cascade,
  project_name       text not null default 'Untitled',
  media_type         text not null check (media_type in ('image','video')),
  original_media_url text,                                   -- storage path in bucket "media"
  preview_url        text,                                   -- storage path in bucket "media"
  edit_parameters    jsonb not null default '{}'::jsonb,     -- full resolved parameters snapshot (+ _clips for video)
  preset_ids         text[] not null default '{}',
  project_version    int not null default 1,                 -- schema version of edit_parameters
  meta               jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index if not exists projects_user_idx on public.projects (user_id, updated_at desc);
drop trigger if exists projects_touch on public.projects;
create trigger projects_touch before update on public.projects for each row execute function public.touch_updated_at();

create table if not exists public.project_media (
  id           bigint generated always as identity primary key,
  project_id   uuid not null references public.projects(project_id) on delete cascade,
  user_id      uuid not null references auth.users(id) on delete cascade,
  kind         text not null check (kind in ('original','preview','export')),
  storage_path text not null,
  size_bytes   bigint not null default 0,
  mime_type    text,
  created_at   timestamptz not null default now(),
  unique (project_id, kind)
);
create index if not exists project_media_user_idx on public.project_media (user_id);

-- Server-side storage quota (uses real object sizes from storage.objects, not client-reported sizes)
create or replace function public.enforce_media_quota() returns trigger language plpgsql security definer set search_path = public, storage as $$
declare used bigint; plan text; quota_mb bigint; q jsonb;
begin
  select coalesce(sum((o.metadata->>'size')::bigint),0) into used from storage.objects o
   where o.bucket_id = 'media' and (storage.foldername(o.name))[1] = new.user_id::text;
  select subscription_plan into plan from public.profiles where id = new.user_id;
  select value into q from public.app_settings where key = 'quotas';
  quota_mb := coalesce((q->>(case plan when 'premium' then 'premium_mb' when 'ai_premium' then 'ai_premium_mb' else 'free_mb' end))::bigint, 200);
  if used > quota_mb * 1048576 then
    raise exception 'Storage quota exceeded (% MB)', quota_mb using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists project_media_quota on public.project_media;
create trigger project_media_quota before insert or update on public.project_media for each row execute function public.enforce_media_quota();

-- -------------------------------------------------------------------------------------
-- 8. subscriptions / 9. donations / 10. payment_transactions  (written only by Edge Functions)
-- -------------------------------------------------------------------------------------
create table if not exists public.subscriptions (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid references auth.users(id) on delete set null,
  plan                     text not null check (plan in ('premium','ai_premium')),
  status                   text not null default 'incomplete',    -- active | trialing | past_due | canceled | incomplete | test
  interval                 text not null default 'month' check (interval in ('month','year')),
  provider                 text not null default 'test',
  provider_customer_id     text,
  provider_subscription_id text unique,
  current_period_end       timestamptz,
  cancel_at_period_end     boolean not null default false,
  is_test                  boolean not null default false,
  created_at               timestamptz not null default now(),
  updated_at               timestamptz not null default now()
);
create index if not exists subs_user_idx on public.subscriptions (user_id, status);
drop trigger if exists subs_touch on public.subscriptions;
create trigger subs_touch before update on public.subscriptions for each row execute function public.touch_updated_at();

create table if not exists public.donations (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete set null,
  amount       numeric(12,2) not null check (amount > 0 and amount <= 100000),
  currency     text not null default 'USD',
  interval     text not null default 'once' check (interval in ('once','month')),
  message      text check (char_length(message) <= 280),
  is_anonymous boolean not null default false,
  status       text not null default 'pending' check (status in ('pending','succeeded','failed','refunded','canceled','test')),
  is_test      boolean not null default false,
  provider     text not null default 'test',
  provider_ref text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists donations_user_idx on public.donations (user_id, created_at desc);
create index if not exists donations_ref_idx on public.donations (provider_ref);
drop trigger if exists donations_touch on public.donations;
create trigger donations_touch before update on public.donations for each row execute function public.touch_updated_at();

create table if not exists public.payment_transactions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references auth.users(id) on delete set null,
  kind         text not null check (kind in ('donation','subscription')),
  amount       numeric(12,2) not null default 0,
  currency     text not null default 'USD',
  status       text not null default 'pending',
  provider     text not null default 'test',
  provider_ref text unique,
  is_test      boolean not null default false,
  raw          jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
create index if not exists ptx_created_idx on public.payment_transactions (created_at desc);
drop trigger if exists ptx_touch on public.payment_transactions;
create trigger ptx_touch before update on public.payment_transactions for each row execute function public.touch_updated_at();

-- -------------------------------------------------------------------------------------
-- 11. banners / 12. announcements
-- -------------------------------------------------------------------------------------
create table if not exists public.banners (
  id          uuid primary key default gen_random_uuid(),
  title       jsonb not null default '{}'::jsonb,
  description jsonb not null default '{}'::jsonb,
  kicker      jsonb not null default '{}'::jsonb,
  link        text,
  image_url   text,
  art_seed    int not null default 0,
  sort_order  int not null default 0,
  is_active   boolean not null default true,
  starts_at   timestamptz,
  ends_at     timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
drop trigger if exists banners_touch on public.banners;
create trigger banners_touch before update on public.banners for each row execute function public.touch_updated_at();

create table if not exists public.announcements (
  id           uuid primary key default gen_random_uuid(),
  title        jsonb not null default '{}'::jsonb,
  body         jsonb not null default '{}'::jsonb,
  is_published boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
drop trigger if exists ann_touch on public.announcements;
create trigger ann_touch before update on public.announcements for each row execute function public.touch_updated_at();

-- -------------------------------------------------------------------------------------
-- 13. usage_logs (events, exports, errors, admin audit trail 'admin.*')
-- -------------------------------------------------------------------------------------
create table if not exists public.usage_logs (
  id         bigint generated always as identity primary key,
  user_id    uuid references auth.users(id) on delete set null,
  event      text not null check (char_length(event) <= 80),
  meta       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists logs_event_idx on public.usage_logs (event, created_at desc);
create index if not exists logs_user_idx  on public.usage_logs (user_id, created_at desc);

-- -------------------------------------------------------------------------------------
-- 14. ai_jobs
-- -------------------------------------------------------------------------------------
create table if not exists public.ai_jobs (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references auth.users(id) on delete cascade,
  task            text not null,
  status          text not null default 'queued' check (status in ('queued','processing','succeeded','failed','canceled')),
  params          jsonb not null default '{}'::jsonb,
  input_path      text,
  result_path     text,
  result_url      text,
  provider        text,
  provider_job_id text,
  error_message   text,
  credits         int not null default 1,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists ai_jobs_user_idx on public.ai_jobs (user_id, created_at desc);
drop trigger if exists ai_jobs_touch on public.ai_jobs;
create trigger ai_jobs_touch before update on public.ai_jobs for each row execute function public.touch_updated_at();

-- -------------------------------------------------------------------------------------
-- 15. app_settings / 16. translations
-- -------------------------------------------------------------------------------------
create table if not exists public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
drop trigger if exists settings_touch on public.app_settings;
create trigger settings_touch before update on public.app_settings for each row execute function public.touch_updated_at();

create table if not exists public.translations (
  id         bigint generated always as identity primary key,
  lang       text not null check (lang ~ '^[a-z]{2}(-[A-Z]{2})?$'),
  key        text not null,
  value      text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (lang, key)
);
drop trigger if exists tr_touch on public.translations;
create trigger tr_touch before update on public.translations for each row execute function public.touch_updated_at();

-- =====================================================================================
-- New-user trigger: create profile from auth metadata
-- =====================================================================================
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, username, country, language)
  values (new.id, new.email,
          coalesce(nullif(new.raw_user_meta_data->>'username',''), nullif(new.raw_user_meta_data->>'full_name',''), split_part(new.email,'@',1)),
          new.raw_user_meta_data->>'country',
          coalesce(new.raw_user_meta_data->>'language','en'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- keep profiles.email in sync when the user changes e-mail
create or replace function public.handle_user_email() returns trigger language plpgsql security definer set search_path = public as $$
begin update public.profiles set email = new.email where id = new.id; return new; end $$;
drop trigger if exists on_auth_user_email on auth.users;
create trigger on_auth_user_email after update of email on auth.users for each row execute function public.handle_user_email();

-- =====================================================================================
-- Row Level Security
-- =====================================================================================
alter table public.profiles             enable row level security;
alter table public.user_roles           enable row level security;
alter table public.preset_categories    enable row level security;
alter table public.presets              enable row level security;
alter table public.preset_versions      enable row level security;
alter table public.preset_favorites     enable row level security;
alter table public.projects             enable row level security;
alter table public.project_media        enable row level security;
alter table public.subscriptions        enable row level security;
alter table public.donations            enable row level security;
alter table public.payment_transactions enable row level security;
alter table public.banners              enable row level security;
alter table public.announcements        enable row level security;
alter table public.usage_logs           enable row level security;
alter table public.ai_jobs              enable row level security;
alter table public.app_settings         enable row level security;
alter table public.translations         enable row level security;

-- helper to (re)create policies idempotently
do $$ declare r record; begin
  for r in select schemaname, tablename, policyname from pg_policies where schemaname = 'public' and policyname like 'lumora_%' loop
    execute format('drop policy %I on %I.%I', r.policyname, r.schemaname, r.tablename);
  end loop;
end $$;

-- profiles: own row or admin; users may update only safe columns (see column grants below)
create policy lumora_profiles_select on public.profiles for select using (id = auth.uid() or public.is_admin());
create policy lumora_profiles_update on public.profiles for update using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated, anon;
grant update (username, avatar_url, country, language, last_seen_at) on public.profiles to authenticated;

-- user_roles: read own or admin; writes only via set_user_role()
create policy lumora_roles_select on public.user_roles for select using (user_id = auth.uid() or public.is_admin());

-- categories / presets / versions
create policy lumora_cats_read  on public.preset_categories for select using (is_active or public.is_content_editor());
create policy lumora_cats_write on public.preset_categories for all using (public.is_content_editor()) with check (public.is_content_editor());
create policy lumora_presets_read  on public.presets for select using (is_published or public.is_content_editor());
create policy lumora_presets_write on public.presets for all using (public.is_content_editor()) with check (public.is_content_editor());
create policy lumora_pv_read  on public.preset_versions for select using (public.is_content_editor());
create policy lumora_pv_write on public.preset_versions for insert with check (public.is_content_editor());

-- favorites / projects / media: owner only
create policy lumora_favs_own on public.preset_favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid() and public.is_active_user());
create policy lumora_projects_own on public.projects for all using (user_id = auth.uid()) with check (user_id = auth.uid() and public.is_active_user());
create policy lumora_pmedia_own on public.project_media for all using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.is_active_user() and exists (select 1 from public.projects p where p.project_id = project_media.project_id and p.user_id = auth.uid()));

-- payments: read own or admin; NO client writes (Edge Functions use the service role)
create policy lumora_subs_read on public.subscriptions for select using (user_id = auth.uid() or public.is_admin());
create policy lumora_don_read  on public.donations for select using (user_id = auth.uid() or public.is_admin());
create policy lumora_ptx_read  on public.payment_transactions for select using (user_id = auth.uid() or public.is_admin());

-- content
create policy lumora_banners_read  on public.banners for select using ((is_active and (starts_at is null or starts_at <= now()) and (ends_at is null or ends_at > now())) or public.is_content_editor());
create policy lumora_banners_write on public.banners for all using (public.is_content_editor()) with check (public.is_content_editor());
create policy lumora_ann_read  on public.announcements for select using (is_published or public.is_content_editor());
create policy lumora_ann_write on public.announcements for all using (public.is_content_editor()) with check (public.is_content_editor());
create policy lumora_tr_read   on public.translations for select using (true);
create policy lumora_tr_write  on public.translations for all using (public.is_content_editor()) with check (public.is_content_editor());
create policy lumora_set_read  on public.app_settings for select using (true);
create policy lumora_set_write on public.app_settings for all using (public.is_admin()) with check (public.is_admin());

-- logs: anyone may insert their own events (admin.* only by admins); read own or admin
create policy lumora_logs_insert on public.usage_logs for insert with check ((user_id is null or user_id = auth.uid()) and (event not like 'admin.%' or public.is_content_editor()));
create policy lumora_logs_read   on public.usage_logs for select using (user_id = auth.uid() or public.is_admin());

-- ai jobs: read own or admin; created/updated by the ai-jobs Edge Function only
create policy lumora_ai_read on public.ai_jobs for select using (user_id = auth.uid() or public.is_admin());

-- =====================================================================================
-- RPC functions
-- =====================================================================================
create or replace function public.increment_preset_usage(p_preset_id text) returns void language sql security definer set search_path = public as $$
  update public.presets set usage_count = usage_count + 1 where preset_id = p_preset_id and is_published $$;
revoke all on function public.increment_preset_usage(text) from public;
grant execute on function public.increment_preset_usage(text) to anon, authenticated;

create or replace function public.admin_dashboard_stats() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare out jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  select jsonb_build_object(
    'total_members',        (select count(*) from profiles),
    'new_members_7d',       (select count(*) from profiles where created_at > now() - interval '7 days'),
    'active_users_7d',      (select count(distinct user_id) from usage_logs where user_id is not null and created_at > now() - interval '7 days'),
    'free_members',         (select count(*) from profiles where subscription_plan = 'free'),
    'paid_members',         (select count(*) from profiles where subscription_plan <> 'free' and subscription_status in ('active','trialing')),
    'total_donations',      (select coalesce(sum(amount),0) from donations where status = 'succeeded' and not is_test),
    'test_donations',       (select coalesce(sum(amount),0) from donations where is_test),
    'subscription_revenue', (select coalesce(sum(amount),0) from payment_transactions where kind = 'subscription' and status = 'succeeded' and not is_test),
    'presets_total',        (select count(*) from presets),
    'presets_published',    (select count(*) from presets where is_published),
    'preset_uses',          (select coalesce(sum(usage_count),0) from presets),
    'errors_7d',            (select count(*) from usage_logs where event = 'error' and created_at > now() - interval '7 days')
  ) into out;
  return out;
end $$;
revoke all on function public.admin_dashboard_stats() from public;
grant execute on function public.admin_dashboard_stats() to authenticated;

-- Role management: super_admin only; cannot remove your own super_admin role
create or replace function public.set_user_role(p_user uuid, p_role text, p_grant boolean) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_super_admin() then raise exception 'only super_admin can change roles' using errcode = '42501'; end if;
  if p_role not in ('admin','super_admin','editor') then raise exception 'invalid role'; end if;
  if p_user = auth.uid() and p_role = 'super_admin' and not p_grant then raise exception 'cannot remove your own super_admin role'; end if;
  if p_grant then
    insert into public.user_roles (user_id, role, granted_by) values (p_user, p_role, auth.uid()) on conflict do nothing;
  else
    delete from public.user_roles where user_id = p_user and role = p_role;
  end if;
  insert into public.usage_logs (user_id, event, meta) values (auth.uid(), 'admin.role', jsonb_build_object('target', p_user, 'role', p_role, 'grant', p_grant));
end $$;
revoke all on function public.set_user_role(uuid, text, boolean) from public;
grant execute on function public.set_user_role(uuid, text, boolean) to authenticated;

-- Account suspension: admins; only super_admin can suspend another admin
create or replace function public.admin_set_account_status(p_user uuid, p_status text) returns void language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() then raise exception 'forbidden' using errcode = '42501'; end if;
  if p_status not in ('active','suspended') then raise exception 'invalid status'; end if;
  if p_user = auth.uid() then raise exception 'cannot change your own status'; end if;
  if exists (select 1 from public.user_roles where user_id = p_user and role in ('admin','super_admin')) and not public.is_super_admin() then
    raise exception 'only super_admin can suspend admins' using errcode = '42501'; end if;
  update public.profiles set account_status = p_status where id = p_user;
  insert into public.usage_logs (user_id, event, meta) values (auth.uid(), 'admin.status', jsonb_build_object('target', p_user, 'status', p_status));
end $$;
revoke all on function public.admin_set_account_status(uuid, text) from public;
grant execute on function public.admin_set_account_status(uuid, text) to authenticated;

-- =====================================================================================
-- Storage buckets & policies
-- =====================================================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('media',         'media',         false, 524288000, array['image/*','video/*','application/octet-stream']),
  ('avatars',       'avatars',       true,  3145728,   array['image/*']),
  ('preset-thumbs', 'preset-thumbs', true,  2097152,   array['image/*']),
  ('banners',       'banners',       true,  52428800,  array['image/*','video/mp4','video/webm'])
on conflict (id) do update set public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

do $$ declare r record; begin
  for r in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'lumora_%' loop
    execute format('drop policy %I on storage.objects', r.policyname);
  end loop;
end $$;

-- media: private, each user owns the folder named after their uid  (media/<uid>/...)
create policy lumora_media_read   on storage.objects for select to authenticated using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy lumora_media_insert on storage.objects for insert to authenticated with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text and public.is_active_user());
create policy lumora_media_update on storage.objects for update to authenticated using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
create policy lumora_media_delete on storage.objects for delete to authenticated using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
-- avatars: public read, own folder write
create policy lumora_avatar_write  on storage.objects for insert to authenticated with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy lumora_avatar_update on storage.objects for update to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy lumora_avatar_delete on storage.objects for delete to authenticated using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
-- preset thumbnails & banners: public read, content editors write
create policy lumora_cms_insert on storage.objects for insert to authenticated with check (bucket_id in ('preset-thumbs','banners') and public.is_content_editor());
create policy lumora_cms_update on storage.objects for update to authenticated using (bucket_id in ('preset-thumbs','banners') and public.is_content_editor());
create policy lumora_cms_delete on storage.objects for delete to authenticated using (bucket_id in ('preset-thumbs','banners') and public.is_content_editor());

-- =====================================================================================
-- Bootstrap: make yourself super admin (run after signing up once in the app)
--   insert into public.user_roles (user_id, role)
--   select id, 'super_admin' from auth.users where email = 'you@example.com';
-- =====================================================================================
