begin;
create table public.branches(id int primary key, name text not null, district text not null);
create table public.ingredients(id int primary key, name text not null, unit text not null check(unit in ('g','ml','piece')), unit_cost numeric(12,5) not null check(unit_cost>=0), pack_size numeric not null check(pack_size>0), lead_days int not null default 1 check(lead_days>=0), demo_shelf_days int not null check(demo_shelf_days>0));
create table public.meals(id int primary key,name text not null,price numeric(10,2) not null check(price>=0));
create table public.recipe_versions(id int primary key,meal_id int not null references public.meals,version int not null,active boolean not null default true,unique(meal_id,version));
create unique index recipe_active on public.recipe_versions(meal_id) where active;
create table public.recipe_items(recipe_id int references public.recipe_versions,ingredient_id int references public.ingredients,quantity numeric(12,3) not null check(quantity>0),primary key(recipe_id,ingredient_id));
create index recipe_ingredient on public.recipe_items(ingredient_id);
create table public.stock_lots(id uuid primary key default gen_random_uuid(),branch_id int not null references public.branches,ingredient_id int not null references public.ingredients,lot_code text not null,received_at timestamptz not null default now(),expires_at timestamptz not null,unit_cost numeric(12,5) not null check(unit_cost>=0),remaining numeric(14,3) not null default 0 check(remaining>=0),supplier text not null default '',unique(branch_id,ingredient_id,lot_code),check(expires_at>received_at));
create index lots_fefo on public.stock_lots(branch_id,ingredient_id,expires_at) where remaining>0;
create index lots_ingredient on public.stock_lots(ingredient_id);
create table public.sales_orders(id uuid primary key default gen_random_uuid(),branch_id int not null references public.branches,request_key uuid not null unique,created_at timestamptz not null default now(),total numeric(12,2) not null default 0,source text not null default 'demo_pos');
create index orders_branch_date on public.sales_orders(branch_id,created_at);
create table public.order_items(id bigint generated always as identity primary key,order_id uuid not null references public.sales_orders,recipe_id int not null references public.recipe_versions,quantity int not null check(quantity between 1 and 10000),unit_price numeric(10,2) not null check(unit_price>=0));
create index items_order on public.order_items(order_id);
create index items_recipe on public.order_items(recipe_id);
create table public.stock_movements(id bigint generated always as identity primary key,lot_id uuid not null references public.stock_lots,kind text not null check(kind in ('receipt','sale','waste','transfer_in','transfer_out','adjustment','historical_consumption')),quantity numeric(14,3) not null check(quantity<>0),occurred_at timestamptz not null default now(),order_id uuid references public.sales_orders,reference_id uuid not null default gen_random_uuid(),note text not null default '',check((kind in ('receipt','transfer_in') and quantity>0) or (kind in ('sale','waste','transfer_out','historical_consumption') and quantity<0) or kind='adjustment'));
create index movements_lot on public.stock_movements(lot_id);
create index movements_date on public.stock_movements(occurred_at,kind);
create index movements_order on public.stock_movements(order_id) where order_id is not null;
create table public.waste_records(id uuid primary key default gen_random_uuid(),lot_id uuid not null references public.stock_lots,quantity numeric not null check(quantity>0),reason text not null,created_at timestamptz not null default now());
create index waste_lot on public.waste_records(lot_id);
create table public.stock_counts(id uuid primary key default gen_random_uuid(),lot_id uuid not null references public.stock_lots,expected numeric not null,actual numeric not null check(actual>=0),reason text not null,created_at timestamptz not null default now());
create index counts_lot on public.stock_counts(lot_id);
create table public.transfers(id uuid primary key default gen_random_uuid(),from_lot uuid not null references public.stock_lots,to_lot uuid not null references public.stock_lots,quantity numeric not null check(quantity>0),created_at timestamptz not null default now());
create index transfers_from on public.transfers(from_lot);
create index transfers_to on public.transfers(to_lot);
create table public.sales_history(branch_id int references public.branches,meal_id int references public.meals,sale_date date not null,quantity int not null check(quantity>=0),revenue numeric(12,2) not null,stockout boolean not null default false,is_synthetic boolean not null default true,primary key(branch_id,meal_id,sale_date));
create index history_meal on public.sales_history(meal_id);
create index history_date on public.sales_history(sale_date);
create table public.purchase_orders(id uuid primary key default gen_random_uuid(),branch_id int not null references public.branches,ingredient_id int not null references public.ingredients,quantity numeric not null check(quantity>0),expected_on date not null,status text not null default 'pending' check(status in ('pending','received','cancelled')),created_at timestamptz not null default now());
create index purchase_branch on public.purchase_orders(branch_id,status);
create index purchase_ingredient on public.purchase_orders(ingredient_id);
create table public.preparation_plans(id uuid primary key default gen_random_uuid(),branch_id int not null references public.branches,meal_id int not null references public.meals,plan_date date not null,quantity int not null check(quantity>=0),created_at timestamptz not null default now(),unique(branch_id,meal_id,plan_date));
create index plans_meal on public.preparation_plans(meal_id);
create table public.forecast_runs(id uuid primary key default gen_random_uuid(),branch_id int references public.branches,start_date date not null,days int not null,buffer numeric not null,method text not null,result jsonb not null,created_at timestamptz not null default now());
create index forecast_branch on public.forecast_runs(branch_id);
create table public.app_metadata(key text primary key,value jsonb not null);

create function public.apply_movement() returns trigger language plpgsql security invoker set search_path='' as $$
begin
 update public.stock_lots set remaining=remaining+new.quantity where id=new.lot_id;
 return new;
end $$;
create trigger movement_balance after insert on public.stock_movements for each row execute function public.apply_movement();
create view public.daily_sales with(security_invoker=true) as
select branch_id,meal_id,sale_date,sum(quantity)::int quantity,sum(revenue) revenue,bool_or(stockout) stockout from (
select branch_id,meal_id,sale_date,quantity,revenue,stockout from public.sales_history
union all
select o.branch_id,r.meal_id,(o.created_at at time zone 'Asia/Riyadh')::date,i.quantity,i.quantity*i.unit_price,false from public.sales_orders o join public.order_items i on i.order_id=o.id join public.recipe_versions r on r.id=i.recipe_id
) s group by branch_id,meal_id,sale_date;

-- Browser clients have no database access. A localhost Node server uses a server-only key.
do $$ declare t record; begin for t in select tablename from pg_tables where schemaname='public' loop
execute format('alter table public.%I enable row level security',t.tablename);
execute format('revoke all on public.%I from anon,authenticated',t.tablename);
execute format('grant all on public.%I to service_role',t.tablename);
end loop; end $$;
revoke all on all sequences in schema public from anon,authenticated;
revoke all on public.daily_sales from anon,authenticated;
grant usage,select on all sequences in schema public to service_role;
grant select on public.daily_sales to service_role;
revoke execute on function public.apply_movement() from public,anon,authenticated;
commit;
