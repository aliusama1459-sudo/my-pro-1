-- Karachi Nasheman kitchen database. Run once in Supabase → SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.ingredients (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default 'Other',
  unit text not null,
  unit_price numeric(12,2) not null default 0 check (unit_price >= 0),
  stock_quantity numeric(14,3) not null default 0 check (stock_quantity >= 0),
  created_at timestamptz not null default now()
);

create table if not exists public.recipes (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text not null default 'Other',
  batch_qty numeric(12,3) not null check (batch_qty > 0),
  batch_unit text not null default 'kg deg',
  portions integer not null check (portions > 0),
  portion_size numeric(12,3) not null default 300,
  portion_unit text not null default 'g',
  created_at timestamptz not null default now()
);

create table if not exists public.recipe_ingredients (
  id uuid primary key default gen_random_uuid(),
  recipe_id uuid not null references public.recipes(id) on delete cascade,
  ingredient_id uuid not null references public.ingredients(id) on delete restrict,
  quantity numeric(14,3) not null check (quantity > 0),
  unique (recipe_id, ingredient_id)
);

create table if not exists public.dispatches (
  id uuid primary key default gen_random_uuid(),
  dispatch_code text not null unique,
  recipe_id uuid references public.recipes(id) on delete set null,
  recipe_name text not null,
  branch_name text not null,
  batch_qty numeric(12,3) not null check (batch_qty > 0),
  batch_unit text not null,
  dispatch_date date not null default current_date,
  portions integer not null default 0,
  total_cost numeric(14,2) not null default 0,
  status text not null default 'Dispatched',
  created_at timestamptz not null default now()
);

create table if not exists public.dispatch_ingredients (
  id uuid primary key default gen_random_uuid(),
  dispatch_id uuid not null references public.dispatches(id) on delete cascade,
  ingredient_id uuid references public.ingredients(id) on delete set null,
  ingredient_name text not null,
  unit text not null,
  quantity_used numeric(14,3) not null,
  unit_price numeric(12,2) not null,
  line_cost numeric(14,2) not null
);

create index if not exists dispatches_date_idx on public.dispatches(dispatch_date desc);
create index if not exists dispatches_branch_date_idx on public.dispatches(branch_name, dispatch_date desc);
create index if not exists recipe_ingredients_recipe_idx on public.recipe_ingredients(recipe_id);
create index if not exists dispatch_ingredients_dispatch_idx on public.dispatch_ingredients(dispatch_id);

alter table public.ingredients enable row level security;
alter table public.recipes enable row level security;
alter table public.recipe_ingredients enable row level security;
alter table public.dispatches enable row level security;
alter table public.dispatch_ingredients enable row level security;

-- Staff must sign in. These policies deliberately do not expose kitchen data to anonymous visitors.
drop policy if exists "signed in kitchen staff manage ingredients" on public.ingredients;
create policy "signed in kitchen staff manage ingredients" on public.ingredients for all to authenticated using (true) with check (true);
drop policy if exists "signed in kitchen staff manage recipes" on public.recipes;
create policy "signed in kitchen staff manage recipes" on public.recipes for all to authenticated using (true) with check (true);
drop policy if exists "signed in kitchen staff manage recipe ingredients" on public.recipe_ingredients;
create policy "signed in kitchen staff manage recipe ingredients" on public.recipe_ingredients for all to authenticated using (true) with check (true);
drop policy if exists "signed in kitchen staff manage dispatches" on public.dispatches;
create policy "signed in kitchen staff manage dispatches" on public.dispatches for all to authenticated using (true) with check (true);
drop policy if exists "signed in kitchen staff manage dispatch ingredients" on public.dispatch_ingredients;
create policy "signed in kitchen staff manage dispatch ingredients" on public.dispatch_ingredients for all to authenticated using (true) with check (true);

grant select, insert, update, delete on public.ingredients, public.recipes, public.recipe_ingredients, public.dispatches, public.dispatch_ingredients to authenticated;

-- Record the dispatch, take a row lock on each stock item, and deduct all ingredients atomically.
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
  if auth.uid() is null then raise exception 'Sign in is required to record a dispatch.'; end if;
  if p_batch_qty is null or p_batch_qty <= 0 then raise exception 'Dispatch quantity must be greater than zero.'; end if;
  if coalesce(trim(p_branch_name), '') = '' then raise exception 'Choose a destination branch.'; end if;

  select * into r from public.recipes where id = p_recipe_id;
  if not found then raise exception 'Recipe not found.'; end if;
  multiplier := p_batch_qty / r.batch_qty;
  portion_count := round(r.portions * multiplier)::integer;
  d_code := 'D-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

  -- Lock ingredient rows in stable ID order so simultaneous dispatches cannot overspend stock.
  for line in
    select ri.ingredient_id, ri.quantity, i.name, i.unit, i.unit_price
    from public.recipe_ingredients ri
    join public.ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id
    order by ri.ingredient_id
    for update of i
  loop
    used_qty := line.quantity * multiplier;
    select stock_quantity into current_stock from public.ingredients where id = line.ingredient_id;
    if current_stock < used_qty then
      raise exception 'Not enough stock for %: need % %, have % %.', line.name, round(used_qty, 3), line.unit, round(current_stock, 3), line.unit;
    end if;
    line_total := round((used_qty * line.unit_price)::numeric, 2);
    total := total + line_total;
  end loop;

  insert into public.dispatches(dispatch_code, recipe_id, recipe_name, branch_name, batch_qty, batch_unit, dispatch_date, portions, total_cost)
  values (d_code, r.id, r.name, trim(p_branch_name), p_batch_qty, r.batch_unit, coalesce(p_dispatch_date, current_date), portion_count, total)
  returning id into d_id;

  for line in
    select ri.ingredient_id, ri.quantity, i.name, i.unit, i.unit_price
    from public.recipe_ingredients ri
    join public.ingredients i on i.id = ri.ingredient_id
    where ri.recipe_id = p_recipe_id
    order by ri.ingredient_id
    for update of i
  loop
    used_qty := line.quantity * multiplier;
    line_total := round((used_qty * line.unit_price)::numeric, 2);
    update public.ingredients set stock_quantity = stock_quantity - used_qty where id = line.ingredient_id;
    insert into public.dispatch_ingredients(dispatch_id, ingredient_id, ingredient_name, unit, quantity_used, unit_price, line_cost)
    values (d_id, line.ingredient_id, line.name, line.unit, used_qty, line.unit_price, line_total);
  end loop;
  return d_id;
end;
$$;

revoke all on function public.record_kitchen_dispatch(uuid, text, numeric, date) from public, anon;
grant execute on function public.record_kitchen_dispatch(uuid, text, numeric, date) to authenticated;
