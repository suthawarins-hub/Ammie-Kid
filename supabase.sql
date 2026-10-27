-- ============================================================================
-- PREGNANT MANAGER PRO | Supabase Database & Storage | v2.0
-- Compatible with the existing Pastel PWA (app.js and config.js).
-- Run ONCE in Supabase Dashboard > SQL Editor > New Query > Run.
-- You can re-run to refresh functions and policies without deleting family data.
-- ============================================================================
-- Features stored as JSONB collections:
-- families.data.settings   = parents, pregnancy, EDD, fetal sex, names, birth
-- appointments             = doctor, location, exam, date/time, follow-up
-- symptoms                 = maternal symptoms, mood, trends
-- kicks                    = fetal-movement recording sessions
-- tasks                    = baby shopping, hospital list, preparations
-- photos                   = family portraits, ultrasound, milestones, files
-- babyLogs                 = feeding, sleep and postnatal logs
-- growth                   = newborn weight/length measurements
-- vaccines                 = immunisation record entries
-- postpartumLogs           = mother postpartum record entries
-- memories                 = milestones and family journal entries
-- Access: Supabase Auth + household membership; device PIN is NOT a DB role.
-- ============================================================================

begin;

-- 1) Shared family data. Keep all personal health content private to members.
create table if not exists public.families (
  id uuid primary key default gen_random_uuid(),
  title text not null default 'Our Little Family',
  data jsonb not null default '{}'::jsonb,
  version bigint not null default 0 check (version >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint family_data_object check (jsonb_typeof(data) = 'object')
);

create table if not exists public.family_members (
  id uuid primary key default gen_random_uuid(),
  family_id uuid not null references public.families(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  invited_email text,
  role text not null default 'parent' check (role in ('owner', 'parent')),
  created_at timestamptz not null default now(),
  constraint member_has_identity check (user_id is not null or invited_email is not null)
);

create unique index if not exists family_member_user_unique
  on public.family_members(family_id, user_id) where user_id is not null;
create unique index if not exists family_member_invited_email_unique
  on public.family_members(family_id, lower(invited_email)) where invited_email is not null;
create index if not exists family_members_user_idx
  on public.family_members(user_id);
create index if not exists family_members_family_idx
  on public.family_members(family_id);

alter table public.families enable row level security;
alter table public.family_members enable row level security;

-- REVOKE all inherited grants (on some Supabase projects public tables are
-- granted to anon/authenticated by default). Only SELECT is exposed directly;
-- writes go through authenticated RPCs below.
revoke all privileges on table public.families, public.family_members from anon, authenticated;
grant select on table public.families, public.family_members to authenticated;

-- 2) Lookup functions avoid recursive RLS checks in membership policies.
-- SECURITY DEFINER + empty search_path; each function verifies its caller.
create or replace function public.is_family_member(p_family uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.family_members m
    where m.family_id = p_family and m.user_id = auth.uid()
  );
$$;

create or replace function public.is_family_owner(p_family uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select auth.uid() is not null and exists (
    select 1 from public.family_members m
    where m.family_id = p_family
      and m.user_id = auth.uid()
      and m.role = 'owner'
  );
$$;

-- 3) Row security: logged-in members only. No public access policies.
drop policy if exists "family members read family" on public.families;
drop policy if exists "family members update family" on public.families;
drop policy if exists "family members read memberships" on public.family_members;
drop policy if exists "pmp_families_read" on public.families;
drop policy if exists "pmp_family_members_read" on public.family_members;

create policy "pmp_families_read" on public.families
  for select to authenticated using (public.is_family_member(id));
create policy "pmp_family_members_read" on public.family_members
  for select to authenticated using (public.is_family_member(family_id));

-- 4) Create a household and put its creator in the owner role atomically.
create or replace function public.create_family(p_title text default 'Our Little Family')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_family uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'Sign in before creating a family';
  end if;
  select lower(email) into v_email from auth.users where id = auth.uid();

  insert into public.families(title)
  values (left(coalesce(nullif(btrim(p_title), ''), 'Our Little Family'), 120))
  returning id into v_family;

  insert into public.family_members(family_id, user_id, invited_email, role)
  values (v_family, auth.uid(), v_email, 'owner');

  return v_family;
end;
$$;

-- 5) Invite the other parent by email. It becomes effective only after
-- that account signs in with the matching VERIFIED email address.
create or replace function public.invite_parent(p_family uuid, p_email text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_email text := lower(btrim(p_email));
begin
  if not public.is_family_owner(p_family) then
    raise exception 'Only the family owner can invite another account';
  end if;
  if v_email is null or length(v_email) > 254
     or v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Please enter a valid email address';
  end if;
  if exists (
    select 1 from public.family_members
    where family_id = p_family and lower(invited_email) = v_email
  ) then
    raise exception 'This email is already in the household or invited';
  end if;
  insert into public.family_members(family_id, invited_email, role)
  values (p_family, v_email, 'parent');
end;
$$;

create or replace function public.accept_pending_invites()
returns integer
language plpgsql security definer set search_path = ''
as $$
declare
  v_email text;
  v_confirmed timestamptz;
  v_count integer := 0;
begin
  if auth.uid() is null then
    raise exception 'Sign in first';
  end if;
  -- Do not trust mutable account metadata or an unverified JWT email.
  select lower(u.email), u.email_confirmed_at
  into v_email, v_confirmed
  from auth.users u where u.id = auth.uid();

  if coalesce(v_email, '') = '' or v_confirmed is null then
    -- Return 0 so app boot can still open its own existing family.
    return 0;
  end if;

  update public.family_members m
  set user_id = auth.uid()
  where m.user_id is null and lower(m.invited_email) = v_email;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 6) Atomic writes to the family's JSONB journal, no accidental overwrite
-- from two members saving different entries at the same time.
-- Each RPC validates membership, collection names and entry sizes.
create or replace function public.pmp_merge_settings(p_family uuid, p_patch jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_family_member(p_family) then
    raise exception 'Not authorised for this family';
  end if;
  if p_patch is null or jsonb_typeof(p_patch) <> 'object'
     or pg_column_size(p_patch) > 30000 then
    raise exception 'Invalid settings payload';
  end if;

  update public.families
  set data = jsonb_set(
        data,
        '{settings}',
        coalesce(data -> 'settings', '{}'::jsonb) || p_patch,
        true
      ),
      version = version + 1,
      updated_at = now()
  where id = p_family;
end;
$$;

create or replace function public.pmp_add_item(
  p_family uuid, p_collection text, p_item jsonb
)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_family_member(p_family) then
    raise exception 'Not authorised for this family';
  end if;
  if coalesce(p_collection, '') not in
    ('appointments','symptoms','kicks','tasks','photos',
     'babyLogs','growth','vaccines','postpartumLogs','memories') then
    raise exception 'Unknown journal collection';
  end if;
  if p_item is null or jsonb_typeof(p_item) <> 'object'
     or coalesce(p_item ->> 'id','') = ''
     or pg_column_size(p_item) > 15000 then
    raise exception 'Invalid journal entry';
  end if;

  -- App generates a unique UUID id for each entry.
  update public.families
  set data = jsonb_set(
        data,
        array[p_collection],
        coalesce(data -> p_collection, '[]'::jsonb)
          || jsonb_build_array(p_item),
        true
      ),
      version = version + 1,
      updated_at = now()
  where id = p_family
    and not exists (
      select 1
      from jsonb_array_elements(coalesce(data -> p_collection, '[]'::jsonb)) x
      where x ->> 'id' = p_item ->> 'id'
    );

  if not found then
    raise exception 'Duplicate item id or family not found';
  end if;
end;
$$;

create or replace function public.pmp_update_item(
  p_family uuid, p_collection text, p_item_id text, p_patch jsonb
)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_family_member(p_family) then
    raise exception 'Not authorised for this family';
  end if;
  if coalesce(p_collection, '') not in
    ('appointments','symptoms','kicks','tasks','photos',
     'babyLogs','growth','vaccines','postpartumLogs','memories') then
    raise exception 'Unknown journal collection';
  end if;
  if coalesce(p_item_id, '') = '' or p_patch is null
     or jsonb_typeof(p_patch) <> 'object'
     or (p_patch ? 'id')
     or pg_column_size(p_patch) > 15000 then
    raise exception 'Invalid journal update';
  end if;

  update public.families
  set data = jsonb_set(
      data, array[p_collection],
      (
        select coalesce(
          jsonb_agg(
            case when x.obj ->> 'id' = p_item_id
              then x.obj || p_patch else x.obj end
            order by x.ordinal
          ), '[]'::jsonb
        )
        from jsonb_array_elements(
          coalesce(data -> p_collection, '[]'::jsonb)
        ) with ordinality as x(obj, ordinal)
      ), true
    ),
    version = version + 1,
    updated_at = now()
  where id = p_family
    and exists (
      select 1 from jsonb_array_elements(
        coalesce(data -> p_collection, '[]'::jsonb)
      ) x where x ->> 'id' = p_item_id
    );

  if not found then
    raise exception 'Item not found';
  end if;
end;
$$;

create or replace function public.pmp_remove_item(
  p_family uuid, p_collection text, p_item_id text
)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_family_member(p_family) then
    raise exception 'Not authorised for this family';
  end if;
  if coalesce(p_collection, '') not in
    ('appointments','symptoms','kicks','tasks','photos',
     'babyLogs','growth','vaccines','postpartumLogs','memories') then
    raise exception 'Unknown journal collection';
  end if;
  if coalesce(p_item_id, '') = '' then
    raise exception 'An item id is required';
  end if;

  update public.families
  set data = jsonb_set(
      data, array[p_collection],
      (
        select coalesce(jsonb_agg(x.obj order by x.ordinal), '[]'::jsonb)
        from jsonb_array_elements(
          coalesce(data -> p_collection, '[]'::jsonb)
        ) with ordinality as x(obj, ordinal)
        where x.obj ->> 'id' <> p_item_id
      ), true
    ),
    version = version + 1,
    updated_at = now()
  where id = p_family
    and exists (
      select 1 from jsonb_array_elements(
        coalesce(data -> p_collection, '[]'::jsonb)
      ) x where x ->> 'id' = p_item_id
    );

  if not found then
    raise exception 'Item not found';
  end if;
end;
$$;

-- Privileges: never allow anonymous execution of household RPCs.
revoke all on function public.is_family_member(uuid) from public, anon, authenticated;
revoke all on function public.is_family_owner(uuid) from public, anon, authenticated;
revoke all on function public.create_family(text) from public, anon, authenticated;
revoke all on function public.invite_parent(uuid, text) from public, anon, authenticated;
revoke all on function public.accept_pending_invites() from public, anon, authenticated;
revoke all on function public.pmp_merge_settings(uuid, jsonb) from public, anon, authenticated;
revoke all on function public.pmp_add_item(uuid, text, jsonb) from public, anon, authenticated;
revoke all on function public.pmp_update_item(uuid, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.pmp_remove_item(uuid, text, text) from public, anon, authenticated;

grant execute on function public.is_family_member(uuid) to authenticated;
grant execute on function public.is_family_owner(uuid) to authenticated;
grant execute on function public.create_family(text) to authenticated;
grant execute on function public.invite_parent(uuid, text) to authenticated;
grant execute on function public.accept_pending_invites() to authenticated;
grant execute on function public.pmp_merge_settings(uuid, jsonb) to authenticated;
grant execute on function public.pmp_add_item(uuid, text, jsonb) to authenticated;
grant execute on function public.pmp_update_item(uuid, text, text, jsonb) to authenticated;
grant execute on function public.pmp_remove_item(uuid, text, text) to authenticated;

-- 7) Private images: family, ultrasound, milestones and health documents.
-- Client storage path format: <family_uuid>/<random_uuid>.jpg|png|webp
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'pregnancy-media', 'pregnancy-media', false, 12582912,
  array['image/jpeg','image/png','image/webp']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Replace policies from earlier builds if they exist.
drop policy if exists "private pregnancy file read" on storage.objects;
drop policy if exists "private pregnancy file upload" on storage.objects;
drop policy if exists "private pregnancy file delete" on storage.objects;
drop policy if exists "pmp_media_select" on storage.objects;
drop policy if exists "pmp_media_insert" on storage.objects;
drop policy if exists "pmp_media_delete" on storage.objects;

create policy "pmp_media_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'pregnancy-media' and exists (
      select 1 from public.families f
      where f.id::text = (storage.foldername(name))[1]
        and public.is_family_member(f.id)
    )
  );

create policy "pmp_media_insert" on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'pregnancy-media' and exists (
      select 1 from public.families f
      where f.id::text = (storage.foldername(name))[1]
        and public.is_family_member(f.id)
    )
  );

create policy "pmp_media_delete" on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'pregnancy-media' and exists (
      select 1 from public.families f
      where f.id::text = (storage.foldername(name))[1]
        and public.is_family_member(f.id)
    )
  );

commit;

-- ============================================================================
-- Done! On a NEW project, expect:
-- 2 tables: public.families, public.family_members
-- 9 RPC helpers for Auth/membership/data; 1 private Storage bucket
-- 2 RLS table policies + 3 Storage policies
-- NO public access to the photos or health records.
-- IMPORTANT: RLS must be tested with two REAL Auth users plus an outsider.
-- SQL does NOT create Auth accounts, configure Auth URL or email confirmation,
-- send push notifications, run a Python service, or process medical diagnoses.
-- Never run this script with the browser publishable key.
-- ============================================================================
