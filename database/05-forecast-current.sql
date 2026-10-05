create or replace function public.forecast(p_branch int default null,p_start date default current_date+1,p_days int default 7,p_buffer numeric default 0.1) returns jsonb language plpgsql security invoker set search_path='' as $$
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
