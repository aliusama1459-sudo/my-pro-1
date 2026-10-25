-- Run after access_control.sql to add date-stamped inventory activity.
create table if not exists public.inventory_movements (
  id uuid primary key default gen_random_uuid(),
  ingredient_id uuid references public.ingredients(id) on delete set null,
  item_name text not null,
  unit text not null,
  movement_type text not null check (movement_type in ('opening', 'restock', 'adjustment', 'dispatch')),
  quantity_change numeric(14,3) not null,
  quantity_after numeric(14,3) not null,
  movement_date date not null default current_date,
  note text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists inventory_movements_date_idx on public.inventory_movements(movement_date desc);
create index if not exists inventory_movements_ingredient_date_idx on public.inventory_movements(ingredient_id, movement_date desc);
alter table public.inventory_movements enable row level security;
drop policy if exists "kitchen roles manage inventory movements" on public.inventory_movements;
create policy "kitchen roles manage inventory movements" on public.inventory_movements for all to authenticated using (public.has_kitchen_access()) with check (public.has_kitchen_access());
grant select, insert, update, delete on public.inventory_movements to authenticated;

-- Reconstruct opening balances and dispatch use already recorded before this
-- history table existed, so recent test dispatches still appear in reports.
with used as (
  select di.ingredient_id, d.id as dispatch_id, d.dispatch_code, d.dispatch_date, d.created_at,
         max(di.ingredient_name) as item_name, max(di.unit) as unit, sum(di.quantity_used) as quantity_used
  from public.dispatch_ingredients di join public.dispatches d on d.id = di.dispatch_id
  where di.ingredient_id is not null
  group by di.ingredient_id, d.id, d.dispatch_code, d.dispatch_date, d.created_at
), opening as (
  select i.id, i.name, i.unit, i.created_at,
         i.stock_quantity + coalesce(sum(u.quantity_used), 0) as opening_quantity
  from public.ingredients i left join used u on u.ingredient_id = i.id
  group by i.id
)
insert into public.inventory_movements(ingredient_id, item_name, unit, movement_type, quantity_change, quantity_after, movement_date, note)
select o.id, o.name, o.unit, 'opening', o.opening_quantity, o.opening_quantity,
       timezone('Asia/Karachi', o.created_at)::date, 'Opening balance reconstructed when inventory history was enabled'
from opening o
where o.opening_quantity > 0
  and not exists (select 1 from public.inventory_movements m where m.ingredient_id = o.id);

with used as (
  select di.ingredient_id, d.id as dispatch_id, d.dispatch_code, d.dispatch_date, d.created_at,
         max(di.ingredient_name) as item_name, max(di.unit) as unit, sum(di.quantity_used) as quantity_used
  from public.dispatch_ingredients di join public.dispatches d on d.id = di.dispatch_id
  where di.ingredient_id is not null
  group by di.ingredient_id, d.id, d.dispatch_code, d.dispatch_date, d.created_at
), opening as (
  select i.id, i.stock_quantity + coalesce(sum(u.quantity_used), 0) as opening_quantity
  from public.ingredients i left join used u on u.ingredient_id = i.id group by i.id
), ordered as (
  select u.*, o.opening_quantity,
         o.opening_quantity - sum(u.quantity_used) over (partition by u.ingredient_id order by u.dispatch_date, u.created_at, u.dispatch_id) as after_quantity
  from used u join opening o on o.id = u.ingredient_id
)
insert into public.inventory_movements(ingredient_id, item_name, unit, movement_type, quantity_change, quantity_after, movement_date, note)
select ingredient_id, item_name, unit, 'dispatch', -quantity_used, after_quantity, dispatch_date, 'Kitchen dispatch ' || dispatch_code
from ordered u
where not exists (select 1 from public.inventory_movements m where m.ingredient_id = u.ingredient_id and m.note = 'Kitchen dispatch ' || u.dispatch_code);

create or replace function public.track_ingredient_stock_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  delta numeric(14,3);
  kind text;
  detail text;
begin
  if tg_op = 'INSERT' then
    delta := coalesce(new.stock_quantity, 0);
    if delta <= 0 then return new; end if;
    kind := 'opening';
    detail := 'Opening stock';
  else
    delta := new.stock_quantity - old.stock_quantity;
    if delta = 0 then return new; end if;
    kind := coalesce(nullif(current_setting('app.inventory_movement_type', true), ''), case when delta > 0 then 'restock' else 'adjustment' end);
    detail := coalesce(nullif(current_setting('app.inventory_movement_note', true), ''), case when delta > 0 then 'Stock added' else 'Manual stock adjustment' end);
  end if;
  insert into public.inventory_movements(ingredient_id, item_name, unit, movement_type, quantity_change, quantity_after, movement_date, note)
  values (new.id, new.name, new.unit, kind, delta, new.stock_quantity, case when tg_op = 'INSERT' then timezone('Asia/Karachi', new.created_at)::date else timezone('Asia/Karachi', now())::date end, detail);
  return new;
end;
$$;

drop trigger if exists ingredient_stock_movement on public.ingredients;
create trigger ingredient_stock_movement
after insert or update of stock_quantity on public.ingredients
for each row execute procedure public.track_ingredient_stock_change();

-- Keep dispatch deductions and their inventory-history rows in the same transaction.
create or replace function public.record_kitchen_dispatch(
  p_recipe_id uuid,
  p_branch_name text,
  p_batch_qty numeric,
  p_dispatch_date date default current_date
) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.recipes%rowtype;
  d_id uuid;
  d_code text;
  multiplier numeric;
  portion_count integer;
  total numeric(14,2) := 0;
  line record;
  current_stock numeric;
  used_qty numeric;
  line_total numeric(14,2);
begin
  if auth.uid() is null or not public.has_kitchen_access() then raise exception 'Kitchen access is required to record a dispatch.'; end if;
  if p_batch_qty is null or p_batch_qty <= 0 then raise exception 'Dispatch quantity must be greater than zero.'; end if;
  if coalesce(trim(p_branch_name), '') = '' then raise exception 'Choose a destination branch.'; end if;
  select * into r from public.recipes where id = p_recipe_id;
  if not found then raise exception 'Recipe not found.'; end if;
  multiplier := p_batch_qty / r.batch_qty;
  portion_count := round(r.portions * multiplier)::integer;
  d_code := 'D-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  for line in
    select ri.ingredient_id, ri.quantity, i.name, i.unit, i.unit_price
    from public.recipe_ingredients ri join public.ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id order by ri.ingredient_id for update of i
  loop
    used_qty := line.quantity * multiplier;
    select stock_quantity into current_stock from public.ingredients where id = line.ingredient_id;
    if current_stock < used_qty then raise exception 'Not enough stock for %: need % %, have % %.', line.name, round(used_qty, 3), line.unit, round(current_stock, 3), line.unit; end if;
    total := total + round((used_qty * line.unit_price)::numeric, 2);
  end loop;

  insert into public.dispatches(dispatch_code, recipe_id, recipe_name, branch_name, batch_qty, batch_unit, dispatch_date, portions, total_cost)
  values (d_code, r.id, r.name, trim(p_branch_name), p_batch_qty, r.batch_unit, coalesce(p_dispatch_date, current_date), portion_count, total)
  returning id into d_id;

  perform set_config('app.inventory_movement_type', 'dispatch', true);
  perform set_config('app.inventory_movement_note', 'Kitchen dispatch ' || d_code, true);
  for line in
    select ri.ingredient_id, ri.quantity, i.name, i.unit, i.unit_price
    from public.recipe_ingredients ri join public.ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id order by ri.ingredient_id for update of i
  loop
    used_qty := line.quantity * multiplier;
    line_total := round((used_qty * line.unit_price)::numeric, 2);
    update public.ingredients set stock_quantity = stock_quantity - used_qty where id = line.ingredient_id;
    insert into public.dispatch_ingredients(dispatch_id, ingredient_id, ingredient_name, unit, quantity_used, unit_price, line_cost)
    values (d_id, line.ingredient_id, line.name, line.unit, used_qty, line.unit_price, line_total);
  end loop;
  perform set_config('app.inventory_movement_type', '', true);
  perform set_config('app.inventory_movement_note', '', true);
  return d_id;
end;
$$;

revoke all on function public.record_kitchen_dispatch(uuid, text, numeric, date) from public, anon;
grant execute on function public.record_kitchen_dispatch(uuid, text, numeric, date) to authenticated;
