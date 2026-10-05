-- Transactional integration tests: every mutation is rolled back.
begin;
set local role service_role;
do $$
declare before_qty numeric; after_qty numeric; other_qty numeric; request uuid=gen_random_uuid(); result jsonb; order_count int; fail_expected boolean=false; lot uuid; dest uuid; q numeric; x uuid;
begin
select sum(remaining) into before_qty from public.stock_lots where branch_id=1 and ingredient_id=1;
select sum(remaining) into other_qty from public.stock_lots where branch_id=2 and ingredient_id=1;
result=public.place_order(1,'[{"meal_id":1,"quantity":2}]'::jsonb,request);
select sum(remaining) into after_qty from public.stock_lots where branch_id=1 and ingredient_id=1;
assert before_qty-after_qty=300,'Sale did not deduct exactly 300g beef';
assert (select sum(remaining) from public.stock_lots where branch_id=2 and ingredient_id=1)=other_qty,'Other branch changed';
result=public.place_order(1,'[{"meal_id":1,"quantity":2}]'::jsonb,request);
assert (result->>'duplicate')::boolean,'Idempotency failed';
assert (select sum(remaining) from public.stock_lots where branch_id=1 and ingredient_id=1)=after_qty,'Duplicate deducted stock';
select count(*) into order_count from public.sales_orders;
begin perform public.place_order(1,'[{"meal_id":1,"quantity":10000}]',gen_random_uuid()); exception when others then fail_expected=true; end;
assert fail_expected,'Insufficient stock was accepted';
assert (select count(*) from public.sales_orders)=order_count,'Failed order was not rolled back';
assert (select sum(remaining) from public.stock_lots where branch_id=1 and ingredient_id=1)=after_qty,'Failed order changed stock';
lot=public.receive_stock(1,1,2,'kg',now()+interval '10 day','TEST-'||request,'test');
assert (select remaining from public.stock_lots where id=lot)=2000,'kg conversion failed';
perform public.record_waste(lot,100,'اختبار');
assert (select remaining from public.stock_lots where id=lot)=1900,'Waste deduction failed';
perform public.count_stock(lot,1800,'اختبار جرد');
assert (select remaining from public.stock_lots where id=lot)=1800,'Count adjustment failed';
x=public.transfer_stock(lot,2,300);
assert (select remaining from public.stock_lots where id=lot)=1500,'Transfer origin failed';
select to_lot into dest from public.transfers where id=x;
assert (select remaining from public.stock_lots where id=dest)=300,'Transfer destination failed';
assert (select expires_at from public.stock_lots where id=dest)=(select expires_at from public.stock_lots where id=lot),'Transfer changed expiry';
assert jsonb_array_length(public.forecast(1,current_date,7,0.1)->'days')=35,'Forecast row count failed';
assert not exists(select 1 from public.stock_lots l left join (select lot_id,sum(quantity) q from public.stock_movements group by lot_id) m on m.lot_id=l.id where l.remaining<>coalesce(m.q,0)),'Ledger mismatch';
end $$;
select 'PASS: exact recipe deduction, branch isolation, duplicate prevention, atomic rejection, unit conversion, waste, count, transfer, forecast, ledger' as result;
rollback;
