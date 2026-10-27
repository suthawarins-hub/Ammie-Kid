-- Pregnant Manager Pro — Supabase schema v1.2
-- Execute in a NEW Supabase project -> SQL Editor.
-- Never put a service_role or secret key inside index.html.
create extension if not exists pgcrypto;

create table if not exists public.families (
 id uuid primary key default gen_random_uuid(),
 title text not null default 'Our little family',
 data jsonb not null default '{}'::jsonb,
 version bigint not null default 0 check(version >= 0),
 created_at timestamptz not null default now(),
 updated_at timestamptz not null default now(),
 constraint family_data_object check(jsonb_typeof(data)='object')
);
create table if not exists public.family_members (
 id uuid primary key default gen_random_uuid(),
 family_id uuid not null references public.families(id) on delete cascade,
 user_id uuid references auth.users(id) on delete cascade,
 invited_email text,
 role text not null default 'parent' check(role in ('owner','parent')),
 created_at timestamptz not null default now(),
 constraint member_has_identity check(user_id is not null or invited_email is not null)
);
create unique index if not exists family_member_user_unique on public.family_members(family_id,user_id) where user_id is not null;
create unique index if not exists family_member_invited_email_unique on public.family_members(family_id,lower(invited_email)) where invited_email is not null;
create index if not exists family_members_user_idx on public.family_members(user_id);

-- SECURITY DEFINER prevents recursive RLS checks while returning only yes/no.
create or replace function public.is_family_member(p_family uuid) returns boolean
 language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null and exists (
  select 1 from public.family_members m where m.family_id=p_family and m.user_id=auth.uid()
 );
 $$;
create or replace function public.is_family_owner(p_family uuid) returns boolean
 language sql stable security definer set search_path = '' as $$
 select auth.uid() is not null and exists (
  select 1 from public.family_members m where m.family_id=p_family and m.user_id=auth.uid() and m.role='owner'
 );
 $$;
revoke all on function public.is_family_member(uuid),public.is_family_owner(uuid) from public;
grant execute on function public.is_family_member(uuid),public.is_family_owner(uuid) to authenticated;

-- Creation and invitations use server-side auth.uid(), never client-defined user ids.
create or replace function public.create_family(p_title text default 'Our little family') returns uuid
 language plpgsql security definer set search_path = '' as $$
 declare v_id uuid;
 begin
  if auth.uid() is null then raise exception 'Please sign in'; end if;
  insert into public.families(title) values(left(coalesce(nullif(trim(p_title),''),'Our little family'),120)) returning id into v_id;
  insert into public.family_members(family_id,user_id,invited_email,role)
    values(v_id,auth.uid(),lower(auth.jwt()->>'email'),'owner');
  return v_id;
 end $$;
create or replace function public.invite_parent(p_family uuid,p_email text) returns void
 language plpgsql security definer set search_path = '' as $$
 declare v_email text := lower(trim(p_email));
 begin
  if not public.is_family_owner(p_family) then raise exception 'Only a family owner may invite'; end if;
  if v_email is null or v_email !~ '^[^@ ]+@[^@ ]+\.[^@ ]+$' or length(v_email)>254 then raise exception 'Invalid email'; end if;
  if exists(select 1 from public.family_members where family_id=p_family and lower(invited_email)=v_email) then
    raise exception 'This email has already been invited';
  end if;
  insert into public.family_members(family_id,invited_email,role) values(p_family,v_email,'parent');
 end $$;
create or replace function public.accept_pending_invites() returns integer
 language plpgsql security definer set search_path = '' as $$
 declare v_email text := lower(auth.jwt()->>'email'); v_count integer;
 begin
  if auth.uid() is null or nullif(v_email,'') is null then raise exception 'Please sign in'; end if;
  update public.family_members set user_id=auth.uid()
   where user_id is null and lower(invited_email)=v_email;
  get diagnostics v_count = row_count;
  return v_count;
 end $$;
revoke all on function public.create_family(text),public.invite_parent(uuid,text),public.accept_pending_invites() from public;
grant execute on function public.create_family(text),public.invite_parent(uuid,text),public.accept_pending_invites() to authenticated;

alter table public.families enable row level security;
alter table public.family_members enable row level security;
create policy "family members read family" on public.families for select to authenticated using(public.is_family_member(id));
create policy "family members update family" on public.families for update to authenticated
 using(public.is_family_member(id)) with check(public.is_family_member(id));
create policy "family members read memberships" on public.family_members for select to authenticated
 using(public.is_family_member(family_id));
-- Members cannot insert themselves, change their roles or access another family's record.

-- Private image storage. Paths are formatted family-id/random-file.ext.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('pregnancy-media','pregnancy-media',false,12582912,array['image/jpeg','image/png','image/webp'])
 on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy "private pregnancy file read" on storage.objects for select to authenticated
 using(bucket_id='pregnancy-media' and exists(
  select 1 from public.families f where f.id::text=(storage.foldername(name))[1] and public.is_family_member(f.id)
 ));
create policy "private pregnancy file upload" on storage.objects for insert to authenticated
 with check(bucket_id='pregnancy-media' and exists(
  select 1 from public.families f where f.id::text=(storage.foldername(name))[1] and public.is_family_member(f.id)
 ));
create policy "private pregnancy file delete" on storage.objects for delete to authenticated
 using(bucket_id='pregnancy-media' and exists(
  select 1 from public.families f where f.id::text=(storage.foldername(name))[1] and public.is_family_member(f.id)
 ));

-- Grant limited authenticated access; RLS policies still apply.
grant usage on schema public to authenticated;
grant select,update on public.families to authenticated;
grant select on public.family_members to authenticated;

-- Atomic operations on shared family journal: prevent lost writes when both parents
-- edit different entries at the same time. Every RPC rechecks membership.
create or replace function public.pmp_merge_settings(p_family uuid,p_patch jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_family_member(p_family) then raise exception 'Not a family member'; end if;
 if jsonb_typeof(p_patch) <> 'object' or pg_column_size(p_patch)>30000 then raise exception 'Invalid settings'; end if;
 update public.families set data=jsonb_set(data,'{settings}',coalesce(data->'settings','{}'::jsonb)||p_patch,true),version=version+1,updated_at=now() where id=p_family;
end $$;
create or replace function public.pmp_add_item(p_family uuid,p_collection text,p_item jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_family_member(p_family) then raise exception 'Not a family member'; end if;
 if p_collection not in ('appointments','symptoms','kicks','tasks','photos','babyLogs','growth','vaccines','postpartumLogs','memories') then raise exception 'Unknown collection'; end if;
 if jsonb_typeof(p_item)<>'object' or coalesce(p_item->>'id','')='' or pg_column_size(p_item)>15000 then raise exception 'Invalid item'; end if;
 update public.families set data=jsonb_set(data,array[p_collection],coalesce(data->p_collection,'[]'::jsonb)||jsonb_build_array(p_item),true),version=version+1,updated_at=now() where id=p_family;
end $$;
create or replace function public.pmp_update_item(p_family uuid,p_collection text,p_item_id text,p_patch jsonb)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_family_member(p_family) then raise exception 'Not a family member'; end if;
 if p_collection not in ('appointments','symptoms','kicks','tasks','photos','babyLogs','growth','vaccines','postpartumLogs','memories') then raise exception 'Unknown collection'; end if;
 if jsonb_typeof(p_patch)<>'object' or (p_patch ? 'id') or pg_column_size(p_patch)>15000 then raise exception 'Invalid update'; end if;
 update public.families set data=jsonb_set(data,array[p_collection],
   (select coalesce(jsonb_agg(case when obj->>'id'=p_item_id then obj||p_patch else obj end order by ordinal),'[]'::jsonb)
    from jsonb_array_elements(coalesce(data->p_collection,'[]'::jsonb)) with ordinality as a(obj,ordinal)),true),
   version=version+1,updated_at=now() where id=p_family;
end $$;
create or replace function public.pmp_remove_item(p_family uuid,p_collection text,p_item_id text)
returns void language plpgsql security definer set search_path = '' as $$
begin
 if not public.is_family_member(p_family) then raise exception 'Not a family member'; end if;
 if p_collection not in ('appointments','symptoms','kicks','tasks','photos','babyLogs','growth','vaccines','postpartumLogs','memories') then raise exception 'Unknown collection'; end if;
 update public.families set data=jsonb_set(data,array[p_collection],
   (select coalesce(jsonb_agg(obj order by ordinal),'[]'::jsonb) from jsonb_array_elements(coalesce(data->p_collection,'[]'::jsonb)) with ordinality as a(obj,ordinal) where obj->>'id'<>p_item_id),true),
   version=version+1,updated_at=now() where id=p_family;
end $$;
revoke all on function public.pmp_merge_settings(uuid,jsonb),public.pmp_add_item(uuid,text,jsonb),public.pmp_update_item(uuid,text,text,jsonb),public.pmp_remove_item(uuid,text,text) from public;
grant execute on function public.pmp_merge_settings(uuid,jsonb),public.pmp_add_item(uuid,text,jsonb),public.pmp_update_item(uuid,text,text,jsonb),public.pmp_remove_item(uuid,text,text) to authenticated;
