-- Pregnant Manager Pro: read-only check after running the main SQL.
-- Does not expose or change family health data.
select 'family tables' as component,
       case when to_regclass('public.families') is not null
              and to_regclass('public.family_members') is not null
            then 'OK' else 'MISSING' end as status;

select 'RLS on both tables' as component,
       case when count(*) = 2 and bool_and(relrowsecurity)
            then 'OK' else 'MISSING' end as status
from pg_class where oid in ('public.families'::regclass, 'public.family_members'::regclass);

select 'private pregnancy-media bucket' as component,
       case when count(*) = 1 and bool_and(not public)
            then 'OK' else 'MISSING' end as status
from storage.buckets where id = 'pregnancy-media';

select 'app RPC functions' as component,
       case when count(*) = 9 then 'OK' else 'MISSING' end as status
from pg_proc p join pg_namespace n on p.pronamespace = n.oid
where n.nspname = 'public'
  and p.proname in (
    'is_family_member','is_family_owner','create_family','invite_parent',
    'accept_pending_invites','pmp_merge_settings','pmp_add_item',
    'pmp_update_item','pmp_remove_item'
  );

select 'storage policies' as component,
       case when count(*) = 3 then 'OK' else 'MISSING' end as status
from pg_policies where schemaname = 'storage' and tablename = 'objects'
  and policyname in ('pmp_media_select','pmp_media_insert','pmp_media_delete');

-- v7: ensure the three JSONB write RPCs accept the newly introduced collections.
select 'v7 prenatal/reminders collections' as component,
       case when count(*) = 3
                  and bool_and(position('prenatalVisits' in pg_get_functiondef(p.oid)) > 0)
                  and bool_and(position('reminders' in pg_get_functiondef(p.oid)) > 0)
            then 'OK' else 'MISSING -- run v7_upgrade.sql' end as status
from pg_proc p join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('pmp_add_item','pmp_update_item','pmp_remove_item');
