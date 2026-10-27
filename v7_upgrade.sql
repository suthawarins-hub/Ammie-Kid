-- Pregnant Manager Pro v7 — non-destructive upgrade for an existing v2 database.
-- Extends the allowed JSONB collections for prenatal visits and family reminders.
-- Does not drop tables, rows, policies or storage objects.
begin;
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
     'babyLogs','growth','vaccines','postpartumLogs','memories','prenatalVisits','reminders') then
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
     'babyLogs','growth','vaccines','postpartumLogs','memories','prenatalVisits','reminders') then
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
     'babyLogs','growth','vaccines','postpartumLogs','memories','prenatalVisits','reminders') then
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


revoke all on function public.pmp_add_item(uuid, text, jsonb) from public, anon;
revoke all on function public.pmp_update_item(uuid, text, text, jsonb) from public, anon;
revoke all on function public.pmp_remove_item(uuid, text, text) from public, anon;
grant execute on function public.pmp_add_item(uuid, text, jsonb) to authenticated;
grant execute on function public.pmp_update_item(uuid, text, text, jsonb) to authenticated;
grant execute on function public.pmp_remove_item(uuid, text, text) to authenticated;
commit;
