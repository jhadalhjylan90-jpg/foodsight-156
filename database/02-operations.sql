begin;
create function public.place_order(p_branch int,p_items jsonb,p_request uuid) returns jsonb language plpgsql security invoker set search_path='' as $$
declare oid uuid; it record; need record; lot record; left_qty numeric; take_qty numeric;
begin
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 or jsonb_array_length(p_items)>50 then raise exception 'أضف وجبة واحدة على الأقل'; end if;
 perform 1 from public.branches where id=p_branch for update; if not found then raise exception 'الفرع غير موجود'; end if;
 select id into oid from public.sales_orders where request_key=p_request;
 if oid is not null then return jsonb_build_object('id',oid,'duplicate',true); end if;
 insert into public.sales_orders(branch_id,request_key) values(p_branch,p_request) returning id into oid;
 for it in select (x->>'meal_id')::int meal_id,(x->>'quantity')::int quantity from jsonb_array_elements(p_items) x loop
 if it.quantity is null or it.quantity<1 or it.quantity>10000 then raise exception 'كمية الوجبة غير صحيحة'; end if;
 insert into public.order_items(order_id,recipe_id,quantity,unit_price) select oid,r.id,it.quantity,m.price from public.recipe_versions r join public.meals m on m.id=r.meal_id where r.meal_id=it.meal_id and r.active;
 if not found then raise exception 'الوجبة أو الوصفة غير موجودة'; end if;
 end loop;
 for need in select ri.ingredient_id,sum(ri.quantity*oi.quantity) qty,ing.name from public.order_items oi join public.recipe_items ri on ri.recipe_id=oi.recipe_id join public.ingredients ing on ing.id=ri.ingredient_id where oi.order_id=oid group by ri.ingredient_id,ing.name order by ri.ingredient_id loop
 left_qty=need.qty;
 for lot in select * from public.stock_lots where branch_id=p_branch and ingredient_id=need.ingredient_id and remaining>0 and received_at<=now() and expires_at>now() order by expires_at,id for update loop
 take_qty=least(left_qty,lot.remaining);
 insert into public.stock_movements(lot_id,kind,quantity,order_id,note) values(lot.id,'sale',-take_qty,oid,'استهلاك بيع حسب الوصفة');
 left_qty=left_qty-take_qty; exit when left_qty=0;
 end loop;
 if left_qty>0 then raise exception 'المخزون غير كافٍ: % — العجز % بالوحدة الأساسية',need.name,left_qty; end if;
 end loop;
 update public.sales_orders set total=(select sum(quantity*unit_price) from public.order_items where order_id=oid) where id=oid;
 return (select jsonb_build_object('id',id,'total',total,'duplicate',false) from public.sales_orders where id=oid);
end $$;

create function public.receive_stock(p_branch int,p_ingredient int,p_quantity numeric,p_unit text,p_expiry timestamptz,p_code text,p_supplier text default '',p_purchase uuid default null) returns uuid language plpgsql security invoker set search_path='' as $$
declare ing public.ingredients; q numeric; lid uuid; po public.purchase_orders;
begin
 perform 1 from public.branches where id=p_branch for update;
 select * into strict ing from public.ingredients where id=p_ingredient;
 q=p_quantity*case when p_unit='kg' and ing.unit='g' then 1000 when p_unit='l' and ing.unit='ml' then 1000 when p_unit=ing.unit then 1 when p_unit='pack' then ing.pack_size else null end;
 if q is null or q<=0 or q>100000000 or p_expiry is null or p_expiry<=now() or length(trim(p_code))=0 then raise exception 'تحقق من الكمية والوحدة والصلاحية ورقم الدفعة'; end if;
 if p_purchase is not null then select * into strict po from public.purchase_orders where id=p_purchase for update;
 if po.status<>'pending' or po.branch_id<>p_branch or po.ingredient_id<>p_ingredient or po.quantity<>q then raise exception 'التوريد لا يطابق الطلب المنتظر'; end if; end if;
 insert into public.stock_lots(branch_id,ingredient_id,lot_code,expires_at,unit_cost,supplier) values(p_branch,p_ingredient,trim(p_code),p_expiry,ing.unit_cost,p_supplier) returning id into lid;
 insert into public.stock_movements(lot_id,kind,quantity,note) values(lid,'receipt',q,'استلام مخزون');
 if p_purchase is not null then update public.purchase_orders set status='received' where id=p_purchase; end if;
 return lid;
end $$;

create function public.record_waste(p_lot uuid,p_quantity numeric,p_reason text) returns uuid language plpgsql security invoker set search_path='' as $$
declare l public.stock_lots; rid uuid;
begin
 select * into strict l from public.stock_lots where id=p_lot;
 perform 1 from public.branches where id=l.branch_id for update;
 select * into strict l from public.stock_lots where id=p_lot for update;
 if p_quantity is null or p_quantity<=0 or p_quantity>l.remaining or length(trim(p_reason))<2 then raise exception 'تحقق من كمية الهدر وسببه'; end if;
 insert into public.waste_records(lot_id,quantity,reason) values(p_lot,p_quantity,p_reason) returning id into rid;
 insert into public.stock_movements(lot_id,kind,quantity,reference_id,note) values(p_lot,'waste',-p_quantity,rid,p_reason); return rid;
end $$;
create function public.count_stock(p_lot uuid,p_actual numeric,p_reason text) returns uuid language plpgsql security invoker set search_path='' as $$
declare l public.stock_lots; rid uuid;
begin
 select * into strict l from public.stock_lots where id=p_lot;
 perform 1 from public.branches where id=l.branch_id for update;
 select * into strict l from public.stock_lots where id=p_lot for update;
 if p_actual is null or p_actual<0 or length(trim(p_reason))<2 then raise exception 'أدخل كمية فعلية وسبب التسوية'; end if;
 insert into public.stock_counts(lot_id,expected,actual,reason) values(p_lot,l.remaining,p_actual,p_reason) returning id into rid;
 if p_actual<>l.remaining then insert into public.stock_movements(lot_id,kind,quantity,reference_id,note) values(p_lot,'adjustment',p_actual-l.remaining,rid,p_reason); end if; return rid;
end $$;
create function public.transfer_stock(p_lot uuid,p_branch int,p_quantity numeric) returns uuid language plpgsql security invoker set search_path='' as $$
declare l public.stock_lots; dest uuid; rid uuid=gen_random_uuid();
begin
 select * into strict l from public.stock_lots where id=p_lot;
 perform 1 from public.branches where id in(l.branch_id,p_branch) order by id for update;
 select * into strict l from public.stock_lots where id=p_lot for update;
 if p_quantity is null or p_quantity<=0 or p_quantity>l.remaining or p_branch=l.branch_id or l.expires_at<=now() then raise exception 'تحقق من الفرع والكمية وصلاحية الدفعة'; end if;
 insert into public.stock_lots(branch_id,ingredient_id,lot_code,expires_at,unit_cost,supplier) values(p_branch,l.ingredient_id,'TR-'||rid,l.expires_at,l.unit_cost,l.supplier) returning id into dest;
 insert into public.transfers(id,from_lot,to_lot,quantity) values(rid,p_lot,dest,p_quantity);
 insert into public.stock_movements(lot_id,kind,quantity,reference_id,note) values(p_lot,'transfer_out',-p_quantity,rid,'نقل إلى فرع آخر'),(dest,'transfer_in',p_quantity,rid,'استلام من فرع آخر'); return rid;
end $$;

create function public.dashboard(p_branch int default null,p_from date default current_date-6,p_to date default current_date) returns jsonb language sql stable security invoker set search_path='' as $$
select jsonb_build_object(
'branches',(select jsonb_agg(b order by id) from public.branches b),
'ingredients',(select jsonb_agg(i order by id) from public.ingredients i),
'meals',(select jsonb_agg(m order by id) from public.meals m),
'recipes',(select jsonb_agg(r) from (select v.meal_id,v.id recipe_id,i.ingredient_id,i.quantity from public.recipe_versions v join public.recipe_items i on i.recipe_id=v.id where v.active) r),
'sales',coalesce((select jsonb_agg(s order by sale_date,branch_id,meal_id) from public.daily_sales s where (p_branch is null or s.branch_id=p_branch) and s.sale_date between p_from and p_to),'[]'::jsonb),
'lots',coalesce((select jsonb_agg(l order by expires_at) from public.stock_lots l where remaining>0 and (p_branch is null or branch_id=p_branch)),'[]'::jsonb),
'waste',coalesce((select jsonb_agg(w) from (select w.*,l.branch_id,l.ingredient_id,l.unit_cost from public.waste_records w join public.stock_lots l on l.id=w.lot_id where (p_branch is null or l.branch_id=p_branch) and (w.created_at at time zone 'Asia/Riyadh')::date between p_from and p_to) w),'[]'::jsonb),
'movements',coalesce((select jsonb_agg(m) from (select m.*,l.branch_id,l.ingredient_id,l.lot_code from public.stock_movements m join public.stock_lots l on l.id=m.lot_id where (p_branch is null or l.branch_id=p_branch) and (m.occurred_at at time zone 'Asia/Riyadh')::date between p_from and p_to order by m.occurred_at desc,m.id desc limit 400) m),'[]'::jsonb),
'purchases',coalesce((select jsonb_agg(p order by expected_on) from public.purchase_orders p where status='pending' and (p_branch is null or branch_id=p_branch)),'[]'::jsonb),
'plans',coalesce((select jsonb_agg(p order by plan_date) from public.preparation_plans p where plan_date>=current_date and (p_branch is null or branch_id=p_branch)),'[]'::jsonb),
'metadata',(select value from public.app_metadata where key='dataset'),
'server_time',now()
) $$;

-- Weighted same-weekday historical baseline. Summer and payday effects are learned from data,
-- not hardcoded into forecasting. Days flagged stockout are excluded from training.
create function public.forecast(p_branch int default null,p_start date default current_date+1,p_days int default 7,p_buffer numeric default 0.1) returns jsonb language plpgsql security invoker set search_path='' as $$
declare result jsonb;
begin
 if p_days not between 1 and 28 or p_buffer<0 or p_buffer>0.5 or p_start<current_date then raise exception 'اختر فترة مستقبلية من 1 إلى 28 يومًا وهامشًا من 0 إلى 50%%'; end if;
 with targets as (select b.id branch_id,m.id meal_id,d::date as day from public.branches b cross join public.meals m cross join generate_series(p_start::timestamp,(p_start+p_days-1)::timestamp,interval '1 day') d where p_branch is null or b.id=p_branch),
 predictions as (
 select t.*,coalesce(round(sum(s.quantity*w.weight)/nullif(sum(w.weight),0)),0)::int predicted,count(s.sale_date) samples,coalesce(round(stddev_samp(s.quantity)),0) deviation
 from targets t left join public.daily_sales s on s.branch_id=t.branch_id and s.meal_id=t.meal_id and s.sale_date<least(p_start,current_date) and s.sale_date>=least(p_start,current_date)-365 and extract(dow from s.sale_date)=extract(dow from t.day) and not s.stockout
 cross join lateral(select (case when s.sale_date>=current_date-56 then 3.0 else 1.0 end)*(case when extract(month from s.sale_date)=extract(month from t.day) then 2.0 else 1.0 end)*(case when (extract(day from s.sale_date)>=27)=(extract(day from t.day)>=27) then 1.3 else 1.0 end) weight) w group by t.branch_id,t.meal_id,t.day
 ) select jsonb_build_object('days',jsonb_agg(jsonb_build_object('branch_id',branch_id,'meal_id',meal_id,'day',day,'predicted',predicted,'planned',coalesce((select pp.quantity from public.preparation_plans pp where pp.branch_id=predictions.branch_id and pp.meal_id=predictions.meal_id and pp.plan_date=predictions.day),ceil(predicted*(1+p_buffer))),'actual_sold',coalesce((select ds.quantity from public.daily_sales ds where ds.branch_id=predictions.branch_id and ds.meal_id=predictions.meal_id and ds.sale_date=predictions.day),0),'samples',samples,'low',greatest(0,predicted-deviation),'high',predicted+deviation) order by day,branch_id,meal_id),'method','متوسط مرجح للأيام المماثلة خلال 365 يومًا؛ وزن أعلى لآخر 8 أسابيع والشهر وفترة الشهر المماثلة. تُستبعد أيام نفاد المخزون. النطاق وصفي وليس ضمانًا.','created_at',now()) into result from predictions;
 insert into public.forecast_runs(branch_id,start_date,days,buffer,method,result) values(p_branch,p_start,p_days,p_buffer,'weighted_same_weekday_v1',result);
 return result;
end $$;
revoke execute on all functions in schema public from public,anon,authenticated;
grant execute on all functions in schema public to service_role;
notify pgrst,'reload schema';
commit;
