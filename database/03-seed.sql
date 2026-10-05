begin;
insert into public.branches values(1,'فرع بريدة','الريان'),(2,'فرع عنيزة','الأشرفية'),(3,'فرع الرس','الحزم');
insert into public.ingredients values
(1,'لحم برجر','g',0.042,1000,2,7),(2,'دجاج برجر','g',0.024,1000,1,5),(3,'دجاج شاورما محضّر','g',0.026,1000,1,1),(4,'خبز برجر','piece',0.9,48,1,4),(5,'خبز شاورما','piece',0.45,60,1,3),(6,'شرائح جبن','piece',0.6,50,2,14),(7,'بطاطس مجمدة','g',0.006,2500,2,30),(8,'خس','g',0.009,1000,1,2),(9,'طماطم','g',0.005,1000,1,3),(10,'صوص','ml',0.012,1000,2,7),(11,'زيت','ml',0.008,5000,2,30);
insert into public.meals values(1,'برجر لحم',24),(2,'برجر دجاج',21),(3,'شاورما دجاج',12),(4,'بطاطس',8),(5,'سلطة',10);
insert into public.recipe_versions values(1,1,1,true),(2,2,1,true),(3,3,1,true),(4,4,1,true),(5,5,1,true);
insert into public.recipe_items values(1,1,150),(1,4,1),(1,6,1),(1,8,15),(1,9,20),(1,10,20),(2,2,150),(2,4,1),(2,6,1),(2,8,15),(2,10,20),(2,11,10),(3,3,120),(3,5,1),(3,9,20),(3,10,25),(4,7,150),(4,11,15),(5,8,80),(5,9,70),(5,10,15);
-- Reproducible synthetic daily summaries, not real POS transactions.
insert into public.sales_history(branch_id,meal_id,sale_date,quantity,revenue,stockout)
select b.id,m.id,d::date,q.n,q.n*m.price,(extract(doy from d)::int+b.id*7+m.id)%91=0
from public.branches b cross join public.meals m cross join generate_series(current_date-365,current_date-1,interval '1 day') d
cross join lateral(select greatest(1,round((case m.id when 1 then 65 when 2 then 78 when 3 then 105 when 4 then 95 else 38 end)*(case b.id when 1 then 1.2 when 2 then 0.95 else 0.75 end)*(case when extract(dow from d) in(4,5,6) then 1.36 else 0.9 end)*(case when extract(month from d) in(7,8) then 1.22 else 1 end)*(case when extract(day from d)>=27 then 1.14 else 1 end)*(0.84+((extract(doy from d)::int*17+b.id*13+m.id*23)%37)/100.0)*(case when (extract(doy from d)::int+b.id*7+m.id)%91=0 then 0.58 else 1 end)))::int n) q;
-- Each historical lot has a matching receipt, recipe consumption and recorded waste.
-- Same-day disposal is a simulated preparation/overproduction loss, not a food-safety rule.
do $$ declare r record; lid uuid; wid uuid; waste numeric; begin
for r in select h.branch_id,ri.ingredient_id,h.sale_date,sum(h.quantity*ri.quantity) qty,i.unit_cost,i.demo_shelf_days,i.unit from public.sales_history h join public.recipe_versions rv on rv.meal_id=h.meal_id and rv.active join public.recipe_items ri on ri.recipe_id=rv.id join public.ingredients i on i.id=ri.ingredient_id group by h.branch_id,ri.ingredient_id,h.sale_date,i.unit_cost,i.demo_shelf_days,i.unit loop
waste=ceil(r.qty*(0.012+((extract(doy from r.sale_date)::int+r.branch_id+r.ingredient_id)%7)*0.004));
insert into public.stock_lots(branch_id,ingredient_id,lot_code,received_at,expires_at,unit_cost,supplier) values(r.branch_id,r.ingredient_id,'H-'||r.sale_date||'-'||r.ingredient_id,(r.sale_date::timestamp+interval '6 hour') at time zone 'Asia/Riyadh',((r.sale_date+r.demo_shelf_days)::timestamp+interval '6 hour') at time zone 'Asia/Riyadh',r.unit_cost,'مورد تجريبي') returning id into lid;
insert into public.stock_movements(lot_id,kind,quantity,occurred_at,note) values(lid,'receipt',r.qty+waste,(r.sale_date::timestamp+interval '6 hour') at time zone 'Asia/Riyadh','توريد تاريخي تجريبي'),(lid,'historical_consumption',-r.qty,(r.sale_date::timestamp+interval '21 hour') at time zone 'Asia/Riyadh','استهلاك الوصفات للمبيعات اليومية التجريبية');
insert into public.waste_records(lot_id,quantity,reason,created_at) values(lid,waste,case when r.ingredient_id in(3,8,9) then 'فائض تحضير' else 'فاقد تجهيز' end,(r.sale_date::timestamp+interval '23 hour') at time zone 'Asia/Riyadh') returning id into wid;
insert into public.stock_movements(lot_id,kind,quantity,occurred_at,reference_id,note) values(lid,'waste',-waste,(r.sale_date::timestamp+interval '23 hour') at time zone 'Asia/Riyadh',wid,'هدر تجريبي موثق');
end loop;
-- Current opening stock: short-life components intentionally have lower coverage.
for r in select b.id branch_id,i.*,coalesce((select sum(h.quantity*ri.quantity)/7 from public.sales_history h join public.recipe_versions v on v.meal_id=h.meal_id and v.active join public.recipe_items ri on ri.recipe_id=v.id where h.branch_id=b.id and ri.ingredient_id=i.id and h.sale_date>=current_date-7),0) daily from public.branches b cross join public.ingredients i loop
insert into public.stock_lots(branch_id,ingredient_id,lot_code,received_at,expires_at,unit_cost,supplier) values(r.branch_id,r.id,'OPEN-'||current_date||'-'||r.id,now()-interval '2 hour',now()+make_interval(hours=>case when r.id=3 then 18 when r.id=8 then 30 else r.demo_shelf_days*24 end),r.unit_cost,'مورد تجريبي') returning id into lid;
insert into public.stock_movements(lot_id,kind,quantity,note) values(lid,'receipt',ceil(r.daily*(case when r.id=3 then 0.8 when r.id=8 then 1.1 else 3.5 end)),'رصيد افتتاحي تجريبي');
end loop; end $$;
insert into public.app_metadata values('dataset',jsonb_build_object('synthetic',true,'start',current_date-365,'end',current_date-1,'days',365,'description','بيانات تجريبية مولدة: ملخصات يومية، وليست فواتير POS حقيقية. مدد الصلاحية افتراضات للعرض وليست تعليمات حفظ غذائي.'));
commit;
