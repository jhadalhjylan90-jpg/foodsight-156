begin;
create function public.receive_bundle(p_branch int,p_lines jsonb,p_code text) returns jsonb language plpgsql security invoker set search_path='' as $$
declare l jsonb; ids jsonb='[]'::jsonb; lid uuid; ing public.ingredients;
begin
 if jsonb_typeof(p_lines)<>'array' or jsonb_array_length(p_lines)<1 or jsonb_array_length(p_lines)>30 then raise exception 'قائمة المكونات غير صحيحة'; end if;
 for l in select value from jsonb_array_elements(p_lines) loop
 select * into strict ing from public.ingredients where id=(l->>'ingredient_id')::int;
 lid=public.receive_stock(p_branch,ing.id,(l->>'quantity')::numeric,ing.unit,(l->>'expiry')::timestamptz,p_code||'-'||ing.id,'تعبئة حسب الوجبات',null);
 ids=ids||jsonb_build_array(lid);
 end loop;return ids;
end $$;
revoke execute on function public.receive_bundle(int,jsonb,text) from public,anon,authenticated;
grant execute on function public.receive_bundle(int,jsonb,text) to service_role;
commit;
