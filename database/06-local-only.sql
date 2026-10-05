begin;
do $$ declare t record;begin
for t in select tablename from pg_tables where schemaname='public' loop
execute format('drop policy if exists owner_select on public.%I',t.tablename);
execute format('drop policy if exists owner_insert on public.%I',t.tablename);
execute format('drop policy if exists owner_update on public.%I',t.tablename);
execute format('revoke all on public.%I from anon,authenticated',t.tablename);
end loop;end $$;
revoke all on all sequences in schema public from anon,authenticated;
revoke all on public.daily_sales from anon,authenticated;
revoke execute on all functions in schema public from public,anon,authenticated;
grant execute on all functions in schema public to service_role;
commit;
